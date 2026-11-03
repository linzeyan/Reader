import XCTest
@testable import NovelReader

/// A pasted address whose site has no source, through the whole environment.
///
/// Only the refusal and the feed are offline. Every path that ends in a new source goes
/// through a real page in a real web view, which no stub reaches — that half is
/// `LiveSiteTests.testPastingABookFromASiteWithNoSourceInstallsOne`.
///
/// The network is stubbed globally, as `SubscriptionImportTests` explains: a feed is read
/// through the app's own `URLSession.shared`.
@MainActor
final class PastedBookTests: XCTestCase {
    private var tempRoot: URL!
    private var env: AppEnvironment!

    override func setUpWithError() throws {
        URLProtocol.registerClass(StubProtocol.self)
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PastedBookTests-\(UUID().uuidString)")
        env = AppEnvironment(
            database: try AppDatabase.makeInMemory(),
            files: ChapterFileStore(root: tempRoot.appendingPathComponent("files")),
            cache: ChapterCache(
                files: ChapterFileStore(root: tempRoot.appendingPathComponent("cache"))
            ),
            coverFiles: CoverStore(root: tempRoot.appendingPathComponent("covers")),
            sites: SiteStore(directory: tempRoot.appendingPathComponent("sites")),
            queueStore: DownloadQueueStore(url: tempRoot.appendingPathComponent("queue.json"))
        )
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(StubProtocol.self)
        StubProtocol.reset()
        try? FileManager.default.removeItem(at: tempRoot)
    }

    /// No source is no longer the end of the line — the paste tries to make one — so an
    /// address that cannot become one has to say so on its own row, with the derivation's
    /// reason, which is the part that tells the reader what to paste instead. And it must
    /// leave nothing behind: a source installed for a site that was never read would be
    /// listed in settings and match every later paste from that host.
    ///
    /// The feed tried first must not speak for it either: the reason is the derivation's,
    /// because a book is what was being looked for once no feed answered.
    func testAnAddressNoSourceCanBeMadeForFailsOnItsRowAndInstallsNothing() async throws {
        XCTAssertTrue(env.sites.rules.isEmpty, "the premise: nothing installed")

        env.additions.start(AddBookLine.pasted("ftp://example.com/book/1"), as: .book)
        await env.additions.settle()

        let reason = AppEnvironment.AddBookError
            .derivationFailed(RuleDeriver.DeriveError.badURL.localizedDescription)
            .localizedDescription
        XCTAssertEqual(env.additions.failures, 1)
        XCTAssertEqual(env.additions.lines.first?.status.note, reason)
        XCTAssertTrue(env.sites.rules.isEmpty, "nothing installed for a site that was never read")
        XCTAssertTrue(env.books.isEmpty)
    }

    /// A feed shared from a browser, or pasted on the novel shelf, used to be handed to the
    /// derivation — a web view load that ended in "could not make a source". It is one
    /// plain request away from being a subscription, so that request goes first, and what
    /// it finds goes on the subscriptions shelf with the row saying so.
    func testAFeedNoSourceClaimsBecomesASubscription() async throws {
        StubProtocol.answer = .ok("""
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel>
          <title>A Blog</title>
          <item>
            <title>An article</title>
            <link>https://blog.example/1</link>
            <guid>tag:blog.example,2026:1</guid>
            <pubDate>Wed, 02 Oct 2002 08:00:00 GMT</pubDate>
            <description><![CDATA[<p>Text.</p>]]></description>
          </item>
        </channel></rss>
        """)

        env.additions.start(AddBookLine.pasted("https://blog.example/feed"), as: .book)
        await env.additions.settle()

        XCTAssertEqual(env.additions.added, 1, "\(String(describing: env.additions.lines.first?.status.note))")
        XCTAssertEqual(env.books.map(\.kind), [.feed])
        XCTAssertEqual(
            env.additions.lines.first?.status.note,
            String(localized: "library.add.subscribed \("A Blog")")
        )
        XCTAssertTrue(env.sites.rules.isEmpty, "no source made for what was never a book")
    }

    /// A list pasted a second time is mostly books already on the shelf. Each one asked for
    /// again is two trips through a WAF to write back what the shelf already says, and a row
    /// with the same green tick as a new book leaves the reader unable to see what was new.
    func testABookAlreadyOnTheShelfIsNotFetchedAndSaysSo() async throws {
        let rule = SiteRule(
            id: "demo", name: "Demo", host: "demo.test",
            urls: .init(
                book: "https://demo.test/book/{bookId}",
                catalog: "https://demo.test/book/{bookId}/",
                chapter: "https://demo.test/txt/{bookId}/{chapterId}"
            ),
            idPatterns: .init(bookId: "/book/(\\d+)", chapterId: "/txt/\\d+/(\\d+)"),
            search: nil,
            book: .init(
                title: .init(meta: nil, selector: "h1", attribute: nil),
                author: nil, cover: nil, category: nil, status: nil, intro: nil, latestChapter: nil
            ),
            catalog: .init(container: "#catalog", linkSelector: "a", order: .ascending),
            chapter: .init(
                titleSelectors: ["h1"], contentSelectors: [".content"],
                stripSelectors: [], dropParagraphPatterns: nil, prevSelector: nil, nextSelector: nil
            ),
            notes: nil
        )
        _ = try env.sites.importRule(data: JSONEncoder().encode(rule))
        try env.repo.bookmark(siteId: "demo", siteBookId: "42", title: "諸界第一因")

        // demo.test resolves nowhere: a fetch would fail the row rather than pass it.
        env.additions.start(AddBookLine.pasted("https://demo.test/book/42"), as: .book)
        await env.additions.settle()

        let status = try XCTUnwrap(env.additions.lines.first?.status)
        XCTAssertTrue(status.isPresent, status.note ?? "no note")
        XCTAssertEqual(status.note, String(localized: "library.add.present \("諸界第一因")"))
        XCTAssertEqual(env.additions.failures, 0)
    }
}
