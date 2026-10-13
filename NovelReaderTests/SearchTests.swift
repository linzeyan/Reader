import XCTest
@testable import NovelReader

/// Cross-site search is the feature most exposed to one bad source breaking
/// everything, and to encoding mistakes on the legacy-charset sites. These tests
/// pin the parts that can be checked without a live network.
final class SearchTests: XCTestCase {

    private func makeRule(search: SiteRule.Search?) -> SiteRule {
        SiteRule(
            id: "demo",
            name: "Demo",
            host: "demo.test",
            urls: .init(
                book: "https://demo.test/book/{bookId}.htm",
                catalog: "https://demo.test/book/{bookId}/",
                chapter: "https://demo.test/txt/{bookId}/{chapterId}"
            ),
            idPatterns: .init(bookId: "/book/(\\d+)", chapterId: "/txt/\\d+/(\\d+)"),
            search: search,
            book: .init(
                title: .init(meta: "og:novel:book_name", selector: nil, attribute: nil),
                author: nil, cover: nil, category: nil, status: nil, intro: nil, latestChapter: nil
            ),
            catalog: .init(container: "#catalog", linkSelector: "a", order: .ascending),
            chapter: .init(
                titleSelectors: ["h1"], contentSelectors: [".content"],
                stripSelectors: [], dropParagraphPatterns: nil,
                prevSelector: nil, nextSelector: nil
            ),
            notes: nil
        )
    }

    private func getSearch(url: String) -> SiteRule.Search {
        .init(
            method: .get, url: url, queryField: "keyword",
            resultContainer: "#results", resultLinkSelector: "a.book",
            resultTitleSelector: nil, resultAuthorSelector: ".author", resultCoverSelector: nil
        )
    }

    /// A Chinese query has to survive templating into a GET URL. Getting this
    /// wrong silently returns zero results rather than erroring, so it is worth
    /// pinning explicitly.
    func testGetSearchURLPercentEncodesChineseQuery() throws {
        let search = getSearch(url: "https://demo.test/search/?keyword={query}")
        let url = try XCTUnwrap(SearchService.getSearchURL(search, query: "武俠"))
        XCTAssertFalse(url.absoluteString.contains("{query}"), "template placeholder survived")
        XCTAssertTrue(url.absoluteString.contains("%E6%AD%A6%E4%BF%A0"))
        // The decoded form must round-trip back to what the user typed.
        XCTAssertEqual(url.query?.removingPercentEncoding, "keyword=武俠")
    }

    func testGetSearchURLHandlesSpaces() throws {
        let search = getSearch(url: "https://demo.test/search/?keyword={query}")
        let url = try XCTUnwrap(SearchService.getSearchURL(search, query: "a b"))
        XCTAssertNil(URLComponents(string: url.absoluteString)?.host.flatMap { _ in nil as String? })
        XCTAssertFalse(url.absoluteString.contains(" "), "raw space would make an invalid URL")
    }

    /// A form submit writes a title's space as `+`; missing that left a comic site
    /// probed with 「ONE PIECE」 looking as if it had no search at all.
    func testTemplateRecognisesAFormEncodedSpace() {
        XCTAssertEqual(
            SearchDeriver.template(from: "https://demo.test/search?q=ONE+PIECE&t=1", query: "ONE PIECE"),
            "https://demo.test/search?q={query}&t=1"
        )
        XCTAssertEqual(
            SearchDeriver.template(from: "https://demo.test/search?q=ONE%20PIECE", query: "ONE PIECE"),
            "https://demo.test/search?q={query}"
        )
    }

    /// A site whose rule has no search block must be reported as unsupported,
    /// not silently treated as "found nothing" — an all-sites search has to tell
    /// the user which sources it could not query.
    func testSearchScriptRefusesRuleWithoutSearchBlock() {
        let rule = makeRule(search: nil)
        XCTAssertThrowsError(try ExtractorScript.searchResults(rule)) { error in
            guard case ExtractorScript.BuildError.searchUnsupported = error else {
                return XCTFail("expected searchUnsupported, got \(error)")
            }
        }
        XCTAssertThrowsError(try ExtractorScript.submitSearch(rule, query: "x"))
    }

    func testSearchScriptCarriesRuleSelectors() throws {
        let rule = makeRule(search: getSearch(url: "https://demo.test/search/?keyword={query}"))
        let script = try ExtractorScript.searchResults(rule)
        XCTAssertTrue(script.contains("#results"))
        XCTAssertTrue(script.contains("a.book"))
        XCTAssertTrue(script.contains(".author"))
    }

    /// The POST path submits a real form so WebKit applies the document's
    /// charset. The query must reach that form intact, including quotes that
    /// would otherwise break out of the generated JS.
    func testSubmitScriptEscapesQuery() throws {
        let search = SiteRule.Search(
            method: .post, url: "https://demo.test/modules/article/search.php",
            queryField: "searchkey", resultContainer: nil, resultLinkSelector: "a",
            resultTitleSelector: nil, resultAuthorSelector: nil, resultCoverSelector: nil
        )
        let rule = makeRule(search: search)
        let script = try ExtractorScript.submitSearch(rule, query: "he said \"hi\"")
        XCTAssertTrue(script.contains("searchkey"))
        XCTAssertFalse(script.contains("\"hi\""), "unescaped quotes would break the script")
        XCTAssertTrue(script.contains("\\\"hi\\\""))
    }

    // MARK: - Reading a results page

