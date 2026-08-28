import XCTest
@testable import NovelReader

/// The delete scopes are a product requirement, and each one is destructive in
/// a different blast radius. These tests exist to pin that radius: a scope that
/// quietly widened would silently destroy a user's other downloads.
final class DownloadStoreTests: XCTestCase {
    private var tempRoot: URL!
    private var store: DownloadStore!
    private var library: LibraryRepo!

    private var bookA: Book!   // site "alpha"
    private var bookB: Book!   // site "alpha", different book
    private var bookC: Book!   // site "beta"

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NovelReaderTests-\(UUID().uuidString)")
        let database = try AppDatabase.makeInMemory()
        library = LibraryRepo(database: database)
        store = DownloadStore(database: database, files: ChapterFileStore(root: tempRoot))

        bookA = try library.bookmark(siteId: "alpha", siteBookId: "1", title: "A")
        bookB = try library.bookmark(siteId: "alpha", siteBookId: "2", title: "B")
        bookC = try library.bookmark(siteId: "beta", siteBookId: "1", title: "C")

        for book in [bookA!, bookB!, bookC!] {
            try library.replaceCatalog(bookId: book.id, entries: [
                (siteChapterId: "c1", title: "Chapter 1", url: "https://x/1"),
                (siteChapterId: "c2", title: "Chapter 2", url: "https://x/2"),
            ])
            for chapterId in ["c1", "c2"] {
                try store.save(paragraphs: ["line"], book: book, siteChapterId: chapterId)
            }
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func downloadedCounts() throws -> (a: Int, b: Int, c: Int) {
        (
            try store.downloadedCount(bookId: bookA.id),
            try store.downloadedCount(bookId: bookB.id),
            try store.downloadedCount(bookId: bookC.id)
        )
    }

    func testSetupDownloadsEverything() throws {
        let counts = try downloadedCounts()
        XCTAssertEqual(counts.a, 2)
        XCTAssertEqual(counts.b, 2)
        XCTAssertEqual(counts.c, 2)
    }

    func testDeleteChapterRemovesOnlyThatChapter() throws {
        try store.delete(.chapter(book: bookA, siteChapterId: "c1"))

        let counts = try downloadedCounts()
        XCTAssertEqual(counts.a, 1, "only one chapter of book A should remain")
        XCTAssertEqual(counts.b, 2)
        XCTAssertEqual(counts.c, 2)
        XCTAssertFalse(store.files.exists(siteId: "alpha", siteBookId: "1", siteChapterId: "c1"))
        XCTAssertTrue(store.files.exists(siteId: "alpha", siteBookId: "1", siteChapterId: "c2"))
    }

    func testDeleteBookLeavesSiblingBookOnSameSiteIntact() throws {
        try store.delete(.book(bookA))

        let counts = try downloadedCounts()
        XCTAssertEqual(counts.a, 0)
        XCTAssertEqual(counts.b, 2, "a sibling book on the same site must be untouched")
        XCTAssertEqual(counts.c, 2)
        XCTAssertTrue(store.files.exists(siteId: "alpha", siteBookId: "2", siteChapterId: "c1"))
    }

    func testDeleteSiteClearsThatSiteOnly() throws {
        try store.delete(.site(siteId: "alpha"))

        let counts = try downloadedCounts()
        XCTAssertEqual(counts.a, 0)
        XCTAssertEqual(counts.b, 0)
        XCTAssertEqual(counts.c, 2, "a different site must be untouched")
        XCTAssertTrue(store.files.exists(siteId: "beta", siteBookId: "1", siteChapterId: "c1"))
    }

    func testDeleteEverythingClearsAllSites() throws {
        try store.delete(.everything)

        let counts = try downloadedCounts()
        XCTAssertEqual(counts.a, 0)
        XCTAssertEqual(counts.b, 0)
        XCTAssertEqual(counts.c, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempRoot.path))
    }

