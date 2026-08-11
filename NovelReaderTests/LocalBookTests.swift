import XCTest
@testable import NovelReader

/// An imported book is deliberately not a new kind of book: it is a bookmark
/// under a reserved source whose chapters are all already "downloaded". These
/// tests hold the two ends of that decision — the plumbing that has to keep
/// working for free, and the one place where a local book must behave
/// differently from every other one.
/// `@MainActor` only because building a `WebFetcher` means building a
/// `WKWebView`. The import itself deliberately runs off the main thread.
@MainActor
final class LocalBookImportTests: XCTestCase {
    private var tempRoot: URL!
    private var repo: LibraryRepo!
    private var downloads: DownloadStore!

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NovelReaderTests-\(UUID().uuidString)")
        let database = try AppDatabase.makeInMemory()
        repo = LibraryRepo(database: database)
        downloads = DownloadStore(database: database, files: ChapterFileStore(root: tempRoot))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    /// Importing a text file has to leave the database in exactly the state a
    /// finished download leaves it in: a catalog whose every row is flagged, and a
    /// text file on disk for each. Everything the product gets "for free" from the
    /// storage screen, the delete scopes and the reader rests on this.
    func testImportedTextFileLooksLikeAFullyDownloadedBook() async throws {
        let file = try write("山月記.txt", text: """
        第一章 下山
        雪停了。
        第二章 入城
        城門在傍晚關上。
        """)
        let importer = LocalBookImporter(repo: repo, downloads: downloads, fetcher: WebFetcher())

        let book = try await importer.importBook(from: file) { _ in }

        XCTAssertEqual(book.siteId, Book.localSiteId)
        XCTAssertTrue(book.isLocal)
        // No metadata in a text file, so the filename is the only honest title.
        XCTAssertEqual(book.title, "山月記")

        let chapters = try repo.chapters(bookId: book.id)
        XCTAssertEqual(chapters.map(\.title), ["第一章 下山", "第二章 入城"])
        XCTAssertEqual(chapters.map(\.index), [0, 1])
        XCTAssertTrue(chapters.allSatisfy(\.isDownloaded), "imported text is its own download")
        XCTAssertEqual(
            try downloads.readParagraphs(book: book, siteChapterId: chapters[1].siteChapterId),
            ["城門在傍晚關上。"]
        )
        XCTAssertGreaterThan(downloads.size(of: .book(book)), 0, "the storage screen must see it")
    }

    /// The chapter URL exists only because the column is not nullable. It has to
    /// be something nothing will ever fetch, so that a code path which tries
    /// fails instead of quietly reaching some site.
    func testChapterURLsAreUnfetchable() async throws {
        let file = try write("a.txt", text: "第一章 下山\n雪停了。")
        let importer = LocalBookImporter(repo: repo, downloads: downloads, fetcher: WebFetcher())

        let book = try await importer.importBook(from: file) { _ in }

        let urls = try repo.chapters(bookId: book.id).map(\.url)
        XCTAssertFalse(urls.isEmpty)
        XCTAssertTrue(
            urls.allSatisfy { URL(string: $0)?.scheme == Book.localSiteId },
            "expected an unfetchable scheme, got \(urls)"
        )
    }

    /// Re-importing the same file must land on the same book. Identity from the
    /// bytes rather than from a fresh id is what lets someone who deleted the text
    /// to save space get it back *under their reading position*, instead of ending
    /// up with two copies of one novel.
    func testReimportingTheSameFileUpdatesTheSameBook() async throws {
        let file = try write("b.txt", text: "第一章 下山\n雪停了。\n第二章 入城\n城門關上。")
        let importer = LocalBookImporter(repo: repo, downloads: downloads, fetcher: WebFetcher())

        let first = try await importer.importBook(from: file) { _ in }
        try repo.updateProgress(bookId: first.id, chapterIndex: 1, offset: 0)
        try downloads.delete(.book(first))
        XCTAssertEqual(try downloads.downloadedCount(bookId: first.id), 0)

        let second = try await importer.importBook(from: file) { _ in }

        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(try repo.allBooks().count, 1, "a re-import must not duplicate the book")
        XCTAssertEqual(second.lastReadChapterIndex, 1, "the reading position must survive")
        XCTAssertEqual(try downloads.downloadedCount(bookId: second.id), 2, "text restored")
    }

