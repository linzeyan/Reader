import XCTest
@testable import NovelReader

/// Reading a page's head for the feed it declares.
///
/// This is the path a normal subscription takes: what someone pastes is the address in
/// their browser's bar, and the feed is a line in the head of what comes back. Everything
/// pinned here is a shape that turns up in real pages, and the cost of getting one wrong
/// is that a perfectly ordinary blog cannot be subscribed to at all.
final class FeedDiscoveryTests: XCTestCase {
    private let page = URL(string: "https://example.com/blog/")!

    private func discover(_ html: String, at url: URL? = nil) -> [URL] {
        FeedDiscovery.feedURLs(inHTML: Data(html.utf8), at: url ?? page)
    }

    private func head(_ links: String) -> String {
        "<!DOCTYPE html><html><head><title>A blog</title>\(links)</head><body></body></html>"
    }

    func testTheDeclaredFeedIsFound() {
        let found = discover(head(
            #"<link rel="alternate" type="application/rss+xml" href="https://example.com/feed.xml">"#
        ))

        XCTAssertEqual(found.map(\.absoluteString), ["https://example.com/feed.xml"])
    }

    /// Feeds are declared as `/feed.xml` far more often than in full, so a discovery that
    /// only handled absolute addresses would miss most of the pages it exists for.
    func testARelativeAddressIsResolvedAgainstThePage() {
        XCTAssertEqual(
            discover(head(#"<link rel="alternate" type="application/atom+xml" href="/feed.xml">"#))
                .map(\.absoluteString),
            ["https://example.com/feed.xml"]
        )
        XCTAssertEqual(
            discover(head(#"<link rel="alternate" type="application/atom+xml" href="atom.xml">"#))
                .map(\.absoluteString),
            ["https://example.com/blog/atom.xml"]
        )
    }

    /// Hand-written and generated markup disagree about every one of these, and a browser
    /// reads them all the same way.
    func testAttributeStyleDoesNotMatter() {
        let found = discover(head(
            """
            <LINK TYPE='application/rss+xml' REL='alternate' TITLE='Posts' HREF='/a.xml' />
            <link href=/b.xml rel=alternate type=application/atom+xml>
            """
        ))

        XCTAssertEqual(
            found.map(\.absoluteString),
            ["https://example.com/a.xml", "https://example.com/b.xml"]
        )
    }

    /// A feed address with parameters is written with `&amp;` in HTML, and left as it is
    /// the request goes out asking for a parameter literally called `amp;format`.
    func testAnEscapedAmpersandIsRestored() {
        let found = discover(head(
            #"<link rel="alternate" type="application/rss+xml" href="/?feed=rss&amp;lang=en">"#
        ))

        XCTAssertEqual(found.map(\.absoluteString), ["https://example.com/?feed=rss&lang=en"])
    }

    /// `rel="alternate"` is also how a page points at its other languages and its print
    /// stylesheet. Those carry no feed type, and following one would subscribe the reader
    /// to a web page.
    func testAlternatesThatAreNotFeedsAreIgnored() {
        let found = discover(head(
            """
            <link rel="alternate" hreflang="fr" href="https://example.com/fr/">
            <link rel="alternate" type="text/html" href="https://m.example.com/">
            <link rel="stylesheet" href="/style.css">
            <link rel="alternate" type="application/json" href="/api/posts.json">
            """
        ))

        XCTAssertTrue(found.isEmpty, "\(found)")
    }

    /// The order the page lists them in is the publisher's own preference, and the first
    /// one is what a subscription takes.
    func testSeveralFeedsComeBackInTheOrderTheyWereDeclared() {
        let found = discover(head(
            """
            <link rel="alternate" type="application/atom+xml" href="/atom.xml">
            <link rel="alternate" type="application/feed+json" href="/feed.json">
            """
        ))

        XCTAssertEqual(
            found.map(\.absoluteString),
            ["https://example.com/atom.xml", "https://example.com/feed.json"]
        )
    }

    /// WordPress declares a comments feed on every page it serves, beside the posts feed
    /// and sometimes before it. Subscribing someone to that is subscribing them to
    /// strangers arguing under articles they never see.
    func testAPostsFeedWinsOverACommentsFeed() {
        let found = discover(head(
            """
            <link rel="alternate" type="application/rss+xml" title="Comments Feed" \
            href="https://example.com/comments/feed/">
            <link rel="alternate" type="application/rss+xml" title="Feed" \
            href="https://example.com/feed/">
            """
        ))

        XCTAssertEqual(
            found.map(\.absoluteString),
            ["https://example.com/feed/", "https://example.com/comments/feed/"],
            "the comments feed is ranked last, not dropped — a site may publish nothing else"
        )
    }

    /// A page that declares nothing has to answer nothing, so that the reader is told
    /// their address is not a feed rather than being subscribed to something else.
    func testAPageThatDeclaresNoFeedFindsNothing() {
        XCTAssertTrue(discover(head("")).isEmpty)
    }

    /// Below the head is where the false positives live: a tag written out by a script, a
    /// code sample showing this very line. Nothing down there was emitted by the platform
    /// as a declaration.
    func testALinkInTheBodyIsNotADeclaration() {
        let html = """
        <html><head><title>A blog</title></head><body>
        <pre>&lt;link rel="alternate" type="application/rss+xml" href="/wrong.xml"&gt;</pre>
        <link rel="alternate" type="application/rss+xml" href="/also-wrong.xml">
        </body></html>
        """

        XCTAssertTrue(discover(html).isEmpty)
    }

    /// The same feed declared twice — which happens when a template and a plugin both
    /// emit it — is one feed.
    func testTheSameAddressIsNotReturnedTwice() {
        let found = discover(head(
            """
            <link rel="alternate" type="application/rss+xml" href="/feed.xml">
            <link rel="alternate" type="application/rss+xml" href="https://example.com/feed.xml">
            """
        ))

        XCTAssertEqual(found.map(\.absoluteString), ["https://example.com/feed.xml"])
    }

    /// A page in some other encoding still has ASCII tag syntax. The bytes that will not
    /// decode are in the text, which this never looks at, and losing the feed over a
    /// mis-encoded headline would be losing it for nothing.
    func testAPageThatIsNotUTF8StillGivesUpItsFeed() {
        var bytes = Data("<html><head><title>".utf8)
        bytes.append(contentsOf: [0xB8, 0xEA, 0xB4, 0xC1])  // Big5, which UTF-8 cannot read
        bytes.append(Data(
            #"</title><link rel="alternate" type="application/rss+xml" href="/feed.xml"></head>"#
                .utf8
        ))

        XCTAssertEqual(
            FeedDiscovery.feedURLs(inHTML: bytes, at: page).map(\.absoluteString),
            ["https://example.com/feed.xml"]
        )
    }
}
