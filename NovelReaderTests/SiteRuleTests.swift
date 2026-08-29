import XCTest
@testable import NovelReader

/// These tests encode why the rule layer exists: a site must be describable
/// purely as data, and a URL a user pasted must resolve back to ids without the
/// app knowing anything site-specific.
final class SiteRuleTests: XCTestCase {

    /// Mirrors docs/sites/69shuba.json. Kept inline so the test suite does not
    /// depend on a file that is deliberately outside the bundle.
    private static let sampleJSON = """
    {
      "id": "69shuba",
      "name": "69書吧",
      "host": "www.69shuba.com",
      "urls": {
        "book": "https://www.69shuba.com/book/{bookId}.htm",
        "catalog": "https://www.69shuba.com/book/{bookId}/",
        "chapter": "https://www.69shuba.com/txt/{bookId}/{chapterId}"
      },
      "idPatterns": {
        "bookId": "/book/(\\\\d+)(?:\\\\.htm|/)",
        "chapterId": "/txt/\\\\d+/(\\\\d+)"
      },
      "search": {
        "method": "POST",
        "url": "https://www.69shuba.com/modules/article/search.php",
        "queryField": "searchkey",
        "resultLinkSelector": "a[href*='/book/']"
      },
      "book": {
        "title": { "meta": "og:novel:book_name" },
        "author": { "meta": "og:novel:author" },
        "cover": { "meta": "og:image" }
      },
      "catalog": {
        "container": "#catalog",
        "linkSelector": "a[href*='/txt/']",
        "order": "ascending"
      },
      "chapter": {
        "titleSelectors": [".txtnav h1", "h1"],
        "contentSelectors": [".txtnav", "#txtcontent"],
        "stripSelectors": [".txtinfo", "script"],
        "prevSelector": "#prev_url",
        "nextSelector": "#next_url"
      }
    }
    """

    private func makeRule() throws -> SiteRule {
        try JSONDecoder().decode(SiteRule.self, from: Data(Self.sampleJSON.utf8))
    }

    func testDecodesRuleFile() throws {
        let rule = try makeRule()
        XCTAssertEqual(rule.id, "69shuba")
        XCTAssertEqual(rule.catalog.order, .ascending)
        XCTAssertEqual(rule.search?.method, .post)
        // Optional book fields must survive being absent — rule files written by
        // users will rarely fill in every field.
        XCTAssertNil(rule.book.status)
    }

    /// A user pastes whatever URL they happened to be on. Both the book page and
    /// the catalog page must resolve to the same book, or "add by link" breaks.
    func testRecoversBookIdFromEitherPageShape() throws {
        let rule = try makeRule()
        let bookPage = URL(string: "https://www.69shuba.com/book/90442.htm")!
        let catalogPage = URL(string: "https://www.69shuba.com/book/90442/")!
        XCTAssertEqual(rule.bookId(from: bookPage), "90442")
        XCTAssertEqual(rule.bookId(from: catalogPage), "90442")
    }

    func testRecoversChapterIdAndRoundTripsToURL() throws {
        let rule = try makeRule()
        let chapterPage = URL(string: "https://www.69shuba.com/txt/90442/41051913")!
        let chapterId = try XCTUnwrap(rule.chapterId(from: chapterPage))
        XCTAssertEqual(chapterId, "41051913")
        XCTAssertEqual(rule.chapterURL(bookId: "90442", chapterId: chapterId), chapterPage)
    }

    func testMatchesOnlyItsOwnHost() throws {
        let rule = try makeRule()
        XCTAssertTrue(rule.matches(URL(string: "https://www.69shuba.com/book/1.htm")!))
        XCTAssertFalse(rule.matches(URL(string: "https://example.com/book/1.htm")!))
    }

    /// A rule names one host, and the sites this app reads answer to two or three:
    /// manhuagui serves the same book at `www.` and `m.`, and its rule can only be
    /// written against the one whose page shape the selectors match. Someone who
    /// copies an address out of a desktop browser was told "add a source first" for
    /// a source they already had — for a book the app can read.
    ///
    /// The label has to be a whole first label and one of the device ones, though:
    /// `tw.` is a different edition of the site with a different page shape, and
    /// matching it would answer the paste with the wrong selectors rather than with
    /// nothing.
    func testMatchesTheSameSiteReachedThroughItsMobileOrDesktopHost() throws {
        let rule = try makeRule()
        XCTAssertTrue(rule.matches(URL(string: "https://m.69shuba.com/book/1.htm")!))
        XCTAssertTrue(rule.matches(URL(string: "https://69shuba.com/book/1.htm")!))
        XCTAssertTrue(rule.matches(URL(string: "https://WWW.69Shuba.com/book/1.htm")!))
        XCTAssertFalse(rule.matches(URL(string: "https://tw.69shuba.com/book/1.htm")!))
        XCTAssertFalse(rule.matches(URL(string: "https://m.69shuba.com.evil.example/book/1.htm")!))
    }

    /// The shelf offers "copy link" so a reader can open the book where it lives
    /// or send it to someone. What it copies has to be the same page the app
    /// itself fetches, and it has to be absent — not wrong — where no page exists.
    @MainActor
    func testSourceURLIsOfferedOnlyWhereThereIsOne() throws {
        let store = SiteStore(
            directory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("NovelReaderTests-\(UUID().uuidString)")
        )
        try store.importRule(data: Data(Self.sampleJSON.utf8))

        let bookmarked = makeBook(siteId: "69shuba", siteBookId: "90442")
        XCTAssertEqual(
            store.sourceURL(of: bookmarked),
            URL(string: "https://www.69shuba.com/book/90442.htm")
        )

        // An imported file was never on the web, and a bookmark whose rule has
        // been removed has no template left to rebuild from. Inventing an address
        // for either is worse than offering nothing.
        XCTAssertNil(store.sourceURL(of: makeBook(siteId: Book.localSiteId, siteBookId: "sha512")))
        XCTAssertNil(store.sourceURL(of: makeBook(siteId: "uninstalled", siteBookId: "1")))
    }

    private func makeBook(siteId: String, siteBookId: String) -> Book {
        Book(
            id: Book.makeId(siteId: siteId, siteBookId: siteBookId),
            siteId: siteId, siteBookId: siteBookId, kind: .novel, title: "t",
            displayName: nil, author: nil, coverURL: nil, addedAt: Date(), updatedAt: Date(),
            lastReadSiteChapterId: nil, lastReadParagraph: nil,
            lastReadCharacterOffset: nil, lastReadFraction: nil, lastReadAt: nil, catalogUpdatedAt: nil
        )
    }

    /// The generated script is what actually runs in the page, so a rule whose
    /// selectors never reach the JS would fail silently at runtime.
    func testGeneratedScriptsCarryTheRuleSelectors() throws {
        let rule = try makeRule()

        let catalog = try ExtractorScript.catalog(rule)
        XCTAssertTrue(catalog.contains("#catalog"))
        XCTAssertTrue(catalog.contains("a[href*='/txt/']"))

        let chapter = try ExtractorScript.chapter(rule)
        XCTAssertTrue(chapter.contains("#txtcontent"))
        XCTAssertTrue(chapter.contains("#prev_url"))

        let book = try ExtractorScript.book(rule)
        XCTAssertTrue(book.contains("og:novel:book_name"))
        // Absent optional fields must not leak a null placeholder into the JS.
        XCTAssertFalse(book.contains("\"status\":null"))
    }
}