    /// A results row as 69shuba publishes one: the book is linked from its cover
    /// and again from its heading, at the same address, and the cover's `<img>`
    /// carries `alt="1"` — a lazy-loading index, not a name.
    private static let coverAndHeadingRows = """
    <html><body><div class="newbox"><ul>
      <li>
        <a href="/book/51837.htm" class="imgbox"><img src="/c1.jpg" alt="1"></a>
        <a href="/book/51837.htm" class="imgbox"> </a>
        <h3><a href="/book/51837.htm">劍來</a></h3>
      </li>
      <li>
        <a href="/book/53884.htm" class="imgbox"><img src="/c2.jpg" alt="1"></a>
        <h3><a href="/book/53884.htm">劍來（1-42冊）精校版</a></h3>
      </li>
    </ul></div></body></html>
    """

    private func rowsRule() -> SiteRule {
        makeRule(search: .init(
            method: .post, url: "https://demo.test/modules/article/search.php",
            queryField: "searchkey", resultContainer: nil, resultLinkSelector: "a",
            resultTitleSelector: nil, resultAuthorSelector: nil, resultCoverSelector: nil
        ))
    }

    /// The extractor accepts an image's `alt` as a title, which it has to — plenty
    /// of sites link a book from its cover and nowhere else. What it must not do is
    /// let that settle the matter: 69shuba's covers are all `alt="1"`, so taking the
    /// first link per address handed the reader six books called "1" and threw the
    /// heading that names each one away as a duplicate.
    @MainActor
    func testACoverLinkDoesNotKeepTheNameTheHeadingWouldHaveGiven() async throws {
        let payload = try await extract(
            ExtractorScript.searchResults(rowsRule()),
            as: ExtractorScript.SearchPayload.self
        )
        XCTAssertEqual(payload.rows.count, 2, "one row per book, not one per link")
        XCTAssertEqual(payload.rows.map(\.title), ["劍來", "劍來（1-42冊）精校版"])
    }

    /// The derivation preview is what a user confirms a derived rule against, so it
    /// has to read names exactly the way the extractor does — a preview that says
    /// something the search will not say is worse than no preview.
    @MainActor
    func testTheDerivationPreviewNamesBooksTheWayTheExtractorWill() async throws {
        let payload = try await extract(
            SearchDeriver.resultsProbe(rowsRule()),
            as: SearchDeriver.ResultsPayload.self
        )
        XCTAssertEqual(payload.count, 2)
        XCTAssertEqual(payload.titles, ["劍來", "劍來（1-42冊）精校版"])
    }

    // MARK: - Finding the search box

    /// m.wfxs.tw's header: no box on the homepage, only a magnifier linking to the page
    /// that has one, with no text for a person to read and none for a probe either.
    @MainActor
    func testAHomepageWithoutASearchBoxPointsTheWayToOne() async throws {
        let page = ScriptedPage(baseURL: URL(string: "https://demo.test/")!)
        await page.load("""
        <html><body><div class="pull_right">
          <a href="/history.html" class="book"></a>
          <a href="/s/" class="search_new"></a>
        </div><a href="/book/1.html">劍來</a></body></html>
        """)
        let found = try await page.evaluate(SearchDeriver.formProbe, as: SearchDeriver.FormsPayload.self)
        XCTAssertTrue(found.forms.isEmpty)
        XCTAssertEqual(found.searchLink, "https://demo.test/s/")
    }

    /// 85novel's header, whose search runs on Enter or on the magnifier, and whose
    /// nearest button is the × that empties the box. Clicking that one was the whole
    /// search: the query typed in and wiped straight back out.
    @MainActor
    func testTheButtonThatEmptiesTheBoxIsNotTakenForTheSearch() async throws {
        let did = try await submitTyping(in: """
        <div><div class="relative">
          <input id="head-search" type="text" onkeydown="if (event.key === 'Enter') window.did = 'entered'">
          <button onclick="window.did = 'cleared'">×</button>
        </div><button onclick="window.did = 'searched'"><svg></svg></button></div>
        """)
        XCTAssertEqual(did, "searched")

        let alone = try await submitTyping(in: """
        <div><input id="head-search" type="text" onkeydown="if (event.key === 'Enter') window.did = 'entered'">
        <button class="clear" onclick="window.did = 'cleared'"><svg></svg></button></div>
        """)
        XCTAssertEqual(alone, "entered", "with only the × beside it, the box is sent with Enter")
    }

    @MainActor
    private func submitTyping(in body: String) async throws -> String {
        let page = ScriptedPage(baseURL: URL(string: "https://demo.test/")!)
        await page.load("<html><body>\(body)</body></html>")
        let submit = SearchDeriver.typeAndSubmit(selector: "#head-search", query: "劍來")
        _ = try await page.evaluate("({ ok: \(submit) })", as: [String: Bool].self)
        return try await page.evaluate("({ did: window.did || 'nothing' })", as: [String: String].self)["did"]!
    }

    @MainActor
    private func extract<T: Decodable>(_ script: String, as type: T.Type) async throws -> T {
        let page = ScriptedPage(baseURL: URL(string: "https://demo.test/modules/article/search.php")!)
        await page.load(Self.coverAndHeadingRows)
        return try await page.evaluate(script, as: type)
    }

    /// Results must be convertible to the same identity the library uses, or a
    /// search hit could not be matched against an existing bookmark.
    func testResultIdentityMatchesBookIdentity() {
        let rule = makeRule(search: getSearch(url: "https://demo.test/search/?keyword={query}"))
        let url = URL(string: "https://demo.test/book/1234.htm")!
        let bookId = rule.bookId(from: url)
        XCTAssertEqual(bookId, "1234")
        XCTAssertEqual(
            Book.makeId(siteId: rule.id, siteBookId: bookId!),
            "demo|1234"
        )
    }
}
