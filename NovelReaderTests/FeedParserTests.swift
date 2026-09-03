import XCTest
@testable import NovelReader

/// A feed is the one source this app reads that nobody wrote a rule for, so the parser
/// is the whole of the site-specific knowledge — and everything downstream of it treats
/// what comes out as fact. Two of its answers are load-bearing far beyond parsing:
///
/// - **Identity.** `ParsedItem.identity` becomes `Chapter.siteChapterId`, which the
///   reading position, bookmarks and highlights all point at. An article that changes
///   identity between two refreshes is one the reader loses their place in *and* sees
///   again as new; two articles that share one are two collapsed into one.
/// - **The body.** RSS overwhelmingly wraps it in CDATA, which `XMLParser` delivers
///   through a callback of its own — miss it and every article in the world is empty.
///
/// Fixtures are written inline rather than saved as files, matching `EpubDocumentTests`:
/// what each document is trying to prove is then readable beside the assertion.
final class FeedParserTests: XCTestCase {
    private let feedURL = URL(string: "https://example.com/blog/feed.xml")!

    private func parse(_ text: String) throws -> ParsedFeed {
        try FeedParser.parse(Data(text.utf8), url: feedURL)
    }

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    // MARK: - RSS 2.0

    func testRSSReadsTheChannelAndItsItems() throws {
        let feed = try parse("""
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/">
          <channel>
            <title>Example Blog</title>
            <link>https://example.com/</link>
            <image><url>https://example.com/icon.png</url></image>
            <item>
              <title>First post</title>
              <link>https://example.com/first</link>
              <guid isPermaLink="false">tag:example.com,2026:1</guid>
              <description>A teaser sentence.</description>
              <pubDate>Wed, 02 Oct 2002 08:00:00 GMT</pubDate>
              <dc:creator>Ada</dc:creator>
            </item>
          </channel>
        </rss>
        """)

        XCTAssertEqual(feed.title, "Example Blog")
        XCTAssertEqual(feed.homePageURL, "https://example.com/")
        XCTAssertEqual(feed.iconURL, "https://example.com/icon.png")
        XCTAssertEqual(feed.items.count, 1)
        let item = try XCTUnwrap(feed.items.first)
        XCTAssertEqual(item.title, "First post")
        XCTAssertEqual(item.url, "https://example.com/first")
        XCTAssertEqual(item.guid, "tag:example.com,2026:1")
        XCTAssertEqual(item.contentHTML, "A teaser sentence.")
        XCTAssertEqual(item.author, "Ada")
        XCTAssertEqual(item.datePublished, date("2002-10-02T08:00:00Z"))
    }

    /// The single most common shape in the whole format, and the one that reads as
    /// empty if `foundCDATA` is not implemented: the article is not in the document's
    /// character data at all.
    func testAnArticleWrappedInCDATASurvives() throws {
        let feed = try parse("""
        <rss version="2.0"><channel><item>
          <title>Post</title>
          <description><![CDATA[<p>Real markup &amp; a paragraph.</p>]]></description>
        </item></channel></rss>
        """)

        XCTAssertEqual(feed.items.first?.contentHTML, "<p>Real markup &amp; a paragraph.</p>")
    }

    /// A feed that fills both puts the article in one and a teaser in the other. Read
    /// the wrong way round, every article in the library ends at "read more".
    func testTheFullArticleWinsOverTheSummary() throws {
        let feed = try parse("""
        <rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/">
        <channel><item>
          <description>Teaser.</description>
          <content:encoded><![CDATA[<p>The whole article.</p>]]></content:encoded>
        </item></channel></rss>
        """)

        XCTAssertEqual(feed.items.first?.contentHTML, "<p>The whole article.</p>")
    }

    /// `<atom:link rel="self">` addresses the feed document. Taken as the site, "open
    /// the original" would hand the reader the XML they are already reading.
    func testTheFeedsOwnAddressIsNotMistakenForTheSite() throws {
        let feed = try parse("""
        <rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">
        <channel>
          <atom:link href="https://example.com/blog/feed.xml" rel="self" type="application/rss+xml"/>
          <link>https://example.com/blog/</link>
          <title>Blog</title>
        </channel></rss>
        """)

        XCTAssertEqual(feed.homePageURL, "https://example.com/blog/")
    }

