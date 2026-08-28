import WebKit
import XCTest
@testable import NovelReader

/// Comics reach the app the same way novels do — as a rule file someone imported —
/// so three things have to hold. The format can say "this is a comic" without any
/// existing rule file changing. A rule that cannot read a chapter is refused while
/// the user is still looking at an import sheet, not in front of an empty reader.
/// And the image extractor reads what these sites actually publish while never
/// running anything the rule file says: a rule travels between users and is read
/// inside the one web view holding all of their cookies.
final class ComicRuleTests: XCTestCase {

    // MARK: - Fixtures

    /// A novel rule as they were written before comics existed: no `kind` key at all.
    private static let legacyNovelJSON = """
    {
      "id": "demo-novel",
      "name": "Demo Novel",
      "host": "novel.test",
      "urls": {
        "book": "https://novel.test/n/{bookId}",
        "catalog": "https://novel.test/n/{bookId}",
        "chapter": "https://novel.test/n/{bookId}/{chapterId}"
      },
      "idPatterns": {
        "bookId": "/n/([0-9a-z]+)",
        "chapterId": "/n/[0-9a-z]+/([0-9a-z]+)"
      },
      "book": { "title": { "meta": "og:title" } },
      "catalog": { "container": "#catalog", "linkSelector": "a", "order": "ascending" },
      "chapter": {
        "titleSelectors": ["h1"],
        "contentSelectors": [".content"],
        "stripSelectors": ["script"]
      }
    }
    """

    /// Shaped after the comic site whose catalog links nowhere and whose images
    /// hide behind an attribute of the site's own choosing. The strategies are a
    /// parameter because they are what each test here is about.
    private static func comicJSON(strategies: String = domStrategy) -> String {
        """
        {
          "id": "demo-comic",
          "name": "Demo Comic",
          "host": "comic.test",
          "kind": "comic",
          "urls": {
            "book": "https://comic.test/html/{bookId}.html",
            "catalog": "https://comic.test/html/{bookId}.html",
            "chapter": "https://comic.test/online/new-{bookId}.html?ch={chapterId}"
          },
          "idPatterns": {
            "bookId": "/html/(\\\\d+)\\\\.html",
            "chapterId": "cview\\\\('\\\\d+-(\\\\d+)\\\\.html'"
          },
          "book": { "title": { "meta": "og:title" } },
          "catalog": {
            "container": "#chapters",
            "linkSelector": "a",
            "order": "ascending",
            "linkAttribute": "onclick"
          },
          "images": { "strategies": [\(strategies)] }
        }
        """
    }

    private static let domStrategy = """
    { "type": "dom", "selector": "#pics img", "attributes": ["s", "data-src", "src"], "unescape": true }
    """

    private func rule(_ json: String) throws -> SiteRule {
        try JSONDecoder().decode(SiteRule.self, from: Data(json.utf8))
    }

    @MainActor
    private func emptyStore() -> SiteStore {
        SiteStore(
            directory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("NovelReaderTests-\(UUID().uuidString)")
        )
    }

    // MARK: - The format

    /// The promise made when `kind` was added: not one byte of an existing rule
    /// file has to change. Every rule written before comics is a novel, so a
    /// missing key has a correct answer rather than being an error.
    func testARuleFileWithNoKindReadsAsANovel() throws {
        let rule = try rule(Self.legacyNovelJSON)
        XCTAssertEqual(rule.kind, .novel)
        XCTAssertNotNil(rule.chapter)
        XCTAssertNil(rule.images)
        XCTAssertNil(rule.catalog.linkAttribute)
    }

    /// Rules are re-encoded on the way to disk, so what a device reads back is what
    /// this build can decode. A comic that lost its kind on that round trip would
    /// reappear as a novel and be sent to the text reader.
    @MainActor
    func testAComicRuleSurvivesTheImportRoundTrip() throws {
        let store = emptyStore()
        try store.importRule(data: Data(Self.comicJSON().utf8))
        try store.load()

        let stored = try XCTUnwrap(store.rule(id: "demo-comic"))
        XCTAssertEqual(stored.kind, .comic)
        XCTAssertEqual(stored.catalog.linkAttribute, "onclick")
        XCTAssertNil(stored.chapter)
        XCTAssertEqual(stored.images?.strategies.count, 1)
        XCTAssertEqual(stored.images?.strategies.first?.type, .dom)
        XCTAssertEqual(stored.images?.strategies.first?.attributes, ["s", "data-src", "src"])
        XCTAssertEqual(stored.images?.strategies.first?.unescape, true)
    }

