import XCTest
@testable import NovelReader

/// Leaving the app mid-download buys background time to finish the chapter in flight.
/// That time is an assertion the app must hand back; one it loses track of is never
/// ended, and iOS ends the app instead.
@MainActor
final class BackgroundDrainTests: XCTestCase {
    private var tempRoot: URL!
    private var env: AppEnvironment!

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NovelReaderTests-\(UUID().uuidString)")
        env = AppEnvironment(
            database: try AppDatabase.makeInMemory(),
            files: ChapterFileStore(root: tempRoot.appendingPathComponent("files")),
            cache: ChapterCache(
                files: ChapterFileStore(root: tempRoot.appendingPathComponent("cache"))
            ),
            coverFiles: CoverStore(root: tempRoot.appendingPathComponent("covers")),
            sites: SiteStore(directory: tempRoot.appendingPathComponent("sites")),
            queueStore: DownloadQueueStore(url: tempRoot.appendingPathComponent("queue.json"))
        )
    }

    override func tearDownWithError() throws {
        env.downloader.cancel()
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // fb20261113b: iOS 27 can report the background twice with no return to the app in
    // between (`phase bg` twice a second apart in both device traces). The second
    // departure took out a new assertion over the first, and the drain it superseded
    // then ended the *new* one — so the queue drained holding nothing, and the first was
    // never ended. Both traces end the same way: that lost assertion expires, and the
    // next line is a fresh launch. A 38-hour-old process was gone minutes later.
    func test_regression_fb20261113b_leavingTwiceKeepsOneAssertionHeld() throws {
        let rule = SiteRule(
            id: "demo", name: "Demo", host: "novels.test",
            urls: .init(
                book: "https://novels.test/book/{bookId}",
                catalog: "https://novels.test/book/{bookId}/",
                chapter: "https://novels.test/txt/{bookId}/{chapterId}"
            ),
            idPatterns: .init(bookId: "/book/(\\d+)", chapterId: "/txt/\\d+/(\\d+)"),
            search: nil,
            book: .init(
                title: .init(meta: nil, selector: "h1", attribute: nil),
                author: nil, cover: nil, category: nil, status: nil, intro: nil, latestChapter: nil
            ),
            catalog: .init(container: "#catalog", linkSelector: "a", order: .ascending),
            chapter: .init(
                titleSelectors: ["h1"], contentSelectors: [".content"],
                stripSelectors: [], dropParagraphPatterns: nil, prevSelector: nil, nextSelector: nil
            ),
            notes: nil
        )
        let book = try env.repo.bookmark(siteId: "demo", siteBookId: "1", title: "A")
        let chapter = Chapter(
            id: "c1", bookId: book.id, siteChapterId: "c1", index: 0,
            title: "chapter", url: "https://novels.test/txt/1/1", addedAt: nil, downloadedAt: nil
        )
        env.downloader.start(book: book, rule: rule, chapters: [chapter])
        XCTAssertTrue(env.downloader.isBusy, "precondition: a chapter on the wire")

        env.enterBackground()
        let first = env.backgroundAssertion
        XCTAssertNotEqual(first, .invalid, "precondition: leaving bought background time")
        env.enterBackground()

        XCTAssertTrue(env.downloader.isDraining, "still finishing the chapter")
        XCTAssertEqual(
            env.backgroundAssertion, first,
            "draining must hold the assertion it started with — anything else lost one"
        )

        env.downloader.cancel()
        XCTAssertEqual(env.backgroundAssertion, .invalid, "handed back once the queue is at rest")
    }
}
