import XCTest
@testable import NovelReader

/// The download queue is mutated from two places at once — the run loop as each
/// fetch returns, and the user tapping cancel — so its bookkeeping has to
/// tolerate the queue changing underneath a fetch that is still in flight.
@MainActor
final class DownloadManagerTests: XCTestCase {
    private func makeManager() throws -> DownloadManager {
        let database = try AppDatabase.makeInMemory()
        let files = ChapterFileStore(root: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        return DownloadManager(
            service: BookService(fetcher: WebFetcher(), repo: LibraryRepo(database: database)),
            downloads: DownloadStore(database: database, files: files),
            pacer: RequestPacer(),
            // Its own file per manager: these cases mutate a queue that now writes
            // itself to disk, and a shared path would let one case's queue be read
            // back by the next. What that file is *for* is pinned in
            // `DownloadQueuePersistenceTests`.
            queueStore: DownloadQueueStore(
                url: URL.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
            )
        )
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

    private func makeBook() -> Book {
        Book(
            id: "book", siteId: "demo", siteBookId: "1", kind: .novel, title: "t",
            displayName: nil, author: nil, coverURL: nil, addedAt: Date(), updatedAt: Date(),
            lastReadSiteChapterId: nil, lastReadParagraph: nil,
            lastReadCharacterOffset: nil, lastReadFraction: nil, lastReadAt: nil, catalogUpdatedAt: nil
        )
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
        XCTAssertNil(manager.progress, "A finished run must not leave a progress row behind")
        XCTAssertFalse(manager.isBusy)
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
    /// release a hold taken out by the run that replaced it — a background window
    /// told "the queue is at rest" before its first chapter had even been requested
    /// would hand the system's time straight back, having fetched nothing.
    func testTheTeardownOfAReplacedRunDoesNotReleaseTheNewOne() async throws {
        let manager = try makeManager()
        manager.start(
            book: makeBook(), rule: makeRule(), chapters: [makeChapter("1"), makeChapter("2")]
        )
        manager.pause()
        var released = false

        manager.resume { released = true }
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
            manager.remaining.map(\.id), ["3", "4", "5"],
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
        XCTAssertEqual(manager.progress?.completed, 0, "A rejected chapter must not count as progress")
        manager.cancel()
    }
}
