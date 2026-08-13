import XCTest
@testable import NovelReader

/// A download that continues while the app is off screen spends someone's data,
/// battery and goodwill with a WAF-fronted host, all with nobody watching. So the
/// decidable parts are pinned here: whether to ask iOS for a window at all,
/// whether the connection is allowed to be used unattended, and what happens when
/// iOS takes the time back mid-chapter.
///
/// What is *not* asserted, because no simulator can answer it: whether a
/// `WKWebView` can still navigate once iOS has suspended the web content process.
/// That is what the persisted `BackgroundDownloadRun` exists to answer, on a real
/// device.
@MainActor
final class BackgroundDownloadTests: XCTestCase {
    private let suiteName = "BackgroundDownloadTests"
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Whether to ask for a window at all

    /// A schedule left behind for an empty queue wakes the app to do nothing, and
    /// iOS answers repeated pointless wake-ups by granting fewer of them. Spending
    /// that budget is how the feature stops working for the books that need it.
    func testAnIdleQueueAsksForNoWindowAndClearsAnyStandingRequest() throws {
        let harness = try makeHarness(policy: .wifiOnly, connection: .wifi)

        harness.background.scheduleIfNeeded()

        XCTAssertEqual(harness.scheduler.submitted, 0)
        XCTAssertEqual(harness.scheduler.cancelled, 1)
    }

    func testAQueueThatWasPausedWithWorkLeftAsksForAWindow() throws {
        let harness = try makeHarness(policy: .wifiOnly, connection: .wifi)
        queueTwoChapters(harness.downloader)

        harness.background.scheduleIfNeeded()

        XCTAssertEqual(harness.scheduler.submitted, 1)
    }

    /// A challenge needs a human. Another window would fail in exactly the same
    /// way, having spent the same budget, and the user would still be the only one
    /// who can clear it.
    func testAQueueWaitingOnAChallengeAsksForNoWindow() throws {
        let harness = try makeHarness(policy: .wifiOnly, connection: .wifi)
        queueTwoChapters(harness.downloader)
        harness.downloader.pendingChallenge = URL(string: "https://demo.test/book/1")

        harness.background.scheduleIfNeeded()

        XCTAssertEqual(harness.scheduler.submitted, 0)
        XCTAssertEqual(harness.scheduler.cancelled, 1)
    }

    /// The most common reason this feature never runs is Background App Refresh
    /// being switched off for the app, and there is nothing the app can do about it
    /// — so the refusal has to reach the settings screen instead of being eaten.
    func testARefusedRequestIsKeptSoItCanBeShown() throws {
        let harness = try makeHarness(policy: .wifiOnly, connection: .wifi)
        queueTwoChapters(harness.downloader)
        harness.scheduler.failure = FakeError.refused

        harness.background.scheduleIfNeeded()

        XCTAssertEqual(
            harness.background.lastScheduleError, FakeError.refused.localizedDescription
        )
        XCTAssertEqual(
            BackgroundDownloads(
                downloader: harness.downloader, settings: harness.settings,
                connection: { .wifi }, scheduler: harness.scheduler, defaults: defaults
            ).lastScheduleError,
            FakeError.refused.localizedDescription,
            "A refusal the user has not seen yet must survive the app being relaunched"
        )
    }

    // MARK: - The network policy, with nobody to ask

    /// The failure this feature is not allowed to have. In the foreground a
    /// metered connection produces a prompt; there is no prompt to produce when
    /// the phone is in a pocket, so the only honest answer is to fetch nothing and
    /// wait for a window on Wi-Fi.
    func testWifiOnlyFetchesNothingOnCellularAndWaitsForAnotherWindow() throws {
        let harness = try makeHarness(policy: .wifiOnly, connection: .cellular)
        queueTwoChapters(harness.downloader)
        let task = FakeTask()

        harness.background.run(task: task)

        XCTAssertEqual(harness.background.lastRun?.outcome, .blockedByPolicy)
        XCTAssertEqual(harness.background.lastRun?.chapters, 0)
        XCTAssertEqual(harness.background.lastRun?.connection, .cellular)
        XCTAssertFalse(harness.downloader.isBusy, "Not one request may go out")
        XCTAssertEqual(harness.downloader.remainingCount, 2)
        XCTAssertEqual(task.completions, [false], "The window did not do what it was woken for")
        XCTAssertEqual(harness.scheduler.submitted, 1, "The work is still worth another window")
    }

