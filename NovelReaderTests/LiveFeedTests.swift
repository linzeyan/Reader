import XCTest
@testable import NovelReader

/// What subscribing to a real shelf of feeds actually costs, split by where the time goes.
///
/// Opt-in and excluded from `make test` for `LiveSiteTests`' reasons — it needs a network
/// and fails for things outside this code. It is not a correctness check: it asserts only
/// that the pipeline ran, and its output is the report it prints.
///
/// It exists because "make RSS faster" is not answerable without knowing which half is
/// slow. A subscription does two very different things: it reads one document over
/// `URLSession`, and it then puts every article in that document through the shared web
/// view one at a time. Those have opposite fixes — the first is answered by doing several
/// feeds at once, the second is not answered by that at all — and guessing which dominates
/// is how an afternoon gets spent parallelising the cheap half.
///
/// Run cold, it answered: the document is 1% and the bodies are 98%, and *within* the
/// bodies the web view is not the cost either. Three image-heavy feeds of the thirteen
/// took ninety per cent of the run between them at thirty to forty seconds an article,
/// while `hellogithub.com/rss` put a hundred and twenty-five articles through the same
/// serialised web view in 621ms — four milliseconds each. Extraction is milliseconds;
/// pictures are the minutes. So a pool of web views, the obvious-looking fix and the one
/// this test was written to justify, would parallelise the cheap half after all. The
/// remaining cost lives in `ArticleImages` and in the per-article loop that waits for it.
///
/// The split is read off `FeedService`'s own progress callback rather than by
/// instrumenting it: the first report fires once the catalog has been merged and the
/// articles needing a body are known, so everything before it is fetch-and-parse and
/// everything after it is bodies. No production code knows this test exists.
@MainActor
final class LiveFeedTests: XCTestCase {
    /// A real reader's shelf: thirteen publishing platforms, which between them cover
    /// WordPress, Hugo, Ghost, hand-rolled Atom and a Feedburner proxy. The point is the
    /// spread of markup, not the particular blogs.
    private static let feeds = [
        "https://www.kawabangga.com/feed",
        "https://colobu.com/atom.xml",
        "https://feeds.feedburner.com/ruanyifeng",
        "https://taoshu.in/feed.xml",
        "https://u.sb/atom.xml",
        "https://weekly.tw93.fun/rss.xml",
        "https://hellogithub.com/rss",
        "https://blog.huli.tw/atom-ch.xml",
        "https://ivonblog.com/index.xml",
        "https://ganhua.wang/rss.xml",
        "https://soulteary.com/feed/",
        "https://blog.skk.moe/atom.xml",
        "https://blog.webp.se/index.xml"
    ]

    /// One feed's journey, in milliseconds.
    private struct Row {
        let address: String
        /// The book `subscribe` actually stored, which is not derivable from the address.
        /// A feed that redirects — `taoshu.in/feed.xml` is one — is stored under where it
        /// landed, so rebuilding the id from what was typed looks it up and finds nothing.
        /// Measured, that reported a feed with nine articles as `listed=0`.
        var id: String?
        var title: String?
        /// Articles the document listed.
        var listed = 0
        /// Of those, the ones with a body to read — what the expensive half is counted in.
        var bodies = 0
        /// Reading the document off the network, parsing it, and writing the catalog.
        var index: Duration = .zero
        /// Every article's markup through the web view, plus its pictures off the network.
        var text: Duration = .zero
        var failure: String?

        var total: Duration { index + text }

        /// The number this whole exercise is about: what one article costs.
        var perArticle: Duration? {
            bodies > 0 ? text / bodies : nil
        }

        var line: String {
            let verdict = failure == nil ? "OK  " : "FAIL"
            let each = perArticle.map { "\($0.millis)ms/article" } ?? "—"
            return "  \(verdict) \(address.padded(to: 40)) "
                + "listed=\(String(listed).padded(to: 3)) bodies=\(String(bodies).padded(to: 3)) "
                + "index=\(String(index.millis).padded(to: 5))ms "
                + "text=\(String(text.millis).padded(to: 6))ms "
                + "\(each)"
                + (failure.map { "\n        \($0)" } ?? "")
        }
    }

