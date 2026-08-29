import XCTest
@testable import NovelReader

/// Comics leaving the device and coming back.
///
/// The promise being pinned is that the archive is an ordinary folder of pictures —
/// a shape someone can build by hand, or unzip and look at — and that a comic which
/// goes out and comes back is the same comic. Everything below is a round trip or a
/// hand-built archive, because those are the two ways this feature is used.
final class ComicArchiveTests: XCTestCase {
    private var tempRoot: URL!
    private var repo: LibraryRepo!
    private var files: ChapterFileStore!
    private var covers: CoverStore!
    private var downloads: DownloadStore!

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ComicArchiveTests-\(UUID().uuidString)")
        let database = try AppDatabase.makeInMemory()
        repo = LibraryRepo(database: database)
        files = ChapterFileStore(root: tempRoot.appendingPathComponent("Chapters"))
        covers = CoverStore(root: tempRoot.appendingPathComponent("Covers"))
        downloads = DownloadStore(database: database, files: files)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        try? FileManager.default.removeItem(at: BookExporter.directory)
    }

    // MARK: - Round trip

    func testAnExportedComicComesBackWithEveryPageByteForByte() async throws {
        let original = [
            (title: "第1話 出發", pages: [page(1), page(2), page(3)]),
            (title: "第2話 夜車", pages: [page(4), page(5)]),
        ]
        let book = try makeComic(title: "白鳥列車", chapters: original)
        let export = try await exporter().export(book: book, chapters: chapters(of: book)) { _ in }
        XCTAssertEqual(export.urls.count, 1)
        XCTAssertFalse(export.isPartial)

        let imported = try await importer().importComic(from: export.urls[0]) { _ in }

        XCTAssertEqual(imported.kind, .comic)
        XCTAssertEqual(imported.title, "白鳥列車")
        XCTAssertEqual(imported.siteId, Book.localSiteId)
        let landed = try chapters(of: imported)
        XCTAssertEqual(landed.map(\.title), original.map(\.title), "numbering is not a title")
        XCTAssertTrue(landed.allSatisfy(\.isDownloaded))
        for (chapter, source) in zip(landed, original) {
            XCTAssertEqual(try pages(of: chapter, in: imported), source.pages)
        }
    }

    /// The shape is the product, so it is pinned rather than left to the round trip:
    /// a folder for the comic, a folder per chapter, one file per page.
    func testTheArchiveIsAFolderPerChapterAndAFilePerPage() async throws {
        let book = try makeComic(
            title: "木盒與海",
            chapters: [(title: "第1話", pages: [page(1), page(2)]), (title: "第2話", pages: [page(3)])]
        )
        try covers.save(page(9), for: book)

        let export = try await exporter().export(book: book, chapters: chapters(of: book)) { _ in }

        XCTAssertEqual(
            try names(in: export.urls[0]),
            [
                "木盒與海/cover.png",
                "木盒與海/001 第1話/000.png",
                "木盒與海/001 第1話/001.png",
                "木盒與海/002 第2話/000.png",
            ]
        )
    }

    /// Only what is on the device. A chapter the reader never downloaded has no
    /// pages to write, and an archive with an empty folder in it would claim
    /// otherwise.
    func testChaptersThatAreNotOnTheDeviceAreLeftOutAndSaidSo() async throws {
        let book = try makeComic(
            title: "霜降之城",
            chapters: [(title: "第1話", pages: [page(1)])],
            catalogAlso: ["第2話", "第3話"]
        )

        let export = try await exporter().export(book: book, chapters: chapters(of: book)) { _ in }

        XCTAssertEqual(export.chapterCount, 1)
        XCTAssertEqual(export.catalogCount, 3)
        XCTAssertTrue(export.isPartial)
        XCTAssertEqual(try names(in: export.urls[0]), ["霜降之城/001 第1話/000.png"])
    }

    func testAComicWithNothingOnTheDeviceRefusesToExport() async throws {
        let book = try makeComic(title: "空", chapters: [], catalogAlso: ["第1話"])
        do {
            _ = try await exporter().export(book: book, chapters: chapters(of: book)) { _ in }
            XCTFail("a comic with no pages on the device has nothing to write")
        } catch is BookExportError {
            // The message names the situation; the type is what this pins.
        }
    }

    // MARK: - Splitting

    func testAComicTooBigForOneArchiveSplitsAtChapterBoundaries() async throws {
        let book = try makeComic(
            title: "長篇",
            chapters: (1 ... 4).map { (title: "第\($0)話", pages: [page($0, size: 900)]) }
        )
        // Two chapters to a part: each page is 900 bytes and every chapter has one.
        var exporter = self.exporter()
        exporter.partLimit = 2000

        let export = try await exporter.export(book: book, chapters: chapters(of: book)) { _ in }

        XCTAssertEqual(export.urls.count, 2)
        XCTAssertEqual(export.chapterCount, 4)
        // The suffix itself is localised, so what is pinned is that the parts are
        // named after the comic and are told apart from one another.
        let partNames = export.urls.map { $0.deletingPathExtension().lastPathComponent }
        XCTAssertTrue(partNames.allSatisfy { $0.hasPrefix("長篇 (") })
        XCTAssertEqual(Set(partNames).count, 2)
        XCTAssertEqual(
            try names(in: export.urls[0]),
            ["長篇/001 第1話/000.png", "長篇/002 第2話/000.png"]
        )
        XCTAssertEqual(
            try names(in: export.urls[1]),
            ["長篇/003 第3話/000.png", "長篇/004 第4話/000.png"]
        )
    }

    /// The point of splitting at all: the parts go back together. Imported in the
    /// wrong order, because that is the one a person will do by accident, and the
    /// order of the chapters is not allowed to depend on it.
    func testThePartsGoBackTogetherWhicheverOrderTheyAreImportedIn() async throws {
        let book = try makeComic(
            title: "長篇",
            chapters: (1 ... 4).map { (title: "第\($0)話", pages: [page($0, size: 900)]) }
        )
        var exporter = self.exporter()
        exporter.partLimit = 2000
        let export = try await exporter.export(book: book, chapters: chapters(of: book)) { _ in }

        _ = try await importer().importComic(from: export.urls[1]) { _ in }
        let imported = try await importer().importComic(from: export.urls[0]) { _ in }

        let landed = try chapters(of: imported)
        XCTAssertEqual(landed.map(\.title), ["第1話", "第2話", "第3話", "第4話"])
        XCTAssertTrue(landed.allSatisfy(\.isDownloaded), "part two must survive part one arriving")
        XCTAssertEqual(try repo.books(siteId: Book.localSiteId).count, 1, "one comic, not two")
    }

    /// A chapter added to the middle of a comic renumbers every folder after it. If
    /// the number were part of a chapter's identity, re-importing would land a second
    /// copy of the whole comic beside the first.
    func testReImportingAComicThatGainedAChapterUpdatesItInPlace() async throws {
        let first = try makeComic(
            title: "連載",
            chapters: [(title: "第1話", pages: [page(1)]), (title: "第2話", pages: [page(2)])]
        )
        let one = try await exporter().export(book: first, chapters: chapters(of: first)) { _ in }
        _ = try await importer().importComic(from: one.urls[0]) { _ in }

        // The same comic, with a prologue in front — so `第1話` is now folder 002.
        let second = try makeComic(
            title: "連載",
            chapters: [
                (title: "序章", pages: [page(9)]),
                (title: "第1話", pages: [page(1)]),
                (title: "第2話", pages: [page(2)]),
            ],
            siteBookId: "2"
        )
        let two = try await exporter().export(book: second, chapters: chapters(of: second)) { _ in }
        let imported = try await importer().importComic(from: two.urls[0]) { _ in }

        XCTAssertEqual(try chapters(of: imported).map(\.title), ["序章", "第1話", "第2話"])
        XCTAssertEqual(try repo.books(siteId: Book.localSiteId).count, 1)
    }

    // MARK: - Archives someone made by hand

    func testAnArchiveWithoutTheOuterFolderIsNamedAfterTheFile() async throws {
        let url = try build(
            "夜行紀錄.zip",
            [
                "第10話/1.png": page(10),
                "第2話/1.png": page(2),
                "第2話/2.png": page(3),
            ]
        )

        let imported = try await importer().importComic(from: url) { _ in }

        XCTAssertEqual(imported.title, "夜行紀錄")
        XCTAssertEqual(
            try chapters(of: imported).map(\.title), ["第2話", "第10話"],
            "chapter 2 comes before chapter 10, which is not what text order says"
        )
    }

    func testPagesAreOrderedByTheirNumbersRatherThanTheirNames() async throws {
        let url = try build(
            "測試.zip",
            ["名/第1話/2.png": page(2), "名/第1話/10.png": page(10), "名/第1話/1.png": page(1)]
        )

        let imported = try await importer().importComic(from: url) { _ in }

        let chapter = try XCTUnwrap(try chapters(of: imported).first)
        XCTAssertEqual(try pages(of: chapter, in: imported), [page(1), page(2), page(10)])
    }

    func testAFolderOfLooseImagesIsOneChapter() async throws {
        let url = try build("單話.zip", ["001.png": page(1), "002.png": page(2)])

        let imported = try await importer().importComic(from: url) { _ in }

        XCTAssertEqual(try chapters(of: imported).map(\.title), ["單話"])
        XCTAssertEqual(imported.kind, .comic)
    }

    /// Everything a real archive carries besides the comic: the Mac's resource
    /// forks, a hidden index file, a readme, and a page that is not an image at all.
    func testTheArchivesOwnRubbishIsIgnored() async throws {
        let url = try build(
            "名.zip",
            [
                "名/第1話/001.png": page(1),
                "名/第1話/.DS_Store": Data("junk".utf8),
                "名/__MACOSX/第1話/._001.png": Data("fork".utf8),
                "名/readme.txt": Data("hello".utf8),
                "名/第2話/001.jpg": Data("<!DOCTYPE html><html>403".utf8),
            ]
        )

        let imported = try await importer().importComic(from: url) { _ in }

        XCTAssertEqual(
            try chapters(of: imported).map(\.title), ["第1話"],
            "a folder whose only page is an error page is not a chapter"
        )
        let chapter = try XCTUnwrap(try chapters(of: imported).first)
        XCTAssertEqual(try pages(of: chapter, in: imported), [page(1)])
    }

    func testAnArchiveWithNoImagesInItIsNotAComic() async throws {
        let url = try build("名.zip", ["名/notes/readme.txt": Data("hello".utf8)])
        do {
            _ = try await importer().importComic(from: url) { _ in }
            XCTFail("nothing readable is not an import")
        } catch LocalBookError.empty {
            // Right failure.
        }
    }

    func testSomethingThatIsNotAZipSaysSoRatherThanCrashing() async throws {
        let url = tempRoot.appendingPathComponent("nonsense.zip")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try Data("this is not an archive".utf8).write(to: url)
        do {
            _ = try await importer().importComic(from: url) { _ in }
            XCTFail("a text file is not an archive")
        } catch LocalBookError.badArchive(_) {
            // Right failure, and it carries the technical detail on a second line.
        }
    }

    // MARK: - Failure

    /// An import that fails part-way gives back exactly what it took, and nothing
    /// that was already on the shelf.
    ///
    /// The cover write is what fails here only because it is the last thing that
    /// can: the store it writes to cannot be created. What is being pinned is the
    /// rollback — the chapters this import wrote go away, and the ones the previous
    /// import left stay.
    func testAFailedImportLeavesThePreviousPartsAlone() async throws {
        let book = try makeComic(
            title: "長篇",
            chapters: (1 ... 4).map { (title: "第\($0)話", pages: [page($0, size: 900)]) }
        )
        var exporter = self.exporter()
        exporter.partLimit = 2000
        let export = try await exporter.export(book: book, chapters: chapters(of: book)) { _ in }
        let imported = try await importer().importComic(from: export.urls[0]) { _ in }

        let broken = ComicArchiveImporter(
            repo: repo,
            downloads: downloads,
            covers: CoverStore(root: URL(fileURLWithPath: "/dev/null/Covers"))
        )
        do {
            _ = try await broken.importComic(from: export.urls[1]) { _ in }
            XCTFail("the cover store cannot be written to")
        } catch {
            // Any failure will do; what matters is what it left behind.
        }

        let landed = try chapters(of: imported)
        XCTAssertEqual(landed.map(\.title), ["第1話", "第2話"], "the failed part is not in the catalog")
        XCTAssertTrue(landed.allSatisfy(\.isDownloaded), "the first part keeps its pages")
        XCTAssertEqual(try pages(of: landed[0], in: imported), [page(1, size: 900)])
    }

    /// Main-actor bound on purpose: the task below inherits that isolation, so it
    /// cannot start before this test suspends, which is what makes "cancel, then
    /// await" deterministic rather than a race with a very short import.
    @MainActor
    func testACancelledImportLeavesNothingBehind() async throws {
        let book = try makeComic(title: "白鳥列車", chapters: [(title: "第1話", pages: [page(1)])])
        let export = try await exporter().export(book: book, chapters: chapters(of: book)) { _ in }

        let task = Task { try await importer().importComic(from: export.urls[0]) { _ in } }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled import must not return a book")
        } catch is CancellationError {
            // The checkpoint before any work is the one that fires here.
        }

        XCTAssertTrue(try repo.books(siteId: Book.localSiteId).isEmpty)
    }

    // MARK: - Fixtures

    private func exporter() -> ComicExporter { ComicExporter(files: files, covers: covers) }

    private func importer() -> ComicArchiveImporter {
        ComicArchiveImporter(repo: repo, downloads: downloads, covers: covers)
    }

    /// A page: real image bytes, and a different picture for every number.
    private func page(_ seed: Int, size: Int = 32) -> Data {
        Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            + Data(repeating: UInt8(seed % 251), count: size)
    }

    private func makeComic(
        title: String,
        chapters: [(title: String, pages: [Data])],
        catalogAlso undownloaded: [String] = [],
        siteBookId: String = "1"
    ) throws -> Book {
        let book = try repo.bookmark(
            siteId: "comics.example", siteBookId: siteBookId, kind: .comic, title: title
        )
        let entries = (chapters.map(\.title) + undownloaded).enumerated().map { index, name in
            (siteChapterId: "c\(index)", title: name, url: "https://comics.example/\(index)")
        }
        try repo.replaceCatalog(bookId: book.id, entries: entries)
        for (index, chapter) in chapters.enumerated() {
            try downloads.save(pages: chapter.pages, book: book, siteChapterId: "c\(index)")
        }
        return book
    }

    private func chapters(of book: Book) throws -> [Chapter] {
        try repo.chapters(bookId: book.id)
    }

    private func pages(of chapter: Chapter, in book: Book) throws -> [Data] {
        try files.pageURLs(
            siteId: book.siteId, siteBookId: book.siteBookId, siteChapterId: chapter.siteChapterId
        ).map { try Data(contentsOf: $0) }
    }

    private func names(in url: URL) throws -> [String] {
        try ZipFileReader(reading: url).entries.map(\.name)
    }

    /// An archive built the way a person's zip tool builds one — arbitrary order,
    /// no directory records — so the importer is tested on what it will actually be
    /// given rather than on what this app writes.
    private func build(_ name: String, _ contents: [String: Data]) throws -> URL {
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let url = tempRoot.appendingPathComponent(name)
        let builder = try ZipBuilder(creating: url)
        for (path, data) in contents.sorted(by: { $0.key < $1.key }) {
            try builder.append(ZipBuilder.Entry(name: path, data: data, compressed: true))
        }
        try builder.finish()
        return url
    }
}
