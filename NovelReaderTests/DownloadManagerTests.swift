import XCTest
@testable import NovelReader

/// The download queue is mutated from two places at once — the run loop as each
/// fetch returns, and the user tapping cancel — so its bookkeeping has to
/// tolerate the queue changing underneath a fetch that is still in flight.
@MainActor
final class DownloadManagerTests: XCTestCase {
    private func makeManager(trace: TraceLog = .makeShared()) throws -> DownloadManager {
        let database = try AppDatabase.makeInMemory()
        let files = ChapterFileStore(root: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        return DownloadManager(
            service: BookService(fetcher: WebFetcher(), repo: LibraryRepo(database: database)),
            downloads: DownloadStore(database: database, files: files),
            images: ImageFetcher(),
            pacer: RequestPacer(),
            // Its own file per manager: these cases mutate a queue that now writes
            // itself to disk, and a shared path would let one case's queue be read
            // back by the next. What that file is *for* is pinned in
            // `DownloadQueuePersistenceTests`.
            queueStore: DownloadQueueStore(
                url: URL.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
            ),
            trace: trace
        )
    }

    /// A `TraceLog` of its own, recording, writing nowhere anything else reads.
    private func makeTrace() -> TraceLog {
        let root = URL.temporaryDirectory.appendingPathComponent(
            "DownloadManagerTests-\(UUID().uuidString)"
        )
        let trace = TraceLog(
            directory: root, defaults: UserDefaults(suiteName: root.lastPathComponent)!
        )
        trace.isOn = true
        return trace
    }

    /// Polls, because `note` hands the line to a writer queue rather than blocking the
    /// caller — the whole point of the instrument being safe to put in a download loop.
    private func waitForTrace(
        _ event: String, in trace: TraceLog, within seconds: Double = 5
    ) -> String? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let lines = String(data: trace.contents(), encoding: .utf8)?
                .split(separator: "\n").map(String.init) ?? []
            if let line = lines.first(where: { $0.contains(event) }) { return line }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return nil
    }

