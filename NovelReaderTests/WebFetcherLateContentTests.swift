import XCTest
@testable import NovelReader

/// Pages that are not finished when they say they are.
///
/// The fetcher reads a page at its load event. Two kinds of site make that the
/// wrong moment: one fills its chapter list in by XHR after load, and one serves a
/// proof-of-work page first that swaps itself for the real page a second later.
/// Both are driven through the real `fetch` on local pages, because what is being
/// pinned is the waiting, and the waiting lives nowhere else.
@MainActor
final class WebFetcherLateContentTests: XCTestCase {
    private struct Links: Decodable { let count: Int }
    private static let countLinks = "(function () { return { count: document.querySelectorAll('#list a').length }; })()"

    /// A chapter list that lands a second after load.
    private static let lateList = page("""
    <div id="list"></div>
    <script>
      setTimeout(function () {
        document.getElementById('list').innerHTML = '<a href="/c/1">第一章</a><a href="/c/2">第二章</a>';
      }, 1000);
    </script>
    """)

    /// Read without waiting, the list is not there yet — which is the whole reason
    /// `waitFor` exists — and waited for, it is.
    func testALateChapterListIsReadWhenTheRuleWaitsForIt() async throws {
        let fetcher = WebFetcher()
        let host = HeadlessHost(webView: fetcher.webView)
        defer { host.tearDown() }

        let hurried = try await fetcher.fetch(Self.lateList, extracting: Self.countLinks, as: Links.self)
        XCTAssertEqual(hurried.count, 0, "the fixture must be late, or this test proves nothing")

        let waited = try await fetcher.fetch(
            Self.lateList, extracting: Self.countLinks, as: Links.self, waitingFor: "#list a"
        )
        XCTAssertEqual(waited.count, 2)
    }

    /// A search with no hits never produces the row a rule waits for. That must end
    /// as the extractor's own "nothing here", not as an error — a failed search and
    /// an empty one are different things to tell a reader.
    func testAWaitThatNeverMatchesStillReadsThePage() async throws {
        let fetcher = WebFetcher()
        let host = HeadlessHost(webView: fetcher.webView)
        defer { host.tearDown() }

        let empty = Self.page("<div id=\"list\"></div><p>沒有找到</p>")
        let read = try await fetcher.fetch(
            empty, extracting: Self.countLinks, as: Links.self, waitingFor: "#list a"
        )
        XCTAssertEqual(read.count, 0)
    }

    /// One site's own bot check: a page titled 「正在验证浏览器」 whose script solves a
    /// proof of work and then replaces itself with the page asked for. Read at its
    /// load event, the reader gets the check's text, and parking the web view right
    /// after kills the proof before it earns the cookie — so every fetch failed.
    func testASelfClearingProofOfWorkPageIsWaitedOutRatherThanRead() async throws {
        let fetcher = WebFetcher()
        let host = HeadlessHost(webView: fetcher.webView)
        defer { host.tearDown() }

        let check = Self.page("""
        <title>正在验证浏览器</title>
        <script src="/__gatekeeper_challenge/assets/0/challenge.js"></script>
        <p>请稍候，验证将自动完成。</p>
        <script>
          setTimeout(function () {
            document.open();
            document.write('<html><body><h1 id="book">詭舍2</h1></body></html>');
            document.close();
          }, 1000);
        </script>
        """)
        struct Title: Decodable { let title: String? }
        let read = try await fetcher.fetch(
            check,
            extracting: "(function () { var h = document.getElementById('book'); return { title: h ? h.textContent : null }; })()",
            as: Title.self
        )
        XCTAssertEqual(read.title, "詭舍2")
    }

    private static func page(_ body: String) -> URL {
        let html = "<html><head><meta charset=\"utf-8\"></head><body>\(body)</body></html>"
        let encoded = html.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return URL(string: "data:text/html;charset=utf-8,\(encoded)")!
    }
}
