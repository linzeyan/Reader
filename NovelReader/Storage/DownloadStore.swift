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

    /// The same contract for an article: its structure and the plain text it flattens to
    /// both land before the flag says it is readable. See `ChapterFileStore.write(blocks:)`
    /// for why both files are written.
    func save(blocks: [ArticleBlock], book: Book, siteChapterId: String, now: Date = Date()) throws {
        try files.write(
            blocks: blocks, siteId: book.siteId, siteBookId: book.siteBookId,
            siteChapterId: siteChapterId
        )
        try writer.write { db in
            let id = Chapter.makeId(bookId: book.id, siteChapterId: siteChapterId)
            guard var chapter = try Chapter.fetchOne(db, key: id) else { return }
            chapter.downloadedAt = now
            try chapter.update(db)
        }
    }

    /// One of an article's pictures, before the blocks that name it are written.
    ///
    /// No flag of its own and deliberately no ordering promise beyond that: a picture that
    /// lands and is then never referred to — because the article's blocks failed to
    /// write — is bytes in a directory the chapter's own delete scope already covers.
    func write(image data: Data, named name: String, book: Book, siteChapterId: String) throws {
        try files.write(
            image: data, named: name, siteId: book.siteId, siteBookId: book.siteBookId,
            siteChapterId: siteChapterId
        )
    }

    /// The same contract for a comic chapter: the pages land first, and only a chapter
    /// that is on disk gets the flag that says so. A `nil` page is one the site would
    /// not give up; `ChapterFileStore.writePages` keeps its place in the numbering.
    func save(pages: [Data?], book: Book, siteChapterId: String, now: Date = Date()) throws {
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

    /// Fills in one page of a chapter that is already on the device, and touches nothing
    /// in the database: the chapter was downloaded before this and is downloaded after
    /// it. See `ChapterFileStore.fillPage`.
    func fillPage(_ bytes: Data, index: Int, book: Book, siteChapterId: String) throws {
        try files.fillPage(
            bytes, index: index, siteId: book.siteId, siteBookId: book.siteBookId,
            siteChapterId: siteChapterId
        )
    }

    func readParagraphs(book: Book, siteChapterId: String) throws -> [String] {
        try files.readParagraphs(
            siteId: book.siteId, siteBookId: book.siteBookId, siteChapterId: siteChapterId
        )
    }

    /// An article's blocks, or nil for anything stored as prose — which is every novel
    /// chapter, and every article taken in before this app knew about structure.
    func readBlocks(book: Book, siteChapterId: String) -> [ArticleBlock]? {
        files.readBlocks(
            siteId: book.siteId, siteBookId: book.siteBookId, siteChapterId: siteChapterId
        )
    }

    /// Where an article's pictures are, which is what the layout resolves their file names
    /// against.
    func imageDirectory(book: Book, siteChapterId: String) -> URL {
        files.imageDirectory(
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