    /// Nothing requires a channel to declare its title before its first item. Searching
    /// descendants instead of direct children would name the feed after an article.
    func testAChannelIsNotNamedAfterItsFirstArticle() throws {
        let feed = try parse("""
        <rss version="2.0"><channel>
          <item><title>An article</title></item>
          <title>The blog</title>
        </channel></rss>
        """)

        XCTAssertEqual(feed.title, "The blog")
    }

    func testRelativeLinksAreResolvedAgainstTheFeed() throws {
        let feed = try parse("""
        <rss version="2.0"><channel><item>
          <link>/2026/09/a-post</link>
        </item></channel></rss>
        """)

        XCTAssertEqual(feed.items.first?.url, "https://example.com/2026/09/a-post")
    }

    // MARK: - RSS 1.0 / RDF

    /// RSS 1.0 puts its items *beside* the channel rather than inside it, and has no
    /// `<pubDate>` at all. Both are why the reader collects items from the document and
    /// consults `<dc:date>`.
    func testRDFItemsSitBesideTheChannel() throws {
        let feed = try parse("""
        <?xml version="1.0"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                 xmlns:dc="http://purl.org/dc/elements/1.1/">
          <channel rdf:about="https://example.com/">
            <title>Old School</title>
            <link>https://example.com/</link>
          </channel>
          <item rdf:about="https://example.com/one">
            <title>One</title>
            <link>https://example.com/one</link>
            <dc:date>2002-10-02T08:00:00Z</dc:date>
          </item>
        </rdf:RDF>
        """)

        XCTAssertEqual(feed.title, "Old School")
        XCTAssertEqual(feed.items.count, 1)
        XCTAssertEqual(feed.items.first?.title, "One")
        XCTAssertEqual(feed.items.first?.datePublished, date("2002-10-02T08:00:00Z"))
    }

    // MARK: - Atom

    func testAtomReadsEntriesAndTheirAlternateLinks() throws {
        let feed = try parse("""
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Atom Blog</title>
          <link rel="self" href="https://example.com/blog/feed.xml"/>
          <link rel="alternate" href="https://example.com/blog/"/>
          <icon>https://example.com/icon.png</icon>
          <entry>
            <title>An entry</title>
            <link rel="alternate" href="https://example.com/entry"/>
            <id>urn:uuid:1225c695</id>
            <published>2002-10-02T08:00:00Z</published>
            <updated>2026-09-03T00:00:00Z</updated>
            <author><name>Grace</name></author>
            <content type="html">&lt;p&gt;Escaped markup.&lt;/p&gt;</content>
          </entry>
        </feed>
        """)

        XCTAssertEqual(feed.title, "Atom Blog")
        XCTAssertEqual(feed.homePageURL, "https://example.com/blog/")
        XCTAssertEqual(feed.iconURL, "https://example.com/icon.png")
        let entry = try XCTUnwrap(feed.items.first)
        XCTAssertEqual(entry.url, "https://example.com/entry")
        XCTAssertEqual(entry.guid, "urn:uuid:1225c695")
        XCTAssertEqual(entry.author, "Grace")
        XCTAssertEqual(entry.contentHTML, "<p>Escaped markup.</p>")
        // When the article appeared, not when it was last touched: `updated` is four
        // years later here precisely so a reader that took it would be visible.
        XCTAssertEqual(entry.datePublished, date("2002-10-02T08:00:00Z"))
    }