    /// A personal hotspot arrives as a Wi-Fi interface, so `NetworkMonitor` folds
    /// it into `.cellular`. This is the check that the background path respects
    /// that rather than trusting the interface name.
    func testWifiOnlyFetchesNothingOnAHotspot() throws {
        let connection = NetworkMonitor.classify(
            isSatisfied: true, usesCellular: false, isExpensive: true
        )
        let harness = try makeHarness(policy: .wifiOnly, connection: connection)
        queueTwoChapters(harness.downloader)

        harness.background.run(task: FakeTask())

        XCTAssertEqual(harness.background.lastRun?.outcome, .blockedByPolicy)
        XCTAssertFalse(harness.downloader.isBusy)
    }

    /// Before the first path report there is no evidence the connection is cheap.
    /// The foreground resolves that doubt towards "do not nag"; the background has
    /// to resolve it the other way, because the cost of being wrong is a data bill
    /// the user never agreed to.
    func testWifiOnlyFetchesNothingWhileTheConnectionIsStillUnreported() throws {
        let harness = try makeHarness(policy: .wifiOnly, connection: .unknown)
        queueTwoChapters(harness.downloader)

        harness.background.run(task: FakeTask())

        XCTAssertEqual(harness.background.lastRun?.outcome, .blockedByPolicy)
        XCTAssertFalse(harness.downloader.isBusy)
    }

    /// The other half of the promise: a user who has said the data is theirs to
    /// spend must actually get their book overnight.
    func testAllowingCellularLetsTheQueueRunInTheBackground() throws {
        let harness = try makeHarness(policy: .wifiAndCellular, connection: .cellular)
        queueTwoChapters(harness.downloader)

        harness.background.run(task: FakeTask())

        XCTAssertTrue(harness.downloader.isBusy)
        harness.downloader.cancel()
    }

    // MARK: - Handing the time back

    /// Being woken for an empty queue is not a failure, but it is not a reason to
    /// stay scheduled either: the download was finished in the foreground while
    /// the request was still standing.
    func testAWindowWithNothingToDoReportsSuccessAndStopsAskingForMore() throws {
        let harness = try makeHarness(policy: .wifiOnly, connection: .wifi)
        let task = FakeTask()

        harness.background.run(task: task)

        XCTAssertEqual(harness.background.lastRun?.outcome, .nothingToDo)
        XCTAssertEqual(task.completions, [true])
        XCTAssertEqual(harness.scheduler.cancelled, 1)
        XCTAssertEqual(harness.scheduler.submitted, 0)
    }

    /// Expiration is the path most likely to be wrong, because two things race to
    /// end one window: iOS wanting its time back, and the queue coming to rest
    /// because that very pause cancelled it. `setTaskCompleted` raises the second
    /// time it is called, and reporting `completed` for a run iOS cut short would
    /// throw away the one signal that says the window was too short.
    func testExpirationPausesTheQueueOnceAndKeepsItsChapters() async throws {
        let harness = try makeHarness(policy: .wifiOnly, connection: .wifi)
        queueTwoChapters(harness.downloader)
        let task = FakeTask()
        harness.background.run(task: task)
        XCTAssertTrue(harness.downloader.isBusy)

        // Fired with no suspension in between, so the run is still parked on its
        // first fetch — which is exactly when iOS would cut a real window short.
        let expire = try XCTUnwrap(task.expirationHandler)
        expire()
        await waitForRecord(harness.background)

        XCTAssertEqual(harness.background.lastRun?.outcome, .expired)
        XCTAssertEqual(task.completions, [false], "Completed exactly once, and not as a success")
        XCTAssertEqual(harness.downloader.status, .paused)
        XCTAssertTrue(harness.downloader.canResume, "An expired window must not lose the queue")
        XCTAssertEqual(harness.downloader.remainingCount, 2)
        XCTAssertEqual(harness.scheduler.submitted, 1, "What is left needs another window")
        harness.downloader.cancel()
    }

    // MARK: - The record

