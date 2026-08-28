import Foundation
import GRDB

/// Keeps the download index and the files on disk in agreement.
///
/// Every mutation touches both a database flag and a file, so the ordering
/// matters: the flag is cleared *before* the file is removed. If the process
/// dies between the two, the result is an orphaned file — wasted space that a
/// later re-download simply overwrites. The reverse order would leave a row
/// claiming a chapter is available when its text is already gone, which the
/// reader would surface as a broken chapter.
struct DownloadStore {
    let database: AppDatabase
    let files: ChapterFileStore

    private var writer: any DatabaseWriter { database.writer }

    // MARK: - Saving

    /// Writes chapter text and flags the index entry as downloaded.
    /// The file is written first here — the mirror image of deletion — so a flag
    /// is never set for text that failed to land.
    func save(
        paragraphs: [String],
        book: Book,
        siteChapterId: String,
        now: Date = Date()
    ) throws {
        try files.write(
            paragraphs: paragraphs,
            siteId: book.siteId,
            siteBookId: book.siteBookId,
            siteChapterId: siteChapterId
        )
        try writer.write { db in
            let id = Chapter.makeId(bookId: book.id, siteChapterId: siteChapterId)
            guard var chapter = try Chapter.fetchOne(db, key: id) else { return }
            chapter.downloadedAt = now
            try chapter.update(db)
        }
    }

    /// The same contract for a comic chapter: the pages land first, and only a chapter
    /// that is completely on disk gets the flag that says so.
    func save(pages: [Data], book: Book, siteChapterId: String, now: Date = Date()) throws {
        try files.writePages(
            pages, siteId: book.siteId, siteBookId: book.siteBookId, siteChapterId: siteChapterId
        )
        try writer.write { db in
            let id = Chapter.makeId(bookId: book.id, siteChapterId: siteChapterId)
            guard var chapter = try Chapter.fetchOne(db, key: id) else { return }
            chapter.downloadedAt = now
            try chapter.update(db)
        }
    }

    func readParagraphs(book: Book, siteChapterId: String) throws -> [String] {
        try files.readParagraphs(
            siteId: book.siteId, siteBookId: book.siteBookId, siteChapterId: siteChapterId
        )
    }

    // MARK: - Deleting (requirement 4.3)

    /// The four delete levels the product requires. Carries book/site ids so the
    /// file layer can find the subtree without another database round-trip.
    enum Scope: Equatable {
        case chapter(book: Book, siteChapterId: String)
        case book(Book)
        case site(siteId: String)
        case everything
    }

    func delete(_ scope: Scope) throws {
        try clearFlags(for: scope)
        try files.delete(fileScope(for: scope))
    }

    private func fileScope(for scope: Scope) -> ChapterFileStore.Scope {
        switch scope {
        case let .chapter(book, siteChapterId):
            return .chapter(siteId: book.siteId, siteBookId: book.siteBookId, siteChapterId: siteChapterId)
        case let .book(book):
            return .book(siteId: book.siteId, siteBookId: book.siteBookId)
        case let .site(siteId):
            return .site(siteId: siteId)
        case .everything:
            return .everything
        }
    }

    private func clearFlags(for scope: Scope) throws {
        try writer.write { db in
            switch scope {
            case let .chapter(book, siteChapterId):
                let id = Chapter.makeId(bookId: book.id, siteChapterId: siteChapterId)
                try db.execute(
                    sql: "UPDATE chapter SET downloadedAt = NULL WHERE id = ?",
                    arguments: [id]
                )
            case let .book(book):
                try db.execute(
                    sql: "UPDATE chapter SET downloadedAt = NULL WHERE bookId = ?",
                    arguments: [book.id]
                )
            case let .site(siteId):
                // chapter has no siteId of its own; scope through its book.
                try db.execute(
                    sql: """
                    UPDATE chapter SET downloadedAt = NULL
                    WHERE bookId IN (SELECT id FROM book WHERE siteId = ?)
                    """,
                    arguments: [siteId]
                )
            case .everything:
                try db.execute(sql: "UPDATE chapter SET downloadedAt = NULL")
            }
        }
    }

    // MARK: - Accounting

    func downloadedCount(bookId: String) throws -> Int {
        try writer.read { db in
            try Chapter
                .filter(Column("bookId") == bookId && Column("downloadedAt") != nil)
                .fetchCount(db)
        }
    }

    func size(of scope: Scope) -> Int64 {
        files.size(of: fileScope(for: scope))
    }
}