    /// `type="xhtml"` holds real elements. Read as text the article arrives as one
    /// paragraph-less run of prose, which is what the reader would then have to scroll
    /// through.
    func testAtomXHTMLContentKeepsItsParagraphs() throws {
        let feed = try parse("""
        <feed xmlns="http://www.w3.org/2005/Atom">
          <entry>
            <content type="xhtml">
              <div xmlns="http://www.w3.org/1999/xhtml">
                <p>First paragraph.</p>
                <p>Second one, with <em>emphasis</em>.</p>
              </div>
            </content>
          </entry>
        </feed>
        """)

        let html = try XCTUnwrap(feed.items.first?.contentHTML)
        XCTAssertTrue(html.contains("<p>First paragraph.</p>"), html)
        XCTAssertTrue(html.contains("<em>emphasis</em>"), html)
    }

    func testAtomFallsBackToTheSummaryAndToUpdated() throws {
        let feed = try parse("""
        <feed xmlns="http://www.w3.org/2005/Atom"><entry>
          <summary>All there is.</summary>
          <updated>2002-10-02T08:00:00Z</updated>
        </entry></feed>
        """)

        XCTAssertEqual(feed.items.first?.contentHTML, "All there is.")
        XCTAssertEqual(feed.items.first?.datePublished, date("2002-10-02T08:00:00Z"))
    }

    // MARK: - JSON Feed

    func testJSONFeedReadsItsItems() throws {
        let feed = try parse("""
        {
          "version": "https://jsonfeed.org/version/1.1",
          "title": "JSON Blog",
          "home_page_url": "https://example.com/",
          "icon": "https://example.com/icon.png",
          "items": [
            {
              "id": "1",
              "url": "https://example.com/one",
              "title": "One",
              "content_html": "<p>Markup.</p>",
              "date_published": "2002-10-02T08:00:00Z",
              "authors": [{ "name": "Linus" }]
            }
          ]
        }
        """)

        XCTAssertEqual(feed.title, "JSON Blog")
        XCTAssertEqual(feed.iconURL, "https://example.com/icon.png")
        let item = try XCTUnwrap(feed.items.first)
        XCTAssertEqual(item.guid, "1")
        XCTAssertEqual(item.contentHTML, "<p>Markup.</p>")
        XCTAssertEqual(item.author, "Linus")
        XCTAssertEqual(item.datePublished, date("2002-10-02T08:00:00Z"))
    }

    /// `content_text` is not markup, and everything downstream reads markup. Handed
    /// over untouched it would become one paragraph the length of an article.
    func testPlainTextContentBecomesParagraphs() throws {
        let feed = try parse("""
        {
          "version": "https://jsonfeed.org/version/1.1",
          "items": [{ "id": "1", "content_text": "Line one.\\nLine two." }]
        }
        """)

        XCTAssertEqual(feed.items.first?.contentHTML, "<p>Line one.</p><p>Line two.</p>")
    }