    func testProgressRunsForwardToOne() async throws {
        let file = try write("c.txt", text: (1...20).map { "第\($0)章\n內容\($0)。" }.joined(separator: "\n"))
        let importer = LocalBookImporter(repo: repo, downloads: downloads, fetcher: WebFetcher())

        let reported = Reported()
        _ = try await importer.importBook(from: file) { reported.values.append($0) }

        let values = reported.values
        XCTAssertFalse(values.isEmpty)
        XCTAssertEqual(try XCTUnwrap(values.last), 1, accuracy: 0.0001)
        XCTAssertEqual(values, values.sorted(), "a progress bar must never run backwards")
    }

    /// The whole EPUB path in one go: archive, package document, spine order,
    /// table of contents, and chapter text pulled out through the app's web view.
    /// The pieces are covered separately; this is the one that would catch them
    /// being wired together wrongly.
    func testImportingAnEpubProducesOrderedChaptersWithText() async throws {
        let file = try write("book.epub", data: Self.epub)
        let importer = LocalBookImporter(repo: repo, downloads: downloads, fetcher: WebFetcher())

        let book = try await importer.importBook(from: file) { _ in }

        // Metadata from the package document, not from the filename.
        XCTAssertEqual(book.title, "山月記")
        XCTAssertEqual(book.author, "中島敦")

        let chapters = try repo.chapters(bookId: book.id)
        // Two chapters, not three: the cover document is `linear="no"` and holds
        // no text, so it is neither in the spine nor in the catalog.
        XCTAssertEqual(chapters.map(\.title), ["第一章 回鄉", "第二章 虎嘯"])
        XCTAssertTrue(chapters.allSatisfy(\.isDownloaded))
        XCTAssertEqual(
            try downloads.readParagraphs(book: book, siteChapterId: chapters[0].siteChapterId),
            ["隴西的李徵。"]
        )
        // The heading is not repeated at the top of the body: an imported EPUB goes
        // through the same extractor as a fetched page, echo removal included.
        XCTAssertEqual(
            try downloads.readParagraphs(book: book, siteChapterId: chapters[1].siteChapterId),
            ["月光落在草上。"]
        )
    }

    /// The point of cancelling: nothing is left behind.
    ///
    /// A book that stayed on the shelf holding its first few chapters is worse than
    /// an import that failed outright — the row looks finished, so the reader finds
    /// out by running off the end of the text. Both halves are asserted, the row and
    /// the files, because they are stored in two places that can disagree.
    func testCancellingAnImportLeavesNoBookAndNoFiles() async throws {
        let file = try write("cancel.txt", text: (1...200).map { "第\($0)章\n內容\($0)。" }
            .joined(separator: "\n"))
        let importer = LocalBookImporter(repo: repo, downloads: downloads, fetcher: WebFetcher())
        let canceller = Canceller()

        // Cancelled from the progress callback, which is the only way to land the
        // cancel *while chapters are being written* rather than racing the whole
        // import. The first callback arrives once chapter one is already on disk, so
        // the rollback always has something real to undo.
        canceller.task = Task {
            try await importer.importBook(from: file) { _ in
                canceller.reports += 1
                canceller.cancel()
            }
        }

        do {
            _ = try await canceller.task?.value
            XCTFail("a cancelled import must not return a book")
        } catch is CancellationError {
            // Expected, and it must be this error and not a generic failure: the
            // library banner tells the two apart.
        }

        XCTAssertGreaterThan(
            canceller.reports, 0, "the cancel has to land mid-write to prove anything"
        )
        XCTAssertTrue(try repo.allBooks().isEmpty, "no half-imported book may stay on the shelf")
        // Scoped to the imported-books subtree rather than `.everything`, because
        // this test's chapter store and the file it imported share a directory.
        XCTAssertEqual(
            downloads.size(of: .site(siteId: Book.localSiteId)), 0,
            "the chapters written before the cancel have to go with it"
        )
    }

