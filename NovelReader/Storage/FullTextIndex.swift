import Foundation
import GRDB

/// Turning what a reader typed into something FTS5 will accept.
///
/// Everything typed into the library's search field is a string to look for, never an
/// expression: a reader searching 「"不要" OR 走」 wants those nine characters, and FTS5's
/// query language would read three of them as syntax and the rest as a boolean. So
/// nothing the reader types is ever handed to the parser as-is.
///
/// What it is handed instead is the query's own trigrams, ANDed together — *not* a
/// phrase. The index is declared `detail=none`, which stores no token positions, and
/// FTS5 answers a phrase query against such a table with an error rather than degrading
/// to a conjunction: "fts5: phrase queries are not supported (detail!=full)". Positions
/// are what a phrase needs and are also the bulk of the index — dropping them halves it
/// (measured: 0.6× the stored text instead of 1.2×), which on a library of a few
/// thousand downloaded chapters is tens of megabytes of someone's phone.
///
/// The price is that a conjunction is weaker than a phrase: it finds chapters holding
/// all of the query's trigrams, which need not be adjacent, so 「玄重尺的劍」 can bring
/// back a chapter where those three trigrams are scattered. That costs nothing here,
/// because this is only the first of two passes — every candidate is opened and read
/// through `FullTextExcerpt`, which finds the run or drops the result. The direction of
/// the error is what makes this safe: overlapping trigrams mean a chapter that really
/// contains the phrase always contains every one of them, so the filter can waste a file
/// read but can never lose a hit.
enum FullTextQuery {
    /// The shortest query the index can answer. Below this the tokenizer produces no
    /// tokens at all, so the match would be empty rather than wrong — see
    /// `SQLiteTrigramCapabilityTests`, which pins that floor as a property of the
    /// platform rather than a bug to fix.
    ///
    /// Not a floor the *reader* ever meets, though: a shorter query goes to
    /// `likePattern` and is scanned for instead. This names where the index stops being
    /// usable, not where searching stops.
    static let minimumLength = 3

