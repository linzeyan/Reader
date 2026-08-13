import GRDB
import XCTest
@testable import NovelReader

/// What a mark points at, when the catalog under it moves.
///
/// Every one of these three things — the reading position, a bookmark, a highlight —
/// used to store the chapter's *place* in the catalog, and `replaceCatalog` recomputes
/// that place on every refresh. So the day a site slipped a chapter into the middle of a
/// book, every mark past it silently began naming the following chapter's text: the
/// bookmark opened a chapter late, the highlight painted a sentence nobody chose, and
/// the reading position walked backwards. That is the failure this file exists to keep
/// out, and it is stated the only way it can honestly be stated — as the *text* the
/// marks resolve to, not as the numbers they resolve through.
final class ChapterIdentityTests: XCTestCase {
    private var tempRoot: URL!
    private var database: AppDatabase!
    private var repo: LibraryRepo!
    private var downloads: DownloadStore!

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NovelReaderTests-\(UUID().uuidString)")
        database = try AppDatabase.makeInMemory()
        repo = LibraryRepo(database: database)
        downloads = DownloadStore(database: database, files: ChapterFileStore(root: tempRoot))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - Fixtures

    private func entries(
        _ ids: [String]
    ) -> [(siteChapterId: String, title: String, url: String)] {
        ids.map { (siteChapterId: $0, title: "第\($0)章", url: "https://demo.test/1/\($0)") }
    }

    /// Distinct text per chapter, on disk, so that "the mark still points at the same
    /// paragraph" can be asked of the paragraph itself rather than of an index.
    private func text(ofChapter id: String) -> [String] {
        (0..<4).map { "第\(id)章的第\($0)段：雪停了。" }
    }

    private func seed(_ ids: [String], book: Book) throws {
        try repo.replaceCatalog(bookId: book.id, entries: entries(ids))
        for id in ids {
            try downloads.save(paragraphs: text(ofChapter: id), book: book, siteChapterId: id)
        }
    }

    /// The paragraph a stored anchor names, read through the catalog exactly the way the
    /// reader resolves it: find the chapter the mark names, load that chapter's text, take
    /// the paragraph. Nil when the mark no longer resolves to a chapter at all.
    private func paragraph(at position: ReadingPosition, of book: Book) throws -> String? {
        let chapters = try repo.chapters(bookId: book.id)
        guard let chapter = chapters.first(where: { $0.siteChapterId == position.siteChapterId })
        else { return nil }
        let paragraphs = try downloads.readParagraphs(book: book, siteChapterId: chapter.siteChapterId)
        guard paragraphs.indices.contains(position.anchor.paragraph) else { return nil }
        return paragraphs[position.anchor.paragraph]
    }

    private func makeBook() throws -> Book {
        try repo.bookmark(siteId: "demo", siteBookId: "1", title: "山月記")
    }

    // MARK: - The site inserts a chapter

    /// The whole reason for the change. Everything the reader left in the book has to keep
    /// naming the same sentence after the site publishes a chapter *behind* them, which is
    /// the one catalog change that renumbers rows the reader has already touched.
    func testMarksKeepNamingTheSameTextWhenTheSiteInsertsAChapter() throws {
        let book = try makeBook()
        try seed(["1", "2", "3", "4", "5"], book: book)

        // Reading position, bookmark and highlight, all inside chapter 4.
        let reading = ReadingPosition(
            siteChapterId: "4", anchor: TextAnchor(paragraph: 2, characterOffset: 0)
        )
        try repo.updateProgress(bookId: book.id, position: reading)
        try repo.addReadingBookmark(
            bookId: book.id,
            position: ReadingPosition(
                siteChapterId: "4", anchor: TextAnchor(paragraph: 1, characterOffset: 0)
            ),
            excerpt: text(ofChapter: "4")[1]
        )
        try repo.addHighlight(
            bookId: book.id,
            siteChapterId: "4",
            selection: TextSelection(
                start: TextAnchor(paragraph: 3, characterOffset: 0),
                end: TextAnchor(paragraph: 3, characterOffset: 6),
                text: String(text(ofChapter: "4")[3].prefix(6))
            )
        )

        let before = try marked(of: book)
        XCTAssertEqual(before, [
            text(ofChapter: "4")[2], text(ofChapter: "4")[1], text(ofChapter: "4")[3],
        ], "the fixture has to start out pointing where it claims")
        XCTAssertEqual(
            try XCTUnwrap(repo.book(id: book.id)).lastReadIndex(in: repo.chapters(bookId: book.id)),
            3,
            "chapter 4 sits at index 3 today, which is exactly what must not be stored"
        )

        // The site slips a chapter in between 2 and 3. Every later chapter moves up one.
        try seed(["1", "2", "2b", "3", "4", "5"], book: book)

        XCTAssertEqual(
            try marked(of: book), before,
            """
            All three marks still name the paragraphs of chapter 4. Stored as indexes they
            would each have slid onto chapter 3's text, because the number 3 now belongs
            to a different chapter.
            """
        )
        XCTAssertEqual(
            try XCTUnwrap(repo.book(id: book.id)).lastReadIndex(in: repo.chapters(bookId: book.id)),
            4,
            "the same chapter, at its new number — resolved, never stored"
        )
    }