    /// What actually reached the disk.
    ///
    /// The number that tells a slow run from a *lossy* one. A picture that will not
    /// download is not an error and does not fail the article — the block keeps its
    /// address and the reader draws alt text in its place — so a change that quietly
    /// pushed requests past their timeout would show up as "faster" per article while
    /// storing less of what the reader subscribed for. Counting files is the only way to
    /// see it from outside.
    private func storedFiles() -> (count: Int, bytes: Int) {
        guard let walker = FileManager.default.enumerator(
            at: tempRoot, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return (0, 0) }
        var count = 0
        var bytes = 0
        for case let url as URL in walker {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            else { continue }
            count += 1
            bytes += size
        }
        return (count, bytes)
    }

    /// A network with nothing remembered on it.
    ///
    /// Every test here claims to measure a *cold* subscribe, and sharing `URLSession.shared`
    /// silently broke that claim: the two runs live in one process, so the first one filled
    /// the shared `URLCache` with three hundred megabytes of pictures and the second read
    /// them off the disk. Measured, that reported the second run as forty-seven times
    /// faster while storing byte-for-byte the same files — a number that is about the cache
    /// and says nothing whatever about the code under it.
    private func coldSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LiveFeedTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    /// Subscribes to all thirteen the way the app does today — one after another, on a
    /// cold library — and reports where the time went.
    func testSubscribingToAWholeShelfOfFeeds() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["NOVELREADER_LIVE"] == "1",
            "Live feed tests are opt-in: run `make test-live`."
        )
        let database = try AppDatabase.makeInMemory()
        let repo = LibraryRepo(database: database)
        let files = ChapterFileStore(root: tempRoot)
        let service = FeedService(
            repo: repo,
            downloads: DownloadStore(database: database, files: files),
            fetcher: WebFetcher(),
            session: coldSession()
        )

        var rows: [Row] = []
        let wall = ContinuousClock.now
        for address in Self.feeds {
            rows.append(await subscribe(to: address, through: service, repo: repo))
        }
        let elapsed = ContinuousClock.now - wall

        let bodies = rows.reduce(0) { $0 + $1.bodies }
        let index = rows.reduce(Duration.zero) { $0 + $1.index }
        let text = rows.reduce(Duration.zero) { $0 + $1.text }
        let disk = storedFiles()
        print("""

        === live feed report: one at a time ===
        \(rows.map(\.line).joined(separator: "\n"))

          wall           \(elapsed.millis)ms for \(rows.count) feeds, \(bodies) articles
          index total    \(index.millis)ms \
        (\(share(index, of: elapsed))% — one document over URLSession)
          body total     \(text.millis)ms \
        (\(share(text, of: elapsed))% — extraction, then every picture in the article)
          per article    \(bodies > 0 ? String((text / bodies).millis) : "—")ms
          on disk        \(disk.count) files, \(disk.bytes / 1024)KB

        """)

        XCTAssertFalse(rows.isEmpty)
        // Not an assertion about speed — only that the exercise was real. A run where
        // every feed failed would print a beautiful report of nothing.
        XCTAssertGreaterThan(
            rows.filter { $0.failure == nil }.count, Self.feeds.count / 2,
            "More than half the feeds failed; the numbers above are not about this app"
        )
    }

    /// The same thirteen, subscribed to the way the app does it now: handed to the queue
    /// all at once, several hosts in flight, one at a time per host.
    ///
    /// Reported per feed in the same shape as the run above, because the wall clock alone
    /// could not say *why* a batch got slower — whether one feed took the whole regression
    /// or every one of them got a little worse, which have nothing to do with each other.
    /// The first run of this answered "3.8× slower" and left the question open.
    func testSubscribingToAWholeShelfThroughTheQueue() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["NOVELREADER_LIVE"] == "1",
            "Live feed tests are opt-in: run `make test-live-feeds`."
        )
        let database = try AppDatabase.makeInMemory()
        let repo = LibraryRepo(database: database)
        let files = ChapterFileStore(root: tempRoot)
        let service = FeedService(
            repo: repo,
            downloads: DownloadStore(database: database, files: files),
            fetcher: WebFetcher(),
            session: coldSession()
        )
        // Written from inside the `subscribe` closure, which is the only place that knows
        // when one feed began and ended — the queue reports statuses, not stopwatches.
        var timings: [String: Row] = [:]
        let queue = BookAdditions(pacer: RequestPacer())
        queue.connect(
            BookAdditions.Work(
                subscribe: { address, progress in
                    let started = ContinuousClock.now
                    var indexed: ContinuousClock.Instant?
                    var bodies = 0
                    func record(_ book: Book?, failure: String?) {
                        let finished = ContinuousClock.now
                        timings[address] = Row(
                            address: address, id: book?.id, title: book?.shownName,
                            bodies: bodies,
                            index: (indexed ?? finished) - started,
                            text: finished - (indexed ?? finished),
                            failure: failure
                        )
                    }
                    do {
                        let book = try await service.subscribe(to: address) { report in
                            if indexed == nil {
                                indexed = .now
                                bodies = report.total
                            }
                            progress(report)
                        }
                        record(book, failure: nil)
                        return book.shownName
                    } catch {
                        record(nil, failure: error.localizedDescription)
                        throw error
                    }
                },
                addBook: { _ in "" },
                keep: { _, _ in nil },
                settled: {},
                report: { _ in }
            )
        )

        let wall = ContinuousClock.now
        queue.start(AddBookLine.numbered(Self.feeds.map { ($0, nil) }), as: .subscription)
        await queue.settle()
        let elapsed = ContinuousClock.now - wall

        let rows = Self.feeds.compactMap { address -> Row? in
            guard var row = timings[address] else { return nil }
            row.listed = row.id.flatMap { try? repo.chapters(bookId: $0).count } ?? 0
            return row
        }
        let bodies = rows.reduce(0) { $0 + $1.bodies }
        let busy = rows.reduce(Duration.zero) { $0 + $1.total }
        let disk = storedFiles()
        print("""

        === live feed report: through the queue ===
        \(rows.map(\.line).joined(separator: "\n"))

          wall           \(elapsed.millis)ms for \(rows.count) feeds, \(bodies) articles
          at once        \(BookAdditions.maxConcurrentFeeds) hosts
          feed time      \(busy.millis)ms added up \
        (\(share(busy, of: elapsed))% of the wall clock — over 100% is the overlap working)
          per article    \(bodies > 0 ? String((elapsed / bodies).millis) : "—")ms of wall clock
          on disk        \(disk.count) files, \(disk.bytes / 1024)KB

        """)

        XCTAssertGreaterThan(
            queue.added, Self.feeds.count / 2,
            "More than half the feeds failed; the numbers above are not about this app"
        )
    }

    private func subscribe(
        to address: String, through service: FeedService, repo: LibraryRepo
    ) async -> Row {
        var row = Row(address: address)
        let started = ContinuousClock.now
        // Nil until the first progress report, which is the moment the catalog is written
        // and the article loop is about to begin.
        var indexed: ContinuousClock.Instant?
        do {
            let book = try await service.subscribe(to: address) { progress in
                if indexed == nil {
                    indexed = .now
                    row.bodies = progress.total
                }
            }
            row.title = book.shownName
            row.listed = (try? repo.chapters(bookId: book.id).count) ?? 0
        } catch {
            row.failure = error.localizedDescription
        }
        let finished = ContinuousClock.now
        // A feed that published no bodies never reports progress, so the whole of it was
        // the index — which is the honest reading: there was nothing else to do.
        row.index = (indexed ?? finished) - started
        row.text = finished - (indexed ?? finished)
        return row
    }

    private func share(_ part: Duration, of whole: Duration) -> Int {
        whole.millis > 0 ? part.millis * 100 / whole.millis : 0
    }
}

private extension Duration {
    var millis: Int {
        Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
