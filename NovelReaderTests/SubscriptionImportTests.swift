import XCTest
@testable import NovelReader

/// Importing a subscription list, through the whole app rather than through `OPML` alone:
/// the file is read, every address in it is subscribed to, and what lands on the shelf is
/// what is asserted.
///
/// The network is stubbed by registering the protocol globally, because this is the one
/// path that runs through the app's own `URLSession.shared` — an environment built the way
/// the app builds it, which is the point of testing here rather than a layer down.
@MainActor
final class SubscriptionImportTests: XCTestCase {
    private var tempRoot: URL!
    private var env: AppEnvironment!

    override func setUpWithError() throws {
        URLProtocol.registerClass(StubProtocol.self)
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SubscriptionImportTests-\(UUID().uuidString)")
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

    private func feed(_ title: String) -> StubProtocol.Answer {
        .ok("""
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel>
          <title>\(title)</title>
          <item>
            <title>An article</title>
            <link>https://example.com/1</link>
            <guid>tag:\(title)</guid>
            <pubDate>Wed, 02 Oct 2002 08:00:00 GMT</pubDate>
            <description><![CDATA[<p>Text.</p>]]></description>
          </item>
        </channel></rss>
        """)
    }

    private func write(_ opml: String) throws -> URL {
        let url = tempRoot.appendingPathComponent("subscriptions.opml")
        try FileManager.default.createDirectory(
            at: tempRoot, withIntermediateDirectories: true
        )
        try Data(opml.utf8).write(to: url)
        return url
    }

    private let list = """
    <?xml version="1.0" encoding="UTF-8"?>
    <opml version="1.0">
      <head><title>Subscriptions</title></head>
      <body>
        <outline text="First" type="rss" xmlUrl="https://a.example/feed"/>
        <outline text="Second" type="rss" xmlUrl="https://b.example/feed"/>
      </body>
    </opml>
    """

    private var feeds: [Book] {
        env.books.filter { $0.kind == .feed }.sorted { $0.siteBookId < $1.siteBookId }
    }

    /// The whole point of the format: a list someone exported from another reader becomes
    /// a shelf they can read, in one gesture, with the articles already there.
    func testEveryFeedInTheListIsSubscribedTo() async throws {
        StubProtocol.answersByURL = [
            "https://a.example/feed": feed("First Blog"),
            "https://b.example/feed": feed("Second Blog"),
        ]

        let added = try await env.importSubscriptions(from: try write(list))

        XCTAssertEqual(added, 2)
        XCTAssertEqual(feeds.map(\.title), ["First Blog", "Second Blog"])
        // Named from their own documents, not from the file: the publisher's title is the
        // current one, and an OPML can be years old.
        XCTAssertEqual(try env.repo.chapters(bookId: feeds[0].id).count, 1)
    }

    /// A bad minute on a train must not cost the reader subscriptions out of a file they
    /// may well delete afterwards. The row goes on the shelf under the name the file gave
    /// it, and it is stale, so the next refresh fills it in.
    func testAFeedThatWillNotAnswerIsStillAdded() async throws {
        StubProtocol.answersByURL = ["https://a.example/feed": feed("First Blog")]
        StubProtocol.answer = .status(500)

        let added = try await env.importSubscriptions(from: try write(list))

        XCTAssertEqual(added, 2)
        let unreachable = try XCTUnwrap(feeds.last)
        XCTAssertEqual(unreachable.title, "Second", "the name the file gave it")
        XCTAssertTrue(try env.repo.chapters(bookId: unreachable.id).isEmpty)
        XCTAssertTrue(
            unreachable.isCatalogStale,
            "so that opening the app is enough to fill it in"
        )
    }

    /// Importing the same file twice is something people do — two devices, or a list they
    /// were not sure had gone through. It has to be a re-read, not a second shelf.
    func testImportingTheSameListTwiceAddsNothingTheSecondTime() async throws {
        StubProtocol.answersByURL = [
            "https://a.example/feed": feed("First Blog"),
            "https://b.example/feed": feed("Second Blog"),
        ]
        let file = try write(list)
        _ = try await env.importSubscriptions(from: file)

        let added = try await env.importSubscriptions(from: file)

        XCTAssertEqual(added, 0)
        XCTAssertEqual(feeds.count, 2)
    }

    /// What the shelf tells the reader afterwards is two numbers side by side — how many
    /// the file listed, how many of them were new — and only one of them is returned. The
    /// other is read off the progress, so the progress has to have named the whole file by
    /// the time the import ends: a count that stopped short would have the reader told a
    /// total they never watched the bar reach.
    func testTheProgressNamesTheWholeFileSoTheResultCanBeCountedFromIt() async throws {
        StubProtocol.answersByURL = [
            "https://a.example/feed": feed("First Blog"),
            "https://b.example/feed": feed("Second Blog"),
        ]

        var listed = 0
        let added = try await env.importSubscriptions(from: try write(list)) { listed = $0.count }

        XCTAssertEqual(listed, 2, "the file's own length, not how far the import got")
        XCTAssertEqual(added, 2)
    }

    /// A file with nothing in it has to say so. Silence would be indistinguishable from
    /// an import that worked, and the reader would go looking for feeds that never came.
    func testAFileWithNoFeedsInItIsReported() async throws {
        let file = try write("<opml version=\"1.0\"><body><outline text=\"Folder\"/></body></opml>")

        do {
            _ = try await env.importSubscriptions(from: file)
            XCTFail("a list with no feeds in it must not pass silently")
        } catch {
            XCTAssertTrue(error is AppEnvironment.OPMLError, "\(error)")
        }
    }

    /// The other direction, from the shelf this time: what is exported is what is on it,
    /// under the names the reader sees — including one they chose themselves, and in the
    /// order a person reading the file would look for them in.
    func testTheExportListsTheShelfUnderTheNamesTheReaderSees() async throws {
        StubProtocol.answersByURL = [
            "https://a.example/feed": feed("First Blog"),
            "https://b.example/feed": feed("Second Blog"),
        ]
        _ = try await env.importSubscriptions(from: try write(list))
        env.rename(feeds[0], to: "My name for it")

        let exported = OPML.subscriptions(in: Data(env.subscriptionsDocument().utf8))

        XCTAssertEqual(
            exported,
            [
                OPML.Subscription(title: "My name for it", address: "https://a.example/feed"),
                OPML.Subscription(title: "Second Blog", address: "https://b.example/feed"),
            ]
        )
    }
}