    /// The three marks resolved to the text they point at, in one call, so a test can
    /// compare the whole set across a catalog change.
    private func marked(of book: Book) throws -> [String?] {
        let reloaded = try XCTUnwrap(repo.book(id: book.id))
        let bookmark = try XCTUnwrap(repo.readingBookmarks(bookId: book.id).first)
        let highlight = try XCTUnwrap(repo.highlights(bookId: book.id).first)
        return try [
            paragraph(at: try XCTUnwrap(reloaded.readingPosition), of: book),
            paragraph(at: bookmark.position, of: book),
            paragraph(at: highlight.position, of: book),
        ]
    }

    /// A mark made in the inserted chapter is a mark in that chapter, not in whatever
    /// used to hold its number. The catalog it was made against is already the new one,
    /// so this is the case a stored index gets right by accident — it is here because
    /// nothing about the new chapter may need special handling.
    func testAMarkMadeInAnInsertedChapterPointsIntoThatChapter() throws {
        let book = try makeBook()
        try seed(["1", "2", "3"], book: book)
        try seed(["1", "1b", "2", "3"], book: book)

        try repo.addReadingBookmark(
            bookId: book.id,
            position: ReadingPosition(
                siteChapterId: "1b", anchor: TextAnchor(paragraph: 0, characterOffset: 0)
            )
        )

        let bookmark = try XCTUnwrap(repo.readingBookmarks(bookId: book.id).first)
        XCTAssertEqual(try paragraph(at: bookmark.position, of: book), text(ofChapter: "1b")[0])
    }

    // MARK: - The site removes a chapter

    /// A mark whose chapter the site drops is *kept*. The excerpt is what the reader wrote
    /// down, a chapter pulled from a catalog often comes back, and a refresh deleting a
    /// reader's marks is a data loss they never asked for and cannot undo.
    ///
    /// What it loses is the ability to be opened: it resolves to no chapter, which is what
    /// `ReadingMarksView` reads to decide there is nowhere to send the reader. Landing
    /// them "close by" instead would be the exact lie this identity is here to prevent.
    func testAMarkOutlivesTheChapterTheSiteRemoved() throws {
        let book = try makeBook()
        try seed(["1", "2", "3"], book: book)
        try repo.addReadingBookmark(
            bookId: book.id,
            position: ReadingPosition(
                siteChapterId: "2", anchor: TextAnchor(paragraph: 1, characterOffset: 0)
            ),
            excerpt: "雪停了。"
        )

        try repo.replaceCatalog(bookId: book.id, entries: entries(["1", "3"]))

        let bookmark = try XCTUnwrap(repo.readingBookmarks(bookId: book.id).first)
        XCTAssertEqual(bookmark.siteChapterId, "2", "the row keeps pointing where it pointed")
        XCTAssertEqual(bookmark.excerpt, "雪停了。", "and keeps the text the reader recognised")
        XCTAssertNil(
            try paragraph(at: bookmark.position, of: book),
            "but it resolves to no chapter, so there is nowhere to open"
        )
    }

    /// And it sorts last. The list is in reading order; a mark that cannot be placed in
    /// the book cannot be placed among the ones that can, and the foot of the list is
    /// where it pushes nothing else out of the way.
    func testMarksThatNoLongerResolveSortAfterTheOnesThatDo() throws {
        let book = try makeBook()
        try seed(["1", "2", "3"], book: book)
        for id in ["1", "2", "3"] {
            try repo.addReadingBookmark(
                bookId: book.id,
                position: ReadingPosition(
                    siteChapterId: id, anchor: TextAnchor(paragraph: 0, characterOffset: 0)
                )
            )
            try repo.addHighlight(
                bookId: book.id,
                siteChapterId: id,
                selection: TextSelection(
                    start: .start, end: TextAnchor(paragraph: 0, characterOffset: 4), text: "雪停了。"
                )
            )
        }

        // The middle chapter goes, so the survivor order is unambiguous.
        try repo.replaceCatalog(bookId: book.id, entries: entries(["1", "3"]))

        XCTAssertEqual(
            try repo.readingBookmarks(bookId: book.id).map(\.siteChapterId), ["1", "3", "2"]
        )
        XCTAssertEqual(try repo.highlights(bookId: book.id).map(\.siteChapterId), ["1", "3", "2"])
    }

    // MARK: - Migration

    /// v6's backfill: the index a mark held named a chapter in the catalog as it stood,
    /// and that chapter's own id is the only honest conversion available. Nothing else
    /// could be — the number is precisely what the next insertion invalidates.
    func testMigrationConvertsStoredIndexesToTheChaptersTheyNamed() throws {
        let queue = try storeAtV5(markedChapterIndexes: [1, 2])

        try AppDatabase.migrator.migrate(queue)

        let repo = LibraryRepo(database: try AppDatabase(queue))
        XCTAssertEqual(
            try repo.readingBookmarks(bookId: "demo|1").map(\.siteChapterId), ["c1", "c2"],
            "the ids of the chapters that were at indexes 1 and 2"
        )
        XCTAssertEqual(try repo.highlights(bookId: "demo|1").map(\.siteChapterId), ["c1", "c2"])
    }