    /// Every field of a JSON Feed but `version` is optional, so an error page from a
    /// misconfigured host decodes cleanly as a feed with no items — subscribing the
    /// reader to nothing and reporting success.
    func testJSONThatIsNotAFeedIsRefused() {
        XCTAssertThrowsError(try parse(#"{ "error": "not found", "items": [] }"#))
    }

    func testAnHTMLPageIsRefused() {
        XCTAssertThrowsError(try parse("<!DOCTYPE html><html><body><h1>Hi</h1></body></html>"))
    }

    // MARK: - Entities

    /// XML defines five named entities; HTML defines hundreds, and feeds are written by
    /// people thinking in HTML. `XMLParser` treats an undefined one as fatal, so without
    /// the repair pass a single em dash in a single headline costs the whole feed.
    func testNamedHTMLEntitiesDoNotLoseTheFeed() throws {
        let feed = try parse("""
        <rss version="2.0"><channel>
          <title>Tips &amp; Tricks &mdash; the blog</title>
          <item><title>Space&nbsp;bar</title></item>
        </channel></rss>
        """)

        XCTAssertEqual(feed.title, "Tips & Tricks — the blog")
        XCTAssertEqual(feed.items.first?.title, "Space\u{00A0}bar")
    }

    /// An entity the table does not know must cost one word, not the subscription: it
    /// comes through as the literal the publisher wrote.
    func testAnUnknownEntityCostsOneWordAndNotTheFeed() throws {
        let feed = try parse("""
        <rss version="2.0"><channel>
          <item><title>Say &frobnicate; now</title></item>
        </channel></rss>
        """)

        XCTAssertEqual(feed.items.first?.title, "Say &frobnicate; now")
    }

    // MARK: - Identity

    /// The publisher's own id first. Everything the reader marks in an article is
    /// filed under this.
    func testIdentityPrefersThePublishersOwnId() {
        let item = ParsedItem(guid: "tag:a", url: "https://example.com/a", title: "A")
        XCTAssertEqual(item.identity, "tag:a")
    }

    func testIdentityFallsBackToThePermalink() {
        let item = ParsedItem(url: "https://example.com/a", title: "A")
        XCTAssertEqual(item.identity, "https://example.com/a")
    }

    /// A recurring column shares its title with every previous instalment, and a batch
    /// published together shares a date. Neither alone can name an article.
    func testTwoUntitledPostsOnTheSameDayAreStillTwoArticles() {
        let when = date("2002-10-02T08:00:00Z")
        let first = ParsedItem(title: "Weekly digest", datePublished: when)
        let second = ParsedItem(title: "Weekly digest", datePublished: when.addingTimeInterval(60))
        XCTAssertNotEqual(first.identity, second.identity)
    }

    /// A publisher fixing a typo has not published a new article. If the body were part
    /// of the identity, the reader would find the same piece in their list twice — one
    /// of them carrying their bookmarks, the other flagged as new.
    func testCorrectingAnArticleDoesNotRepublishIt() {
        let when = date("2002-10-02T08:00:00Z")
        let before = ParsedItem(title: "A post", contentHTML: "<p>teh</p>", datePublished: when)
        let after = ParsedItem(title: "A post", contentHTML: "<p>the</p>", datePublished: when)
        XCTAssertEqual(before.identity, after.identity)
    }

    // MARK: - Dates

    func testRFC822DatesAreReadInTheirCommonShapes() {
        let expected = date("2002-10-02T08:00:00Z")
        XCTAssertEqual(FeedDate.parse("Wed, 02 Oct 2002 08:00:00 GMT"), expected)
        XCTAssertEqual(FeedDate.parse("Wed, 2 Oct 2002 08:00:00 +0000"), expected)
        XCTAssertEqual(FeedDate.parse("02 Oct 2002 08:00:00 GMT"), expected)
        XCTAssertEqual(FeedDate.parse("Wed, 02 Oct 2002 08:00 GMT"), expected)
        // No zone at all, which RFC 822 says to read as GMT.
        XCTAssertEqual(FeedDate.parse("Wed, 02 Oct 2002 08:00:00"), expected)
    }

    func testISO8601DatesAreReadWithAndWithoutFractionalSeconds() {
        let expected = date("2002-10-02T08:00:00Z")
        XCTAssertEqual(FeedDate.parse("2002-10-02T08:00:00Z"), expected)
        XCTAssertEqual(FeedDate.parse("2002-10-02T08:00:00.000Z"), expected)
        XCTAssertEqual(FeedDate.parse("2002-10-02T16:00:00+08:00"), expected)
        // The `T` written as a space — neither standard allows it, and it is common.
        // This is also the shape that catches the prefix trap: every reader here
        // matches a prefix, so a date-only formatter consulted too early answers
        // midnight and quietly loses the time of day.
        XCTAssertEqual(FeedDate.parse("2002-10-02 08:00:00"), expected)
        // And a feed that really does publish only a day still parses.
        XCTAssertEqual(FeedDate.parse("2002-10-02"), date("2002-10-02T00:00:00Z"))
    }

    /// Nil has to survive as nil. Reading an unparseable date as "now" would sort every
    /// such article to the top of the feed on every refresh — a list that reshuffles
    /// itself each time it is opened.
    func testAnUnreadableDateIsNilRatherThanNow() {
        XCTAssertNil(FeedDate.parse("sometime last week"))
        XCTAssertNil(FeedDate.parse(""))
        XCTAssertNil(FeedDate.parse(nil))
    }
}
