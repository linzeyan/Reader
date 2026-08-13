import GRDB
import XCTest
@testable import NovelReader

/// An 800-chapter book takes far longer than iOS keeps a backgrounded app alive,
/// so the queue has to outlive the process that built it. That is the one reason
/// the queue file exists, and the first case here is the whole justification for it.
///
/// The rest guard the ways a queue read back from a previous life can be wrong: it
/// can ask for chapters that have since arrived, chapters the site has removed, or
/// a book the user has deleted — and it must never be the thing that spends a data
/// plan, because the "yes, use cellular" it was started with died with its process.
@MainActor
final class DownloadQueuePersistenceTests: XCTestCase {
    private static let suiteName = "DownloadQueuePersistenceTests"
    private var directory: URL!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        // Cleared at the *start* of every case rather than in a teardown. This suite
        // writes real files, and a teardown that does not run — a crash, a stopped
        // run — would hand the next case a queue nothing in it wrote. Reading a
        // queue from somewhere else is precisely what is under test, so that failure
        // would look like a pass.
        directory = URL.temporaryDirectory
            .appendingPathComponent("DownloadQueuePersistenceTests", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suiteName))
        defaults.removePersistentDomain(forName: Self.suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: Self.suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Surviving the process

    /// The reason all of this exists. A queue paused by the app going away, and then
    /// terminated along with the process holding it, has to come back with exactly
    /// the chapters it still owed — not "a download the user watched start and never
    /// saw again".
    func testTheQueueSurvivesTheProcessThatWroteIt() throws {
        let first = try makeHarness()
        let book = try seedBook(first, siteBookId: "1", chapters: ["1", "2", "3"])
        try queue(first, book)
        XCTAssertTrue(fileExists(first), "A paused queue with work left has to be on disk")

        let second = try relaunch(first)
        second.restorer.restore()

        XCTAssertEqual(second.downloader.remaining.map(\.siteChapterId), ["1", "2", "3"])
        XCTAssertEqual(second.downloader.status, .paused)
        XCTAssertTrue(second.downloader.canResume)
        XCTAssertEqual(second.downloader.progress?.total, 3)
        XCTAssertEqual(second.downloader.progress?.bookId, book.id)
    }

    /// The queue file is allowed to be out of date — it is written when the queue
    /// gains work and when it comes to rest, not once per chapter — because the
    /// chapters `DownloadStore` has written are the truth for what is finished.
    /// This is that claim: a stale queue costs no repeated requests.
    func testChaptersAlreadyOnDiskAreNotQueuedAgain() throws {
        let first = try makeHarness()
        let book = try seedBook(first, siteBookId: "1", chapters: ["1", "2", "3"])
        try queue(first, book)
        // The run got one chapter further before the process died, so what is on
        // disk still asks for it.
        try first.downloads.save(paragraphs: ["text"], book: book, siteChapterId: "2")

        let second = try relaunch(first)
        second.restorer.restore()

        XCTAssertEqual(second.downloader.remaining.map(\.siteChapterId), ["1", "3"])
    }

    /// A chapter the site has taken down since the queue was written no longer has a
    /// catalog row, and a dead id must not sit at the head of the queue failing
    /// forever — it takes everything behind it down with it.
    func testChaptersTheSiteHasRemovedAreDropped() throws {
        let first = try makeHarness()
        let book = try seedBook(first, siteBookId: "1", chapters: ["1", "2", "3"])
        try queue(first, book)
        // The row goes directly rather than through a catalog refresh: what this
        // pins is the queue's reaction to a chapter that is no longer indexed, and
        // routing it through `replaceCatalog` would drag that method's reindexing
        // into a case that is not about it.
        try first.database.writer.write { db in
            try db.execute(
                sql: "DELETE FROM chapter WHERE id = ?",
                arguments: [Chapter.makeId(bookId: book.id, siteChapterId: "2")]
            )
        }

        let second = try relaunch(first)
        second.restorer.restore()

        XCTAssertEqual(
            second.downloader.remaining.map(\.siteChapterId), ["1", "3"],
            "A dead id must be dropped, not left at the head of the queue failing forever"
        )
    }

    // MARK: - The policy, run again from scratch

    /// Consent to spend cellular data was given for one run, in a process that no
    /// longer exists. A queue coming back off disk must clear the policy again — and
    /// on a metered connection under Wi-Fi only that means fetching nothing at all,
    /// not one chapter's worth of somebody's data plan.
    func testAQueueRestoredOnCellularUnderWifiOnlyDoesNotStartItself() throws {
        let first = try makeHarness()
        let book = try seedBook(first, siteBookId: "1", chapters: ["1", "2", "3"])
        try queue(first, book)

        let second = try relaunch(first, policy: .wifiOnly, connection: .cellular)
        second.restorer.restore()

        XCTAssertFalse(second.downloader.isBusy, "Not one request may go out")
        XCTAssertEqual(second.downloader.remaining.count, 3, "…and the queue is still there")
        XCTAssertTrue(second.downloader.canResume)
        XCTAssertEqual(
            second.downloader.lastError, String(localized: "downloads.cellular.paused"),
            "A queue that comes back and then sits there has to say why"
        )
    }

    /// The other half of that promise: on a connection the policy allows, the
    /// download the user asked for yesterday simply carries on without being asked
    /// for again.
    func testAQueueRestoredOnWifiContinuesByItself() throws {
        let first = try makeHarness()
        let book = try seedBook(first, siteBookId: "1", chapters: ["1", "2", "3"])
        try queue(first, book)

        let second = try relaunch(first, policy: .wifiOnly, connection: .wifi)
        second.restorer.restore()

        XCTAssertTrue(second.downloader.isBusy)
        second.downloader.cancel()
    }

    /// At the moment the app starts, no network path has been reported yet, and
    /// `.unknown` is not evidence of Wi-Fi. Resolving it either way at launch is a
    /// coin toss with somebody's data plan on one side, so the decision waits for
    /// the first report — and then actually gets made.
    func testTheDecisionWaitsForTheFirstPathReport() throws {
        let first = try makeHarness()
        let book = try seedBook(first, siteBookId: "1", chapters: ["1", "2", "3"])
        try queue(first, book)

        let second = try relaunch(first, policy: .wifiOnly, connection: .unknown)
        second.restorer.restore()
        XCTAssertFalse(second.downloader.isBusy, "Nothing has said this connection is cheap")

        second.connection.current = .wifi
        second.restorer.connectionChanged()

        XCTAssertTrue(second.downloader.isBusy)
        second.downloader.cancel()
    }

    // MARK: - Queues that cannot be trusted

    /// A file this build cannot parse is thrown away whole rather than salvaged. The
    /// user loses one tap on "download"; a queue pieced together from bytes we do
    /// not understand would fetch the wrong chapters and never say so.
    func testAnUnreadableQueueIsThrownAwayAndRecorded() throws {
        let harness = try makeHarness()
        try Data("{ not a queue".utf8).write(to: harness.queueStore.url)

        harness.restorer.restore()

        XCTAssertEqual(harness.downloader.status, .idle)
        XCTAssertTrue(harness.downloader.remaining.isEmpty)
        XCTAssertFalse(fileExists(harness), "A file that cannot be read is not kept around")
        XCTAssertEqual(
            harness.background.lastRun?.outcome, .queueLost,
            "Losing a queue silently is the failure this record exists to prevent"
        )
    }

    /// Same treatment for a shape that parses but comes from a version this build
    /// does not know: the fields could mean anything.
    func testAQueueFromAnUnknownFormatVersionIsThrownAway() throws {
        let harness = try makeHarness()
        let future = PersistedDownloadQueue(
            bookId: "demo|1", siteChapterIds: ["1"],
            version: PersistedDownloadQueue.currentVersion + 1
        )
        try JSONEncoder().encode(future).write(to: harness.queueStore.url)

        harness.restorer.restore()

        XCTAssertTrue(harness.downloader.remaining.isEmpty)
        XCTAssertFalse(fileExists(harness))
        XCTAssertEqual(harness.background.lastRun?.outcome, .queueLost)
    }

    // MARK: - Books that are no longer there

    /// A queue whose book has been deleted has nothing to download into. Dropped
    /// rather than restored against a book that does not exist — and quietly,
    /// because the user deleting a book is not a failure to report.
    func testAQueueForADeletedBookIsDropped() throws {
        let first = try makeHarness()
        let book = try seedBook(first, siteBookId: "1", chapters: ["1", "2", "3"])
        try queue(first, book)
        // Deleted without going through `AppEnvironment.removeBookmark`, which
        // cancels a queue it can see: this is the case where the book went away in
        // another session, or arrived deleted from iCloud.
        try first.repo.removeBookmark(bookId: book.id)

        let second = try relaunch(first)
        second.restorer.restore()

        XCTAssertEqual(second.downloader.status, .idle)
        XCTAssertTrue(second.downloader.remaining.isEmpty)
        XCTAssertFalse(fileExists(second))
        XCTAssertNil(
            second.background.lastRun,
            "Deleting a book is the user's own doing, not something to report as a fault"
        )
    }

    /// And the deletion has to stay local to the book that was deleted: a queue for
    /// a different book is untouched by it.
    func testDeletingOneBookLeavesAnotherBooksQueueAlone() throws {
        let first = try makeHarness()
        let doomed = try seedBook(first, siteBookId: "1", chapters: ["1", "2"])
        let queued = try seedBook(first, siteBookId: "2", chapters: ["7", "8"])
        try queue(first, queued)
        try first.repo.removeBookmark(bookId: doomed.id)

        let second = try relaunch(first)
        second.restorer.restore()

        XCTAssertEqual(second.downloader.remaining.map(\.siteChapterId), ["7", "8"])
        XCTAssertEqual(second.downloader.progress?.bookId, queued.id)
    }

    // MARK: - Queues that are over

    /// Cancelling is the user saying they do not want this download. A file left
    /// behind would start it again at the next launch.
    func testCancellingTheQueueRemovesTheFile() throws {
        let harness = try makeHarness()
        let book = try seedBook(harness, siteBookId: "1", chapters: ["1", "2"])
        try queue(harness, book)
        XCTAssertTrue(fileExists(harness))

        harness.downloader.cancel()

        XCTAssertFalse(fileExists(harness))
    }

    /// Nor may a queue survive being finished — waking up to re-download a book that
    /// is already complete is exactly the pointless wake-up the background budget
    /// gets spent on.
    func testAFinishedQueueRemovesTheFile() throws {
        let harness = try makeHarness()
        let book = try seedBook(harness, siteBookId: "1", chapters: ["1"])
        try queue(harness, book)
        XCTAssertTrue(fileExists(harness))

        // Nothing left to fetch is the cheapest way to reach "finished" without a
        // network.
        try harness.downloads.save(paragraphs: ["text"], book: book, siteChapterId: "1")
        harness.downloader.start(
            book: book, rule: Self.makeRule(), chapters: try harness.repo.chapters(bookId: book.id)
        )

        XCTAssertEqual(harness.downloader.status, .finished)
        XCTAssertFalse(fileExists(harness))
    }

    // MARK: - Harness

    /// The connection the harness reports, mutable so a case can do what a launch
    /// does: come up with nothing reported yet, and have a path arrive afterwards.
    private final class ConnectionBox {
        var current: NetworkMonitor.Connection

        init(_ current: NetworkMonitor.Connection) {
            self.current = current
        }
    }

    private struct Harness {
        let database: AppDatabase
        let repo: LibraryRepo
        let downloads: DownloadStore
        let downloader: DownloadManager
        let background: BackgroundDownloads
        let restorer: DownloadQueueRestorer
        let queueStore: DownloadQueueStore
        let connection: ConnectionBox
    }

    /// - Parameter database: the library a previous "launch" left behind. Everything
    ///   else is built fresh, which is the point of `relaunch`: the queue has to
    ///   arrive from the file and not from an object that outlived the termination.
    private func makeHarness(
        database: AppDatabase? = nil,
        policy: DownloadSettings.NetworkPolicy = .wifiOnly,
        connection: NetworkMonitor.Connection = .unknown
    ) throws -> Harness {
        let database = try database ?? AppDatabase.makeInMemory()
        let repo = LibraryRepo(database: database)
        let downloads = DownloadStore(
            database: database,
            files: ChapterFileStore(root: directory.appendingPathComponent("Chapters"))
        )
        let queueStore = DownloadQueueStore(
            url: directory.appendingPathComponent("DownloadQueue.json")
        )
        let downloader = DownloadManager(
            service: BookService(fetcher: WebFetcher(), repo: repo),
            downloads: downloads, pacer: RequestPacer(), queueStore: queueStore
        )
        let settings = DownloadSettings(defaults: defaults)
        settings.network = policy
        let box = ConnectionBox(connection)
        let background = BackgroundDownloads(
            downloader: downloader, settings: settings, connection: { box.current },
            scheduler: SilentScheduler(), defaults: defaults
        )
        let rule = Self.makeRule()
        return Harness(
            database: database,
            repo: repo,
            downloads: downloads,
            downloader: downloader,
            background: background,
            restorer: DownloadQueueRestorer(
                store: queueStore, downloader: downloader, repo: repo, settings: settings,
                record: background, rule: { $0 == rule.id ? rule : nil },
                connection: { box.current }
            ),
            queueStore: queueStore,
            connection: box
        )
    }

    /// A second object graph over the same library and the same queue file: what the
    /// app looks like after iOS has terminated it and the user opens it again.
    private func relaunch(
        _ harness: Harness,
        policy: DownloadSettings.NetworkPolicy = .wifiOnly,
        connection: NetworkMonitor.Connection = .unknown
    ) throws -> Harness {
        try makeHarness(database: harness.database, policy: policy, connection: connection)
    }

    private func seedBook(
        _ harness: Harness, siteBookId: String, chapters: [String]
    ) throws -> Book {
        let book = try harness.repo.bookmark(
            siteId: "demo", siteBookId: siteBookId, title: "Book \(siteBookId)"
        )
        try harness.repo.replaceCatalog(
            bookId: book.id,
            entries: chapters.map {
                (
                    siteChapterId: $0, title: "chapter \($0)",
                    url: "https://demo.test/txt/\(siteBookId)/\($0)"
                )
            }
        )
        return book
    }

    /// Leaves the queue exactly where backgrounding leaves it: paused, with
    /// everything still owed. Pausing in the same turn as the start means the run
    /// task never got as far as issuing a request.
    private func queue(_ harness: Harness, _ book: Book) throws {
        harness.downloader.start(
            book: book, rule: Self.makeRule(),
            chapters: try harness.repo.chapters(bookId: book.id)
        )
        harness.downloader.pause()
    }

    private func fileExists(_ harness: Harness) -> Bool {
        FileManager.default.fileExists(atPath: harness.queueStore.url.path)
    }

    private static func makeRule() -> SiteRule {
        SiteRule(
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
                author: nil, cover: nil, category: nil, status: nil, intro: nil,
                latestChapter: nil
            ),
            catalog: .init(container: "#catalog", linkSelector: "a", order: .ascending),
            chapter: .init(
                titleSelectors: ["h1"], contentSelectors: [".content"],
                stripSelectors: [], dropParagraphPatterns: nil, prevSelector: nil,
                nextSelector: nil
            ),
            notes: nil
        )
    }
}

/// The scheduler seam, wired to nothing: these cases are about the queue file, and
/// the real `BGTaskScheduler` refuses every request from a test process anyway.
private final class SilentScheduler: BackgroundTaskScheduling {
    func submitProcessingRequest(identifier: String) throws {}
    func cancel(identifier: String) {}
}
