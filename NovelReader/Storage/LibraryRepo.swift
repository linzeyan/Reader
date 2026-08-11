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
    @discardableResult
    func bookmark(
        siteId: String,
        siteBookId: String,
        title: String,
        author: String? = nil,
        coverURL: String? = nil,
        now: Date = Date()
    ) throws -> Book {
        try writer.write { db in
            let id = Book.makeId(siteId: siteId, siteBookId: siteBookId)
            if var existing = try Book.fetchOne(db, key: id) {
                existing.title = title
                existing.author = author ?? existing.author
                existing.coverURL = coverURL ?? existing.coverURL
                existing.updatedAt = now
                try existing.update(db)
                return existing
            }
            let book = Book(
                id: id, siteId: siteId, siteBookId: siteBookId, title: title,
                displayName: nil, author: author, coverURL: coverURL,
                addedAt: now, updatedAt: now,
                lastReadChapterIndex: nil, lastReadParagraph: nil,
                lastReadCharacterOffset: nil, catalogUpdatedAt: nil
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

    func updateProgress(bookId: String, position: ReadingPosition, now: Date = Date()) throws {
        try writer.write { db in
            guard var book = try Book.fetchOne(db, key: bookId) else { return }
            book.lastReadChapterIndex = position.chapterIndex
            book.lastReadParagraph = position.anchor.paragraph
            book.lastReadCharacterOffset = position.anchor.characterOffset
            book.updatedAt = now
            try book.update(db)
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
    func readingBookmarks(bookId: String) throws -> [ReadingBookmark] {
        try writer.read { db in
            try ReadingBookmark
                .filter(Column("bookId") == bookId)
                .order(Column("chapterIndex"), Column("paragraph"), Column("characterOffset"))
                .fetchAll(db)
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

            for (index, entry) in entries.enumerated() {
                let id = Chapter.makeId(bookId: bookId, siteChapterId: entry.siteChapterId)
                if var existing = try Chapter.fetchOne(db, key: id) {
                    existing.index = index
                    existing.title = entry.title
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
    /// The predicate restates `Chapter.isNew(in:)` in SQL — the aggregate cannot
    /// be expressed any other way — so the two have to move together, which
    /// `NewChapterTests` pins.
    func newChapterCounts() throws -> [String: Int] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT chapter."bookId" AS bookId, COUNT(*) AS newCount
                FROM chapter
                JOIN book ON book."id" = chapter."bookId"
                WHERE chapter."addedAt" IS NOT NULL
                  AND (book."lastReadChapterIndex" IS NULL
                       OR chapter."index" > book."lastReadChapterIndex")
                GROUP BY chapter."bookId"
                """)
            return rows.reduce(into: [String: Int]()) { counts, row in
                counts[row["bookId"] as String] = row["newCount"] as Int
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