    /// Both halves of the same rule: a source that declares what it is has to carry
    /// the block that reads it. Neither failure has anywhere honest to go later —
    /// the reader would have nothing to show and nothing to say about why.
    @MainActor
    func testASourceThatCannotReadAChapterIsRefusedAtImport() throws {
        let store = emptyStore()

        let comicWithoutImages = Self.comicJSON()
            .replacingOccurrences(of: "\"images\"", with: "\"unusedImages\"")
        XCTAssertThrowsError(try store.importRule(data: Data(comicWithoutImages.utf8)))

        let novelWithoutChapter = Self.legacyNovelJSON
            .replacingOccurrences(of: "\"chapter\": {", with: "\"unusedChapter\": {")
        XCTAssertThrowsError(try store.importRule(data: Data(novelWithoutChapter.utf8)))

        XCTAssertTrue(store.rules.isEmpty, "a refused rule must not be installed")
    }

    /// Routing a comic into the text reader is a bug in the app, not a bad rule
    /// file, and it has to surface as one rather than extracting nothing and
    /// reading as an empty chapter.
    func testAskingAComicRuleForTextFails() throws {
        let comic = try rule(Self.comicJSON())
        XCTAssertThrowsError(try ExtractorScript.chapter(comic))

        let novel = try rule(Self.legacyNovelJSON)
        XCTAssertThrowsError(try ExtractorScript.comicImages(novel))
    }

    // MARK: - Catalogs that link nowhere

    /// The site this field exists for publishes `<a href="#" onclick="cview(…)">`:
    /// the href identifies nothing and the chapter is named only inside the
    /// handler's arguments. So the id comes out of the raw attribute text and the
    /// address is rebuilt from the template.
    func testACatalogLinkingNowhereRebuildsChapterURLsFromTheTemplate() throws {
        let rule = try rule(Self.comicJSON())
        let payload = ExtractorScript.CatalogPayload(entries: [
            .init(title: "第1話", url: "cview('103-1.html',3,'',1)"),
            .init(title: "第2話", url: "cview('103-2.html',3,'',1)"),
        ])

        let entries = BookService.entries(from: payload, rule: rule, siteBookId: "103")

        XCTAssertEqual(entries.map(\.siteChapterId), ["1", "2"])
        XCTAssertEqual(entries.map(\.url), [
            "https://comic.test/online/new-103.html?ch=1",
            "https://comic.test/online/new-103.html?ch=2",
        ])
    }

