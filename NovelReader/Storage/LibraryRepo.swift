import Foundation
import GRDB

/// Bookmarks and chapter indexes.
struct LibraryRepo {
    let database: AppDatabase

    private var writer: any DatabaseWriter { database.writer }

    // MARK: - Bookmarks

    /// Adds a bookmark, or refreshes the site-provided fields of an existing one.
    /// A re-bookmark must never clobber the user's custom name or reading
    /// position — those are theirs, not the site's.
    ///
    /// - Parameter kind: what the source publishes, taken from its rule. Defaulted
    ///   because the callers that pass nothing are the ones that could not be anything
    ///   else — a book imported from a text file on this device, and the demo shelf. The
    ///   one caller holding a rule passes `rule.kind`, and an incoming iCloud record
    ///   passes the kind it travelled with.
    ///
    ///   Refreshed on an existing row like the title, because it is the source's to say
    ///   in the same way: a rule corrected from novel to comic has to be able to put its
    ///   book right, and re-adding the book is the gesture a reader would make to do it.
    @discardableResult
    func bookmark(
        siteId: String,
        siteBookId: String,
        kind: SiteRule.Kind = .novel,
        title: String,
        author: String? = nil,
        coverURL: String? = nil,
        now: Date = Date()
    ) throws -> Book {
        try writer.write { db in
            let id = Book.makeId(siteId: siteId, siteBookId: siteBookId)
            if var existing = try Book.fetchOne(db, key: id) {
                existing.kind = kind
                existing.title = title
                existing.author = author ?? existing.author
                existing.coverURL = coverURL ?? existing.coverURL
                existing.updatedAt = now
                try existing.update(db)
                return existing
            }
            let book = Book(
                id: id, siteId: siteId, siteBookId: siteBookId, kind: kind, title: title,
                displayName: nil, author: author, coverURL: coverURL,
                addedAt: now, updatedAt: now,
                lastReadSiteChapterId: nil, lastReadParagraph: nil,
                lastReadCharacterOffset: nil, lastReadFraction: nil,
                lastReadAt: nil, catalogUpdatedAt: nil
            )
            try book.insert(db)
            return book
        }
    }

    /// Requirement 3.1. Chapter rows cascade; downloaded files are the caller's
    /// job via `DownloadStore` so file and database work stay in one place.
    func removeBookmark(bookId: String) throws {
        _ = try writer.write { db in try Book.deleteOne(db, key: bookId) }
    }

    /// Requirement 3.2. An empty or whitespace-only name resets to the site title
    /// rather than storing a blank the library would render as an empty row.
    func rename(bookId: String, to newName: String?, now: Date = Date()) throws {
        try writer.write { db in
            guard var book = try Book.fetchOne(db, key: bookId) else { return }
            let trimmed = newName?.trimmingCharacters(in: .whitespacesAndNewlines)
            book.displayName = (trimmed?.isEmpty == false) ? trimmed : nil
            book.updatedAt = now
            try book.update(db)
        }
    }

    func books(siteId: String) throws -> [Book] {
        try writer.read { db in
            try Book.filter(Column("siteId") == siteId)
                .order(Column("addedAt").desc)
                .fetchAll(db)
        }
    }

    func allBooks() throws -> [Book] {
        try writer.read { db in try Book.order(Column("addedAt").desc).fetchAll(db) }
    }

    func book(id: String) throws -> Book? {
        try writer.read { db in try Book.fetchOne(db, key: id) }
    }

    /// - Parameter fraction: how far into that chapter the anchor sits, when the caller
    ///   had the text to measure it against. Nil writes nil rather than keeping the
    ///   previous number: a share left over from the last chapter would be read as
    ///   belonging to this one. The only caller with no text is an incoming iCloud
    ///   record, and the device that owns the position re-publishes the share with it.
    ///
    /// The one writer of `lastReadAt`, because it is the one place a reading position
    /// is recorded: anything else that stamped it would be claiming the book was read
    /// when it was only renamed. An incoming iCloud record passes `now` as the time
    /// the *other* device wrote it, so a book read on the iPad this morning lands in
    /// the history where it belongs rather than at the moment the sync arrived.
    func updateProgress(
        bookId: String,
        position: ReadingPosition,
        fraction: Double? = nil,
        now: Date = Date()
    ) throws {
        try writer.write { db in
            guard var book = try Book.fetchOne(db, key: bookId) else { return }
            book.lastReadSiteChapterId = position.siteChapterId
            book.lastReadParagraph = position.anchor.paragraph
            book.lastReadCharacterOffset = position.anchor.characterOffset
            book.lastReadFraction = fraction
            book.lastReadAt = now
            book.updatedAt = now
            try book.update(db)
        }
    }

