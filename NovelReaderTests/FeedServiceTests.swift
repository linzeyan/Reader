import XCTest
@testable import NovelReader

/// The whole path a subscription takes, with the network stubbed and nothing else:
/// a real database, real files on disk, and the real web view that turns an article's
/// markup into paragraphs. What is asserted at the end is the thing the reader actually
/// gets — the text of an article, read back off the device.
///
/// The network is the only stub because it is the only part that cannot be made to
/// answer on demand. Everything else is the shipping code, so a change that breaks the
/// join between them fails here rather than on a device.
@MainActor
final class FeedServiceTests: XCTestCase {
    private var tempRoot: URL!
    private var repo: LibraryRepo!
    private var downloads: DownloadStore!
    private var service: FeedService!

    private let address = "https://example.com/feed.xml"

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FeedServiceTests-\(UUID().uuidString)")
        let database = try AppDatabase.makeInMemory()
        repo = LibraryRepo(database: database)
        let files = ChapterFileStore(root: tempRoot)
        downloads = DownloadStore(database: database, files: files)
        service = FeedService(
            repo: repo, downloads: downloads, fetcher: WebFetcher(), session: StubProtocol.session()
        )
    }

    override func tearDownWithError() throws {
        StubProtocol.reset()
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func feed(_ items: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel>
          <title>Example Blog</title>
          <link>https://example.com/</link>
          \(items)
        </channel></rss>
        """
    }

    private func item(_ id: String, body: String, published: String = "Wed, 02 Oct 2002 08:00:00 GMT") -> String {
        """
        <item>
          <title>Article \(id)</title>
          <link>https://example.com/\(id)</link>
          <guid>tag:example.com,2026:\(id)</guid>
          <pubDate>\(published)</pubDate>
          <description><![CDATA[\(body)]]></description>
        </item>
        """
    }

    // MARK: - Subscribing

    /// The end-to-end claim of the whole feature: an address goes in, and the article's
    /// text comes back off the device — with no second request, and with nothing asked of
    /// the reader in between.
    func testSubscribingStoresArticleTextOnTheDevice() async throws {
        StubProtocol.answer = .ok(feed(item("1", body: "<p>First paragraph.</p><p>Second one.</p>")))

        let book = try await service.subscribe(to: address)

        XCTAssertEqual(book.kind, .feed)
        XCTAssertEqual(book.siteId, Book.feedSiteId)
        XCTAssertEqual(book.title, "Example Blog")
        let chapter = try XCTUnwrap(try repo.chapters(bookId: book.id).first)
        XCTAssertTrue(chapter.isDownloaded, "an article arrives already on the device")
        let paragraphs = try ChapterFileStore(root: tempRoot).readParagraphs(
            siteId: book.siteId, siteBookId: book.siteBookId, siteChapterId: chapter.siteChapterId
        )
        XCTAssertEqual(paragraphs, ["First paragraph.", "Second one."])
    }

    /// `Book.id` is built out of the address, so the one that is *landed on* has to be
    /// stored: a feed reached over `http` that redirects to `https` would otherwise be two
    /// shelves' worth of the same articles.
    func testTheAddressStoredIsTheOneTheRequestLandedOn() async throws {
        StubProtocol.answer = .ok(feed(item("1", body: "<p>Text.</p>")))
        StubProtocol.landedURL = URL(string: "https://example.com/feed/")!

        let book = try await service.subscribe(to: "example.com/feed")

        XCTAssertEqual(book.siteBookId, "https://example.com/feed/")
    }

    /// A bare host is how an address arrives when it was read off a page rather than
    /// copied out of an address bar.
    func testAnAddressWithNoSchemeIsRead() {
        XCTAssertEqual(
            FeedService.url(from: "example.com/feed.xml")?.absoluteString,
            "https://example.com/feed.xml"
        )
    }

    /// `feed://` is the scheme a browser puts on a subscribe link, and no network stack
    /// has ever spoken it.
    func testTheFeedSchemeIsRewrittenToOneThatExists() {
        XCTAssertEqual(
            FeedService.url(from: "feed://example.com/feed.xml")?.absoluteString,
            "https://example.com/feed.xml"
        )
        XCTAssertEqual(
            FeedService.url(from: "feed:https://example.com/feed.xml")?.absoluteString,
            "https://example.com/feed.xml"
        )
    }

    // MARK: - Refreshing

    /// The politeness budget of the whole feature. Without the validators going back out,
    /// every check downloads the entire document again.
    func testARefreshSendsBackTheValidatorsItWasGiven() async throws {
        StubProtocol.answer = .ok(
            feed(item("1", body: "<p>Text.</p>")),
            headers: ["Etag": "W/\"abc\"", "Last-Modified": "Wed, 02 Oct 2002 08:00:00 GMT"]
        )
        let book = try await service.subscribe(to: address)

        StubProtocol.answer = .notModified
        _ = try await service.refresh(book)

        XCTAssertEqual(StubProtocol.lastRequest?.value(forHTTPHeaderField: "If-None-Match"), "W/\"abc\"")
        XCTAssertEqual(
            StubProtocol.lastRequest?.value(forHTTPHeaderField: "If-Modified-Since"),
            "Wed, 02 Oct 2002 08:00:00 GMT"
        )
    }

    /// A `304` is a successful read that found nothing, so the catalog is as fresh as if
    /// the whole document had come back. Left stale, every visit to the feed would ask
    /// again — which is the one thing conditional requests exist to stop.
    func testNotModifiedLeavesTheArticlesAloneAndMarksTheFeedFresh() async throws {
        StubProtocol.answer = .ok(feed(item("1", body: "<p>Text.</p>")), headers: ["Etag": "\"abc\""])
        let book = try await service.subscribe(to: address)
        XCTAssertTrue(try XCTUnwrap(repo.book(id: book.id)).isCatalogStale == false)

        StubProtocol.answer = .notModified
        let chapters = try await service.refresh(try XCTUnwrap(repo.book(id: book.id)))

        XCTAssertEqual(chapters.count, 1)
        XCTAssertFalse(try XCTUnwrap(repo.book(id: book.id)).isCatalogStale)
        // And the validators survive a 304, which carries none of its own. Dropped, the
        // next request would be unconditional and the feed downloaded in full again.
        XCTAssertEqual(try repo.feedFetchState(bookId: book.id)?.etag, "\"abc\"")
    }

    /// The second refresh must put only the *new* article through the extractor. The one
    /// already on the device is not re-read, which is what keeps a shelf of feeds from
    /// queueing hundreds of round trips through the shared web view on every launch.
    func testARefreshOnlyReadsArticlesThatHaveNoTextYet() async throws {
        StubProtocol.answer = .ok(feed(item("1", body: "<p>One.</p>")))
        let book = try await service.subscribe(to: address)
        let firstWrite = try XCTUnwrap(
            try repo.chapters(bookId: book.id).first?.downloadedAt
        )

        StubProtocol.answer = .ok(
            feed(item("1", body: "<p>One, edited.</p>") + item("2", body: "<p>Two.</p>",
                 published: "Thu, 03 Oct 2002 08:00:00 GMT"))
        )
        _ = try await service.refresh(try XCTUnwrap(repo.book(id: book.id)))

        let chapters = try repo.chapters(bookId: book.id)
        XCTAssertEqual(chapters.count, 2)
        // Untouched: an article already on the device keeps the copy it was stored with.
        XCTAssertEqual(chapters.first?.downloadedAt, firstWrite)
        XCTAssertTrue(try XCTUnwrap(chapters.last).isDownloaded)
    }

    // MARK: - Failures

    func testAHostThatRefusesTheRequestIsReported() async {
        StubProtocol.answer = .status(404)
        do {
            _ = try await service.subscribe(to: address)
            XCTFail("a 404 must not become a subscription")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("404"), error.localizedDescription
            )
        }
    }

    /// What almost every subscription actually looks like: the reader pastes the site,
    /// because that is the address anyone has, and the feed is a line in its head.
    func testPastingASitePageSubscribesToTheFeedItDeclares() async throws {
        StubProtocol.answersByURL = [
            // No trailing slash: what is pasted is what is asked for, and the address a
            // bare host becomes is `https://example.com`.
            "https://example.com": .ok("""
            <!DOCTYPE html><html><head>
            <link rel="alternate" type="application/rss+xml" href="/feed.xml">
            </head><body><h1>A blog</h1></body></html>
            """),
            "https://example.com/feed.xml": .ok(feed(item("1", body: "<p>Text.</p>"))),
        ]

        let book = try await service.subscribe(to: "example.com")

        XCTAssertEqual(
            book.siteBookId, "https://example.com/feed.xml",
            "the subscription is to the feed, not to the page that named it"
        )
        XCTAssertEqual(try repo.chapters(bookId: book.id).count, 1)
    }

    /// The commonest mistake anyone makes with a feed reader: pasting the site instead of
    /// its feed — where the page names no feed either, so there is nothing to follow. It
    /// has to fail as "that is not a feed", not as an empty subscription.
    func testAWebPageIsNotSubscribedTo() async {
        StubProtocol.answer = .ok("<!DOCTYPE html><html><body><h1>A blog</h1></body></html>")
        do {
            _ = try await service.subscribe(to: address)
            XCTFail("an HTML page must not become a subscription")
        } catch {
            XCTAssertTrue(error is FeedParser.ParseError, "\(error)")
        }
    }

    /// An article the feed listed with no body still gets its row: the headline and the
    /// link are real, and dropping it would hide an article the publisher did publish.
    func testAnArticleWithNoBodyStillAppearsInTheCatalog() async throws {
        StubProtocol.answer = .ok(feed("""
        <item>
          <title>Headline only</title>
          <link>https://example.com/1</link>
          <guid>tag:1</guid>
        </item>
        """))

        let book = try await service.subscribe(to: address)

        let chapter = try XCTUnwrap(try repo.chapters(bookId: book.id).first)
        XCTAssertEqual(chapter.title, "Headline only")
        XCTAssertFalse(chapter.isDownloaded)
    }
}
