import XCTest
@testable import NovelReader

/// Two chapters whose paragraphs are distinct from their titles, so a round trip
/// that dropped or duplicated a line shows up.
///
/// At file scope rather than as a static member of the test case because it is a
/// default argument below, and a default argument is evaluated outside any actor —
/// which a `@MainActor` type's own static property cannot be read from.
private let sampleChapters = [
    ImportedChapter(title: "第一章 下山", paragraphs: ["雪停了。", "風也停了。"]),
    ImportedChapter(title: "第二章 入城", paragraphs: ["城門在傍晚關上。"]),
]

/// Export is only worth anything if something can read the result back, so these
/// tests are round trips through the app's own readers rather than assertions
/// about the bytes: an EPUB goes back through `EpubDocument` and the importer, and
/// a text file goes back through `TextBookParser`. A structural assertion is kept
/// for the one thing a round trip cannot see — that `mimetype` is the first entry
/// and uncompressed, which is what every *other* reader relies on.
@MainActor
final class BookExportTests: XCTestCase {
    private var tempRoot: URL!
    private var repo: LibraryRepo!
    private var downloads: DownloadStore!
    private var exporter: BookExporter!

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NovelReaderTests-\(UUID().uuidString)")
        let database = try AppDatabase.makeInMemory()
        repo = LibraryRepo(database: database)
        downloads = DownloadStore(database: database, files: ChapterFileStore(root: tempRoot))
        exporter = BookExporter(downloads: downloads)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - EPUB

    /// The whole point of the EPUB writer: what it produces has to come back out
    /// of the app's own reader with the same chapters, in the same order, under
    /// the same names.
    func testExportedEpubIsReadBackByOurOwnReader() async throws {
        let (book, catalog) = try makeBook()

        let export = try await exporter.export(book: book, chapters: catalog, format: .epub)

        XCTAssertFalse(export.isPartial)
        let document = try EpubDocument.parse(export.data)
        XCTAssertEqual(document.title, "山月記")
        XCTAssertEqual(document.author, "中島敦")
        // Spine order, and titles from the nav document rather than from the
        // filenames — the two things an EPUB can silently get wrong.
        XCTAssertEqual(document.items.map(\.tocTitle), ["第一章 下山", "第二章 入城"])
        XCTAssertEqual(
            document.items.map(\.path),
            ["OEBPS/text/chapter-00001.xhtml", "OEBPS/text/chapter-00002.xhtml"]
        )
    }

    /// One step further than reading the structure: the file goes back in through
    /// the importer, which is how a user would actually return it to the app. That
    /// covers the chapter text as well, because the text only exists once the
    /// extractor has been over the XHTML.
    func testExportedEpubCanBeImportedAgain() async throws {
        let (book, catalog) = try makeBook()
        let export = try await exporter.export(book: book, chapters: catalog, format: .epub)
        let file = try write("export.epub", data: export.data)

        let reimported = try await LocalBookImporter(
            repo: repo, downloads: downloads, fetcher: WebFetcher()
        ).importBook(from: file) { _ in }

        XCTAssertEqual(reimported.title, "山月記")
        XCTAssertEqual(reimported.author, "中島敦")
        let chapters = try repo.chapters(bookId: reimported.id)
        XCTAssertEqual(chapters.map(\.title), ["第一章 下山", "第二章 入城"])
        // The heading written into each document is not read back as a paragraph:
        // the extractor recognises it as the title it already has.
        XCTAssertEqual(
            try downloads.readParagraphs(book: reimported, siteChapterId: chapters[0].siteChapterId),
            ["雪停了。", "風也停了。"]
        )
        XCTAssertEqual(
            try downloads.readParagraphs(book: reimported, siteChapterId: chapters[1].siteChapterId),
            ["城門在傍晚關上。"]
        )
    }

    /// OCF requires `mimetype` to be the first entry in the file and stored, so a
    /// reader can identify an EPUB from a fixed offset without parsing anything.
    /// Nothing in our own round trip depends on it, which is exactly why it needs
    /// its own test.
    func testMimetypeIsTheFirstEntryAndIsNotCompressed() async throws {
        let (book, catalog) = try makeBook()

        let export = try await exporter.export(book: book, chapters: catalog, format: .epub)

        let bytes = [UInt8](export.data)
        XCTAssertEqual(Array(bytes[0 ..< 4]), [0x50, 0x4b, 0x03, 0x04], "a local header must open the file")
        XCTAssertEqual(bytes[8], 0, "compression method must be stored")
        XCTAssertEqual(bytes[9], 0)
        let nameLength = Int(bytes[26]) | Int(bytes[27]) << 8
        XCTAssertEqual(
            String(bytes: bytes[30 ..< 30 + nameLength], encoding: .utf8), "mimetype"
        )
        let payload = 30 + nameLength
        XCTAssertEqual(
            String(bytes: bytes[payload ..< payload + 20], encoding: .utf8), "application/epub+zip"
        )
    }