    // MARK: - Reading history

    /// The books the reader has been in, newest first, and enough about where each
    /// one stopped to draw a row without opening it.
    ///
    /// One query for the whole screen, joined rather than looked up per book, for the
    /// reason `newChapterCounts` gives: this feeds a list, and a per-book lookup would
    /// be a query per row on every reload. The join is the reading position — the book
    /// stores *which* chapter, and only that chapter's own row knows its title and its
    /// number — so a book whose chapter the site has since dropped comes back with
    /// nulls and still appears, which is the honest answer for "you read this, and the
    /// place is gone".
    ///
    /// `lastReadAt` is the gate as well as the order: a book that has never been opened
    /// has no business in a reading history, and one whose history was cleared has been
    /// taken out of it on purpose.
    ///
    /// The id breaks ties the same way `LibrarySort.recentlyRead` breaks them, so the
    /// two orderings of the same column cannot disagree — even in the case neither of
    /// them can really reach, two positions recorded in the same millisecond.
    func recentlyRead(limit: Int) throws -> [RecentRead] {
        guard limit > 0 else { return [] }
        return try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT book.*,
                       lastRead."title" AS lastReadChapterTitle,
                       lastRead."index" AS lastReadChapterIndex,
                       (SELECT COUNT(*) FROM chapter WHERE chapter."bookId" = book."id")
                           AS chapterCount
                FROM book
                LEFT JOIN chapter AS lastRead
                       ON lastRead."bookId" = book."id"
                      AND lastRead."siteChapterId" = book."lastReadSiteChapterId"
                WHERE book."lastReadAt" IS NOT NULL
                ORDER BY book."lastReadAt" DESC, book."id" DESC
                LIMIT ?
                """, arguments: [limit])
            .map { row in
                RecentRead(
                    book: try Book(row: row),
                    chapterTitle: row["lastReadChapterTitle"],
                    chapterIndex: row["lastReadChapterIndex"],
                    chapterCount: row["chapterCount"]
                )
            }
        }
    }

    /// Forgets when every book was last read, and nothing else.
    ///
    /// The positions themselves stay: "clear my recent reading" is about the list on
    /// screen, and dropping where the reader had got to in a dozen novels to satisfy
    /// it would be answering a much larger question than the one asked.
    ///
    /// `updatedAt` is deliberately not bumped. It is what iCloud merges on, so
    /// stamping it here would push a "newer" record at every other device and have
    /// them re-pull rows that did not change.
    func clearReadingHistory() throws {
        try writer.write { db in
            try db.execute(sql: #"UPDATE "book" SET "lastReadAt" = NULL"#)
        }
    }

    // MARK: - Saved positions

    /// Saves a position, or hands back the bookmark already sitting on it.
    ///
    /// Idempotent because the row id *is* the position (`ReadingBookmark.makeId`):
    /// the reader's one bookmark button has to be safe to tap on a page that is
    /// already saved. An existing bookmark keeps its original excerpt and timestamp
    /// — it recorded the text as the reader saw it, and re-stamping it would move a
    /// row the reader never asked to touch.
    @discardableResult
    func addReadingBookmark(
        bookId: String,
        position: ReadingPosition,
        excerpt: String? = nil,
        now: Date = Date()
    ) throws -> ReadingBookmark {
        try writer.write { db in
            let id = ReadingBookmark.makeId(bookId: bookId, position: position)
            if let existing = try ReadingBookmark.fetchOne(db, key: id) { return existing }
            let bookmark = ReadingBookmark(
                bookId: bookId, position: position, createdAt: now, excerpt: excerpt
            )
            try bookmark.insert(db)
            return bookmark
        }
    }

    func removeReadingBookmark(id: String) throws {
        _ = try writer.write { db in try ReadingBookmark.deleteOne(db, key: id) }
    }

    /// In reading order rather than by creation time: this list exists to jump back
    /// into the book, and one that runs the same way as the book is the one a reader
    /// can find a place in.
    ///
    /// Reading order comes from the catalog, which is why this joins: a bookmark stores
    /// *which* chapter it is in, and only the chapter row knows what number that is
    /// today. A bookmark whose chapter the site has since dropped cannot be placed in
    /// the book, so it cannot be placed in the list either — those sort last, where they
    /// stay readable and deletable without pushing anything else out of order.
    func readingBookmarks(bookId: String) throws -> [ReadingBookmark] {
        try writer.read { db in
            try ReadingBookmark.fetchAll(db, sql: """
                SELECT "readingBookmark".*
                FROM "readingBookmark"
                LEFT JOIN "chapter"
                       ON "chapter"."bookId" = "readingBookmark"."bookId"
                      AND "chapter"."siteChapterId" = "readingBookmark"."siteChapterId"
                WHERE "readingBookmark"."bookId" = ?
                ORDER BY "chapter"."index" IS NULL, "chapter"."index",
                         "readingBookmark"."paragraph", "readingBookmark"."characterOffset"
                """, arguments: [bookId])
        }
    }

    // MARK: - Highlights

    /// Marks a passage, or hands back the highlight already on it.
    ///
    /// Idempotent for the same reason `addReadingBookmark` is: the row id *is* the span
    /// (`TextHighlight.makeId`). Marking a sentence that is already marked is a gesture
    /// a reader will make by accident, and it has to be a no-op rather than a second
    /// invisible row underneath the first.
    @discardableResult
    func addHighlight(
        bookId: String,
        siteChapterId: String,
        selection: TextSelection,
        now: Date = Date()
    ) throws -> TextHighlight {
        try writer.write { db in
            let id = TextHighlight.makeId(
                bookId: bookId, siteChapterId: siteChapterId, selection: selection
            )
            if let existing = try TextHighlight.fetchOne(db, key: id) { return existing }
            let highlight = TextHighlight(
                bookId: bookId, siteChapterId: siteChapterId, selection: selection, createdAt: now
            )
            try highlight.insert(db)
            return highlight
        }
    }

    func removeHighlight(id: String) throws {
        _ = try writer.write { db in try TextHighlight.deleteOne(db, key: id) }
    }

    /// In reading order, like the saved positions: the list runs the way the book runs,
    /// which is the only order a reader can find a passage in. It joins the catalog for
    /// that order, and puts what it cannot place last, for the reasons on
    /// `readingBookmarks`.
    func highlights(bookId: String) throws -> [TextHighlight] {
        try writer.read { db in
            try TextHighlight.fetchAll(db, sql: """
                SELECT "textHighlight".*
                FROM "textHighlight"
                LEFT JOIN "chapter"
                       ON "chapter"."bookId" = "textHighlight"."bookId"
                      AND "chapter"."siteChapterId" = "textHighlight"."siteChapterId"
                WHERE "textHighlight"."bookId" = ?
                ORDER BY "chapter"."index" IS NULL, "chapter"."index",
                         "textHighlight"."startParagraph", "textHighlight"."startCharacterOffset"
                """, arguments: [bookId])
        }
    }

    // MARK: - Chapter index

    /// Replaces a book's catalog with a freshly fetched one.
    ///
    /// Rows are upserted and stale ones removed rather than the table being
    /// wiped and refilled, so `downloadedAt` survives a catalog refresh — losing
    /// it would make every already-downloaded chapter look missing.
    ///
    /// A chapter absent from the previous catalog is stamped `addedAt`, which is
    /// what the red "new" marker reads. The diff lives here rather than in the
    /// caller because only this transaction knows which ids were already stored,
    /// and because `catalogUpdatedAt` — the thing that says whether there *was* a
    /// previous catalog — is written by the same write.
    func replaceCatalog(
        bookId: String,
        entries: [(siteChapterId: String, title: String, url: String)],
        now: Date = Date()
    ) throws {
        try writer.write { db in
            let keptIds = Set(entries.map { Chapter.makeId(bookId: bookId, siteChapterId: $0.siteChapterId) })
            let stored = try Book.fetchOne(db, key: bookId)
            // Nothing is new on the first fetch: a book whose every chapter is
            // flagged is a book with no flags worth reading.
            let isFirstCatalog = stored?.catalogUpdatedAt == nil

            // Every number below is about to be reassigned, and `chapter_book_index` is
            // unique and checked row by row: giving chapter 3 its new index while the
            // chapter that currently holds that index is still waiting its turn fails the
            // whole write. Which is to say a catalog could only ever be *appended* to —
            // one inserted or withdrawn chapter and the refresh threw, silently for the
            // background one, leaving the book stuck on the catalog it already had.
            //
            // Parking the current numbering in the negative range clears the way: the
            // mapping is injective, so the unique index stays satisfied throughout, and
            // nothing non-negative is left for a new number to collide with. Rows that
            // are gone from the catalog keep their parked number until they are deleted
            // below; nothing reads a chapter index inside this transaction.
            try db.execute(
                sql: #"UPDATE "chapter" SET "index" = -1 - "index" WHERE "bookId" = ?"#,
                arguments: [bookId]
            )

            for (index, entry) in entries.enumerated() {
                let id = Chapter.makeId(bookId: bookId, siteChapterId: entry.siteChapterId)
                if var existing = try Chapter.fetchOne(db, key: id) {
                    existing.index = index
                    // The stored name wins when it is this one made whole: a chapter
                    // read once carries the full title its own page gave it (see
                    // `BookService.fetchParagraphs`), and a refresh must not put the
                    // catalog's truncation back over it every time it runs.
                    existing.title =
                        Chapter.fullerTitle(existing.title, extending: entry.title) ?? entry.title
                    existing.url = entry.url
                    // `addedAt` is intentionally not touched: rewriting it every
                    // refresh would either clear the marker the reader has not
                    // seen yet or re-raise it daily on chapters they have read.
                    try existing.update(db)
                } else {
                    try Chapter(
                        id: id, bookId: bookId, siteChapterId: entry.siteChapterId,
                        index: index, title: entry.title, url: entry.url,
                        addedAt: isFirstCatalog ? nil : now, downloadedAt: nil
                    ).insert(db)
                }
            }

            let stale = try Chapter.filter(Column("bookId") == bookId).fetchAll(db)
                .filter { !keptIds.contains($0.id) }
            for chapter in stale { try chapter.delete(db) }

            // Stamped here rather than by the caller: the freshness of the
            // catalog is a property of this write, and a caller that forgot to
            // stamp it would make the book look permanently stale.
            if var book = stored {
                book.catalogUpdatedAt = now
                try book.update(db)
            }
        }
    }

    /// Writes a chapter's whole name over the truncated one its catalog gave it.
    ///
    /// Its own row rather than something the reader holds in memory: the name has to
    /// survive into the catalog sheet, the shelf's "last read" line and the next
    /// launch, none of which will ever fetch that page. See `Chapter.fullerTitle`
    /// for what makes a name a repair rather than a rename.
    func updateChapterTitle(chapterId: String, to title: String) throws {
        try writer.write { db in
            guard var chapter = try Chapter.fetchOne(db, key: chapterId) else { return }
            chapter.title = title
            try chapter.update(db)
        }
    }

    func chapters(bookId: String) throws -> [Chapter] {
        try writer.read { db in
            try Chapter.filter(Column("bookId") == bookId)
                .order(Column("index"))
                .fetchAll(db)
        }
    }

    /// How many chapters each book has gained since the reader's position, keyed
    /// by book id. Books with none are absent rather than mapped to zero.
    ///
    /// One grouped query for the whole library, not one per bookmark: this feeds
    /// every row of the library list, and a per-book count would turn drawing a
    /// 40-book shelf into 40 round trips on every reload.
    ///
    /// The predicate restates `Chapter.isNew(lastReadIndex:)` in SQL — the aggregate
    /// cannot be expressed any other way — so the two have to move together, which
    /// `NewChapterTests` pins.
    ///
    /// The extra join is the reading position: the book stores which chapter it is in,
    /// and the comparison needs the number, which only that chapter's own row has. A
    /// null `lastRead."index"` therefore covers both halves of `lastReadIndex(in:)`
    /// being nil — never opened, and a position naming a chapter the site has dropped.
    func newChapterCounts(now: Date = .now) throws -> [String: Int] {
        // `> cutoff` carries the null check with it — a null addedAt compares to null,
        // never to true — so the expiry and "was it ever stamped" stay one condition.
        let cutoff = now.addingTimeInterval(-Chapter.newWindow)
        return try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT chapter."bookId" AS bookId, COUNT(*) AS newCount
                FROM chapter
                JOIN book ON book."id" = chapter."bookId"
                LEFT JOIN chapter AS lastRead
                       ON lastRead."bookId" = book."id"
                      AND lastRead."siteChapterId" = book."lastReadSiteChapterId"
                WHERE chapter."addedAt" > ?
                  AND (lastRead."index" IS NULL OR chapter."index" > lastRead."index")
                GROUP BY chapter."bookId"
                """, arguments: [cutoff])
            return rows.reduce(into: [String: Int]()) { counts, row in
                counts[row["bookId"] as String] = row["newCount"] as Int
            }
        }
    }

    /// Where each book's stored position sits in reading order, keyed by book id. Books
    /// with no position, or whose chapter the site has dropped, are absent.
    ///
    /// The SQL half of `Book.lastReadIndex(in:)`, for the one screen that has the books
    /// but not their catalogs: the shelf. One query for the whole library, for the same
    /// reason `newChapterCounts` is one — it feeds every row of the list, where a
    /// per-book lookup would be a query per row on every reload.
    func lastReadChapterIndexes() throws -> [String: Int] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT book."id" AS bookId, chapter."index" AS chapterIndex
                FROM book
                JOIN chapter ON chapter."bookId" = book."id"
                            AND chapter."siteChapterId" = book."lastReadSiteChapterId"
                """)
            return rows.reduce(into: [String: Int]()) { indexes, row in
                indexes[row["bookId"] as String] = row["chapterIndex"] as Int
            }
        }
    }

    /// The single-book slice of `lastReadChapterIndexes`, for the progress publish
    /// that fires at every chapter turn: refreshing one book must not re-join the
    /// whole library's chapter table behind the reader.
    func lastReadChapterIndex(bookId: String) throws -> Int? {
        try writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT chapter."index"
                FROM book
                JOIN chapter ON chapter."bookId" = book."id"
                            AND chapter."siteChapterId" = book."lastReadSiteChapterId"
                WHERE book."id" = ?
                """, arguments: [bookId])
        }
    }

    /// The single-book slice of `newChapterCounts`, for the same caller and the
    /// same reason.
    func newChapterCount(bookId: String, now: Date = .now) throws -> Int {
        let cutoff = now.addingTimeInterval(-Chapter.newWindow)
        return try writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*)
                FROM chapter
                JOIN book ON book."id" = chapter."bookId"
                LEFT JOIN chapter AS lastRead
                       ON lastRead."bookId" = book."id"
                      AND lastRead."siteChapterId" = book."lastReadSiteChapterId"
                WHERE chapter."bookId" = ?
                  AND chapter."addedAt" > ?
                  AND (lastRead."index" IS NULL OR chapter."index" > lastRead."index")
                """, arguments: [bookId, cutoff]) ?? 0
        }
    }

    /// Requirement 4.2: which chapters of this book are held locally.
    func downloadedChapterIds(bookId: String) throws -> Set<String> {
        try writer.read { db in
            let rows = try Chapter
                .filter(Column("bookId") == bookId && Column("downloadedAt") != nil)
                .fetchAll(db)
            return Set(rows.map(\.siteChapterId))
        }
    }
}
