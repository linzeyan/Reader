import XCTest
@testable import NovelReader

/// What the reader's retry button asks for.
///
/// The report behind this: a site demanding verification fails the *first* chapter, so
/// the reader is left on a screen with a message and a retry — and the retry did
/// nothing, because it asked for the chapter *after* the last loaded one and there was
/// no loaded one. Together with a screen that hides the navigation bar, that made the
/// app unleavable. `ReaderFailureExitTests` walks the way out; this pins the button.
@MainActor
final class ReaderRetryTests: XCTestCase {
    private var tempRoot: URL!
    private var env: AppEnvironment!
    private var files: ChapterFileStore!
    private var book: Book!

    private let siteId = "alpha"
    private let siteBookId = "1"
    private let siteChapterId = "c1"

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NovelReaderTests-\(UUID().uuidString)")
        files = ChapterFileStore(root: tempRoot.appendingPathComponent("files"))
        env = AppEnvironment(
            database: try AppDatabase.makeInMemory(),
            files: files,
            cache: ChapterCache(
                files: ChapterFileStore(root: tempRoot.appendingPathComponent("cache"))
            ),
            coverFiles: CoverStore(root: tempRoot.appendingPathComponent("covers")),
            sites: SiteStore(directory: tempRoot.appendingPathComponent("sites")),
            queueStore: DownloadQueueStore(url: tempRoot.appendingPathComponent("queue.json"))
        )
        book = try env.repo.bookmark(siteId: siteId, siteBookId: siteBookId, title: "A")
        try env.repo.replaceCatalog(bookId: book.id, entries: [
            (siteChapterId: siteChapterId, title: "第1章", url: "https://alpha/1"),
        ])
        // Downloaded as far as the catalog is concerned, with the text missing from
        // disk. No site rule is imported either, so there is nowhere to fetch it from —
        // which is a chapter that will not load, without a network to depend on.
        try env.downloads.save(paragraphs: ["一段"], book: book, siteChapterId: siteChapterId)
        try FileManager.default.removeItem(at: chapterFile)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private var chapterFile: URL {
        files.fileURL(siteId: siteId, siteBookId: siteBookId, siteChapterId: siteChapterId)
    }

    func testRetryAsksAgainForTheChapterThatWouldNotOpen() async throws {
        let model = ReaderModel(book: book, env: env)
        await model.start(at: .chapterStart(siteChapterId))
        XCTAssertTrue(model.loaded.isEmpty, "the chapter should have failed to open")
        XCTAssertNotNil(model.error, "and the reader should be saying so")

        // Whatever was in the way is out of the way — the same shape as a verification
        // the reader has just passed in the challenge sheet.
        try files.write(
            paragraphs: ["一段"], siteId: siteId, siteBookId: siteBookId,
            siteChapterId: siteChapterId
        )

        await model.retry()

        XCTAssertEqual(
            model.loaded.count, 1,
            "retry must ask again for the chapter that failed, not for the one after it"
        )
        XCTAssertNil(model.error)
    }
}
