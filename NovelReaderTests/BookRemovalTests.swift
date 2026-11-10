import XCTest
@testable import NovelReader

/// Removing a book from the shelf must not wait for its downloads to be deleted.
///
/// The report: a book with many chapters on disk held the swipe for seconds, because the
/// search text, every chapter file and every chapter row were deleted before the row was
/// allowed to leave the screen. The screen goes first now, and the deleting follows.
///
/// The other half is what a removal the system cuts short leaves behind. The book's own
/// row is deleted last, so until the files are gone the book is still in the database —
/// which is what puts it back on the shelf at the next launch, removable again, rather
/// than leaving its files on disk with nothing on screen to reach them by.
@MainActor
final class BookRemovalTests: XCTestCase {
    private var tempRoot: URL!
    private var env: AppEnvironment!
    private var book: Book!

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NovelReaderTests-\(UUID().uuidString)")
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
        book = try env.repo.bookmark(siteId: "alpha", siteBookId: "1", title: "A")
        let ids = (1...20).map { "c\($0)" }
        try env.repo.replaceCatalog(bookId: book.id, entries: ids.map {
            (siteChapterId: $0, title: "第\($0)章", url: "https://alpha/\($0)")
        })
        for id in ids {
            try env.downloads.save(paragraphs: ["一段", "二段"], book: book, siteChapterId: id)
        }
        env.recordProgress(book: book, position: .chapterStart("c1"), fraction: 0.5, publish: true)
        env.reloadLibrary()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private var bookDirectory: URL {
        env.files.directory(siteId: book.siteId, siteBookId: book.siteBookId)
    }

    func testTheBookLeavesTheScreenBeforeItsFilesAreDeleted() async throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: bookDirectory.path), "precondition")

        let removal = env.removeBookmark(book)

        // Nothing has been deleted yet — the work has not had a turn — and the shelf
        // already does not show it.
        XCTAssertFalse(env.books.contains { $0.id == book.id }, "gone from the shelf at once")
        XCTAssertFalse(env.recentReads.contains { $0.book.id == book.id }, "…and from the history")
        XCTAssertNotNil(try env.repo.book(id: book.id), "the row outlives the files")

        // A reload while the deleting runs — iCloud, a download landing — must not put
        // the book back.
        env.reloadLibrary()
        XCTAssertFalse(env.books.contains { $0.id == book.id }, "a reload must not bring it back")

        await removal.value

        XCTAssertNil(try env.repo.book(id: book.id), "the row goes once the files have")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bookDirectory.path))
        XCTAssertFalse(env.books.contains { $0.id == book.id })
    }

    /// Swiping twice, or iCloud reporting this device's own removal back, while the
    /// first is still deleting is one removal.
    func testRemovingABookAlreadyBeingRemovedIsTheSameRemoval() async throws {
        let first = env.removeBookmark(book)
        let second = env.removeBookmark(book, publish: false)
        await first.value
        await second.value
        XCTAssertNil(try env.repo.book(id: book.id))
    }
}
