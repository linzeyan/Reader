import XCTest
@testable import NovelReader

/// The file a subscription list travels in.
///
/// Both directions matter equally and for the same reason: this is the promise that the
/// forty feeds someone spent years collecting are theirs and not this app's. A reader
/// gets exactly one chance to believe that, on the day they try to leave.
final class OPMLTests: XCTestCase {
    private func read(_ opml: String) -> [OPML.Subscription] {
        OPML.subscriptions(in: Data(opml.utf8))
    }

    // MARK: - Reading

    /// A NetNewsWire export, which is what most of these files will be.
    func testAnExportedListIsRead() {
        let found = read("""
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="1.0">
          <head><title>Subscriptions</title></head>
          <body>
            <outline text="Daring Fireball" title="Daring Fireball" type="rss" \
        xmlUrl="https://daringfireball.net/feeds/main" htmlUrl="https://daringfireball.net/"/>
            <outline text="Inessential" title="Inessential" type="rss" \
        xmlUrl="https://inessential.com/feed.json"/>
          </body>
        </opml>
        """)

        XCTAssertEqual(found, [
            OPML.Subscription(title: "Daring Fireball", address: "https://daringfireball.net/feeds/main"),
            OPML.Subscription(title: "Inessential", address: "https://inessential.com/feed.json"),
        ])
    }

    /// Folders are how anyone with forty subscriptions keeps them, and this app has none.
    /// Reading only the top level would quietly drop most of a real list.
    func testFeedsInsideFoldersAreImportedToo() {
        let found = read("""
        <opml version="1.0"><body>
          <outline text="Loose feed" xmlUrl="https://a.example/feed"/>
          <outline text="Tech">
            <outline text="Nested" xmlUrl="https://b.example/feed"/>
            <outline text="Deeper">
              <outline text="Deepest" xmlUrl="https://c.example/feed"/>
            </outline>
          </outline>
        </body></opml>
        """)

        XCTAssertEqual(
            found.map(\.address),
            ["https://a.example/feed", "https://b.example/feed", "https://c.example/feed"]
        )
    }

    /// An outline with no address is a folder or a note, not a broken feed.
    func testOutlinesWithNoAddressAreSkipped() {
        XCTAssertTrue(read("""
        <opml version="1.0"><body>
          <outline text="Just a folder"/>
          <outline text="A note" _note="remember this"/>
        </body></opml>
        """).isEmpty)
    }

    /// Twenty years of exporters have written this attribute every way there is, and a
    /// reader that insists on one spelling loses the whole file over it.
    func testTheAddressAttributeIsReadWhateverItsCase() {
        XCTAssertEqual(
            read(#"<opml><body><outline text="A" xmlurl="https://a.example/feed"/></body></opml>"#)
                .map(\.address),
            ["https://a.example/feed"]
        )
    }

    /// `text` is the attribute OPML requires of every outline; `title` is the one that is
    /// often missing. Either names a feed, and a subscription with no name is a blank row.
    func testTheNameFallsBackToTheRequiredAttribute() {
        XCTAssertEqual(
            read(#"<opml><body><outline text="Only text" xmlUrl="https://a.example/feed"/></body></opml>"#)
                .first?.title,
            "Only text"
        )
    }

    /// The same feed filed in two folders is one subscription — `Book.id` is the address,
    /// so importing it twice would only mean fetching it twice.
    func testTheSameAddressIsImportedOnce() {
        let found = read("""
        <opml><body>
          <outline text="Tech"><outline text="A" xmlUrl="https://a.example/feed"/></outline>
          <outline text="Daily"><outline text="A" xmlUrl="https://a.example/feed"/></outline>
        </body></opml>
        """)

        XCTAssertEqual(found.count, 1)
    }

    /// Anything can be dropped on a file picker, and what comes back has to be "no feeds
    /// here" rather than a crash or a subscription to nothing.
    func testSomethingThatIsNotOPMLReadsAsNoSubscriptions() {
        XCTAssertTrue(read("<html><body>Not OPML at all</body></html>").isEmpty)
        XCTAssertTrue(read("").isEmpty)
    }

    // MARK: - Writing

    /// The claim the export makes: what this app wrote, this app can read — which is the
    /// weakest form of the promise, and the only half a test can hold on its own.
    func testWhatIsWrittenCanBeReadBack() {
        let subscriptions = [
            OPML.Subscription(title: "Daring Fireball", address: "https://daringfireball.net/feeds/main"),
            OPML.Subscription(title: "Inessential", address: "https://inessential.com/feed.json"),
        ]

        let document = OPML.document(title: "Subscriptions", subscriptions: subscriptions)

        XCTAssertEqual(read(document), subscriptions)
    }

    /// A title with an ampersand in it is the commonest thing in the world — and written
    /// raw it makes the document unparseable, so one such feed would cost the reader the
    /// whole export.
    func testTitlesAndAddressesAreEscaped() {
        let subscriptions = [
            OPML.Subscription(title: #"Arts & "Letters""#, address: "https://a.example/?feed=rss&x=1"),
        ]

        let document = OPML.document(title: "Subscriptions", subscriptions: subscriptions)

        XCTAssertTrue(document.contains("Arts &amp;"), document)
        XCTAssertEqual(read(document), subscriptions)
    }

    /// An unnamed subscription is written under its address rather than as a blank row —
    /// which is what a list of empty outlines looks like in the reader it lands in.
    func testAFeedWithNoNameIsWrittenUnderItsAddress() {
        let document = OPML.document(
            title: "Subscriptions",
            subscriptions: [OPML.Subscription(title: nil, address: "https://a.example/feed")]
        )

        XCTAssertEqual(read(document).first?.title, "https://a.example/feed")
    }
}