    private func makeRule() -> SiteRule {
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
                author: nil, cover: nil, category: nil, status: nil, intro: nil, latestChapter: nil
            ),
            catalog: .init(container: "#catalog", linkSelector: "a", order: .ascending),
            chapter: .init(
                titleSelectors: ["h1"], contentSelectors: [".content"],
                stripSelectors: [], dropParagraphPatterns: nil, prevSelector: nil, nextSelector: nil
            ),
            notes: nil
        )
    }

    private func downloadedChapter(_ id: String) -> Chapter {
        var chapter = makeChapter(id)
        chapter.downloadedAt = Date()
        return chapter
    }

    private func makeBook(id: String = "book", kind: SiteRule.Kind = .novel) -> Book {
        Book(
            id: id, siteId: "demo", siteBookId: id, kind: kind, title: "t",
            displayName: nil, author: nil, coverURL: nil, addedAt: Date(), updatedAt: Date(),
            lastReadSiteChapterId: nil, lastReadParagraph: nil,
            lastReadCharacterOffset: nil, lastReadFraction: nil, lastReadAt: nil, catalogUpdatedAt: nil
        )
    }

    private func job(_ book: Book, _ ids: [String]) -> DownloadManager.Job {
        DownloadManager.Job(book: book, rule: makeRule(), chapters: ids.map(makeChapter))
    }

    private func makeChapter(_ id: String) -> Chapter {
        Chapter(
            id: id, bookId: "book", siteChapterId: id, index: 0,
            title: "chapter", url: "https://example.com/\(id)", addedAt: nil, downloadedAt: nil
        )
    }

    /// The crash: "download all", then cancel. Cancelling empties the queue
    /// while a chapter fetch is still running; when that fetch returned, the
    /// loop removed the head of an array that no longer had one and the app
    /// died on the spot. Completing a chapter that is no longer queued has to
    /// be an ordinary "stop now", not a trap.
    func testCompletingAChapterAfterCancelIsNotFatal() throws {
        let manager = try makeManager()
        XCTAssertFalse(
            manager.completeIfStillQueued(makeChapter("1")),
            "A chapter that is no longer queued must report that the run should stop"
        )
    }

    /// A finished run must leave nothing on screen. Keeping the last progress
    /// around left a full bar and a "cancel" button on the book page after the
    /// download was over — still offering to cancel it after the downloads had
    /// been deleted.
    func testAFinishedRunClearsItsProgress() throws {
        let manager = try makeManager()
        let book = makeBook()
        // Nothing to do is the cheapest way to reach "finished" without a network.
        manager.start(book: book, rule: makeRule(), chapters: [downloadedChapter("1")])
        XCTAssertEqual(manager.status, .finished)
        XCTAssertTrue(manager.jobs.isEmpty, "A finished run must not leave a progress row behind")
        XCTAssertFalse(manager.isBusy)
    }

    /// A paused book is still the reader's download. Starting another book used to
    /// cancel it outright, throwing the rest of it away without a word; now the new
    /// book takes its place behind it.
    func testAnotherBookQueuesBehindAPausedOneInsteadOfReplacingIt() throws {
        let manager = try makeManager()
        manager.restore([job(makeBook(id: "a"), ["1", "2"])])
        manager.start(book: makeBook(id: "b"), rule: makeRule(), chapters: [makeChapter("3")])

        XCTAssertEqual(manager.jobs.map(\.id), ["a", "b"], "Behind it, in the order asked")
        XCTAssertEqual(manager.job(for: "a")?.remaining.map(\.id), ["1", "2"])
        XCTAssertEqual(manager.activeBookId, "a", "The book in front goes first")
        XCTAssertEqual(manager.remainingCount, 3, "A background window counts every book")
        manager.cancel()
    }

    /// Asking again for a queued book adds to its share rather than queuing it twice
    /// or forgetting the first selection.
    func testAskingAgainForAQueuedBookAddsItsChapters() throws {
        let manager = try makeManager()
        manager.restore([job(makeBook(id: "a"), ["1"]), job(makeBook(id: "b"), ["2"])])
        manager.start(
            book: makeBook(id: "b"), rule: makeRule(), chapters: [makeChapter("2"), makeChapter("3")]
        )

        XCTAssertEqual(manager.jobs.map(\.id), ["a", "b"])
        XCTAssertEqual(manager.job(for: "b")?.remaining.map(\.id), ["2", "3"])
        XCTAssertEqual(manager.job(for: "b")?.total, 2)
        manager.cancel()
    }

    /// Cancelling one book is not cancelling the queue — and a queue that was stopped
    /// stays stopped, because a book leaving it is not the reader saying go.
    func testCancellingOneBookLeavesTheRestQueued() throws {
        let manager = try makeManager()
        manager.restore([job(makeBook(id: "a"), ["1"]), job(makeBook(id: "b"), ["2"])])

        manager.cancel(bookId: "a")

        XCTAssertEqual(manager.jobs.map(\.id), ["b"])
        XCTAssertEqual(manager.status, .paused)
        XCTAssertTrue(manager.canResume)
        manager.cancel()
    }

    /// The point of holding a book rather than stopping the queue: the books behind it
    /// go first, and the held one keeps its place for when it is let go.
    func testAPausedBookIsSteppedOver() throws {
        let manager = try makeManager()
        manager.restore([job(makeBook(id: "a"), ["1"]), job(makeBook(id: "b"), ["2"])])
        manager.pause(bookId: "a")

        manager.resume()

        XCTAssertTrue(manager.isBusy)
        XCTAssertEqual(manager.activeBookId, "b")
        XCTAssertEqual(manager.job(for: "a")?.hold, .paused)
        XCTAssertEqual(manager.jobs.map(\.id), ["a", "b"], "Held, not moved")
        manager.cancel()
    }

    /// Every book held is a queue with nothing it can do: it must come to rest, not
    /// claim to be running, and not offer a resume that would start nothing.
    func testAQueueWhoseBooksAreAllPausedComesToRest() throws {
        let manager = try makeManager()
        manager.restore([job(makeBook(id: "a"), ["1"])])
        manager.pause(bookId: "a")

        manager.resume()

        XCTAssertFalse(manager.isBusy)
        XCTAssertFalse(manager.canResume)
        manager.resume(bookId: "a")
        XCTAssertTrue(manager.isBusy, "Letting the book go is what sets it going")
        manager.cancel()
    }

    /// The point of the queue: one book running out hands straight on to the next,
    /// inside the same run. A feed throws on download without touching the network,
    /// so its only chapter is dropped and the book empties — the hand-over moment.
    func testABookRunningOutHandsOnToTheNext() throws {
        let manager = try makeManager()
        let feed = makeBook(id: "a", kind: .feed)
        manager.start(book: feed, rule: makeRule(), chapters: [makeChapter("1")])
        manager.start(book: makeBook(id: "b"), rule: makeRule(), chapters: [makeChapter("2")])

        waitUntil { manager.activeBookId == "b" }

        XCTAssertEqual(manager.activeBookId, "b", "The next book must start by itself")
        XCTAssertTrue(manager.isBusy, "…as part of the run, not left paused")
        XCTAssertNil(manager.job(for: "a"), "A finished book leaves the queue")
        manager.cancel()
    }

    /// A book whose chapters keep failing is held, with the reason on its row, and the
    /// books behind it go on — one broken book used to stop every download behind it.
    func testAStreakHoldsTheBookAndTheQueueGoesOn() throws {
        let manager = try makeManager()
        let feed = makeBook(id: "a", kind: .feed)
        manager.start(
            book: feed, rule: makeRule(),
            chapters: [makeChapter("1"), makeChapter("2"), makeChapter("3")]
        )
        manager.start(book: makeBook(id: "b"), rule: makeRule(), chapters: [makeChapter("4")])

        waitUntil(seconds: 20) { manager.activeBookId == "b" }

        let held = manager.job(for: "a")
        XCTAssertEqual(held?.hold, .paused)
        XCTAssertEqual(held?.remaining.map(\.id), ["3"], "The third failure keeps its place")
        XCTAssertNotNil(held?.note, "…and says why")
        XCTAssertEqual(manager.activeBookId, "b")
        manager.cancel()
    }

    /// Spins the run loop, which is what lets the run task make progress.
    private func waitUntil(seconds: Double = 8, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// Backgrounding buys about thirty seconds to finish the chapter in flight,
    /// and it is paid for by a background assertion. A queue that has already
    /// stopped must release that hold immediately — holding it for the full grace
    /// period is time taken from the user for a chapter nobody is fetching.
    func testDrainingAQueueThatIsAlreadyAtRestReleasesTheCallerAtOnce() throws {
        let manager = try makeManager()
        var released = false
        manager.stopAfterCurrentChapter(reason: "background") { released = true }
        XCTAssertTrue(released)
        XCTAssertFalse(manager.isDraining, "There is no run to drain")
    }

    /// A drain request must not outlive the run it was made for. Left set, the
    /// next run would stop after a single chapter with nothing on screen to say
    /// why — and the caller waiting on it would never be released.
    func testAUserPauseClearsAPendingDrainAndReleasesTheCaller() throws {
        let manager = try makeManager()
        var released = false
        manager.start(book: makeBook(), rule: makeRule(), chapters: [makeChapter("1")])
        manager.stopAfterCurrentChapter(reason: "background") { released = true }
        XCTAssertTrue(manager.isDraining)

        manager.pause()

        XCTAssertFalse(manager.isDraining)
        XCTAssertTrue(released)
        manager.cancel()
    }

    /// A cancelled run still executes its own teardown: the task body is already
    /// scheduled, so it runs once and reaches its `defer`. That teardown must not
    /// release a hold taken out by the run that replaced it — a background assertion
    /// told "the queue is at rest" before the chapter in flight had landed would hand
    /// the system's time straight back, and the chapter would be fetched again.
    func testTheTeardownOfAReplacedRunDoesNotReleaseTheNewOne() async throws {
        let manager = try makeManager()
        manager.start(
            book: makeBook(), rule: makeRule(), chapters: [makeChapter("1"), makeChapter("2")]
        )
        manager.pause()
        var released = false

        manager.resume()
        manager.stopAfterCurrentChapter(reason: "background") { released = true }
        // Let the cancelled run's body get as far as its defer.
        for _ in 0..<5 { await Task.yield() }

        XCTAssertFalse(released, "The hold belongs to the run that is now going")
        XCTAssertTrue(manager.isBusy)
        manager.cancel()
        XCTAssertTrue(released, "…and is released once that run really does stop")
    }

    /// The download queue that vanished after a Cloudflare check.
    ///
    /// Dropping a chapter that will not fetch is deliberate — one bad chapter must not
    /// strand the eight hundred behind it. But when the failure is not about the
    /// chapter at all, every chapter fails, and dropping each one in turn walks the
    /// whole queue to nothing and calls it a finished download. Resuming after a
    /// challenge is exactly when that happens: the clearance may not have taken, and
    /// the queue quietly ate itself while the reader watched the progress bar run.
    func testAStreakOfFailuresStopsTheQueueInsteadOfEatingIt() throws {
        let manager = try makeManager()
        let chapters = (1...5).map { makeChapter("\($0)") }
        manager.start(book: makeBook(), rule: makeRule(), chapters: chapters)

        // Two chapters that will not fetch, each dropped and walked past — the rule a
        // book with a couple of unreadable chapters depends on.
        XCTAssertFalse(manager.noteChapterFailed())
        XCTAssertTrue(manager.completeIfStillQueued(chapters[0]))
        XCTAssertFalse(manager.noteChapterFailed())
        XCTAssertTrue(manager.completeIfStillQueued(chapters[1]))

        XCTAssertTrue(
            manager.noteChapterFailed(),
            "three in a row is no longer a claim about chapters"
        )
        XCTAssertEqual(
            manager.current?.remaining.map(\.id), ["3", "4", "5"],
            "and the chapter that hit the limit keeps its place, never having had a fair go"
        )
        manager.cancel()
    }

    /// The streak has to be a streak. Three unreadable chapters spread through a long
    /// book is a site with three unreadable chapters, and stopping there would leave the
    /// reader tapping resume for the rest of the novel.
    func testAChapterThatLandsClearsTheStreak() throws {
        let manager = try makeManager()
        let chapters = (1...4).map { makeChapter("\($0)") }
        manager.start(book: makeBook(), rule: makeRule(), chapters: chapters)

        XCTAssertFalse(manager.noteChapterFailed())
        XCTAssertFalse(manager.noteChapterFailed())
        manager.noteChapterSucceeded()

        XCTAssertFalse(manager.noteChapterFailed())
        XCTAssertFalse(manager.noteChapterFailed())
        manager.cancel()
    }

    /// Resuming is the user saying they have dealt with whatever stopped the queue —
    /// cleared the challenge, moved onto Wi-Fi. The new run has to be allowed to find
    /// out for itself, rather than stopping on the first chapter because the last run
    /// had already used the allowance up.
    func testResumingStartsTheFailureCountAgain() throws {
        let manager = try makeManager()
        manager.start(
            book: makeBook(), rule: makeRule(),
            chapters: [makeChapter("1"), makeChapter("2"), makeChapter("3")]
        )
        XCTAssertFalse(manager.noteChapterFailed())
        XCTAssertFalse(manager.noteChapterFailed())
        manager.pause()

        manager.resume()

        XCTAssertFalse(manager.noteChapterFailed(), "the previous run's failures are spent")
        XCTAssertFalse(manager.noteChapterFailed())
        manager.cancel()
    }

    /// The same hazard with the queue non-empty but moved on: whatever is at the
    /// head now belongs to a different run, and must not be consumed by the old
    /// one's progress accounting.
    func testCompletingAChapterThatIsNoLongerAtTheHeadIsRejected() throws {
        let manager = try makeManager()
        let rule = makeRule()
        let book = makeBook()
        manager.start(book: book, rule: rule, chapters: [makeChapter("2"), makeChapter("3")])
        XCTAssertFalse(manager.completeIfStillQueued(makeChapter("1")))
        XCTAssertEqual(manager.current?.completed, 0, "A rejected chapter must not count as progress")
        manager.cancel()
    }

    /// The queue writes down what it did, where somebody can read it afterwards.
    ///
    /// Downloading is the one thing this app does that nobody is watching, and every
    /// other test here inspects state that exists only while the process does. The
    /// question this instrument was added for — "I asked for a download last night and
    /// woke up to nothing" — can only be answered by a file, and before these lines
    /// existed a window that was never granted and a window that ran and achieved
    /// nothing left the same empty record.
    ///
    /// Both counts are asserted rather than the lines merely being present: `n` and `of`
    /// are what separate "the tap queued nothing because it was all on disk already"
    /// from "the tap queued work that then stopped somewhere", which is the distinction
    /// the whole line exists to draw.
    func testAQueueWritesItsControlPointsToTheTrace() throws {
        let trace = makeTrace()
        let manager = try makeManager(trace: trace)

        // One already on disk, so the pair of numbers cannot both be the same value and
        // a line that reported either one twice would still pass.
        manager.start(
            book: makeBook(), rule: makeRule(),
            chapters: [makeChapter("1"), makeChapter("2"), downloadedChapter("3")]
        )
        XCTAssertEqual(
            waitForTrace("dl start", in: trace)?
                .contains("dl start n=2 of=3"), true,
            "the queue has to record how much was asked for against how much was queued"
        )

        // Read rather than assumed: waiting for the line above spins the run loop, which
        // is the one thing that lets the run task make progress. Pinning a literal here
        // would be pinning how far it happened to get.
        let left = manager.remainingCount
        XCTAssertGreaterThan(left, 0, "the queue has to still owe something for this to mean anything")
        manager.cancel()
        XCTAssertEqual(
            waitForTrace("dl cancel", in: trace)?.contains("dl cancel left=\(left)"), true,
            "a queue abandoned with work still in it is exactly what has to be readable later"
        )
    }
}
