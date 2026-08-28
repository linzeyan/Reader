import XCTest
@testable import NovelReader

/// Writes every shape the EPUB exporter can produce to fixed paths on the
/// developer's machine so they can be handed to epubcheck.
///
/// The app's own reader is the only thing that has ever read what the exporter
/// writes, and two halves of one codebase agreeing proves less than it looks like:
/// a mistake made in both directions stays invisible. epubcheck is the outside
/// opinion, and it cannot be run from in here — it is a Java jar this repo does not
/// and should not carry. So the test's job is to produce the files and say where
/// they are; validating them is a shell command.
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
///     for f in build/epubcheck/*.epub; do java -jar epubcheck.jar "$f"; done
///
/// One file is not enough, because a validator only sees what is in the file it is
/// handed and the package document has branches. The cover and the author are each
/// optional, and each one conditionally writes metadata, a manifest item and part
/// of the title page, so all three combinations are written out:
///
/// - both present, every chapter on the device — the whole shape;
/// - both absent — and exported partial, see below;
/// - an author that is present and *empty*.
///
/// The last one was written to ask a question, and it got an answer: epubcheck
/// rejected the `<dc:creator></dc:creator>` it used to produce (RSC-005 — the
/// element must hold at least one character). `BookExporter.author(of:)` is the
/// fix, `BookExportTests.testABlankAuthorIsWrittenAsNoAuthor` is the pin, and this
/// file stays in the set because it is the shape that found it.
///
/// A partial export needs no file of its own — chapter documents are numbered by
/// how many have been *written*, so a book with gaps produces the same structure as
/// a shorter whole one. The both-absent shape is exported partial anyway and
/// asserts that it was, so the path is walked rather than only argued about.
@MainActor
final class EpubValidationTests: XCTestCase {
    private var tempRoot: URL!
    private var repo: LibraryRepo!
    private var downloads: DownloadStore!
    private var coverStore: CoverStore!

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NovelReaderTests-\(UUID().uuidString)")
        let database = try AppDatabase.makeInMemory()
        repo = LibraryRepo(database: database)
        downloads = DownloadStore(database: database, files: ChapterFileStore(root: tempRoot))
        coverStore = CoverStore(root: tempRoot.appendingPathComponent("Covers"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        try? FileManager.default.removeItem(at: BookExporter.directory)
    }

    func testWritesEveryEpubShapeForEpubcheck() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["NOVELREADER_EPUBCHECK"] == "1",
            "Writing EPUBs out for epubcheck is opt-in: set NOVELREADER_EPUBCHECK=1."
        )

        try FileManager.default.createDirectory(
            at: Self.outputDirectory, withIntermediateDirectories: true
        )
        var written: [String] = []
        // A book the user has looked at on the shelf and downloaded in full.
        let full = try makeBook(siteBookId: "1", author: "中島敦", cover: Self.coverURL)
        try storeCover(for: full.book)
        written.append(try await write(full, named: "山月記-full"))
        // One bookmarked, half downloaded, whose cover never arrived.
        written.append(try await write(
            makeBook(siteBookId: "2", author: nil, cover: nil, downloaded: 2),
            named: "山月記-plain", expectingPartial: true
        ))
        // One from a site whose author element is there and says nothing.
        let blankAuthor = try makeBook(siteBookId: "3", author: "", cover: Self.coverURL)
        try storeCover(for: blankAuthor.book)
        written.append(try await write(blankAuthor, named: "山月記-blank-author"))

        print("""

        === epubs written for external validation ===
        \(written.joined(separator: "\n"))

          for f in build/epubcheck/*.epub; do java -jar epubcheck.jar "$f"; done

        """)
    }

    // MARK: - Writing

    /// Exports one book, copies the file where a shell in the checkout can reach it,
    /// and returns the line to print about it.
    ///
    /// Copied out at once rather than at the end: `BookExporter` empties its own
    /// directory at the start of every export, so the previous file is gone the
    /// moment the next one begins.
    ///
    /// Named by the shape it carries rather than by `export.filename`, which is the
    /// book's title and identical for all three.
    private func write(
        _ made: (book: Book, catalog: [Chapter]),
        named name: String,
        expectingPartial: Bool = false
    ) async throws -> String {
        let export = try await BookExporter(downloads: downloads, covers: coverStore)
            .export(book: made.book, chapters: made.catalog, format: .epub) { _ in }
        XCTAssertEqual(
            export.isPartial, expectingPartial,
            "\(name) is meant to come out of the \(expectingPartial ? "partial" : "whole-book") path"
        )

        let destination = Self.outputDirectory.appendingPathComponent("\(name).epub")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: export.url, to: destination)

        let size = try FileManager.default
            .attributesOfItem(atPath: destination.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 0, "an empty file is nothing to validate")
        return """
          \(destination.path)
            \(size) bytes, \(export.chapterCount) of \(export.catalogCount) chapters
        """
    }

    // MARK: - Fixtures

    /// `#filePath` rather than a bundle path: the point of this test is to leave
    /// files where a shell in the checkout can reach them, and the source file is the
    /// only thing that knows where the checkout is.
    ///
    /// Not the simulator's container, which carries two generated UUIDs and so could
    /// not be written down here or in a Makefile. The repo's own build directory is
    /// where every other artefact of a verification run already goes, and it is
    /// git-ignored.
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

    /// Puts a cover on the device, where the shelf keeps the ones it has drawn.
    private func storeCover(for book: Book) throws {
        try coverStore.save(try XCTUnwrap(Data(base64Encoded: Self.pngBase64)), for: book)
    }

    /// - Parameter downloaded: how many of the fixture's chapters have text on this
    ///   device. Fewer than all of them is what makes an export partial. Nil means
    ///   all of them.
    private func makeBook(
        siteBookId: String, author: String?, cover: String?, downloaded: Int? = nil
    ) throws -> (book: Book, catalog: [Chapter]) {
        let book = try repo.bookmark(
            siteId: "alpha", siteBookId: siteBookId, title: "山月記", author: author,
            coverURL: cover
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
        for (offset, chapter) in Self.chapters.prefix(downloaded ?? Self.chapters.count).enumerated() {
            try downloads.save(
                paragraphs: chapter.paragraphs, book: book,
                siteChapterId: String(format: "%05d", offset)
            )
        }
        return (book, try repo.chapters(bookId: book.id))
    }
}