    /// The query's overlapping trigrams as an FTS5 conjunction, or nil for a query too
    /// short to have one.
    ///
    /// Folded first, and that is not optional: the index holds folded text, so trigrams
    /// cut from the query as typed would be looked up in a script the index does not
    /// store, and every cross-script search would quietly return nothing. Folding here
    /// rather than at the call site is what makes that impossible to forget — the same
    /// reason `likePattern` folds.
    ///
    /// Split by Unicode scalar rather than by `Character`, because that is what SQLite's
    /// trigram tokenizer counts: a token is three code points, and grouping a combining
    /// sequence into one `Character` here would build tokens the index has never seen.
    ///
    /// Each trigram is quoted separately — the escape is per token now, not around the
    /// whole query, since the whole query is no longer one thing the parser sees.
    static func matchExpression(for query: String) -> String? {
        let scalars = Array(folded(query).unicodeScalars)
        guard scalars.count >= minimumLength else { return nil }
        return (0...(scalars.count - minimumLength))
            .map { start in
                let token = String(
                    String.UnicodeScalarView(scalars[start ..< start + minimumLength])
                )
                return "\"" + token.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            .joined(separator: " AND ")
    }

    /// The query as a `LIKE` pattern over the stored text, for the searches trigram
    /// cannot answer.
    ///
    /// Two characters is the most ordinary search a Chinese reader makes — 蕭炎, 唐三,
    /// 林動 are how people look for a person — and trigram has no token that short, so
    /// the index simply cannot be asked. Rather than telling a reader their own
    /// character's name is too short to search for, these run as a scan of the same
    /// column the index is built over, which is already folded and therefore already
    /// answers both scripts.
    ///
    /// A scan is affordable here in a way it would not be as the general answer. Measured
    /// over the stored text of a large offline library, on a warm and a cold page cache
    /// alike: 17 ms at 3,000 downloaded chapters, 70 ms at 10,000. The index answers the
    /// same shape of question in 0.04 ms — some four hundred times faster — which is why
    /// this is the exception and not the rule: every query long enough to have a trigram
    /// goes to the index, and only the two-character floor falls through to here.
    ///
    /// `%` and `_` in what the reader typed are escaped, not honoured. Someone searching
    /// for 「100%」 means those four characters; left alone, the `%` would match the rest
    /// of the chapter and the search would answer with every chapter containing "100".
    /// The backslash goes first, or it would escape the escapes added after it. Pair with
    /// `LIKE ? ESCAPE '\'` — SQLite has no default escape character, so the clause is not
    /// optional.
    static func likePattern(for query: String) -> String {
        let escaped = folded(query)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%" + escaped + "%"
    }

    /// The one form both scripts are written down as.
    ///
    /// A reader in Taiwan searching 「鬥破蒼穹」 must find the chapter a simplified site
    /// served, and vice versa — the library holds books from both. `ChineseVariants`
    /// answers this for *site* search by sending the query twice, but an index can do
    /// better: fold both scripts onto one at write time and the question disappears,
    /// at the cost of nothing, since the index is never shown to anybody.
    ///
    /// Character-level (ICU) rather than `ChineseText`'s phrase tier on purpose. This
    /// has to map a query and a chapter onto the *same* string without either of them
    /// seeing the other, and only a per-character map does that: a dictionary that reads
    /// 「斗羅大陸」 as a title in the chapter and 「羅大」 as two characters in the query
    /// would fold them differently and the search would miss. It also keeps offsets
    /// intact, which is what lets a hit found in the folded text be sliced out of the
    /// original for display.
    ///
    /// Simplified is the direction because simplification merges: several traditional
    /// characters share one simplified form, so folding that way is total, where folding
    /// the other way has to guess which 「發」 a 「发」 is.
    static func folded(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: ChineseText.isHan) else { return text }
        let mutable = NSMutableString(string: text)
        guard CFStringTransform(mutable, nil, "Traditional-Simplified" as CFString, false) else {
            return text
        }
        let folded = mutable as String
        // A conversion that changed the length cannot be used to locate anything: the
        // offsets a hit is sliced at would name different characters in the original.
        // Leaving such a paragraph in its own script costs one missed cross-script match;
        // taking it would misquote every hit in it.
        return folded.utf16.count == text.utf16.count ? folded : text
    }
}

/// The searchable copy of the chapters on this device.
///
/// A thin thing on purpose: the schema, its triggers and `Chapter.downloadedAt` between
/// them do most of the work, and what is left here is writing a chapter in, taking one
/// out, and asking which chapters are worth opening. It holds no state.
///
/// What it deliberately does *not* do is decide whether a hit is real. It answers with
/// candidates — chapters whose stored text holds all of the query's trigrams — and
/// `LibrarySearch` opens each one to find the passage or drop it. Two passes, because
/// the index is folded into one script and flattened into one string, and neither of
/// those is what the reader should be shown.
enum FullTextIndex {
    /// Writes one chapter's text into the searchable copy, replacing whatever was there.
    ///
    /// Takes a `Database` rather than opening its own transaction, so a caller can land
    /// this and the `downloadedAt` flag together. That matters: the flag is the app's
    /// definition of "there is a chapter here to read", and a search that could see a
    /// chapter the flag had not admitted to yet would be offering text nothing else in
    /// the app believes exists.
    ///
    /// The paragraphs are joined the way the file stores them, and folded the way every
    /// query will be. `ON CONFLICT` rather than delete-then-insert because the update
    /// trigger already spells out that pairing, and doing it twice would take the row's
    /// tokens out of the index and put them back for no reason.
    static func write(paragraphs: [String], chapterId: String, in db: Database) throws {
        let folded = FullTextQuery.folded(paragraphs.joined(separator: "\n"))
        try db.execute(
            sql: """
                INSERT INTO "chapterText" ("chapterId", "text") VALUES (?, ?)
                ON CONFLICT("chapterId") DO UPDATE SET "text" = excluded."text"
                """,
            arguments: [chapterId, folded]
        )
    }