    /// And the ordinary case is untouched: where the catalog does link somewhere,
    /// the site's own link is what gets stored, because several of these templates
    /// do not round-trip through `{bookId}/{chapterId}`.
    func testAnOrdinaryCatalogKeepsTheSitesOwnLinks() throws {
        let rule = try rule(Self.legacyNovelJSON)
        let payload = ExtractorScript.CatalogPayload(entries: [
            .init(title: "第一章", url: "https://novel.test/n/s6ojkc/s6675fe9?chapterNumber=1"),
            // A "you may also like" cross-link. The chapter pattern matches it, so
            // naming another book is the only thing that tells it apart.
            .init(title: "別本第一章", url: "https://novel.test/n/uefad/z51cc7l"),
            // The same chapter again, the way a catalog repeats its newest entries
            // in a header.
            .init(title: "第一章", url: "https://novel.test/n/s6ojkc/s6675fe9"),
            // Navigation swept up by a broad link selector.
            .init(title: "回書頁", url: "https://novel.test/n/s6ojkc"),
        ])

        let entries = BookService.entries(from: payload, rule: rule, siteBookId: "s6ojkc")

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].siteChapterId, "s6675fe9")
        XCTAssertEqual(
            entries[0].url, "https://novel.test/n/s6ojkc/s6675fe9?chapterNumber=1",
            "the query the site put on its own link is part of the address it published"
        )
    }

    // MARK: - Reading the pages off a chapter

    /// The site whose `<img>` tags are all in the DOM from the start with an empty
    /// `src`, the real address parked in an attribute and HTML-escaped. Reading
    /// `src` is the single biggest trap on it, so the attribute priority list — and
    /// the unescaping — are what the whole strategy rests on.
    @MainActor
    func testADomStrategyPrefersTheNamedAttributeAndUnescapesIt() async throws {
        let payload = try await extractImages(
            from: Self.comicJSON(),
            html: """
            <html><body>
              <div id="pics">
                <img s="https://img1.comic.test/103/1/001.jpg?a=1&amp;b=2" src="">
                <img s="https://img1.comic.test/103/1/002.jpg" src="/placeholder.gif">
                <img src="/banner.gif">
              </div>
            </body></html>
            """
        )

        XCTAssertEqual(payload.imageURLs, [
            "https://img1.comic.test/103/1/001.jpg?a=1&b=2",
            "https://img1.comic.test/103/1/002.jpg",
            // The banner has no `s` and no `data-src`, so the list falls through to
            // `src` — which is exactly what the rule asked for, and why the selector
            // is the thing that has to be tight.
            "https://comic.test/banner.gif",
        ])
        XCTAssertEqual(payload.matchedStrategy, "dom:#pics img")
    }

    /// The two sites that keep only one image in the DOM at a time and publish the
    /// whole chapter as a global their own scripts built. Both shapes: a plain array
    /// of finished URLs, and a directory plus file names plus the CDN's required
    /// query, which has to be assembled.
    @MainActor
    func testAGlobalStrategyWalksADotPathAndAssemblesCDNURLs() async throws {
        let json = Self.comicJSON(strategies: """
            { "type": "global", "arrayPath": "newImgs" },
            { "type": "global", "arrayPath": "cInfo.files", "prefixPath": "cInfo.path",
              "queryPath": "cInfo.sl", "baseURL": "https://cdn.comic.test" }
            """)

        // First strategy absent from the page: the second must take over, which is
        // the whole point of an ordered list.
        let assembled = try await extractImages(
            from: json,
            html: """
            <html><body><script>
              var cInfo = {
                path: '/ps1/o/103/1/',
                files: ['001.jpg', '002.jpg'],
                sl: { e: 1756339200, m: 'abc123' }
              };
              window.cInfo = cInfo;
            </script></body></html>
            """
        )
        XCTAssertEqual(assembled.imageURLs, [
            "https://cdn.comic.test/ps1/o/103/1/001.jpg?e=1756339200&m=abc123",
            "https://cdn.comic.test/ps1/o/103/1/002.jpg?e=1756339200&m=abc123",
        ])
        XCTAssertEqual(assembled.matchedStrategy, "global:cInfo.files")

        // And where the site simply publishes finished URLs, the same strategy type
        // needs none of the assembly fields.
        let direct = try await extractImages(
            from: json,
            html: """
            <html><body><script>
              window.newImgs = ['https://cdn.comic.test/a.webp', 'https://cdn.comic.test/b.webp'];
            </script></body></html>
            """
        )
        XCTAssertEqual(
            direct.imageURLs,
            ["https://cdn.comic.test/a.webp", "https://cdn.comic.test/b.webp"]
        )
        XCTAssertEqual(direct.matchedStrategy, "global:newImgs")
    }

    /// The line the whole design rests on. A rule file is written by one user and
    /// imported by another, and it is read inside the web view carrying every
    /// cookie the reader owns — so a path in a rule is *walked*, one property at a
    /// time, and never evaluated. A rule that smuggles JavaScript into `arrayPath`
    /// must find nothing and change nothing.
    @MainActor
    func testAPathInARuleIsWalkedNeverExecuted() async throws {
        let json = Self.comicJSON(strategies: """
            { "type": "global",
              "arrayPath": "pages;document.getElementById('sentinel').remove()" },
            { "type": "dom", "selector": "#pics img", "attributes": ["s"] }
            """)

        let page = ScriptedPage()
        await page.load("""
        <html><body>
          <div id="sentinel"></div>
          <div id="pics"><img s="https://img1.comic.test/1.jpg"></div>
        </body></html>
        """)

        let payload = try await page.evaluate(
            try ExtractorScript.comicImages(rule(json)), as: ExtractorScript.ComicImagesPayload.self
        )
        XCTAssertEqual(payload.imageURLs, ["https://img1.comic.test/1.jpg"])
        XCTAssertEqual(
            payload.matchedStrategy, "dom:#pics img",
            "the smuggled path has to come back empty, not throw the extraction away"
        )

        let after = try await page.evaluate(
            "({ present: !!document.getElementById('sentinel') })", as: Sentinel.self
        )
        XCTAssertTrue(after.present, "nothing in the rule may run")
    }

    private struct Sentinel: Decodable { let present: Bool }

    @MainActor
    private func extractImages(
        from ruleJSON: String, html: String
    ) async throws -> ExtractorScript.ComicImagesPayload {
        let script = try ExtractorScript.comicImages(try rule(ruleJSON))
        let page = ScriptedPage()
        await page.load(html)
        return try await page.evaluate(script, as: ExtractorScript.ComicImagesPayload.self)
    }
}

/// A page whose own scripts run.
///
/// The web view `WebFetcher.extract(html:)` uses deliberately has scripting off —
/// it reads files from strangers — so it cannot exercise a `global` strategy,
/// whose entire job is to read what a site's scripts built. This is that one
/// missing capability and nothing else: local markup, no network, no cookies.
@MainActor
private final class ScriptedPage: NSObject, WKNavigationDelegate {
    /// Stands in for the chapter page, so a relative URL in the markup resolves
    /// the way it would on the site.
    static let baseURL = URL(string: "https://comic.test/online/new-103.html?ch=1")!

    private let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    private var loaded: CheckedContinuation<Void, Never>?

    func load(_ html: String) async {
        webView.navigationDelegate = self
        await withCheckedContinuation { continuation in
            loaded = continuation
            webView.loadHTMLString(html, baseURL: Self.baseURL)
        }
    }

    func evaluate<T: Decodable>(_ script: String, as type: T.Type) async throws -> T {
        let result = try await webView.evaluateJavaScript(script)
        let data = try JSONSerialization.data(withJSONObject: result as Any)
        return try JSONDecoder().decode(type, from: data)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume()
        loaded = nil
    }
}
