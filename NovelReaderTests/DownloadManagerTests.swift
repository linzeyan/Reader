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
            pacer: RequestPacer()
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
            id: "book", siteId: "demo", siteBookId: "1", title: "t", displayName: nil,
            author: nil, coverURL: nil, addedAt: Date(), updatedAt: Date(),
            lastReadChapterIndex: nil, lastReadOffset: nil, catalogUpdatedAt: nil
        )
    }

    private func makeChapter(_ id: String) -> Chapter {
        Chapter(
            id: id, bookId: "book", siteChapterId: id, index: 0,
            title: "chapter", url: "https://example.com/\(id)", downloadedAt: nil
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