    /// Drops the searchable text for everything a delete scope covers.
    ///
    /// The `IN (SELECT …)` shapes mirror `DownloadStore.clearFlags` exactly, because they
    /// are answering the same question about the same rows and two different readings of
    /// "this site's chapters" is how the two would drift. The index itself is not touched
    /// here — the delete trigger does that, once, wherever the row goes from.
    static func forget(_ scope: DownloadStore.Scope, in db: Database) throws {
        switch scope {
        case let .chapter(book, siteChapterId):
            try db.execute(
                sql: #"DELETE FROM "chapterText" WHERE "chapterId" = ?"#,
                arguments: [Chapter.makeId(bookId: book.id, siteChapterId: siteChapterId)]
            )
        case let .book(book):
            try db.execute(
                sql: """
                    DELETE FROM "chapterText" WHERE "chapterId" IN
                        (SELECT "id" FROM "chapter" WHERE "bookId" = ?)
                    """,
                arguments: [book.id]
            )
        case let .site(siteId):
            try db.execute(
                sql: """
                    DELETE FROM "chapterText" WHERE "chapterId" IN
                        (SELECT "chapter"."id" FROM "chapter"
                         JOIN "book" ON "book"."id" = "chapter"."bookId"
                         WHERE "book"."siteId" = ?)
                    """,
                arguments: [siteId]
            )
        case .everything:
            try db.execute(sql: #"DELETE FROM "chapterText""#)
        }
    }

    /// A downloaded chapter that has never been read into the index.
    ///
    /// What the backfill walks. Comics are excluded by kind rather than discovered to be
    /// textless when the read fails: a comic chapter is a directory of pictures, it will
    /// never have a paragraph in it, and asking the file store every launch would be a
    /// wasted directory read per chapter for ever.
    struct Pending: FetchableRecord, Decodable {
        var chapterId: String
        var siteId: String
        var siteBookId: String
        var siteChapterId: String
    }

    /// Chapters this device has the text of but the index does not, oldest first.
    ///
    /// The whole reason there is a backfill at all: the text lives in files, and a
    /// database migration cannot reach a file. So an upgrade arrives with an empty index
    /// over a full library, and this is what closes that gap — in bounded batches,
    /// because a reader with four hundred downloaded chapters should not meet a launch
    /// that reads four hundred files before it draws anything.
    static func pending(limit: Int, in db: Database) throws -> [Pending] {
        try Pending.fetchAll(
            db,
            sql: """
                SELECT "chapter"."id" AS "chapterId", "book"."siteId" AS "siteId",
                       "book"."siteBookId" AS "siteBookId",
                       "chapter"."siteChapterId" AS "siteChapterId"
                FROM "chapter"
                JOIN "book" ON "book"."id" = "chapter"."bookId"
                LEFT JOIN "chapterText" ON "chapterText"."chapterId" = "chapter"."id"
                WHERE "chapter"."downloadedAt" IS NOT NULL
                  AND "chapterText"."id" IS NULL
                  AND "book"."kind" <> 'comic'
                ORDER BY "chapter"."downloadedAt"
                LIMIT ?
                """,
            arguments: [limit]
        )
    }

    /// One chapter worth opening to look for the passage.
    struct Candidate: FetchableRecord, Decodable {
        var bookId: String
        var siteChapterId: String
        var title: String
        var index: Int
    }

    /// The chapters whose stored text might hold `query`, in reading order within a book.
    ///
    /// The join onto `chapter` is what makes a stale index harmless rather than dangerous.
    /// All four delete levels clear `downloadedAt`, and an inner join drops a chapter whose
    /// row has gone entirely — so a result can only ever name a chapter this device still
    /// has the file for. That is the guarantee, and it does not depend on the index having
    /// been cleaned up correctly; the cleanup is about reclaiming space.
    ///
    /// Two paths because the index has a floor. Anything with a trigram in it goes to
    /// FTS5; a two-character query — the most ordinary way to look for a person — has no
    /// token the index could hold, so it is scanned for instead. Measured at 17 ms over a
    /// 3,000-chapter library against the index's 0.04 ms, which is exactly why the scan is
    /// the exception rather than the design.
    static func candidates(for query: String, limit: Int, in db: Database) throws -> [Candidate] {
        let selection = """
            SELECT "chapter"."bookId" AS "bookId",
                   "chapter"."siteChapterId" AS "siteChapterId",
                   "chapter"."title" AS "title", "chapter"."index" AS "index"
            """
        let ordering = #"ORDER BY "chapter"."bookId", "chapter"."index" LIMIT ?"#
        if let expression = FullTextQuery.matchExpression(for: query) {
            return try Candidate.fetchAll(
                db,
                sql: """
                    \(selection)
                    FROM "chapterTextIndex"
                    JOIN "chapterText" ON "chapterText"."id" = "chapterTextIndex"."rowid"
                    JOIN "chapter" ON "chapter"."id" = "chapterText"."chapterId"
                    WHERE "chapterTextIndex" MATCH ?
                      AND "chapter"."downloadedAt" IS NOT NULL
                    \(ordering)
                    """,
                arguments: [expression, limit]
            )
        }
        return try Candidate.fetchAll(
            db,
            sql: """
                \(selection)
                FROM "chapterText"
                JOIN "chapter" ON "chapter"."id" = "chapterText"."chapterId"
                WHERE "chapterText"."text" LIKE ? ESCAPE '\\'
                  AND "chapter"."downloadedAt" IS NOT NULL
                \(ordering)
                """,
            arguments: [FullTextQuery.likePattern(for: query), limit]
        )
    }
}

/// Where in a chapter a hit actually sits, and enough of the text around it to
/// recognise.
///
/// The index can only say *which chapter* — it holds one row per chapter, folded into one
/// script, and a chapter is four thousand characters of which the reader wants to see
/// twenty. So the hit is located a second time, in the chapter's own paragraphs as they
/// sit on disk, and that second pass is what produces both the quotation and the place to
/// jump to.
///
/// Doing it against the file rather than against anything stored beside the index is
/// deliberate. It reads the text the reader would actually see — their own script, their
/// own paragraph breaks — and it is the same array `ReaderView.storedParagraphs` loads, so
/// the paragraph number found here is the one the reader's anchor means. It also fails in
/// the right direction: a chapter whose file is gone yields no excerpt, and a result with
/// nothing behind it is better dropped than offered.
struct FullTextExcerpt: Equatable {
    /// Which paragraph of the chapter, indexed as `ChapterFileStore.readParagraphs`
    /// returns them — which is what `TextAnchor.paragraph` counts.
    let paragraph: Int
    /// Where in that paragraph, in UTF-16 code units: `TextAnchor.characterOffset`'s unit.
    let characterOffset: Int
    /// The quotation, in the script the chapter is stored in, elided at each end that
    /// was cut.
    let text: String
    /// Where the searched-for run sits inside `text`, so the row can pick it out. Found
    /// here rather than by the view searching `text` again, because the two need not be
    /// in the same script — a traditional query matches a simplified chapter through the
    /// fold, and searching the quotation for the query as typed would find nothing.
    let match: Range<String.Index>

