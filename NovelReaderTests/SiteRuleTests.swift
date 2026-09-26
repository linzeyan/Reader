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

    // MARK: - Pages whose text is not where a plain read finds it

    /// Shaped on haodoo: a table of contents with no links, whose chapter names are
    /// lines of a `<pre>` and whose chapters are addressed by position.
    private static let linesJSON = """
    {
      "id": "lines", "name": "Lines", "host": "www.lines.test",
      "urls": {
        "book": "https://www.lines.test/?P={bookId}:0",
        "catalog": "https://www.lines.test/?P={bookId}:0",
        "chapter": "https://www.lines.test/?P={bookId}:{chapterId}"
      },
      "idPatterns": { "bookId": "[?&]P=([A-Za-z0-9]+):\\\\d", "chapterId": "[?&]P=[A-Za-z0-9]+:([1-9]\\\\d*)" },
      "book": { "title": { "selector": "title" } },
      "catalog": { "container": "#SourceText", "linkSelector": "", "order": "ascending", "lines": true },
      "chapter": {
        "titleSelectors": [], "contentSelectors": ["#content"], "stripSelectors": [],
        "visibleOnly": true,
        "replacements": { "︵": "（", "︶": "）" }
      }
    }
    """

    /// The site paints these lines into a grid of one-character cells, so reading
    /// links would title every chapter 「第」. Read as lines, each chapter keeps its
    /// whole name, is numbered the way the site's reader numbers it — a blank line
    /// is not a chapter — and gets an address built from the template, since the
    /// page links to none. The catalog is typeset like the text, so the preface's
    /// vertical brackets come back horizontal.
    @MainActor
    func testALineCatalogKeepsWholeNamesAndBuildsEachChaptersAddress() async throws {
        let rule = try JSONDecoder().decode(SiteRule.self, from: Data(Self.linesJSON.utf8))
        let page = ScriptedPage()
        await page.load("""
        <html><body>
          <pre id="SourceText" style="display:none">內容簡介

        原序︵趙苕狂︶
        第一回　風雪驚變</pre>
          <table><tr><td class="Char" onclick="GoToChapter(1)">內</td></tr></table>
        </body></html>
        """)
        let payload = try await page.evaluate(
            try ExtractorScript.catalog(rule), as: ExtractorScript.CatalogPayload.self
        )
        let entries = BookService.entries(from: payload, rule: rule, siteBookId: "I09D2")

        XCTAssertEqual(entries.map(\.siteChapterId), ["1", "2", "3"])
        XCTAssertEqual(entries.map(\.title), ["內容簡介", "原序（趙苕狂）", "第一回 風雪驚變"])
        XCTAssertEqual(entries.last?.url, "https://www.lines.test/?P=I09D2:3")
    }

    /// Shaped on qimao: the book's pages build their chapter list in a script that
    /// races the load event, but the site's own API answers the whole list as JSON.
    private static let jsonCatalogJSON = """
    {
      "id": "api", "name": "API", "host": "www.api.test",
      "urls": {
        "book": "https://www.api.test/shuku/{bookId}/",
        "catalog": "https://www.api.test/api/chapter-list?book_id={bookId}",
        "chapter": "https://www.api.test/shuku/{bookId}-{chapterId}/"
      },
      "idPatterns": { "bookId": "/shuku/(\\\\d+)", "chapterId": "/shuku/\\\\d+-(\\\\d+)/" },
      "book": { "title": { "selector": "h1" } },
      "catalog": {
        "container": "body", "linkSelector": "", "order": "ascending",
        "json": { "arrayPath": "data.chapters", "idKey": "id", "titleKey": "title" }
      },
      "chapter": { "titleSelectors": [], "contentSelectors": ["#content"], "stripSelectors": [] }
    }
    """

    /// The list comes whole, chapter 1 included — the page's own panel leaves out
    /// the chapter it is showing. Each chapter is addressed through the template
    /// with the id the API gave, whether that came as a number or a string, and a
    /// row without an id or a title is not a chapter.
    @MainActor
    func testAJSONCatalogListsEveryChapterByTheIdsTheSiteGave() async throws {
        let rule = try JSONDecoder().decode(SiteRule.self, from: Data(Self.jsonCatalogJSON.utf8))
        let page = ScriptedPage()
        await page.load("""
        {"code":0,"data":{"chapters":[
          {"id":"499610","title":"第1章 红杏出墙","is_vip":"0"},
          {"id":520725,"title":"第2章 漂亮的女上司","is_vip":"0"},
          {"id":"","title":"没有 id"},
          {"id":"521841","title":"  "},
          {"id":"521842","title":"第3章 有仇必报","is_vip":"1"}
        ]}}
        """)
        let payload = try await page.evaluate(
            try ExtractorScript.catalog(rule), as: ExtractorScript.CatalogPayload.self
        )
        let entries = BookService.entries(from: payload, rule: rule, siteBookId: "195958")

        XCTAssertEqual(entries.map(\.siteChapterId), ["499610", "520725", "521842"])
        XCTAssertEqual(entries.map(\.title), ["第1章 红杏出墙", "第2章 漂亮的女上司", "第3章 有仇必报"])
        XCTAssertEqual(entries.first?.url, "https://www.api.test/shuku/195958-499610/")
    }

    /// Shaped on 99csw: decoy copies sit in the chapter hidden by a stylesheet
    /// class, and the real paragraphs wait at `visibility: hidden` until the reader
    /// scrolls to them. Only the decoys go: a paragraph not yet revealed is still the
    /// chapter, and a check on visibility rather than display would drop nearly all
    /// of it — on the live site 3 of 44 paragraphs are visible at load.
    @MainActor
    func testAChapterKeepsParagraphsTheSiteHasNotRevealedAndDropsItsDecoys() async throws {
        let rule = try JSONDecoder().decode(SiteRule.self, from: Data(Self.linesJSON.utf8))
        let chapter = """
        <html><head><style>
          #content > div { visibility: hidden }
          #content .v1 { visibility: visible }
          #content .x9 { display: none }
        </style></head><body>
          <div id="content">
            <div class="v1">第一段</div>
            <div class="x9">誘餌段落</div>
            <div>第二段</div>
            <div>第三段</div>
          </div>
        </body></html>
        """
        let page = ScriptedPage()
        await page.load(chapter)
        let read = try await page.evaluate(
            try ExtractorScript.chapter(rule), as: ExtractorScript.ChapterPayload.self
        )
        XCTAssertEqual(read.paragraphs, ["第一段", "第二段", "第三段"])

        // The control: the same page read the ordinary way carries the decoy, which
        // is what makes the assertion above mean anything.
        let plain = SiteRule.Chapter(
            titleSelectors: [], contentSelectors: ["#content"], stripSelectors: [],
            dropParagraphPatterns: nil, prevSelector: nil, nextSelector: nil
        )
        let untouched = ScriptedPage()
        await untouched.load(chapter)
        let asMarkup = try await untouched.evaluate(
            try ExtractorScript.chapter(plain), as: ExtractorScript.ChapterPayload.self
        )
        XCTAssertEqual(asMarkup.paragraphs, ["第一段", "誘餌段落", "第二段", "第三段"])
    }
}
