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

    /// Adds a feed's newly published articles to what is already stored, and removes
    /// nothing.
    ///
    /// The one place a feed's catalog behaves unlike a novel's, and it has to: a feed
    /// document is a *window*, not an index. A site's catalog page lists every chapter
    /// the book has, so a chapter missing from it is a chapter the site withdrew and
    /// `replaceCatalog` is right to drop it. A feed lists the last ten or fifty items and
    /// nothing else — run through `replaceCatalog`, a reader's whole archive would be
    /// deleted every time the publisher posted, taking the downloaded text, the
    /// bookmarks and the highlights with it, and the article they were half way through
    /// would vanish under them.
    ///
    /// Reading order is chronological, oldest first, so that a feed behaves like a book
    /// that gains chapters: new articles land at the end, which is what makes the reading
    /// position, the unread count and "next chapter" work for a subscription without one
    /// line of new code in any of them.
    ///
    /// Ties are broken by id rather than by the order the feed listed them. Publishers
    /// batch-publish with identical timestamps and then reorder freely between two
    /// fetches, and an order that is *stable* matters far more here than one that is
    /// exactly right: `index` is what every mark resolves through, so an order that
    /// changed on refresh would slide the reader's place onto a neighbouring article.
    ///
    /// - Parameter entries: `publishedAt` is nil for an item whose feed gave no date. It
    ///   is stamped `now` on insert and never rewritten afterwards, so an undated article
    ///   holds the moment it first arrived — which is the only honest thing known about
    ///   when it appeared, and, unlike re-stamping it, does not march it up the list on
    ///   every refresh.
    func mergeCatalog(
        bookId: String,
        entries: [(siteChapterId: String, title: String, url: String, publishedAt: Date?)],
        now: Date = Date()
    ) throws {
        try writer.write { db in
            let stored = try Book.fetchOne(db, key: bookId)

            // Everything already here moves into the negative range *before* a single
            // article is written, and every new one is parked below that. This is
            // `replaceCatalog`'s shuffle, and it is needed here for a second reason on
            // top of that one: `chapter_book_index` is unique and SQLite checks it row by
            // row, so two articles arriving in the same refresh cannot both be inserted
            // holding some placeholder number, and no row can take a final number while
            // another still holds it. An article dated in the middle of the order — which
            // for a feed is any backdated post — is exactly the case a direct write fails
            // on, and it fails the whole refresh, silently, forever.
            try db.execute(
                sql: #"UPDATE "chapter" SET "index" = -1 - "index" WHERE "bookId" = ?"#,
                arguments: [bookId]
            )
            var parking = try Int.fetchOne(
                db,
                sql: #"SELECT MIN("index") FROM "chapter" WHERE "bookId" = ?"#,
                arguments: [bookId]
            ) ?? 0

            for entry in entries {
                let id = Chapter.makeId(bookId: bookId, siteChapterId: entry.siteChapterId)
                if var existing = try Chapter.fetchOne(db, key: id) {
                    existing.title =
                        Chapter.fullerTitle(existing.title, extending: entry.title) ?? entry.title
                    existing.url = entry.url
                    // A date already stored wins over an absent one. It is only ever
                    // absent because the publisher gives none, and the stored value is
                    // then the arrival time recorded the first time this ran.
                    existing.publishedAt = entry.publishedAt ?? existing.publishedAt
                    try existing.update(db)
                } else {
                    parking -= 1
                    // Stamped on every insert, the first fetch included. A subscription's
                    // unread count is a matter of `readAt` alone — see `Chapter.isUnread`
                    // — so this column is not what decides it here, and the honest thing
                    // it can say is when the article first reached this device. An
                    // arriving article carries no `readAt`, which is to say it is unread,
                    // which is the whole point of subscribing.
                    try Chapter(
                        id: id, bookId: bookId, siteChapterId: entry.siteChapterId,
                        index: parking, title: entry.title, url: entry.url,
                        addedAt: now, publishedAt: entry.publishedAt ?? now, downloadedAt: nil
                    ).insert(db)
                }
            }

            // Oldest first, so a feed reads like a book that gains chapters. Nulls cannot
            // occur here — every row this function writes gets a date — but SQLite sorts
            // them first, which would put a novel chapter that somehow reached this
            // function at the top rather than in an unreadable middle.
            let ordered = try Chapter.fetchAll(db, sql: """
                SELECT * FROM "chapter" WHERE "bookId" = ?
                ORDER BY "publishedAt", "siteChapterId"
                """, arguments: [bookId])
            for (index, chapter) in ordered.enumerated() {
                var renumbered = chapter
                renumbered.index = index
                try renumbered.update(db)
            }

            if var book = stored {
                book.catalogUpdatedAt = now
                try book.update(db)
            }
        }
    }

    /// Records that the index was read and found unchanged.
    ///
    /// For the one answer that carries no catalog with it: a `304`. The read really
    /// happened and really found nothing, so the freshness this stamps is exactly as
    /// true as the one `mergeCatalog` writes — and without it a feed that publishes
    /// weekly would look stale every day and be asked again on every visit, which is
    /// what conditional requests exist to stop.
    func touchCatalog(bookId: String, now: Date = Date()) throws {
        try writer.write { db in
            guard var book = try Book.fetchOne(db, key: bookId) else { return }
            book.catalogUpdatedAt = now
            try book.update(db)
        }
    }

    // MARK: - Feed fetch state

    /// What this device sent last time, or nil for a feed it has never asked for — which
    /// is the same as having no validators, and asks for the whole document.
    func feedFetchState(bookId: String) throws -> FeedFetchState? {
        try writer.read { db in try FeedFetchState.fetchOne(db, key: bookId) }
    }

    /// Records the validators a response carried, replacing whatever was there.
    ///
    /// Written even for a `304`, which is why `checkedAt` is on the row: a check that
    /// found nothing is still a check, and a feed that has published nothing this month
    /// must not look like one nobody has looked at this month.
    func saveFeedFetchState(_ state: FeedFetchState) throws {
        try writer.write { db in try state.save(db) }
    }

    /// Drops articles a subscription is no longer keeping.
    ///
    /// Rows, not just their text: for a feed the row is the article — the publisher's
    /// window has long since moved past these, so a row with its text deleted is a
    /// headline that opens onto nothing and can never be filled in again. Which articles
    /// these are is `FeedRetention.purgeable`'s to decide, and the files are the caller's
    /// to delete first (see `FeedService.purge`).
    ///
    /// Numbering is left with holes in it. `index` is only ever compared, never counted
    /// on to be contiguous, and the next refresh renumbers the whole catalog anyway.
    func removeChapters(bookId: String, siteChapterIds: [String]) throws {
        guard !siteChapterIds.isEmpty else { return }
        try writer.write { db in
            let ids = siteChapterIds.map { Chapter.makeId(bookId: bookId, siteChapterId: $0) }
            _ = try Chapter.deleteAll(db, keys: ids)
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
    /// The predicate restates `Chapter.isNew(lastReadIndex:)` and `Chapter.isUnread` in
    /// SQL — the aggregate cannot be expressed any other way — so the two have to move
    /// together, which `NewChapterTests` pins.
    ///
    /// The extra join is the reading position: the book stores which chapter it is in,
    /// and the comparison needs the number, which only that chapter's own row has. A
    /// null `lastRead."index"` therefore covers both halves of `lastReadIndex(in:)`
    /// being nil — never opened, and a position naming a chapter the site has dropped.
    ///
    /// A subscription counts something else entirely, and the `CASE` is where the two
    /// part company. For a novel "new" is a claim about recency measured against the
    /// reading position — a chapter published last month is not news, it is simply one
    /// they have not reached, which their position already tells them. For a feed the
    /// count is of articles with no `readAt`, and the position does not enter into it: an
    /// article is read when the reader read *it*, not when they happened to open a newer
    /// one. `Chapter.isNew` and `Chapter.isUnread` are the two halves of this in Swift,
    /// and `NewChapterTests` pins them to this statement.
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
                WHERE \(Self.unreadPredicate)
                GROUP BY chapter."bookId"
                """, arguments: [SiteRule.Kind.feed.rawValue, cutoff])
            return rows.reduce(into: [String: Int]()) { counts, row in
                counts[row["bookId"] as String] = row["newCount"] as Int
            }
        }
    }

    /// What the shelf's badge counts, in one place so the library-wide query and the
    /// single-book one cannot drift apart. Takes the feed kind and the recency cutoff, in
    /// that order.
    private static let unreadPredicate = """
        CASE WHEN book."kind" = ?
             THEN chapter."readAt" IS NULL
             ELSE chapter."addedAt" > ?
                  AND (lastRead."index" IS NULL OR chapter."index" > lastRead."index")
        END
        """

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
                  AND \(Self.unreadPredicate)
                """, arguments: [bookId, SiteRule.Kind.feed.rawValue, cutoff]) ?? 0
        }
    }

    // MARK: - Read articles

    /// Marks articles read, or puts them back to unread.
    ///
    /// Subscriptions only, and the caller is what enforces that: `AppEnvironment` checks
    /// the kind before it gets here. A novel chapter written through this would grow a
    /// `readAt` that nothing reads and that the shelf's `CASE` would ignore — a value with
    /// no meaning is worse than no column.
    ///
    /// Stamped with `now` on the way in and cleared on the way out, rather than toggled
    /// per row: "mark read" is one gesture with one time behind it, and rows that already
    /// carry a stamp keep it — re-marking an article read is not a new act of reading.
    ///
    /// - Returns: how many rows actually changed, so a caller can skip the work of
    ///   refreshing screens for a gesture that did nothing. Marking forty read articles
    ///   read is a no-op, and it is a gesture readers make constantly.
    @discardableResult
    func setArticlesRead(
        _ read: Bool, bookId: String, siteChapterIds: [String], now: Date = Date()
    ) throws -> Int {
        guard !siteChapterIds.isEmpty else { return 0 }
        let stamp: Date? = read ? now : nil
        return try writer.write { db in
            let ids = siteChapterIds.map { Chapter.makeId(bookId: bookId, siteChapterId: $0) }
            // Narrowed to the rows that would actually change, so the count handed back is
            // a count of changes rather than of ids passed in.
            let changed = try Chapter
                .filter(keys: ids)
                .filter(read ? Column("readAt") == nil : Column("readAt") != nil)
                .updateAll(db, Column("readAt").set(to: stamp))
            if changed > 0 { try Self.stamp(db, bookIds: [bookId], now: now) }
            return changed
        }
    }

    /// Bumps `updatedAt` on the books whose read state just moved.
    ///
    /// In the same transaction as the flags, not after it: `updatedAt` is what iCloud
    /// merges on (see `CloudSync`), so a device whose read state changed without it would
    /// publish a record the other device is entitled to ignore — and the article marked
    /// read here would come back unread on the next pull.
    private static func stamp(_ db: Database, bookIds: [String], now: Date) throws {
        guard !bookIds.isEmpty else { return }
        try Book.filter(keys: bookIds).updateAll(db, Column("updatedAt").set(to: now))
    }

    /// Marks every article of one subscription read.
    ///
    /// A statement rather than a read-then-write of the ids, because the set can be the
    /// whole archive of a feed read for a year — and because the honest meaning of the
    /// gesture is "everything in this subscription", not "everything in the list I happen
    /// to be looking at", which a search box or a retention purge could have narrowed.
    @discardableResult
    func markAllRead(bookId: String, now: Date = Date()) throws -> Int {
        try writer.write { db in
            let changed = try Chapter
                .filter(Column("bookId") == bookId && Column("readAt") == nil)
                .updateAll(db, Column("readAt").set(to: now))
            if changed > 0 { try Self.stamp(db, bookIds: [bookId], now: now) }
            return changed
        }
    }

    /// The same, for every subscription on the shelf.
    ///
    /// One statement over the whole library rather than a loop of the above: this is the
    /// "I have been away for a fortnight" gesture, so the set it touches is the largest
    /// this app ever writes in one go, and forty transactions would be forty fsyncs for
    /// one tap.
    ///
    /// - Returns: the books that actually lost unread articles, so the caller knows which
    ///   rows to republish to iCloud without pushing the whole library.
    func markAllFeedsRead(now: Date = Date()) throws -> [String] {
        try writer.write { db in
            let ids = try String.fetchAll(db, sql: """
                SELECT DISTINCT chapter."bookId" FROM chapter
                JOIN book ON book."id" = chapter."bookId"
                WHERE book."kind" = ? AND chapter."readAt" IS NULL
                """, arguments: [SiteRule.Kind.feed.rawValue])
            guard !ids.isEmpty else { return [] }
            try db.execute(sql: """
                UPDATE "chapter" SET "readAt" = ?
                WHERE "readAt" IS NULL
                  AND "bookId" IN (SELECT "id" FROM "book" WHERE "kind" = ?)
                """, arguments: [now, SiteRule.Kind.feed.rawValue])
            try Self.stamp(db, bookIds: ids, now: now)
            return ids
        }
    }

    /// The ids of a subscription's unread articles, newest last.
    ///
    /// Read back for iCloud, which carries the read state as its complement — see
    /// `CloudSync`. The unread set rather than the read one because it is the smaller of
    /// the two by construction: an article is unread until somebody gets to it, and a
    /// subscription anybody actually reads holds far more read articles than unread ones.
    func unreadArticleIds(bookId: String) throws -> [String] {
        try writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT "siteChapterId" FROM "chapter"
                WHERE "bookId" = ? AND "readAt" IS NULL
                ORDER BY "index"
                """, arguments: [bookId])
        }
    }

    /// The newest publication date in a subscription's catalog, or nil for one with no
    /// articles yet.
    ///
    /// The cutoff iCloud's read state is published against: a list of unread ids says
    /// nothing about articles the sending device had never seen, so the receiving one has
    /// to be told where the sender's knowledge stopped.
    func newestArticleDate(bookId: String) throws -> Date? {
        try writer.read { db in
            try Date.fetchOne(
                db,
                sql: #"SELECT MAX("publishedAt") FROM "chapter" WHERE "bookId" = ?"#,
                arguments: [bookId]
            )
        }
    }

    /// Applies another device's read state to the articles this one holds.
    ///
    /// Everything published at or before `through` is set to what the other device said —
    /// read unless it named it unread. `through` is the cutoff and not a formality: the
    /// sending device wrote its list against the catalog *it* had, so an article that
    /// arrived here afterwards is not absent from that list because it was read, it is
    /// absent because the other device had never seen it. Without the cutoff every refresh
    /// that beat the sync would mark its own new articles read.
    ///
    /// Nothing is un-read that this device has not been told about: a null `through` — a
    /// record written before this existed — applies nothing at all.
    /// - Parameter monotonic: when true, articles are only ever marked *read* — the other
    ///   device's unread list is used to hold some back, never to un-read anything here.
    ///   False on the sync's own path, where the record won last-writer-wins and is
    ///   entitled to say both things. True when a refresh has just brought articles in
    ///   underneath a record that was applied before they existed, which is the ordinary
    ///   shape of setting a new device up: the books arrive from iCloud first and the
    ///   articles are fetched after. Marking those read is recovering state that was
    ///   already published; un-reading anything there would be an old record reaching
    ///   forward over a mark made on this device since.
    func applyRemoteReadState(
        bookId: String, unread: Set<String>, through: Date?, monotonic: Bool, now: Date = Date()
    ) throws {
        guard let through else { return }
        try writer.write { db in
            let chapters = try Chapter.fetchAll(db, sql: """
                SELECT * FROM "chapter" WHERE "bookId" = ? AND "publishedAt" <= ?
                """, arguments: [bookId, through])
            for chapter in chapters {
                let shouldBeRead = !unread.contains(chapter.siteChapterId)
                guard shouldBeRead == chapter.isUnread else { continue }
                if monotonic && !shouldBeRead { continue }
                var updated = chapter
                // A stamp already here survives being re-confirmed: it records when this
                // device read the article, which is a truer answer than the moment a sync
                // arrived.
                updated.readAt = shouldBeRead ? (chapter.readAt ?? now) : nil
                try updated.update(db)
            }
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