    /// How much of the surrounding sentence to carry, in characters either side.
    ///
    /// Enough to place the hit in its sentence and not enough to wrap past two lines on a
    /// phone: the row is a list item, and a reader scanning twenty of them is reading the
    /// shape of the sentence, not the paragraph.
    static let context = 24

    /// The first place `query` occurs in these paragraphs, or nil if it does not.
    ///
    /// Both sides are folded before comparing, which is the whole of the cross-script
    /// answer — and it is safe to carry the offsets back to the original because
    /// `FullTextQuery.folded` never changes a string's UTF-16 length.
    ///
    /// First rather than every occurrence: one chapter is one row in the result list, and
    /// the question a reader is asking — which chapter was that in — is answered by the
    /// first one. Listing all of them would bury the other books.
    static func first(of query: String, in paragraphs: [String]) -> FullTextExcerpt? {
        let needle = FullTextQuery.folded(query)
        guard !needle.isEmpty else { return nil }
        for (index, paragraph) in paragraphs.enumerated() {
            let foldedParagraph = FullTextQuery.folded(paragraph)
            guard let found = foldedParagraph.range(of: needle) else { continue }
            // A paragraph whose offsets will not carry across is skipped rather than
            // returned from: another paragraph of the same chapter may hold the same
            // words and quote cleanly, and the chapter is only given up on once none of
            // them does.
            guard let excerpt = excerpt(
                at: found, in: foldedParagraph, of: paragraph, paragraph: index
            ) else { continue }
            return excerpt
        }
        return nil
    }