    /// Cancelling a re-import is the one case where the book must survive.
    ///
    /// The row, the custom name and the reading position predate this import and
    /// belong to the user; deleting them would punish someone for changing their
    /// mind about restoring text they had already read. What must not survive is the
    /// claim that the text is on disk.
    func testCancellingAReimportKeepsTheBookAndItsReadingPosition() async throws {
        let file = try write("reimport.txt", text: (1...200).map { "第\($0)章\n內容\($0)。" }
            .joined(separator: "\n"))
        let importer = LocalBookImporter(repo: repo, downloads: downloads, fetcher: WebFetcher())
        let first = try await importer.importBook(from: file) { _ in }
        try repo.updateProgress(bookId: first.id, chapterIndex: 7, offset: 42)

        let canceller = Canceller()
        canceller.task = Task {
            try await importer.importBook(from: file) { _ in canceller.cancel() }
        }
        do {
            _ = try await canceller.task?.value
            XCTFail("a cancelled import must not return a book")
        } catch is CancellationError {}

        let books = try repo.allBooks()
        XCTAssertEqual(books.map(\.id), [first.id], "the book was already the user's")
        XCTAssertEqual(books.first?.lastReadChapterIndex, 7, "the reading position must survive")
        XCTAssertEqual(
            try downloads.downloadedCount(bookId: first.id), 0,
            "no chapter may still claim to be on disk after the rollback"
        )
        XCTAssertEqual(downloads.size(of: .book(first)), 0)
    }

