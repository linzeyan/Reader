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
        // Cleared at the *start*: the cover tests seed this cache, it is shared by
        // the whole process, and a leftover response would decide whether a later
        // test's export carries a cover.
        URLCache.shared.removeAllCachedResponses()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        try? FileManager.default.removeItem(at: BookExporter.directory)
        URLCache.shared.removeAllCachedResponses()
    }

    // MARK: - EPUB

    /// The whole point of the EPUB writer: what it produces has to come back out
    /// of the app's own reader with the same chapters, in the same order, under
    /// the same names.
    func testExportedEpubIsReadBackByOurOwnReader() async throws {
        let (book, catalog) = try makeBook()

        let export = try await exporter.export(
            book: book, chapters: catalog, format: .epub
        ) { _ in }

        XCTAssertFalse(export.isPartial)
        let document = try EpubDocument.parse(try bytes(of: export))
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
        let export = try await exporter.export(
            book: book, chapters: catalog, format: .epub
        ) { _ in }
        let file = try write("export.epub", data: try bytes(of: export))

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

        let export = try await exporter.export(
            book: book, chapters: catalog, format: .epub
        ) { _ in }

        let bytes = [UInt8](try bytes(of: export))
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

        let export = try await exporter.export(
            book: book, chapters: catalog, format: .epub
        ) { _ in }

        let document = try EpubDocument.parse(try bytes(of: export))
        XCTAssertEqual(document.items.map(\.tocTitle), ["第一章 <序> & 破題"])
        let xhtml = try XCTUnwrap(XMLTree.parse(try XCTUnwrap(document.items.first?.xhtml)))
        XCTAssertEqual(xhtml.first("p")?.text, "他說：「a < b & c > d」。")
    }

    // MARK: - Style and title page

    /// The stylesheet and the title page are in the container, are wired into the
    /// package document, and — the part that matters most — do not turn into a
    /// chapter when the file comes home. The plate carries the book's own name, so
    /// an importer that read it as content would open the novel on a page
    /// repeating its title.
    func testTheEpubCarriesAStylesheetAndATitlePageWithoutGainingAChapter() async throws {
        let (book, catalog) = try makeBook()

        let export = try await exporter.export(
            book: book, chapters: catalog, format: .epub
        ) { _ in }

        let archive = try ZipArchive(data: try bytes(of: export))
        let css = try XCTUnwrap(try archive.data(named: "OEBPS/style.css"))
        XCTAssertFalse(css.isEmpty)
        // No colours anywhere: a reading system's night mode wins by recolouring
        // what the book did not insist on.
        XCTAssertFalse(String(decoding: css, as: UTF8.self).contains("color:"))

        let page = String(decoding: try XCTUnwrap(try archive.data(named: "OEBPS/titlepage.xhtml")), as: UTF8.self)
        XCTAssertTrue(page.contains("<h1>山月記</h1>"), "the title page must name the book")
        XCTAssertTrue(page.contains("中島敦"), "and its author")
        XCTAssertTrue(page.contains("style.css"), "and use the stylesheet")

        let opf = String(decoding: try XCTUnwrap(try archive.data(named: "OEBPS/content.opf")), as: UTF8.self)
        XCTAssertTrue(opf.contains(#"media-type="text/css""#))
        XCTAssertTrue(
            opf.contains(#"<itemref idref="titlepage" linear="no"/>"#),
            "the plate is front matter, not the first chapter"
        )
        // EPUB 3 asks that non-linear content stay reachable, and the toc is where
        // it is reached from. Counted, not merely found: the plate and every
        // chapter get one entry each, and a toc that lists something twice is a
        // reading system showing the same page twice.
        let nav = String(decoding: try XCTUnwrap(try archive.data(named: "OEBPS/nav.xhtml")), as: UTF8.self)
        XCTAssertTrue(nav.contains(#"<a href="titlepage.xhtml">"#))
        XCTAssertEqual(nav.components(separatedBy: "<li>").count - 1, 3, "one entry per document")

        XCTAssertEqual(
            try EpubDocument.parse(try bytes(of: export)).items.count, 2,
            "the title page must not come back as a chapter"
        )
    }

    /// The cover is written only when its bytes are already on the device, because
    /// an export must not make a network request — a file the user is waiting for
    /// cannot be waiting on someone else's server.
    func testTheCoverIsWrittenWhenItsBytesAreAlreadyCached() async throws {
        let cover = try XCTUnwrap(Data(base64Encoded: Self.pngBase64))
        cacheCover(cover, mediaType: "image/png")
        let (book, catalog) = try makeBook(cover: Self.coverURL)

        let export = try await exporter.export(
            book: book, chapters: catalog, format: .epub
        ) { _ in }

        let archive = try ZipArchive(data: try bytes(of: export))
        XCTAssertEqual(try archive.data(named: "OEBPS/cover.png"), cover)
        let opf = String(decoding: try XCTUnwrap(try archive.data(named: "OEBPS/content.opf")), as: UTF8.self)
        XCTAssertTrue(
            opf.contains(#"properties="cover-image""#),
            "an image no reading system knows is the cover is an image nobody sees"
        )
        let page = String(decoding: try XCTUnwrap(try archive.data(named: "OEBPS/titlepage.xhtml")), as: UTF8.self)
        XCTAssertTrue(page.contains(#"src="cover.png""#))
    }

    /// The usual case: the user never looked at this book's cover, so nothing on
    /// the device has it. The title page is still there, in text.
    func testNoCoverIsWrittenWhenNothingIsCached() async throws {
        let (book, catalog) = try makeBook(cover: Self.coverURL)

        let export = try await exporter.export(
            book: book, chapters: catalog, format: .epub
        ) { _ in }

        let archive = try ZipArchive(data: try bytes(of: export))
        XCTAssertNil(try archive.data(named: "OEBPS/cover.png"))
        let opf = String(decoding: try XCTUnwrap(try archive.data(named: "OEBPS/content.opf")), as: UTF8.self)
        XCTAssertFalse(opf.contains("cover-image"))
        let page = String(decoding: try XCTUnwrap(try archive.data(named: "OEBPS/titlepage.xhtml")), as: UTF8.self)
        XCTAssertTrue(page.contains("<h1>山月記</h1>"))
        XCTAssertFalse(page.contains("<img"))
    }

    /// A cover in a format EPUB 3.0 does not list as a core type is left out
    /// rather than declared: an unfallback-able media type makes the whole file
    /// invalid, which is a high price for a picture.
    func testACoverInAnUnsupportedFormatIsLeftOut() async throws {
        cacheCover(Data("RIFF....WEBP".utf8), mediaType: "image/webp")
        let (book, catalog) = try makeBook(cover: Self.coverURL)

        let export = try await exporter.export(
            book: book, chapters: catalog, format: .epub
        ) { _ in }

        let opf = String(
            decoding: try XCTUnwrap(try ZipArchive(data: try bytes(of: export))
                .data(named: "OEBPS/content.opf")),
            as: UTF8.self
        )
        XCTAssertFalse(opf.contains("cover-image"))
    }

    /// An author that is there and blank has to be written as no author at all.
    ///
    /// EPUB 3 requires `dc:creator` to hold at least one character, and epubcheck
    /// rejects an empty one as RSC-005 — a single error that makes the whole file
    /// invalid for a reading system that checks. The shape is reachable: a site
    /// whose author element exists with nothing in it stores `""`, because
    /// `ExtractorScript.readField` cleans the text without folding empty to nil.
    ///
    /// Both halves are asserted. The title page always dropped a blank byline, so
    /// only the package document was wrong, and a fix applied to one of them and
    /// not the other is exactly the state this catches.
    func testABlankAuthorIsWrittenAsNoAuthor() async throws {
        for author in ["", "   "] {
            let (book, catalog) = try makeBook(author: author)

            let export = try await exporter.export(
                book: book, chapters: catalog, format: .epub
            ) { _ in }

            let archive = try ZipArchive(data: try bytes(of: export))
            let opf = String(
                decoding: try XCTUnwrap(try archive.data(named: "OEBPS/content.opf")), as: UTF8.self
            )
            XCTAssertFalse(
                opf.contains("dc:creator"),
                "an empty dc:creator is invalid EPUB, so a blank author gets no element"
            )
            let page = String(
                decoding: try XCTUnwrap(try archive.data(named: "OEBPS/titlepage.xhtml")),
                as: UTF8.self
            )
            XCTAssertFalse(page.contains("class=\"author\""), "and no byline to sit under the title")
        }
    }

    // MARK: - Plain text

    func testExportedTextFileIsReadBackByTheTextParser() async throws {
        let (book, catalog) = try makeBook()

        let export = try await exporter.export(
            book: book, chapters: catalog, format: .text
        ) { _ in }

        let text = try XCTUnwrap(TextBookParser.decode(try bytes(of: export)), "must decode as UTF-8")
        let parsed = TextBookParser.chapters(from: text)
        XCTAssertEqual(parsed.map(\.title), ["第一章 下山", "第二章 入城"])
        XCTAssertEqual(parsed.map(\.paragraphs), [["雪停了。", "風也停了。"], ["城門在傍晚關上。"]])
    }

    /// The exact bytes, because the file is now written a chapter at a time: the
    /// separator has to go before every chapter but the first, and the newline at
    /// the end has to be the only one. A round trip through our own parser cannot
    /// see either seam — it drops blank lines.
    func testTheStreamedTextFileHasNoSeams() async throws {
        let (book, catalog) = try makeBook()

        let export = try await exporter.export(
            book: book, chapters: catalog, format: .text
        ) { _ in }

        XCTAssertEqual(
            String(decoding: try bytes(of: export), as: UTF8.self),
            "第一章 下山\n\n雪停了。\n\n風也停了。\n\n第二章 入城\n\n城門在傍晚關上。\n"
        )
    }

    // MARK: - Streaming, progress, cancellation

    /// Writing the book to a file as it goes must not have changed a byte of it.
    /// An imported book is identified by the digest of its file, so two exports of
    /// the same book that differed would come back as two books.
    func testTwoExportsOfTheSameBookAreByteIdentical() async throws {
        let (book, catalog) = try makeBook()
        for format in [BookExporter.Format.text, .epub] {
            let first = try bytes(of: try await exporter.export(
                book: book, chapters: catalog, format: format
            ) { _ in })
            let second = try bytes(of: try await exporter.export(
                book: book, chapters: catalog, format: format
            ) { _ in })
            XCTAssertEqual(first, second)
        }
    }

    /// Progress has to be able to drive a determinate bar: it may never run
    /// backwards, and it has to arrive at 1. A bar that stops short reads as an
    /// export that hung.
    func testProgressRunsForwardToOne() async throws {
        let (book, catalog) = try makeBook(sampleChapters, downloading: 1)
        let reported = Reported()

        _ = try await exporter.export(book: book, chapters: catalog, format: .epub) {
            reported.values.append($0)
        }

        let values = reported.values
        XCTAssertGreaterThanOrEqual(values.count, catalog.count, "one report per catalog chapter")
        XCTAssertEqual(values, values.sorted(), "a progress bar must never run backwards")
        XCTAssertEqual(try XCTUnwrap(values.last), 1, accuracy: 0.0001)
    }

    /// Cancelling leaves nothing behind. Half an EPUB is not a document, and a
    /// truncated file sitting where the next export looks is worse than no file:
    /// the save sheet would happily hand it to the user as their book.
    func testCancellingAnExportLeavesNoFileBehind() async throws {
        let (book, catalog) = try makeBook()
        let exporter = try XCTUnwrap(self.exporter)
        let canceller = Canceller()

        // Cancelled from the progress callback, so the cancel lands *after* a
        // chapter has really been written rather than racing the whole export.
        canceller.task = Task {
            try await exporter.export(book: book, chapters: catalog, format: .epub) { _ in
                canceller.reports += 1
                canceller.cancel()
            }
        }
        do {
            _ = try await canceller.task?.value
            XCTFail("a cancelled export must not return a file")
        } catch is CancellationError {
            // Expected, and it must be this error rather than a generic failure:
            // the screen tells the two apart, and a cancel is not a problem to
            // report back to the user who asked for it.
        }

        XCTAssertGreaterThan(canceller.reports, 0, "the cancel has to land mid-write to prove anything")
        XCTAssertEqual(try exportedFiles(), [], "a cancelled export may not leave a file")
    }

    // MARK: - Partial books

    /// A book that is only half downloaded exports as half a book, and says so.
    /// Handing over part of a novel as though it were the whole thing is the one
    /// way this feature can mislead someone, and the flag is what the screen uses
    /// to ask before writing anything.
    func testExportOfAPartlyDownloadedBookHoldsOnlyWhatIsOnDisk() async throws {
        let (book, catalog) = try makeBook(sampleChapters, downloading: 1)

        let export = try await exporter.export(
            book: book, chapters: catalog, format: .epub
        ) { _ in }

        XCTAssertTrue(export.isPartial)
        XCTAssertEqual(export.chapterCount, 1)
        XCTAssertEqual(export.catalogCount, 2)
        XCTAssertEqual(
            try EpubDocument.parse(try bytes(of: export)).items.map(\.tocTitle), ["第一章 下山"]
        )
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

        let export = try await exporter.export(
            book: book, chapters: catalog, format: .text
        ) { _ in }

        XCTAssertTrue(export.isPartial)
        XCTAssertEqual(export.chapterCount, 1)
    }

    func testExportingABookWithNothingOnDiskFails() async throws {
        let (book, catalog) = try makeBook(sampleChapters, downloading: 0)
        do {
            _ = try await exporter.export(book: book, chapters: catalog, format: .epub) { _ in }
            XCTFail("a book with no text on the device has nothing to export")
        } catch {
            XCTAssertNotNil(error.localizedDescription)
        }
        XCTAssertEqual(try exportedFiles(), [], "a failed export may not leave a file")
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

    /// A 1×1 PNG. Real bytes with a real media type, because what the exporter
    /// decides about a cover is decided from the cached response's type.
    private static let pngBase64 = """
    iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC
    """

    private static let coverURL = "https://example.com/covers/1.png"

    /// Puts a cover where `AsyncImage` would have left one.
    private func cacheCover(_ data: Data, mediaType: String) {
        let url = URL(string: Self.coverURL)!
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mediaType, "Content-Length": "\(data.count)"]
        )!
        URLCache.shared.storeCachedResponse(
            CachedURLResponse(response: response, data: data), for: URLRequest(url: url)
        )
    }

    /// The export is a file now, so every assertion about its contents reads it.
    private func bytes(of export: BookExporter.Export) throws -> Data {
        try Data(contentsOf: export.url)
    }

    private func exportedFiles() throws -> [String] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: BookExporter.directory.path) else { return [] }
        return try manager.contentsOfDirectory(atPath: BookExporter.directory.path).sorted()
    }

    /// A bookmarked book with a catalog, and its text written through
    /// `DownloadStore` exactly as a finished download would leave it. The stored
    /// catalog comes back with it, because that is what the exporter is handed.
    ///
    /// - Parameter downloading: how many of the chapters get their text on disk.
    ///   Defaults to all of them.
    private func makeBook(
        _ chapters: [ImportedChapter] = sampleChapters,
        downloading: Int? = nil,
        cover: String? = nil,
        author: String? = "中島敦"
    ) throws -> (book: Book, catalog: [Chapter]) {
        let book = try repo.bookmark(
            siteId: "alpha", siteBookId: "1", title: "山月記", author: author, coverURL: cover
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

    /// Collects the progress callbacks, which arrive on the main actor.
    private final class Reported {
        var values: [Double] = []
    }

    /// Holds the export's own task so the progress callback can cancel the very
    /// export that is reporting to it. Without that circle, "cancel after the
    /// first chapter" can only be approximated with a sleep, and a
    /// timing-dependent test of a cancellation path is worse than none.
    @MainActor
    private final class Canceller {
        var task: Task<BookExporter.Export, any Error>?
        /// How many progress callbacks arrived, which is how the test knows the
        /// cancel landed after real work rather than before any.
        var reports = 0

        func cancel() { task?.cancel() }
    }
}