    /// Slices the original paragraph at offsets found in its folded twin, or nil where
    /// those offsets do not describe the original.
    ///
    /// The window is measured in `Character`s while the anchor is measured in UTF-16,
    /// because they answer to different readers: the window is what a person sees and
    /// should not cut a grapheme in half, and the anchor is what the text engine takes.
    ///
    /// The boundary check is the one thing standing between a search and a crash.
    /// `FullTextQuery.folded` promises the *total* UTF-16 length is unchanged, which is
    /// not the same as promising each character keeps its width: a transform that turned
    /// one surrogate pair into two BMP characters would satisfy the length check and
    /// still move every boundary after it. Slicing a `String` at an index inside a
    /// surrogate pair traps, so a hit whose offsets do not land on real character
    /// boundaries is given up on instead. Nobody has ever produced such a pair out of
    /// `Traditional-Simplified` — but losing one result is a thing a reader shrugs at,
    /// and the app dying because they searched for something is not.
    private static func excerpt(
        at found: Range<String.Index>, in foldedText: String, of original: String, paragraph: Int
    ) -> FullTextExcerpt? {
        let startOffset = found.lowerBound.utf16Offset(in: foldedText)
        let endOffset = found.upperBound.utf16Offset(in: foldedText)
        let units = original.utf16
        guard let lowerUnit = units.index(
                  units.startIndex, offsetBy: startOffset, limitedBy: units.endIndex
              ),
              let upperUnit = units.index(
                  units.startIndex, offsetBy: endOffset, limitedBy: units.endIndex
              ),
              let lower = lowerUnit.samePosition(in: original),
              let upper = upperUnit.samePosition(in: original)
        else { return nil }

        let head = original.index(lower, offsetBy: -context, limitedBy: original.startIndex)
            ?? original.startIndex
        let tail = original.index(upper, offsetBy: context, limitedBy: original.endIndex)
            ?? original.endIndex
        // The ellipsis says the sentence carries on, which is the difference between a
        // quotation that looks truncated and one that looks like the whole paragraph.
        let leading = head > original.startIndex ? "…" : ""
        let trailing = tail < original.endIndex ? "…" : ""
        let body = String(original[head..<tail])
        let text = leading + body + trailing

        // Re-measured against the assembled string rather than carried across: the
        // leading ellipsis moved everything along by one character.
        let matchStart = text.index(
            text.startIndex, offsetBy: leading.count + original.distance(from: head, to: lower)
        )
        let matchEnd = text.index(matchStart, offsetBy: original.distance(from: lower, to: upper))

        return FullTextExcerpt(
            paragraph: paragraph,
            characterOffset: startOffset,
            text: text,
            match: matchStart..<matchEnd
        )
    }
}
