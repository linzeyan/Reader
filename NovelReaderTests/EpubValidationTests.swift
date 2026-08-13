import XCTest
@testable import NovelReader

/// Writes one complete export to a fixed path on the developer's machine so it can
/// be handed to epubcheck.
///
/// The app's own reader is the only thing that has ever read what the exporter
/// writes, and two halves of one codebase agreeing proves less than it looks like:
/// a mistake made in both directions stays invisible. epubcheck is the outside
/// opinion, and it cannot be run from in here — it is a Java jar this repo does not
/// and should not carry. So the test's job is to produce the file and say where it
/// is; validating it is a shell command.
///
/// Opt-in through `NOVELREADER_EPUBCHECK`, exactly as `LiveSiteTests` is through
/// `NOVELREADER_LIVE`, and skipped without it: `make test` must not start writing
/// outside the simulator's own container, and a green suite must not depend on a
/// tool nobody has installed.
///
///     TEST_RUNNER_NOVELREADER_EPUBCHECK=1 xcodebuild test \
///       -project NovelReader.xcodeproj -scheme NovelReader \
///       -configuration Debug -derivedDataPath build \
///       -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
///       -only-testing:NovelReaderTests/EpubValidationTests
///     java -jar epubcheck.jar build/epubcheck/山月記.epub
///
/// The export it writes is a complete one — cover, title page, stylesheet, several
/// chapters, punctuation that has to be escaped — because a validator only sees
/// what is in the file it is given.
@MainActor
final class EpubValidationTests: XCTestCase {
    private var tempRoot: URL!
    private var repo: LibraryRepo!
    private var downloads: DownloadStore!

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NovelReaderTests-\(UUID().uuidString)")
        let database = try AppDatabase.makeInMemory()
        repo = LibraryRepo(database: database)
        downloads = DownloadStore(database: database, files: ChapterFileStore(root: tempRoot))
        URLCache.shared.removeAllCachedResponses()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        try? FileManager.default.removeItem(at: BookExporter.directory)
        URLCache.shared.removeAllCachedResponses()
    }

    func testWritesAnEpubForEpubcheck() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["NOVELREADER_EPUBCHECK"] == "1",
            "Writing an EPUB out for epubcheck is opt-in: set NOVELREADER_EPUBCHECK=1."
        )

        let cover = try XCTUnwrap(Data(base64Encoded: Self.pngBase64))
        cacheCover(cover)
        let (book, catalog) = try makeBook()
        let export = try await BookExporter(downloads: downloads)
            .export(book: book, chapters: catalog, format: .epub) { _ in }

        // Not left in the simulator's container: that path carries two generated
        // UUIDs, so it could not be written down here or in a Makefile. The repo's
        // own build directory is where every other artefact of a verification run
        // already goes, and it is git-ignored.
        let destination = Self.outputDirectory.appendingPathComponent("\(export.filename).epub")
        try FileManager.default.createDirectory(
            at: Self.outputDirectory, withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: export.url, to: destination)

        let size = try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int
        print("""

        === epub written for external validation ===
          \(destination.path)
          \(size ?? 0) bytes, \(export.chapterCount) chapters
          java -jar epubcheck.jar "\(destination.path)"

        """)
        XCTAssertGreaterThan(size ?? 0, 0, "an empty file is nothing to validate")
    }

    // MARK: - Fixtures

    /// `#filePath` rather than a bundle path: the point of this test is to leave a
    /// file where a shell in the checkout can reach it, and the source file is the
    /// only thing that knows where the checkout is.
    private static var outputDirectory: URL {
        URL(fileURLWithPath: #filePath)          // …/NovelReaderTests/EpubValidationTests.swift
            .deletingLastPathComponent()         // …/NovelReaderTests
            .deletingLastPathComponent()         // the checkout
            .appendingPathComponent("build/epubcheck", isDirectory: true)
    }

    /// A 1×1 PNG, so the cover in the file is a real image a validator can decode.
    private static let pngBase64 = """
    iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC
    """

    private static let coverURL = "https://example.com/covers/山月記.png"

    private static let chapters = [
        ImportedChapter(
            title: "第一章 下山",
            paragraphs: ["雪停了。", "風也停了。", "他說：「a < b & c > d」，這句話沒人聽懂。"]
        ),
        ImportedChapter(title: "第二章 入城", paragraphs: ["城門在傍晚關上。"]),
        ImportedChapter(title: "第三章 虎嘯", paragraphs: ["月光落在草上。", "草上有影。"]),
    ]

    private func cacheCover(_ data: Data) {
        let url = URL(string: Self.coverURL)!
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/png", "Content-Length": "\(data.count)"]
        )!
        URLCache.shared.storeCachedResponse(
            CachedURLResponse(response: response, data: data), for: URLRequest(url: url)
        )
    }

    private func makeBook() throws -> (book: Book, catalog: [Chapter]) {
        let book = try repo.bookmark(
            siteId: "alpha", siteBookId: "1", title: "山月記", author: "中島敦",
            coverURL: Self.coverURL
        )
        try repo.replaceCatalog(
            bookId: book.id,
            entries: Self.chapters.enumerated().map { offset, chapter in
                (
                    siteChapterId: String(format: "%05d", offset),
                    title: chapter.title,
                    url: "https://example.com/c/\(offset)"
                )
            }
        )
        for (offset, chapter) in Self.chapters.enumerated() {
            try downloads.save(
                paragraphs: chapter.paragraphs, book: book,
                siteChapterId: String(format: "%05d", offset)
            )
        }
        return (book, try repo.chapters(bookId: book.id))
    }
}
