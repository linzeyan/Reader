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
                lastReadChapterIndex: nil, lastReadOffset: nil,
                catalogUpdatedAt: nil
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

    func updateProgress(bookId: String, chapterIndex: Int, offset: Int, now: Date = Date()) throws {
        try writer.write { db in
            guard var book = try Book.fetchOne(db, key: bookId) else { return }
            book.lastReadChapterIndex = chapterIndex
            book.lastReadOffset = offset
            book.updatedAt = now
            try book.update(db)
        }
    }

    // MARK: - Chapter index

    /// Replaces a book's catalog with a freshly fetched one.
    ///
    /// Rows are upserted and stale ones removed rather than the table being
    /// wiped and refilled, so `downloadedAt` survives a catalog refresh — losing
    /// it would make every already-downloaded chapter look missing.
    func replaceCatalog(
        bookId: String,
        entries: [(siteChapterId: String, title: String, url: String)],
        now: Date = Date()
    ) throws {
        try writer.write { db in
            let keptIds = Set(entries.map { Chapter.makeId(bookId: bookId, siteChapterId: $0.siteChapterId) })

            for (index, entry) in entries.enumerated() {
                let id = Chapter.makeId(bookId: bookId, siteChapterId: entry.siteChapterId)
                if var existing = try Chapter.fetchOne(db, key: id) {
                    existing.index = index
                    existing.title = entry.title
                    existing.url = entry.url
                    try existing.update(db)
                } else {
                    try Chapter(
                        id: id, bookId: bookId, siteChapterId: entry.siteChapterId,
                        index: index, title: entry.title, url: entry.url, downloadedAt: nil
                    ).insert(db)
                }
            }

            let stale = try Chapter.filter(Column("bookId") == bookId).fetchAll(db)
                .filter { !keptIds.contains($0.id) }
            for chapter in stale { try chapter.delete(db) }

            // Stamped here rather than by the caller: the freshness of the
            // catalog is a property of this write, and a caller that forgot to
            // stamp it would make the book look permanently stale.
            if var book = try Book.fetchOne(db, key: bookId) {
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
