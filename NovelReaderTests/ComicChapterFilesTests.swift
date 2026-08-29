import XCTest
@testable import NovelReader

/// A comic chapter on disk: a directory of numbered pages, beside the novels' `.txt`
/// files in the same tree.
///
/// The promise being defended is the one the whole download feature rests on —
/// `downloadedAt` is set if and only if there is a readable chapter on the device. A
/// chapter of text is one file, so it was free. A chapter of fifty images is fifty
/// chances to end up with half of one, and half a chapter *that says it is whole* is
/// worse than none: it is only discovered offline, which is the one place it cannot be
/// fixed. Hence the `.partial` directory for an interrupted write, and hence the marker
/// files for the pages a site would not give up — the difference between the two is
/// that the second kind is finished, and knows what it is short.
final class ComicChapterFilesTests: XCTestCase {
    private var root: URL!
    private var files: ChapterFileStore!

    private let site = "manhuagui"
    private let book = "2807"
    private let chapter = "v1"

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ComicChapterFilesTests-\(UUID().uuidString)")
        files = ChapterFileStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testPagesComeBackInReadingOrder() throws {
        try files.writePages(pages(3), siteId: site, siteBookId: book, siteChapterId: chapter)

        let urls = files.pageURLs(siteId: site, siteBookId: book, siteChapterId: chapter)
        XCTAssertEqual(urls.count, 3)
        XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, pages(3))
    }

    /// Sorted by the number, not by the name. A webtoon can run past a thousand slices,
    /// and sorting as text would read page 1000 between 099 and 100 — a chapter that is
    /// all there and in the wrong order, which nothing else would report.
    func testAThousandPagesAreOrderedByNumberNotByName() throws {
        try files.writePages(pages(1001), siteId: site, siteBookId: book, siteChapterId: chapter)

        let urls = files.pageURLs(siteId: site, siteBookId: book, siteChapterId: chapter)
        XCTAssertEqual(urls.count, 1001)
        XCTAssertEqual(try Data(contentsOf: urls[100]), Data("page 100".utf8))
        XCTAssertEqual(try Data(contentsOf: urls[1000]), Data("page 1000".utf8))
    }

    /// The extension is taken from the bytes, because these CDNs serve `.jpg`
    /// addresses holding WebP. Nothing reads it back — this is for whoever opens the
    /// folder — but it should not be a lie.
    func testTheExtensionDescribesWhatTheFileActuallyIs() throws {
        let webp = Data(Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WEBP".utf8))
        try files.writePages([webp], siteId: site, siteBookId: book, siteChapterId: chapter)

        let url = try XCTUnwrap(
            files.pageURLs(siteId: site, siteBookId: book, siteChapterId: chapter).first
        )
        XCTAssertEqual(url.pathExtension, "webp")
    }

    /// A page the site would not give up keeps its number, because the alternative is
    /// every page after it moving up one: a fifty-page chapter that lost page 12 would
    /// read as forty-nine pages, and the reader would have no way to tell that from a
    /// chapter that is forty-nine pages long. The marker is empty and named so that it
    /// is obvious to whoever opens the folder.
    func testAPageThatCouldNotBeFetchedKeepsItsPlaceAsAMarker() throws {
        try files.writePages(
            [Data("page 0".utf8), nil, Data("page 2".utf8)],
            siteId: site, siteBookId: book, siteChapterId: chapter
        )

        let urls = files.pageURLs(siteId: site, siteBookId: book, siteChapterId: chapter)
        XCTAssertEqual(urls.count, 3)
        XCTAssertEqual(urls[1].lastPathComponent, "001.missing")
        XCTAssertEqual(try Data(contentsOf: urls[1]), Data())
        XCTAssertEqual(try Data(contentsOf: urls[2]), Data("page 2".utf8))
        XCTAssertTrue(
            files.hasPages(siteId: site, siteBookId: book, siteChapterId: chapter),
            "A chapter short one page is still a chapter to read"
        )
    }

    /// A gap the reader asked for again and got. The page arrives, the marker goes, and
    /// the chapter is simply one page better than it was — no flag to change, because it
    /// was downloaded before and is downloaded after.
    func testFillingAGapReplacesTheMarkerWithThePage() throws {
        try files.writePages(
            [Data("page 0".utf8), nil], siteId: site, siteBookId: book, siteChapterId: chapter
        )

        try files.fillPage(
            Data("page 1".utf8), index: 1, siteId: site, siteBookId: book, siteChapterId: chapter
        )

        let urls = files.pageURLs(siteId: site, siteBookId: book, siteChapterId: chapter)
        XCTAssertEqual(urls.count, 2)
        XCTAssertFalse(ChapterFileStore.isGap(urls[1]))
        XCTAssertEqual(try Data(contentsOf: urls[1]), Data("page 1".utf8))
    }

    /// `fillPage` writes the page before it removes the marker, so a crash between the
    /// two leaves both on disk. Counting them both would make the chapter a page longer
    /// than it is and put every page after the gap under the wrong number — worse than
    /// either of the states this is choosing between.
    func testAPageAndItsLeftoverMarkerCountOnce() throws {
        try files.writePages(
            [Data("page 0".utf8), nil], siteId: site, siteBookId: book, siteChapterId: chapter
        )
        let directory = files.pageDirectory(
            siteId: site, siteBookId: book, siteChapterId: chapter
        )
        try Data("page 1".utf8).write(to: directory.appendingPathComponent("001.jpg"))

        let urls = files.pageURLs(siteId: site, siteBookId: book, siteChapterId: chapter)
        XCTAssertEqual(urls.count, 2)
        XCTAssertEqual(
            try Data(contentsOf: urls[1]), Data("page 1".utf8),
            "The page wins over the marker it was meant to replace"
        )
    }

    /// The whole point of writing through `.partial`: until the last page has landed
    /// there is nothing for a reader to find, so a chapter that was interrupted reads
    /// as absent rather than as short.
    func testAHalfWrittenChapterIsNotReadable() throws {
        let partial = files
            .pageDirectory(siteId: site, siteBookId: book, siteChapterId: chapter)
            .appendingPathExtension("partial")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data("page 0".utf8).write(to: partial.appendingPathComponent("000.jpg"))

        XCTAssertFalse(files.hasPages(siteId: site, siteBookId: book, siteChapterId: chapter))
        XCTAssertTrue(files.pageURLs(siteId: site, siteBookId: book, siteChapterId: chapter).isEmpty)
    }

    /// And the leftovers of that interrupted attempt must not survive into the next
    /// one, or a chapter re-downloaded shorter would come back with the old attempt's
    /// pages still in it.
    func testWritingAgainClearsWhatTheLastAttemptLeft() throws {
        let directory = files.pageDirectory(siteId: site, siteBookId: book, siteChapterId: chapter)
        let partial = directory.appendingPathExtension("partial")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: partial.appendingPathComponent("999.jpg"))

        try files.writePages(pages(2), siteId: site, siteBookId: book, siteChapterId: chapter)

        XCTAssertEqual(files.pageURLs(siteId: site, siteBookId: book, siteChapterId: chapter).count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testRewritingAChapterLeavesNoPagesFromTheLongerOne() throws {
        try files.writePages(pages(5), siteId: site, siteBookId: book, siteChapterId: chapter)
        try files.writePages(pages(2), siteId: site, siteBookId: book, siteChapterId: chapter)

        XCTAssertEqual(files.pageURLs(siteId: site, siteBookId: book, siteChapterId: chapter).count, 2)
    }

    /// The reason the pages went into the existing tree rather than a second one: the
    /// four delete levels and the size recursion were meant to keep working untouched.
    func testDeletingAChapterTakesItsPagesAndItsLeftovers() throws {
        try files.writePages(pages(3), siteId: site, siteBookId: book, siteChapterId: chapter)
        let partial = files
            .pageDirectory(siteId: site, siteBookId: book, siteChapterId: chapter)
            .appendingPathExtension("partial")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)

        try files.delete(.chapter(siteId: site, siteBookId: book, siteChapterId: chapter))

        XCTAssertFalse(files.hasPages(siteId: site, siteBookId: book, siteChapterId: chapter))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testDeletingTheBookTakesTheChaptersOfBothKinds() throws {
        try files.writePages(pages(2), siteId: site, siteBookId: book, siteChapterId: chapter)
        try files.write(paragraphs: ["text"], siteId: site, siteBookId: book, siteChapterId: "afterword")

        try files.delete(.book(siteId: site, siteBookId: book))

        XCTAssertFalse(files.hasPages(siteId: site, siteBookId: book, siteChapterId: chapter))
        XCTAssertFalse(files.exists(siteId: site, siteBookId: book, siteChapterId: "afterword"))
    }

    func testTheStorageScreenCountsPages() throws {
        try files.writePages(pages(4), siteId: site, siteBookId: book, siteChapterId: chapter)

        let expected = Int64(pages(4).reduce(0) { $0 + $1.count })
        XCTAssertEqual(
            files.size(of: .chapter(siteId: site, siteBookId: book, siteChapterId: chapter)),
            expected
        )
        XCTAssertEqual(files.size(of: .book(siteId: site, siteBookId: book)), expected)
    }

    private func pages(_ count: Int) -> [Data] {
        (0..<count).map { Data("page \($0)".utf8) }
    }
}
