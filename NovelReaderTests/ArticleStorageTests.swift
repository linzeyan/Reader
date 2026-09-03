import UIKit
import XCTest
@testable import NovelReader

/// An article on the device: its structure, its pictures, and what deleting it takes with
/// it.
///
/// The promise being pinned is the one every part of this app is built on — a chapter is
/// downloaded *if and only if* there is something readable on the device — now that a
/// downloaded article is three things rather than one: a JSON file of blocks, a `.txt`
/// projection of the same words, and a directory of pictures.
final class ArticleStorageTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var downloads: DownloadStore!
    private var library: LibraryRepo!
    private var book: Book!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ArticleStorageTests-\(UUID().uuidString)")
        database = try AppDatabase.makeInMemory()
        library = LibraryRepo(database: database)
        downloads = DownloadStore(database: database, files: ChapterFileStore(root: root))
        book = try library.bookmark(
            siteId: Book.feedSiteId, siteBookId: "https://example.com/feed.xml",
            kind: .feed, title: "A feed"
        )
        try library.mergeCatalog(bookId: book.id, entries: [
            (siteChapterId: "a1", title: "An article", url: "https://example.com/1", publishedAt: nil),
        ])
        StubProtocol.reset()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        StubProtocol.reset()
    }

    private func article() -> [ArticleBlock] {
        [
            ArticleBlock(kind: .heading, runs: [InlineRun(text: "Why it matters")], level: 2),
            ArticleBlock(kind: .paragraph, runs: [
                InlineRun(text: "See "),
                InlineRun(text: "the other post", href: "https://example.com/other/"),
                InlineRun(text: "."),
            ]),
            ArticleBlock(kind: .code, runs: [InlineRun(text: "let x = 1")], language: "swift"),
            ArticleBlock(
                kind: .image, runs: [],
                image: ImageRef(
                    source: "https://example.com/a.png", file: "004.png",
                    width: 800, height: 600, alt: "A hillside"
                )
            ),
        ]
    }

    // MARK: - Blocks

    func testAnArticleComesBackTheShapeItWentIn() throws {
        try downloads.save(blocks: article(), book: book, siteChapterId: "a1")

        let read = try XCTUnwrap(downloads.readBlocks(book: book, siteChapterId: "a1"))

        XCTAssertEqual(read, article(), "structure that does not survive a round trip is decoration")
    }

    /// Both files, always. The `.txt` is what everything that predates articles reads —
    /// the export to txt and EPUB, the cache accounting — and it is also the fallback if
    /// the JSON is ever unreadable.
    func testTheProseProjectionIsWrittenBesideTheBlocks() throws {
        try downloads.save(blocks: article(), book: book, siteChapterId: "a1")

        let lines = try downloads.readParagraphs(book: book, siteChapterId: "a1")

        XCTAssertEqual(
            lines,
            ["Why it matters", "See the other post.", "let x = 1", "A hillside"],
            "an article has to be readable as prose by everything that never heard of blocks"
        )
        XCTAssertTrue(
            downloads.files.exists(
                siteId: book.siteId, siteBookId: book.siteBookId, siteChapterId: "a1"
            )
        )
    }

    func testSavingAnArticleMarksItDownloaded() throws {
        try downloads.save(blocks: article(), book: book, siteChapterId: "a1")

        XCTAssertEqual(try downloads.downloadedCount(bookId: book.id), 1)
    }

    /// Retention deletes articles for a living. A scope that missed the JSON or the
    /// pictures would leave the device filling up with files nothing can ever find again.
    func testDeletingAChapterTakesItsBlocksAndPicturesWithIt() throws {
        try downloads.save(blocks: article(), book: book, siteChapterId: "a1")
        try downloads.write(
            image: Data("not really a picture".utf8), named: "004.png",
            book: book, siteChapterId: "a1"
        )
        let sizeBefore = downloads.size(of: .chapter(book: book, siteChapterId: "a1"))
        XCTAssertGreaterThan(sizeBefore, 0, "and the storage screen has to count all of it")

        try downloads.delete(.chapter(book: book, siteChapterId: "a1"))

        XCTAssertNil(downloads.readBlocks(book: book, siteChapterId: "a1"))
        XCTAssertEqual(downloads.size(of: .chapter(book: book, siteChapterId: "a1")), 0)
        XCTAssertEqual(try downloads.downloadedCount(bookId: book.id), 0)
    }

    /// A novel chapter and an article live in the same tree and are read by the same
    /// reader. Asking prose for its blocks has to be an honest "there are none" rather
    /// than an error or an empty article.
    func testProseHasNoBlocks() throws {
        try downloads.save(paragraphs: ["A line."], book: book, siteChapterId: "a1")

        XCTAssertNil(downloads.readBlocks(book: book, siteChapterId: "a1"))
        XCTAssertEqual(try downloads.readParagraphs(book: book, siteChapterId: "a1"), ["A line."])
    }

    // MARK: - Pictures

    private func images() -> ArticleImages {
        ArticleImages(session: StubProtocol.session(), downloads: downloads)
    }

    private func picture(width: Int, height: Int) throws -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height), format: format
        ).image { _ in
            UIColor.darkGray.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try XCTUnwrap(image.pngData())
    }

    func testAPictureIsStoredBesideItsArticleAndRecordedInTheBlock() async throws {
        StubProtocol.answer = .bytes(try picture(width: 600, height: 400))
        let blocks = [ArticleBlock(
            kind: .image, runs: [],
            image: ImageRef(source: "https://example.com/a.png", alt: "A hillside")
        )]

        let stored = try await images().stored(
            blocks, book: book, siteChapterId: "a1", referer: nil
        )

        let reference = try XCTUnwrap(stored[0].image)
        let file = try XCTUnwrap(reference.file, "a picture that arrived has to be pointed at")
        XCTAssertEqual(reference.width, 600)
        XCTAssertEqual(reference.height, 400)
        XCTAssertEqual(reference.alt, "A hillside", "and nothing else about the block changes")
        let directory = downloads.imageDirectory(book: book, siteChapterId: "a1")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path)
        )
    }

    /// Memory, not disk. A picture in an article is drawn as a text attachment, which
    /// decodes the whole file: a press photograph at its published size is tens of
    /// megabytes of bitmap sitting inside a column of prose.
    func testAnOversizedPictureIsStoredSmallerThanItWasPublished() async throws {
        StubProtocol.answer = .bytes(try picture(width: 4000, height: 1000))
        let blocks = [ArticleBlock(
            kind: .image, runs: [], image: ImageRef(source: "https://example.com/wide.png")
        )]

        let stored = try await images().stored(
            blocks, book: book, siteChapterId: "a1", referer: nil
        )

        let reference = try XCTUnwrap(stored[0].image)
        XCTAssertEqual(reference.width, ArticleImages.maxPixelSize)
        XCTAssertEqual(reference.height, ArticleImages.maxPixelSize / 4, "in proportion")
        XCTAssertNotNil(reference.file)
    }

    /// One dead picture must not cost the reader the article. The block keeps its address
    /// and its alt text, which is exactly what the layout draws in its place.
    func testAPictureThatWillNotDownloadLeavesTheArticleReadable() async throws {
        StubProtocol.answer = .status(404)
        let blocks = [
            ArticleBlock(kind: .paragraph, runs: [InlineRun(text: "Before.")]),
            ArticleBlock(
                kind: .image, runs: [],
                image: ImageRef(source: "https://example.com/gone.png", alt: "A hillside")
            ),
        ]

        let stored = try await images().stored(
            blocks, book: book, siteChapterId: "a1", referer: nil
        )

        XCTAssertEqual(stored.count, 2)
        XCTAssertNil(stored[1].image?.file)
        XCTAssertEqual(stored[1].image?.source, "https://example.com/gone.png")
        XCTAssertEqual(stored[1].image?.alt, "A hillside")
    }

    /// A 200 that is not a picture: a hotlink-denied stub, a login page, a WAF
    /// interstitial. Storing one would put a page of HTML where a photograph goes.
    func testAnAnswerThatIsNotAPictureIsNotStored() async throws {
        StubProtocol.answer = .ok("<html><body>Please sign in</body></html>")
        let blocks = [ArticleBlock(
            kind: .image, runs: [], image: ImageRef(source: "https://example.com/a.png")
        )]

        let stored = try await images().stored(
            blocks, book: book, siteChapterId: "a1", referer: nil
        )

        XCTAssertNil(stored[0].image?.file)
    }

    /// The page an image belongs to, which is what the hosts that refuse hotlinking key
    /// off. Without it a great many articles arrive with every picture missing.
    func testTheArticlesOwnPageIsSentAsTheReferer() async throws {
        StubProtocol.answer = .bytes(try picture(width: 100, height: 100))
        let blocks = [ArticleBlock(
            kind: .image, runs: [], image: ImageRef(source: "https://example.com/a.png")
        )]

        _ = try await images().stored(
            blocks, book: book, siteChapterId: "a1",
            referer: URL(string: "https://example.com/posts/one/")
        )

        XCTAssertEqual(
            StubProtocol.lastRequest?.value(forHTTPHeaderField: "Referer"),
            "https://example.com/posts/one/"
        )
    }
}
