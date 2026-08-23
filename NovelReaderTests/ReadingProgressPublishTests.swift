import XCTest
@testable import NovelReader

/// Leaving the reader must leave the shelf agreeing with the database.
///
/// The report behind this: a reader went from chapter 121 to 125 while a download ran,
/// backed out, and the recent-reading list still said 121 — until an unrelated reload
/// minutes later happened to pick the truth up. The database had 125 all along. The
/// throttled `.reading` writes had recorded it without publishing — that is their whole
/// design — and the `.leaving` write on the way out was then refused as identical to
/// the last one, taking the publish down with it. The refusal is right (re-stamping
/// `updatedAt` would fight the iCloud merge); swallowing the publish is the bug.
@MainActor
final class ReadingProgressPublishTests: XCTestCase {
    private var tempRoot: URL!
    private var env: AppEnvironment!
    private var book: Book!

    private let siteId = "alpha"
    private let siteBookId = "1"
    private let chapterIds = ["c1", "c2", "c3", "c4", "c5"]

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NovelReaderTests-\(UUID().uuidString)")
        env = AppEnvironment(
            database: try AppDatabase.makeInMemory(),
            files: ChapterFileStore(root: tempRoot.appendingPathComponent("files")),
            sites: SiteStore(directory: tempRoot.appendingPathComponent("sites")),
            queueStore: DownloadQueueStore(url: tempRoot.appendingPathComponent("queue.json"))
        )
        book = try env.repo.bookmark(siteId: siteId, siteBookId: siteBookId, title: "A")
        try env.repo.replaceCatalog(bookId: book.id, entries: chapterIds.map {
            (siteChapterId: $0, title: "第\($0)章", url: "https://alpha/\($0)")
        })
        // Every chapter on disk, so the session below runs without a site rule or a
        // network — the same offline shape `ReaderRetryTests` uses.
        for id in chapterIds {
            try env.downloads.save(paragraphs: ["一段", "二段"], book: book, siteChapterId: id)
        }
        // The state the report starts from: an older position, published, so the
        // recent-reading list is showing it.
        env.recordProgress(book: book, position: .chapterStart("c1"), fraction: 0.5, publish: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testLeavingPublishesAPositionTheThrottledWriteAlreadyRecorded() async throws {
        let model = ReaderModel(book: book, env: env)
        await model.start(at: .chapterStart("c3"))

        // A page settling on a later chapter: a throttled `.reading` write. The row
        // is updated; the shelf deliberately is not told yet.
        model.notePage(chapterIndex: 4, anchor: .start, fraction: 0.4)

        // Closing the book without having moved since that write — what every settled
        // page looks like on the way out.
        model.stopReading()

        let stored = try XCTUnwrap(env.repo.book(id: book.id))
        XCTAssertEqual(
            stored.lastReadSiteChapterId, "c5",
            "the throttled write reached the database"
        )
        XCTAssertEqual(
            env.recentReads.first?.book.lastReadSiteChapterId, "c5",
            "leaving must publish what the database already knows"
        )
    }
}