    /// The row ids are rewritten with the column, and they have to be: identity is what
    /// makes the bookmark button idempotent, so a converted row the reader re-bookmarks
    /// must be recognised as the row it already is. Left alone, the old id would no longer
    /// match what `makeId` produces and the reader would get a second, invisible bookmark
    /// on a page they had already saved.
    func testMigrationRewritesTheRowIdsSoReMarkingStaysIdempotent() throws {
        let queue = try storeAtV5(markedChapterIndexes: [1])
        try AppDatabase.migrator.migrate(queue)
        let repo = LibraryRepo(database: try AppDatabase(queue))
        let stored = try XCTUnwrap(repo.readingBookmarks(bookId: "demo|1").first)

        let again = try repo.addReadingBookmark(bookId: "demo|1", position: stored.position)

        XCTAssertEqual(again.id, stored.id)
        XCTAssertEqual(
            try repo.readingBookmarks(bookId: "demo|1").count, 1,
            "saving the same page again must land on the converted row, not beside it"
        )
        XCTAssertEqual(
            stored.id, ReadingBookmark.makeId(bookId: "demo|1", position: stored.position),
            "which is only true if the migration wrote the id the model derives"
        )
    }

    /// A mark whose index names no chapter is dropped. It never had a stable identity to
    /// convert — there is no id to write down — and a row that can never resolve again
    /// would be permanent dead weight in a list the reader cannot clear by reading.
    ///
    /// Deliberately not the same answer as a chapter removed *after* v6: that row keeps a
    /// real chapter id, so it is kept and can come back to life if the site restores the
    /// chapter. This one has nothing to come back to.
    func testMigrationDropsMarksWhoseIndexNamesNoChapter() throws {
        let queue = try storeAtV5(markedChapterIndexes: [1, 9])

        try AppDatabase.migrator.migrate(queue)

        let repo = LibraryRepo(database: try AppDatabase(queue))
        XCTAssertEqual(
            try repo.readingBookmarks(bookId: "demo|1").map(\.siteChapterId), ["c1"],
            "index 9 is past the end of the catalog, so there is nothing to name"
        )
        XCTAssertEqual(try repo.highlights(bookId: "demo|1").map(\.siteChapterId), ["c1"])
    }

    /// The index columns go rather than sitting beside the ids. Keeping both would leave
    /// two answers to "which chapter", and the number is the one that rots — this whole
    /// migration is what happens when something reads the rotten one.
    func testTheChapterIndexColumnsAreGone() throws {
        let queue = try storeAtV5(markedChapterIndexes: [1])

        try AppDatabase.migrator.migrate(queue)

        for table in [ReadingBookmark.databaseTableName, TextHighlight.databaseTableName] {
            let columns = try queue.read { db in try db.columns(in: table).map(\.name) }
            XCTAssertFalse(columns.contains("chapterIndex"), "\(table) still has the index")
            XCTAssertTrue(columns.contains("siteChapterId"), "\(table) is missing the id")
        }
    }

    /// A database as v5 shipped it, written in raw SQL: these rows have to be the shape
    /// the released app wrote, which the current models can no longer express.
    ///
    /// The chapter ids are deliberately unlike the numbers they sit at, so that a
    /// migration that quietly copied the index across would fail rather than pass.
    private func storeAtV5(markedChapterIndexes: [Int]) throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v5.highlights")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO "book" ("id", "siteId", "siteBookId", "title", "addedAt", "updatedAt")
                VALUES ('demo|1', 'demo', '1', 't', '2024-01-01', '2024-01-01')
                """)
            for index in 0..<5 {
                try db.execute(
                    sql: """
                        INSERT INTO "chapter"
                        ("id", "bookId", "siteChapterId", "index", "title", "url")
                        VALUES (?, 'demo|1', ?, ?, '第\(index + 1)章', 'https://demo.test/1/\(index)')
                        """,
                    arguments: ["demo|1|c\(index)", "c\(index)", index]
                )
            }
            for index in markedChapterIndexes {
                try db.execute(
                    sql: """
                        INSERT INTO "readingBookmark"
                        ("id", "bookId", "chapterIndex", "paragraph", "characterOffset",
                         "createdAt", "excerpt")
                        VALUES (?, 'demo|1', ?, 17, 23, '2024-02-01', '雪停了。')
                        """,
                    arguments: ["demo|1|\(index)|17|23", index]
                )
                try db.execute(
                    sql: """
                        INSERT INTO "textHighlight"
                        ("id", "bookId", "chapterIndex", "startParagraph", "startCharacterOffset",
                         "endParagraph", "endCharacterOffset", "createdAt", "excerpt")
                        VALUES (?, 'demo|1', ?, 3, 0, 3, 6, '2024-02-01', '雪停了。')
                        """,
                    arguments: ["demo|1|\(index)|3|0|3|6", index]
                )
            }
        }
        return queue
    }
}