    /// The record is the entire observability of this feature, and the interesting
    /// cases are the ones where the process does not survive to show it — so it has
    /// to be on disk before the window ends, not held in memory.
    func testTheLastRunSurvivesTheProcessThatWroteIt() throws {
        let harness = try makeHarness(policy: .wifiOnly, connection: .cellular)
        queueTwoChapters(harness.downloader)
        harness.background.run(task: FakeTask())

        let reloaded = BackgroundDownloads(
            downloader: harness.downloader, settings: harness.settings,
            connection: { .wifi }, scheduler: harness.scheduler, defaults: defaults
        )

        XCTAssertEqual(reloaded.lastRun, harness.background.lastRun)
        XCTAssertEqual(reloaded.lastRun?.outcome, .blockedByPolicy)
    }

    /// A window that arrives after iOS has terminated the app lands in a process
    /// with no scene, and so with no object graph and no windowed web view to fetch
    /// through. The queue itself survives on disk, so what has to be recorded is
    /// that the window was unusable — otherwise this is indistinguishable from "the
    /// window never came", and those call for opposite reactions.
    func testAWindowThatOutlivesTheProcessSaysSoRatherThanNothing() throws {
        BackgroundDownloads.recordDeferredToLaunch(defaults: defaults)

        let harness = try makeHarness(policy: .wifiOnly, connection: .wifi)

        XCTAssertEqual(harness.background.lastRun?.outcome, .deferredToLaunch)
    }

    // MARK: - Harness

    private struct Harness {
        let background: BackgroundDownloads
        let downloader: DownloadManager
        let settings: DownloadSettings
        let scheduler: FakeScheduler
    }

    private func makeHarness(
        policy: DownloadSettings.NetworkPolicy, connection: NetworkMonitor.Connection
    ) throws -> Harness {
        let database = try AppDatabase.makeInMemory()
        let files = ChapterFileStore(
            root: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        let downloader = DownloadManager(
            service: BookService(fetcher: WebFetcher(), repo: LibraryRepo(database: database)),
            downloads: DownloadStore(database: database, files: files),
            pacer: RequestPacer(),
            queueStore: DownloadQueueStore(
                url: URL.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
            )
        )
        let settings = DownloadSettings(defaults: defaults)
        settings.network = policy
        let scheduler = FakeScheduler()
        return Harness(
            background: BackgroundDownloads(
                downloader: downloader, settings: settings,
                connection: { connection }, scheduler: scheduler, defaults: defaults
            ),
            downloader: downloader,
            settings: settings,
            scheduler: scheduler
        )
    }

    /// Leaves the queue exactly where backgrounding leaves it: paused, with work
    /// remaining. Pausing in the same turn as the start means the run task never
    /// got to issue a request.
    private func queueTwoChapters(_ downloader: DownloadManager) {
        let book = Book(
            id: "book", siteId: "demo", siteBookId: "1", title: "t", displayName: nil,
            author: nil, coverURL: nil, addedAt: Date(), updatedAt: Date(),
            lastReadSiteChapterId: nil, lastReadParagraph: nil,
            lastReadCharacterOffset: nil, catalogUpdatedAt: nil
        )
        let chapters = (1...2).map {
            Chapter(
                id: "\($0)", bookId: "book", siteChapterId: "\($0)", index: $0,
                title: "chapter", url: "https://demo.test/txt/1/\($0)", addedAt: nil,
                downloadedAt: nil
            )
        }
        downloader.start(book: book, rule: Self.makeRule(), chapters: chapters)
        downloader.pause()
    }

    /// The expiration handler hops to the main actor on purpose — iOS calls it off
    /// it — so a test has to let that hop happen.
    private func waitForRecord(_ background: BackgroundDownloads) async {
        for _ in 0..<50 where background.lastRun == nil {
            await Task.yield()
        }
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

private enum FakeError: LocalizedError {
    case refused

    var errorDescription: String? { "Background App Refresh is off" }
}

private final class FakeScheduler: BackgroundTaskScheduling {
    var submitted = 0
    var cancelled = 0
    var failure: (any Error)?

    func submitProcessingRequest(identifier: String) throws {
        if let failure { throw failure }
        submitted += 1
    }

    func cancel(identifier: String) {
        cancelled += 1
    }
}

/// Stands in for `BGTask`, which cannot be constructed. Records every completion
/// rather than the last one, so completing a window twice is visible instead of
/// being overwritten — on a real `BGTask` it raises.
private final class FakeTask: BackgroundTaskHandle {
    var expirationHandler: (() -> Void)?
    var completions: [Bool] = []

    func setTaskCompleted(success: Bool) {
        completions.append(success)
    }
}
