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
