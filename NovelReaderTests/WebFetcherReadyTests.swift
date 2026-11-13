import Network
import XCTest
@testable import NovelReader

/// A page whose load event never comes, read as soon as what the fetch wants is on it.
///
/// The comic sites are covered in ad images, and on the slowest of them the load event
/// did not arrive inside the fetch timeout at all — so every catalog waited out the whole
/// readable grace, five seconds, for a list that had been there since the first second.
/// The fixture reproduces that with one image whose server accepts the connection and
/// never answers.
@MainActor
final class WebFetcherReadyTests: XCTestCase {
    private struct Links: Decodable { let count: Int }
    private static let countLinks =
        "(function () { return { count: document.querySelectorAll('#list a').length }; })()"

    func testAPageThatNeverFinishesLoadingIsReadOnceItsListIsThere() async throws {
        let stall = try StallingServer()
        defer { stall.stop() }
        let fetcher = WebFetcher()
        let host = HeadlessHost(webView: fetcher.webView)
        defer { host.tearDown() }
        let catalog = Self.page("""
        <img src="http://127.0.0.1:\(stall.port)/banner.jpg">
        <div id="list"><a href="/c/1">第一章</a><a href="/c/2">第二章</a></div>
        """)

        let hurried = ContinuousClock.now
        let ready = try await fetcher.fetch(
            catalog, extracting: Self.countLinks, as: Links.self,
            readyWhen: try ExtractorScript.matches("#list a")
        )
        XCTAssertEqual(ready.count, 2)
        XCTAssertLessThan(
            ContinuousClock.now - hurried, .seconds(3),
            "a parsed page that has its list should not wait for the load event"
        )

        let patient = ContinuousClock.now
        let waited = try await fetcher.fetch(catalog, extracting: Self.countLinks, as: Links.self)
        XCTAssertEqual(waited.count, 2)
        XCTAssertGreaterThanOrEqual(
            ContinuousClock.now - patient, .seconds(5),
            "the fixture must never finish loading, or the first half proves nothing"
        )
    }

    /// A chapter whose page list sits on a global the page's script builds — nothing in
    /// the DOM to wait for, which is why a chapter's readiness is the extractor's own
    /// answer rather than a selector.
    func testAChapterThatNeverFinishesLoadingIsReadOnceItsPagesCanBe() async throws {
        let stall = try StallingServer()
        defer { stall.stop() }
        let fetcher = WebFetcher()
        let host = HeadlessHost(webView: fetcher.webView)
        defer { host.tearDown() }
        let rule = try JSONDecoder().decode(SiteRule.self, from: Data(Self.comicRule.utf8))
        let chapter = Self.page("""
        <img src="http://127.0.0.1:\(stall.port)/ad.gif">
        <h1>第1話</h1>
        <script>var newImgs = ['https://img.test/1.jpg', 'https://img.test/2.jpg'];</script>
        """)

        let start = ContinuousClock.now
        let read = try await fetcher.fetch(
            chapter, extracting: try ExtractorScript.comicImages(rule),
            as: ExtractorScript.ComicImagesPayload.self,
            readyWhen: try ExtractorScript.comicImagesReady(rule)
        )
        XCTAssertEqual(read.imageURLs, ["https://img.test/1.jpg", "https://img.test/2.jpg"])
        XCTAssertLessThan(
            ContinuousClock.now - start, .seconds(3),
            "a parsed chapter whose pages can be read should not wait for the load event"
        )
    }

    private static let comicRule = """
    {
      "id": "ready-comic", "name": "Ready Comic", "host": "comic.test", "kind": "comic",
      "urls": {
        "book": "https://comic.test/b/{bookId}",
        "catalog": "https://comic.test/b/{bookId}",
        "chapter": "https://comic.test/c/{chapterId}"
      },
      "idPatterns": { "bookId": "/b/(\\\\d+)", "chapterId": "/c/(\\\\d+)" },
      "book": { "title": { "meta": "og:title" } },
      "catalog": { "container": "#chapters", "linkSelector": "a", "order": "ascending" },
      "images": { "strategies": [{ "type": "global", "arrayPath": "newImgs" }] }
    }
    """

    private static func page(_ body: String) -> URL {
        let html = "<html><head><meta charset=\"utf-8\"></head><body>\(body)</body></html>"
        let encoded = html.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return URL(string: "data:text/html;charset=utf-8,\(encoded)")!
    }
}

/// A loopback server that takes every connection and never says a word, so whatever
/// asked it for something is still waiting when the test ends.
private final class StallingServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "StallingServer")
    private let listener: NWListener
    /// Held so the connections stay open; touched only on `queue`.
    private var connections: [NWConnection] = []
    private(set) var port: UInt16 = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.connections.append(connection)
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    func stop() {
        listener.cancel()
        queue.sync { connections.forEach { $0.cancel() } }
    }
}