    /// The same four levels, for a book whose chapters are directories of pages rather
    /// than files of text.
    ///
    /// Nothing above `ChapterFileStore` knows the two shapes apart, which is exactly
    /// why this is worth checking: a scope that quietly only took the `.txt` would leave
    /// a comic's pages on the device, and the storage screen would go on reporting space
    /// the user has already asked twice to get back.
    func testEveryLevelTakesAComicsPagesWithItsFlag() throws {
        let comic = try library.bookmark(
            siteId: "alpha", siteBookId: "3", kind: .comic, title: "D"
        )
        try library.replaceCatalog(bookId: comic.id, entries: [
            (siteChapterId: "v1", title: "Volume 1", url: "https://x/v1"),
        ])
        let pages = [Data("page 0".utf8), Data("page 1".utf8)]
        let levels: [DownloadStore.Scope] = [
            .chapter(book: comic, siteChapterId: "v1"),
            .book(comic),
            .site(siteId: "alpha"),
            .everything,
        ]

        for level in levels {
            try store.save(pages: pages, book: comic, siteChapterId: "v1")
            XCTAssertEqual(try store.downloadedCount(bookId: comic.id), 1)
            XCTAssertTrue(store.files.hasPages(siteId: "alpha", siteBookId: "3", siteChapterId: "v1"))

            try store.delete(level)

            XCTAssertEqual(
                try store.downloadedCount(bookId: comic.id), 0, "\(level) left the flag set"
            )
            XCTAssertFalse(
                store.files.hasPages(siteId: "alpha", siteBookId: "3", siteChapterId: "v1"),
                "\(level) left the pages on disk"
            )
        }
    }

    /// Deleting downloads must not delete the bookmark itself — they are
    /// separate user intentions.
    func testDeletingDownloadsKeepsBookmarks() throws {
        try store.delete(.everything)
        XCTAssertEqual(try library.allBooks().count, 3)
    }

    func testDeleteIsIdempotent() throws {
        try store.delete(.book(bookA))
        XCTAssertNoThrow(try store.delete(.book(bookA)))
    }

    /// A refreshed catalog must not appear to un-download everything.
    func testCatalogRefreshPreservesDownloadedFlags() throws {
        try library.replaceCatalog(bookId: bookA.id, entries: [
            (siteChapterId: "c1", title: "Chapter 1 (renamed)", url: "https://x/1"),
            (siteChapterId: "c2", title: "Chapter 2", url: "https://x/2"),
            (siteChapterId: "c3", title: "Chapter 3", url: "https://x/3"),
        ])

        XCTAssertEqual(try store.downloadedCount(bookId: bookA.id), 2)
        let chapters = try library.chapters(bookId: bookA.id)
        XCTAssertEqual(chapters.count, 3)
        XCTAssertEqual(chapters.map(\.index), [0, 1, 2])
        XCTAssertEqual(chapters[0].title, "Chapter 1 (renamed)")
    }
}

final class ChapterFileStoreSafetyTests: XCTestCase {
    /// Ids come from user-imported rule files, so a hostile or sloppy id must not
    /// be able to write outside the download root.
    func testPathTraversalIdsAreNeutralised() {
        let root = URL(fileURLWithPath: "/tmp/root")
        let store = ChapterFileStore(root: root)
        let url = store.fileURL(siteId: "../../etc", siteBookId: "a/b", siteChapterId: "..")
        XCTAssertTrue(url.path.hasPrefix(root.path), "escaped the download root: \(url.path)")
        XCTAssertFalse(url.pathComponents.contains(".."))
    }

    /// Two ids that sanitise to the same characters must not collide onto one
    /// file, or a reader would serve the wrong chapter's text.
    func testDistinctIdsDoNotCollideAfterSanitising() {
        let a = ChapterFileStore.safeComponent("a/b")
        let b = ChapterFileStore.safeComponent("a:b")
        XCTAssertNotEqual(a, b)
    }

    func testPlainIdsStayReadable() {
        XCTAssertEqual(ChapterFileStore.safeComponent("41051913"), "41051913")
        XCTAssertEqual(ChapterFileStore.safeComponent("69shuba"), "69shuba")
    }
}
