import XCTest
@testable import NovelReader

/// What a backup has to be worth taking.
///
/// The format's whole claim is that it holds what this app cannot fetch again — the shelf,
/// where the reader got to, what they marked, the sources they installed by hand — so most
/// of what is asserted here is a round trip: capture a library, restore it into an empty
/// one, and find the same things. The rest is about restoring onto a library that is not
/// empty, which is the case that can destroy something: a merge that overwrote, or a
/// second restore that doubled every mark, would both be silent.
@MainActor
final class LibraryBackupTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LibraryBackupTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - A library to back up

    /// One library: its database, its installed sources and its settings, all disposable.
    ///
    /// The settings sit in a `UserDefaults` suite of their own rather than in `.standard`,
    /// because `ReaderSettings.shared` is what the running app reads — a test that wrote
    /// through it would change the simulator's reader for every test that ran afterwards.
    private struct Library {
        let repo: LibraryRepo
        let sites: SiteStore
        let targets: LibraryBackup.Settings.Targets
        let suiteName: String
    }

    private func makeLibrary(_ name: String) throws -> Library {
        let suiteName = "LibraryBackupTests.\(name).\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        // Loaded, the way every store the app builds is. A Debug build seeds development
        // rules on load, so a store that had never loaded would start from a different
        // source list than the one it is being compared with — and the assertions below
        // are about what a *restore* changed, not about what the build shipped.
        let sites = SiteStore(directory: tempRoot.appendingPathComponent(name))
        try sites.load()
        return Library(
            repo: LibraryRepo(database: try AppDatabase.makeInMemory()),
            sites: sites,
            targets: LibraryBackup.Settings.Targets(
                reader: ReaderSettings(defaults: defaults),
                library: LibrarySettings(defaults: defaults),
                downloads: DownloadSettings(defaults: defaults),
                feeds: FeedRetentionSettings(defaults: defaults)
            ),
            suiteName: suiteName
        )
    }

    private func capture(_ library: Library) throws -> LibraryBackup {
        try LibraryBackup.capture(
            repo: library.repo, sites: library.sites, settings: library.targets
        )
    }

    @discardableResult
    private func restore(
        _ backup: LibraryBackup, into library: Library
    ) throws -> LibraryBackup.Outcome {
        try backup.restore(
            into: library.repo, sites: library.sites, settings: library.targets
        )
    }

    private func makeRule(name: String = "Demo") -> SiteRule {
        SiteRule(
            id: "demo", name: name, host: "demo.test",
            urls: .init(
                book: "https://demo.test/book/{bookId}",
                catalog: "https://demo.test/book/{bookId}/",
                chapter: "https://demo.test/txt/{bookId}/{chapterId}"
            ),
            idPatterns: .init(bookId: "/book/(\\d+)", chapterId: "/txt/\\d+/(\\d+)"),
            search: nil,
            book: .init(
                title: .init(meta: nil, selector: "h1", attribute: nil),
                author: nil, cover: nil, category: nil, status: nil, intro: nil, latestChapter: nil
            ),
            catalog: .init(container: "#catalog", linkSelector: "a", order: .ascending),
            chapter: .init(
                titleSelectors: ["h1"], contentSelectors: [".content"],
                stripSelectors: [], dropParagraphPatterns: nil, prevSelector: nil, nextSelector: nil
            ),
            notes: nil
        )
    }

    private func position(_ chapter: String, paragraph: Int = 4) -> ReadingPosition {
        ReadingPosition(
            siteChapterId: chapter,
            anchor: TextAnchor(paragraph: paragraph, characterOffset: 0)
        )
    }

    /// A book with a place in it, a saved position and a marked passage — one of each
    /// thing the file claims to carry.
    @discardableResult
    private func seedBook(_ library: Library, siteBookId: String = "1") throws -> Book {
        let book = try library.repo.bookmark(
            siteId: "demo", siteBookId: siteBookId, title: "A Novel", author: "An Author"
        )
        try library.repo.rename(bookId: book.id, to: "My name for it")
        try library.repo.updateProgress(
            bookId: book.id, position: position("c7"), fraction: 0.5,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try library.repo.addReadingBookmark(
            bookId: book.id, position: position("c3"), excerpt: "Where I stopped."
        )
        try library.repo.addHighlight(
            bookId: book.id, siteChapterId: "c5",
            selection: TextSelection(
                start: TextAnchor(paragraph: 2, characterOffset: 0),
                end: TextAnchor(paragraph: 2, characterOffset: 11),
                text: "Marked text"
            )
        )
        return try XCTUnwrap(library.repo.book(id: book.id))
    }

    // MARK: - Round trip

    /// The claim the whole format rests on: a device that lost everything gets back the
    /// shelf, the reader's own name for a book, where they stopped, and both kinds of mark.
    func testEverythingTheReaderOwnsSurvivesTheRoundTrip() throws {
        let source = try makeLibrary("source")
        let original = try seedBook(source)

        let restored = try makeLibrary("restored")
        let outcome = try restore(
            try LibraryBackup.read(try LibraryBackup.encoder().encode(capture(source))),
            into: restored
        )

        let book = try XCTUnwrap(restored.repo.book(id: original.id))
        XCTAssertEqual(book.title, "A Novel")
        XCTAssertEqual(book.displayName, "My name for it", "the one part of a row that is theirs")
        XCTAssertEqual(book.readingPosition, original.readingPosition)
        XCTAssertEqual(book.lastReadFraction, 0.5)
        XCTAssertEqual(
            book.lastReadAt, original.lastReadAt,
            "the reading history is this column ordered, so restoring it as 'now' would"
                + " report every book as read tonight"
        )
        XCTAssertEqual(try restored.repo.readingBookmarks(bookId: book.id).count, 1)
        let highlight = try XCTUnwrap(restored.repo.highlights(bookId: book.id).first)
        XCTAssertEqual(highlight.excerpt, "Marked text")
        XCTAssertEqual(outcome, LibraryBackup.Outcome(books: 1, marks: 2, rules: 0))
    }

    /// A restored book has to look un-fetched, because it is: none of its chapters came
    /// with it. Carrying `catalogUpdatedAt` would tell a fresh install that its empty
    /// catalog was current, and the reader would open a book with nothing in it and
    /// nothing on its way.
    func testARestoredBookIsStaleSoItsCatalogIsFetchedAgain() throws {
        let source = try makeLibrary("source")
        let book = try seedBook(source)
        try source.repo.touchCatalog(bookId: book.id)
        XCTAssertFalse(try XCTUnwrap(source.repo.book(id: book.id)).isCatalogStale)

        let restored = try makeLibrary("restored")
        try restore(capture(source), into: restored)

        XCTAssertTrue(try XCTUnwrap(restored.repo.book(id: book.id)).isCatalogStale)
    }

    func testTheInstalledSourcesComeBack() throws {
        let source = try makeLibrary("source")
        _ = try source.sites.importRule(data: try JSONEncoder().encode(makeRule()))

        let restored = try makeLibrary("restored")
        let outcome = try restore(capture(source), into: restored)

        XCTAssertEqual(restored.sites.rule(id: "demo")?.name, "Demo")
        XCTAssertEqual(outcome.rules, 1)
    }

    /// A rule the reader has since updated is theirs, and the backup's copy is older by
    /// definition. Sources are the one thing in this file that is a *program*, and
    /// overwriting a working one with a stale one would break the books it serves.
    func testARuleAlreadyInstalledIsNotOverwritten() throws {
        let source = try makeLibrary("source")
        _ = try source.sites.importRule(data: try JSONEncoder().encode(makeRule()))
        let backup = try capture(source)

        let restored = try makeLibrary("restored")
        _ = try restored.sites.importRule(
            data: try JSONEncoder().encode(makeRule(name: "Demo, corrected"))
        )
        let outcome = try restore(backup, into: restored)

        XCTAssertEqual(restored.sites.rule(id: "demo")?.name, "Demo, corrected")
        XCTAssertEqual(outcome.rules, 0, "nothing was installed, and it must not claim so")
    }

    func testSettingsComeBack() throws {
        let source = try makeLibrary("source")
        source.targets.reader.fontSize = 24
        source.targets.reader.theme = .sepia
        source.targets.library.groupBySource = false
        source.targets.downloads.network = .wifiAndCellular
        source.targets.feeds.keep = .fifty

        let restored = try makeLibrary("restored")
        try restore(capture(source), into: restored)

        XCTAssertEqual(restored.targets.reader.fontSize, 24)
        XCTAssertEqual(restored.targets.reader.theme, .sepia)
        XCTAssertFalse(restored.targets.library.groupBySource)
        XCTAssertEqual(restored.targets.downloads.network, .wifiAndCellular)
        XCTAssertEqual(restored.targets.feeds.keep, .fifty)
    }

    // MARK: - Restoring onto a library that is not empty

    /// A restore puts things back; it must never take anything away. Picking the wrong
    /// file is a mistake someone makes once — and it has to stay a mistake they can undo
    /// by deleting a few rows, not one that empties their shelf.
    func testRestoringDoesNotRemoveWhatIsAlreadyHere() throws {
        let source = try makeLibrary("source")
        try seedBook(source, siteBookId: "1")
        let backup = try capture(source)

        let target = try makeLibrary("target")
        let untouched = try target.repo.bookmark(siteId: "demo", siteBookId: "99", title: "Mine")
        try restore(backup, into: target)

        XCTAssertNotNil(try target.repo.book(id: untouched.id))
        XCTAssertEqual(try target.repo.allBooks().count, 2)
    }

    /// The merge rule `CloudSync` already uses, spelled the same way: a row is replaced
    /// only by a newer one. A backup taken last month must not drag a book back to where
    /// the reader was when they took it.
    func testABookReadFurtherHereKeepsItsOwnPlace() throws {
        let source = try makeLibrary("source")
        let book = try seedBook(source)
        let backup = try capture(source)

        let target = try makeLibrary("target")
        try seedBook(target)
        try target.repo.updateProgress(
            bookId: book.id, position: position("c40"), fraction: 0.9,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let outcome = try restore(backup, into: target)

        XCTAssertEqual(
            try XCTUnwrap(target.repo.book(id: book.id)).readingPosition, position("c40")
        )
        XCTAssertEqual(outcome.books, 0)
    }

    /// Marks are merged even when the book's own row is not, and that is deliberate: a
    /// book read further on this device is still a book whose highlights only ever
    /// existed in the file. They are not part of the record last-writer-wins decides.
    func testMarksMergeEvenIntoABookThisDeviceHasNewer() throws {
        let source = try makeLibrary("source")
        let book = try seedBook(source)
        let backup = try capture(source)

        let target = try makeLibrary("target")
        try target.repo.bookmark(siteId: "demo", siteBookId: "1", title: "A Novel")
        try target.repo.updateProgress(
            bookId: book.id, position: position("c40"),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let outcome = try restore(backup, into: target)

        XCTAssertEqual(try target.repo.readingBookmarks(bookId: book.id).count, 1)
        XCTAssertEqual(try target.repo.highlights(bookId: book.id).count, 1)
        XCTAssertEqual(outcome, LibraryBackup.Outcome(books: 0, marks: 2, rules: 0))
    }

    /// Restoring the same file twice is something people do — two devices, or a restore
    /// they were not sure had gone through. The second one has to be a no-op, and has to
    /// say so: a mark's id is the passage it covers, so nothing can double, but a report
    /// that counted them all again would read as a library restored twice over.
    func testRestoringTheSameBackupTwiceChangesNothingTheSecondTime() throws {
        let source = try makeLibrary("source")
        let book = try seedBook(source)
        let backup = try capture(source)
        let target = try makeLibrary("target")
        try restore(backup, into: target)

        let outcome = try restore(backup, into: target)

        XCTAssertEqual(outcome, LibraryBackup.Outcome())
        XCTAssertEqual(try target.repo.readingBookmarks(bookId: book.id).count, 1)
        XCTAssertEqual(try target.repo.highlights(bookId: book.id).count, 1)
    }

    // MARK: - Imported books

    /// An imported book's text is a file this backup does not carry and no site can
    /// re-serve. Restoring the row alone would put a book on the shelf that opens onto
    /// nothing, so it is skipped — and reported, because the reader can do something
    /// about it.
    func testAnImportedBookIsNotRecreatedAsAnEmptyShell() throws {
        let source = try makeLibrary("source")
        let imported = try source.repo.bookmark(
            siteId: Book.localSiteId, siteBookId: "hash-of-the-file", title: "An EPUB"
        )
        try source.repo.addReadingBookmark(bookId: imported.id, position: position("0"))

        let target = try makeLibrary("target")
        let outcome = try restore(capture(source), into: target)

        XCTAssertNil(try target.repo.book(id: imported.id))
        XCTAssertEqual(outcome, LibraryBackup.Outcome(books: 0, marks: 0, rules: 0, skippedImports: 1))
    }

    /// And the other half of that promise: import the file again — which lands on the same
    /// id, because the id is a hash of its contents — restore the same backup, and the
    /// marks made in it are back.
    func testAnImportedBookThatIsHereAgainGetsItsMarksBack() throws {
        let source = try makeLibrary("source")
        let imported = try source.repo.bookmark(
            siteId: Book.localSiteId, siteBookId: "hash-of-the-file", title: "An EPUB"
        )
        try source.repo.addReadingBookmark(
            bookId: imported.id, position: position("0"), excerpt: "A line I kept."
        )
        let backup = try capture(source)

        let target = try makeLibrary("target")
        try target.repo.bookmark(
            siteId: Book.localSiteId, siteBookId: "hash-of-the-file", title: "An EPUB"
        )
        let outcome = try restore(backup, into: target)

        XCTAssertEqual(
            try target.repo.readingBookmarks(bookId: imported.id).first?.excerpt, "A line I kept."
        )
        XCTAssertEqual(outcome.skippedImports, 0)
    }

    // MARK: - Files that are not backups

    func testAFileThatIsNotABackupIsRefused() {
        XCTAssertThrowsError(try LibraryBackup.read(Data(#"{"feeds": []}"#.utf8))) { error in
            XCTAssertEqual(error as? LibraryBackup.Failure, .unreadable)
        }
    }

    /// A file from a build that has since changed the shape would be restored *wrongly*
    /// rather than not at all, and a wrong restore is the one failure here with no way
    /// back — every other one leaves rows to delete.
    func testABackupFromANewerBuildIsRefusedRatherThanGuessedAt() throws {
        let source = try makeLibrary("source")
        var backup = try capture(source)
        backup.version = LibraryBackup.currentVersion + 1
        let data = try LibraryBackup.encoder().encode(backup)

        XCTAssertThrowsError(try LibraryBackup.read(data)) { error in
            XCTAssertEqual(
                error as? LibraryBackup.Failure,
                .unsupportedVersion(LibraryBackup.currentVersion + 1)
            )
        }
    }
}
