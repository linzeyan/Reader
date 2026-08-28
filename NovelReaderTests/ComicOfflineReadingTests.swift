import UIKit
import XCTest
@testable import NovelReader

/// Reading a comic that is already on the device.
///
/// This is what downloading a comic is *for*, and the only place the promise can be
/// checked: on a plane, a chapter either opens or it does not, and there is no way to
/// fix it there. Every path here runs with a session that refuses every request, so a
/// test that passes has proved the pages came off the disk rather than proving the
/// simulator has a network.
@MainActor
final class ComicOfflineReadingTests: XCTestCase {
    private var tempRoot: URL!
    private var env: AppEnvironment!
    private var files: ChapterFileStore!
    private var book: Book!

    private let siteId = "comic.test"
    private let siteBookId = "1"
    private let siteChapterId = "c1"

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ComicOfflineReadingTests-\(UUID().uuidString)")
        files = ChapterFileStore(root: tempRoot.appendingPathComponent("files"))
        env = AppEnvironment(
            database: try AppDatabase.makeInMemory(),
            files: files,
            coverFiles: CoverStore(root: tempRoot.appendingPathComponent("covers")),
            sites: SiteStore(directory: tempRoot.appendingPathComponent("sites")),
            queueStore: DownloadQueueStore(url: tempRoot.appendingPathComponent("queue.json"))
        )
        book = try env.repo.bookmark(
            siteId: siteId, siteBookId: siteBookId, kind: .comic, title: "漫畫"
        )
        try env.repo.replaceCatalog(bookId: book.id, entries: [
            (siteChapterId: siteChapterId, title: "第1話", url: "https://comic.test/1"),
        ])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    /// No site rule is installed, so every route to the network is closed before it
    /// starts: if the chapter opens, it opened off the disk. That is also a real state —
    /// a book restored from iCloud onto a device that never imported the rule — and its
    /// downloaded chapters have no reason not to be readable.
    func testADownloadedChapterOpensWithNoRuleAndNoNetwork() async throws {
        let pages = (0..<3).map { Data("page \($0)".utf8) }
        try env.downloads.save(pages: pages, book: book, siteChapterId: siteChapterId)

        let model = ComicReaderModel(book: book, env: env)
        await model.start(at: .chapterStart(siteChapterId))

        XCTAssertNil(model.error)
        XCTAssertEqual(model.loaded.count, 1)
        let opened = try XCTUnwrap(model.loaded.first)
        XCTAssertEqual(opened.imageURLs.count, 3)
        XCTAssertTrue(opened.imageURLs.allSatisfy(\.isFileURL))
        XCTAssertEqual(try opened.imageURLs.map { try Data(contentsOf: $0) }, pages)
    }

    /// The disk decides, not the flag. A row can outlive its files — the storage screen
    /// clears flags before it removes anything, and a crash in between leaves exactly
    /// this — and a chapter of no pages is not something to open. It reads as absent, so
    /// the ordinary online path runs and reports why it cannot.
    func testAChapterWhoseFilesAreGoneIsNotOpenedAsAnEmptyOne() async throws {
        try env.downloads.save(pages: [Data("page 0".utf8)], book: book, siteChapterId: siteChapterId)
        try FileManager.default.removeItem(
            at: files.pageDirectory(
                siteId: siteId, siteBookId: siteBookId, siteChapterId: siteChapterId
            )
        )

        let model = ComicReaderModel(book: book, env: env)
        await model.start(at: .chapterStart(siteChapterId))

        XCTAssertTrue(model.loaded.isEmpty)
        XCTAssertNotNil(model.error, "a chapter that is not on disk after all has to say so")
    }

    /// The other half of the same promise: the store draws a downloaded page without
    /// asking anything for it. The size matters as much as the picture — the column
    /// stacks pages by their heights, and a downloaded chapter that reported estimates
    /// would shift under the reader as it drew.
    func testTheStoreSizesAndDecodesAPageFromDisk() async throws {
        let bytes = Self.png(width: 80, height: 120)
        try env.downloads.save(pages: [bytes], book: book, siteChapterId: siteChapterId)
        let urls = files.pageURLs(siteId: siteId, siteBookId: siteBookId, siteChapterId: siteChapterId)

        let store = ComicPageStore(
            urls: urls,
            chapterPage: URL(string: "https://comic.test/1")!,
            fetcher: ImageFetcher(session: Self.refusingSession())
        )
        let sized = expectation(description: "size")
        let drawn = expectation(description: "image")
        store.onSize = { _, _ in sized.fulfill() }
        store.onImage = { _ in drawn.fulfill() }
        store.onFailure = { page, error in
            XCTFail("page \(page) went to the network: \(error)")
        }

        store.setWindow(0..<1, width: 80)

        await fulfillment(of: [sized, drawn], timeout: 5)
        XCTAssertEqual(store.size(page: 0), CGSize(width: 80, height: 120))
        XCTAssertNotNil(store.image(page: 0))
    }

    // MARK: - Helpers

    /// A real PNG, because this is the one test that decodes rather than counting
    /// bytes. Scale 1 so the pixel size is the size asked for.
    private static func png(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let size = CGSize(width: width, height: height)
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.gray.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// Airplane mode, in the only form a test can have it: every request fails.
    private static func refusingSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RefusingOrigin.self]
        return URLSession(configuration: config)
    }
}

/// Answers every request with "no network", so any page that reaches for one fails
/// loudly instead of quietly succeeding on the machine running the tests.
private final class RefusingOrigin: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}