    func testUnreadableFileIsReported() async {
        let missing = tempRoot.appendingPathComponent("nope.txt")
        let importer = LocalBookImporter(repo: repo, downloads: downloads, fetcher: WebFetcher())
        do {
            _ = try await importer.importBook(from: missing) { _ in }
            XCTFail("importing a file that is not there must fail")
        } catch {
            XCTAssertNotNil(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private func write(_ name: String, text: String) throws -> URL {
        try write(name, data: Data(text.utf8))
    }

    private func write(_ name: String, data: Data) throws -> URL {
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let url = tempRoot.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// A two-chapter EPUB with a cover the spine excludes and an ncx that names
    /// both chapters — the smallest thing that is still shaped like a real book.
    private static let epub = ZipWriter.archive([
        ZipWriter.Entry(name: "mimetype", text: "application/epub+zip"),
        ZipWriter.Entry(name: "META-INF/container.xml", text: """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """, deflated: true),
        ZipWriter.Entry(name: "content.opf", text: """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>山月記</dc:title>
            <dc:creator>中島敦</dc:creator>
          </metadata>
          <manifest>
            <item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>
            <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="c2.xhtml" media-type="application/xhtml+xml"/>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
          </manifest>
          <spine toc="ncx">
            <itemref idref="cover" linear="no"/>
            <itemref idref="c1"/>
            <itemref idref="c2"/>
          </spine>
        </package>
        """, deflated: true),
        ZipWriter.Entry(name: "toc.ncx", text: """
        <?xml version="1.0"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <navMap>
            <navPoint id="p1"><navLabel><text>第一章 回鄉</text></navLabel>
              <content src="c1.xhtml"/></navPoint>
            <navPoint id="p2"><navLabel><text>第二章 虎嘯</text></navLabel>
              <content src="c2.xhtml"/></navPoint>
          </navMap>
        </ncx>
        """, deflated: true),
        ZipWriter.Entry(name: "cover.xhtml", text: "<html><body><img src='c.jpg'/></body></html>"),
        ZipWriter.Entry(name: "c1.xhtml", text: """
        <html><body><h1>回鄉</h1><p>隴西的李徵。</p></body></html>
        """, deflated: true),
        ZipWriter.Entry(name: "c2.xhtml", text: """
        <html><body><h1>虎嘯</h1><div>月光落在草上。</div></body></html>
        """, deflated: true),
    ])

    /// Collects the progress callbacks, which arrive on the main actor.
    private final class Reported {
        var values: [Double] = []
    }

    /// Holds the import's own task so the progress callback can cancel the very
    /// import that is reporting to it. Without that circle, "cancel after the third
    /// chapter" can only be approximated with a sleep, and a timing-dependent test
    /// of a cancellation path is worse than none.
    @MainActor
    private final class Canceller {
        var task: Task<Book, any Error>?
        /// How many progress callbacks arrived, which is how the test knows the
        /// cancel landed after real work rather than before any.
        var reports = 0

        func cancel() { task?.cancel() }
    }
}

/// The source id imported books use has to stay theirs. A rule that took it over
/// would relabel a shelf of the user's own files with a site's name and offer to
/// refetch their catalogs from a site that has never seen them.
final class ReservedSourceIdTests: XCTestCase {
    @MainActor
    func testARuleCannotClaimTheImportedSourceId() throws {
        let store = SiteStore(
            directory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("NovelReaderTests-\(UUID().uuidString)")
        )
        let json = """
        {
          "id": "\(Book.localSiteId)", "name": "Impostor", "host": "example.com",
          "urls": { "book": "https://example.com/b/{bookId}",
                    "catalog": "https://example.com/b/{bookId}/",
                    "chapter": "https://example.com/c/{chapterId}" },
          "idPatterns": { "bookId": "/b/(\\\\d+)", "chapterId": "/c/(\\\\d+)" },
          "book": { "title": { "selector": "h1" } },
          "catalog": { "container": "#c", "linkSelector": "a", "order": "ascending" },
          "chapter": { "titleSelectors": ["h1"], "contentSelectors": ["#t"], "stripSelectors": [] }
        }
        """
        XCTAssertThrowsError(try store.importRule(data: Data(json.utf8)))
        XCTAssertTrue(store.rules.isEmpty)
    }
}

/// iCloud carries bookmarks, custom names and reading positions. A book that came
/// out of a file on *this* device has none of that to offer another one: the other
/// device would show a book it can never open.
final class LocalBookCloudSyncTests: XCTestCase {
    /// Stands in for the real key-value store, which needs an iCloud account and a
    /// signed app — neither of which a unit test has. Overriding the four members
    /// `CloudSync` uses keeps the test offline and lets it assert on exactly what
    /// would have travelled between devices.
    private final class SpyStore: NSUbiquitousKeyValueStore {
        var values: [String: Any] = [:]
        // Both setters: the store has a typed `Data` overload, and a record is
        // encoded JSON, so that is the one the sync path actually calls.
        override func set(_ aData: Data?, forKey aKey: String) { values[aKey] = aData }
        override func set(_ anObject: Any?, forKey aKey: String) { values[aKey] = anObject }
        override func removeObject(forKey aKey: String) { values.removeValue(forKey: aKey) }
        override func synchronize() -> Bool { true }
        override var dictionaryRepresentation: [String: Any] { values }
    }

    @MainActor
    func testLocalBooksAreNotPushedButOthersAre() throws {
        let repo = LibraryRepo(database: try AppDatabase.makeInMemory())
        let fetched = try repo.bookmark(siteId: "alpha", siteBookId: "1", title: "Fetched")
        let imported = try repo.bookmark(
            siteId: Book.localSiteId, siteBookId: "abc123", title: "Imported"
        )

        let store = SpyStore()
        let defaults = UserDefaults(suiteName: "novelreader.tests.\(UUID().uuidString)")!
        defaults.set(true, forKey: CloudSync.enabledDefaultsKey)
        let sync = CloudSync(repo: repo, store: store, defaults: defaults)

        sync.pushAll()
        sync.push(imported)

        // The positive half is what keeps this test honest: if the spy were never
        // written to at all, "the local book was skipped" would prove nothing.
        XCTAssertNotNil(store.values["book.\(fetched.id)"], "a normal book must sync")
        XCTAssertNil(store.values["book.\(imported.id)"], "an imported book must not sync")
    }
}