    /// Text that XML cannot carry verbatim has to survive as text rather than
    /// breaking the document. An unescaped `&` here would make the file
    /// unopenable, which is the failure mode this whole path exists to avoid.
    func testMarkupCharactersInTheTextSurvive() async throws {
        let (book, catalog) = try makeBook([
            ImportedChapter(title: "第一章 <序> & 破題", paragraphs: ["他說：「a < b & c > d」。"])
        ])

        let export = try await exporter.export(book: book, chapters: catalog, format: .epub)

        let document = try EpubDocument.parse(export.data)
        XCTAssertEqual(document.items.map(\.tocTitle), ["第一章 <序> & 破題"])
        let xhtml = try XCTUnwrap(XMLTree.parse(try XCTUnwrap(document.items.first?.xhtml)))
        XCTAssertEqual(xhtml.first("p")?.text, "他說：「a < b & c > d」。")
    }

    // MARK: - Plain text

    func testExportedTextFileIsReadBackByTheTextParser() async throws {
        let (book, catalog) = try makeBook()

        let export = try await exporter.export(book: book, chapters: catalog, format: .text)

        let text = try XCTUnwrap(TextBookParser.decode(export.data), "must decode as UTF-8")
        let parsed = TextBookParser.chapters(from: text)
        XCTAssertEqual(parsed.map(\.title), ["第一章 下山", "第二章 入城"])
        XCTAssertEqual(parsed.map(\.paragraphs), [["雪停了。", "風也停了。"], ["城門在傍晚關上。"]])
    }

    // MARK: - Partial books

    /// A book that is only half downloaded exports as half a book, and says so.
    /// Handing over part of a novel as though it were the whole thing is the one
    /// way this feature can mislead someone, and the flag is what the screen uses
    /// to ask before writing anything.
    func testExportOfAPartlyDownloadedBookHoldsOnlyWhatIsOnDisk() async throws {
        let (book, catalog) = try makeBook(sampleChapters, downloading: 1)

        let export = try await exporter.export(book: book, chapters: catalog, format: .epub)

        XCTAssertTrue(export.isPartial)
        XCTAssertEqual(export.chapterCount, 1)
        XCTAssertEqual(export.catalogCount, 2)
        XCTAssertEqual(try EpubDocument.parse(export.data).items.map(\.tocTitle), ["第一章 下山"])
    }

    /// A chapter flagged as downloaded whose file has gone missing counts as
    /// absent, not as an empty chapter: the flag can outlive the file, and a
    /// heading with nothing under it would be a lie in the file.
    func testAFlaggedChapterWithNoFileIsLeftOut() async throws {
        let (book, catalog) = try makeBook()
        try FileManager.default.removeItem(
            at: ChapterFileStore(root: tempRoot).fileURL(
                siteId: book.siteId, siteBookId: book.siteBookId,
                siteChapterId: catalog[0].siteChapterId
            )
        )

        let export = try await exporter.export(book: book, chapters: catalog, format: .text)

        XCTAssertTrue(export.isPartial)
        XCTAssertEqual(export.chapterCount, 1)
    }

    func testExportingABookWithNothingOnDiskFails() async throws {
        let (book, catalog) = try makeBook(sampleChapters, downloading: 0)
        do {
            _ = try await exporter.export(book: book, chapters: catalog, format: .epub)
            XCTFail("a book with no text on the device has nothing to export")
        } catch {
            XCTAssertNotNil(error.localizedDescription)
        }
    }

    // MARK: - Naming

    /// The name goes into a save sheet, so a Chinese title has to come out intact —
    /// only the characters a filesystem or a share sheet cannot carry are replaced.
    func testFilenameKeepsTheTitleAndDropsWhatAFilesystemCannotTake() {
        XCTAssertEqual(BookExporter.filename(from: "山月記"), "山月記")
        XCTAssertEqual(BookExporter.filename(from: "夜/雨:寄?北"), "夜 雨 寄 北")
        XCTAssertEqual(BookExporter.filename(from: "  ..hidden  "), "hidden")
        XCTAssertEqual(BookExporter.filename(from: "///"), "book", "a name is still needed")
    }

    // MARK: - Helpers

    /// A bookmarked book with a catalog, and its text written through
    /// `DownloadStore` exactly as a finished download would leave it. The stored
    /// catalog comes back with it, because that is what the exporter is handed.
    ///
    /// - Parameter downloading: how many of the chapters get their text on disk.
    ///   Defaults to all of them.
    private func makeBook(
        _ chapters: [ImportedChapter] = sampleChapters, downloading: Int? = nil
    ) throws -> (book: Book, catalog: [Chapter]) {
        let book = try repo.bookmark(
            siteId: "alpha", siteBookId: "1", title: "山月記", author: "中島敦"
        )
        try repo.replaceCatalog(
            bookId: book.id,
            entries: chapters.enumerated().map { offset, chapter in
                (
                    siteChapterId: String(format: "%05d", offset),
                    title: chapter.title,
                    url: "https://example.com/c/\(offset)"
                )
            }
        )
        let stored = downloading ?? chapters.count
        for (offset, chapter) in chapters.enumerated() where offset < stored {
            try downloads.save(
                paragraphs: chapter.paragraphs, book: book,
                siteChapterId: String(format: "%05d", offset)
            )
        }
        return (book, try repo.chapters(bookId: book.id))
    }

    private func write(_ name: String, data: Data) throws -> URL {
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let url = tempRoot.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}
