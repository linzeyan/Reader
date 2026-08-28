import GRDB
import XCTest
@testable import NovelReader

/// The reading history, and the one decision it makes for the whole app: which tab a
/// launch opens on.
///
/// Every rule here is invisible until it is wrong. A history that lists books nobody
/// opened, one that survives being cleared, or a "finished" that fires a percent early
/// would each look like the app misremembering what the reader did — which is the one
/// thing this screen exists to get right.
final class RecentReadingTests: XCTestCase {
    private let day: TimeInterval = 24 * 60 * 60
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeRepo() throws -> LibraryRepo {
        LibraryRepo(database: try AppDatabase.makeInMemory())
    }

    private func entries(_ count: Int) -> [(siteChapterId: String, title: String, url: String)] {
        (1...count).map {
            (siteChapterId: "\($0)", title: "第\($0)章", url: "https://demo.test/1/\($0)")
        }
    }

    /// A bookmarked book with a catalog, ready to be read.
    @discardableResult
    private func book(
        _ siteBookId: String, chapters: Int, in repo: LibraryRepo
    ) throws -> Book {
        let book = try repo.bookmark(siteId: "demo", siteBookId: siteBookId, title: "書\(siteBookId)")
        try repo.replaceCatalog(bookId: book.id, entries: entries(chapters))
        return book
    }

    // MARK: - What goes in the list

    /// The gate. A shelf holds every book someone has ever bookmarked; a history holds
    /// the ones they have actually been in, and the difference is the whole point of the
    /// screen being first.
    func testOnlyBooksThatHaveBeenReadAppearInTheHistory() throws {
        let repo = try makeRepo()
        let read = try book("1", chapters: 3, in: repo)
        try book("2", chapters: 3, in: repo)
        try repo.updateProgress(bookId: read.id, position: .chapterStart("2"), now: epoch)

        let history = try repo.recentlyRead(limit: 15)

        XCTAssertEqual(history.map(\.id), [read.id])
    }

    func testTheHistoryRunsNewestFirstAndStopsAtTheLimit() throws {
        let repo = try makeRepo()
        let first = try book("1", chapters: 3, in: repo)
        let second = try book("2", chapters: 3, in: repo)
        let third = try book("3", chapters: 3, in: repo)
        try repo.updateProgress(bookId: first.id, position: .chapterStart("1"), now: epoch)
        try repo.updateProgress(
            bookId: second.id, position: .chapterStart("1"), now: epoch.addingTimeInterval(day)
        )
        try repo.updateProgress(
            bookId: third.id, position: .chapterStart("1"), now: epoch.addingTimeInterval(2 * day)
        )

        XCTAssertEqual(
            try repo.recentlyRead(limit: 15).map(\.id), [third.id, second.id, first.id]
        )
        XCTAssertEqual(
            try repo.recentlyRead(limit: 2).map(\.id), [third.id, second.id],
            "the limit has to cut from the far end, not the near one"
        )
        XCTAssertTrue(try repo.recentlyRead(limit: 0).isEmpty)
    }

    /// Reading a book again moves it, rather than listing it twice. The history is one
    /// row per book by construction — the timestamp lives on the book — and this is the
    /// property that makes it readable at five rows long.
    func testReadingABookAgainMovesItToTheTopInsteadOfRepeatingIt() throws {
        let repo = try makeRepo()
        let first = try book("1", chapters: 3, in: repo)
        let second = try book("2", chapters: 3, in: repo)
        try repo.updateProgress(bookId: first.id, position: .chapterStart("1"), now: epoch)
        try repo.updateProgress(
            bookId: second.id, position: .chapterStart("1"), now: epoch.addingTimeInterval(day)
        )

        try repo.updateProgress(
            bookId: first.id, position: .chapterStart("2"), now: epoch.addingTimeInterval(2 * day)
        )

        XCTAssertEqual(try repo.recentlyRead(limit: 15).map(\.id), [first.id, second.id])
    }

    /// The row has to say where the reader stopped without opening the book, which is
    /// what the join in `recentlyRead` is for.
    func testAHistoryRowCarriesTheChapterTheReaderStoppedIn() throws {
        let repo = try makeRepo()
        let book = try book("1", chapters: 12, in: repo)
        try repo.updateProgress(
            bookId: book.id, position: .chapterStart("5"), fraction: 0.4, now: epoch
        )

        let entry = try XCTUnwrap(repo.recentlyRead(limit: 15).first)

        XCTAssertEqual(entry.chapterTitle, "第5章")
        XCTAssertEqual(entry.chapterIndex, 4, "reading order is 0-based, as everywhere else")
        XCTAssertEqual(entry.chapterCount, 12)
        XCTAssertEqual(entry.book.lastReadFraction, 0.4)
    }

    /// A site withdrawing the chapter someone stopped in must not take the book out of
    /// their history — they did read it. What it takes is the place, and the row says so
    /// rather than inventing one.
    func testABookWhoseChapterTheSiteDroppedKeepsItsPlaceInTheHistory() throws {
        let repo = try makeRepo()
        let book = try book("1", chapters: 4, in: repo)
        try repo.updateProgress(bookId: book.id, position: .chapterStart("3"), now: epoch)

        try repo.replaceCatalog(
            bookId: book.id,
            entries: [("1", "第1章", "u"), ("2", "第2章", "u"), ("4", "第4章", "u")]
        )

        let entry = try XCTUnwrap(repo.recentlyRead(limit: 15).first)
        XCTAssertNil(entry.chapterTitle)
        XCTAssertNil(entry.chapterIndex)
        XCTAssertEqual(entry.chapterCount, 3)
        XCTAssertFalse(entry.isFinished, "a place nobody can find is not the end of the book")
    }

    // MARK: - Clearing

    /// "Clear recent reading" is about the list. Reading positions are what the reader
    /// would be furious to lose, and nothing on that button suggests it touches them.
    func testClearingTheHistoryForgetsTheDatesAndKeepsEveryPosition() throws {
        let repo = try makeRepo()
        let book = try book("1", chapters: 6, in: repo)
        try repo.updateProgress(
            bookId: book.id, position: .chapterStart("4"), fraction: 0.5, now: epoch
        )

        try repo.clearReadingHistory()

        XCTAssertTrue(try repo.recentlyRead(limit: 15).isEmpty)
        let stored = try XCTUnwrap(repo.book(id: book.id))
        XCTAssertNil(stored.lastReadAt)
        XCTAssertEqual(stored.lastReadSiteChapterId, "4")
        XCTAssertEqual(stored.lastReadFraction, 0.5)
    }

    /// Clearing is not a library edit, so it must not look like one to iCloud:
    /// `updatedAt` is what the merge compares, and bumping it here would have every
    /// other device re-pull rows whose content did not change.
    func testClearingTheHistoryDoesNotRepublishTheBookToICloud() throws {
        let repo = try makeRepo()
        let book = try book("1", chapters: 6, in: repo)
        try repo.updateProgress(bookId: book.id, position: .chapterStart("2"), now: epoch)
        let before = try XCTUnwrap(repo.book(id: book.id)).updatedAt

        try repo.clearReadingHistory()

        XCTAssertEqual(
            try XCTUnwrap(repo.book(id: book.id)).updatedAt.timeIntervalSince1970,
            before.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    /// Reading a book after clearing puts it back, which is the only way the history can
    /// be cleared without being disabled.
    func testReadingAfterClearingStartsTheHistoryAgain() throws {
        let repo = try makeRepo()
        let book = try book("1", chapters: 6, in: repo)
        try repo.updateProgress(bookId: book.id, position: .chapterStart("2"), now: epoch)
        try repo.clearReadingHistory()

        try repo.updateProgress(
            bookId: book.id, position: .chapterStart("3"), now: epoch.addingTimeInterval(day)
        )

        XCTAssertEqual(try repo.recentlyRead(limit: 15).map(\.id), [book.id])
    }

    // MARK: - Finished

    /// "Finished" is the last chapter *and* the end of it, and the end is the number the
    /// app has been showing all along: `TextAnchor.shareText` rounds to a whole percent,
    /// so anything that prints as 100% is finished and nothing else is. A row reading
    /// 100% next to no badge — or a badge next to 99% — is the failure this pins.
    func testABookIsFinishedOnlyAtTheEndOfItsLastChapter() throws {
        XCTAssertTrue(finished(chapterIndex: 9, of: 10, fraction: 1))
        XCTAssertTrue(
            finished(chapterIndex: 9, of: 10, fraction: 0.995),
            "the smallest share that prints as 100%"
        )
        XCTAssertFalse(
            finished(chapterIndex: 9, of: 10, fraction: 0.99),
            "prints as 99%, so it must not claim to be finished"
        )
        XCTAssertFalse(
            finished(chapterIndex: 8, of: 10, fraction: 1),
            "the end of a chapter is not the end of the book"
        )
        XCTAssertFalse(
            finished(chapterIndex: 9, of: 10, fraction: nil),
            "no recorded share means which chapter and nothing finer — not 100%"
        )
        XCTAssertFalse(
            finished(chapterIndex: nil, of: 10, fraction: 1),
            "a position that no longer resolves is not the end of anything"
        )
        XCTAssertFalse(
            finished(chapterIndex: 0, of: 0, fraction: 1),
            "a book with no catalog has no last chapter to have reached"
        )
    }

    // MARK: - Which tab a launch opens on

    /// The reason the history is the first screen: it is where reading is resumed. A
    /// reader with a book on the go must land on it.
    func testTheAppOpensOnTheHistoryWhileAnythingOnItIsUnfinished() {
        let history = [
            entry(chapterIndex: 9, of: 10, fraction: 1),
            entry(chapterIndex: 3, of: 40, fraction: 0.2),
        ]

        XCTAssertEqual(RootTab.home(recent: history), .recent)
    }

    /// And the reason it is not always: a history of nothing but finished books is a
    /// screen of dead ends. What that reader came for is the next book, which is the
    /// shelf.
    func testTheAppOpensOnTheLibraryWhenEveryRecentBookIsFinished() {
        let history = [
            entry(chapterIndex: 9, of: 10, fraction: 1),
            entry(chapterIndex: 199, of: 200, fraction: 1),
        ]

        XCTAssertEqual(RootTab.home(recent: history), .library)
    }

    /// A fresh install, and a reader who has just cleared the history. Neither has
    /// anything to resume, and the history's own empty state points at the shelf — so
    /// opening there directly is the same answer without the extra tap.
    func testAnEmptyHistoryOpensOnTheLibrary() {
        XCTAssertEqual(RootTab.home(recent: []), .library)
    }

    /// The rule reads the list *as shown*. A book pushed off the end of a five-row list
    /// cannot be tapped, so it must not be the reason the app opens on a screen where
    /// every visible row is a dead end.
    func testTheDecisionOnlyCountsTheRowsTheReaderCanActuallySee() {
        let history = [
            entry(chapterIndex: 9, of: 10, fraction: 1),
            entry(chapterIndex: 2, of: 30, fraction: 0.1),
        ]

        XCTAssertEqual(RootTab.home(recent: Array(history.prefix(1))), .library)
        XCTAssertEqual(RootTab.home(recent: history), .recent)
    }

    // MARK: - The length setting

    /// Also the guard against the clamp being written as a `didSet` that assigns back to
    /// its own property. Under `@Observable` a stored property becomes an accessor pair,
    /// so that assignment calls the setter again rather than being the no-op it is on a
    /// real stored property — and the first out-of-range value crashed the app.
    func testTheHistoryLengthDefaultsToFiveAndStaysInsideWhatTheStepperOffers() {
        let defaults = UserDefaults(suiteName: "novelreader.tests.\(UUID().uuidString)")!
        let settings = LibrarySettings(defaults: defaults)

        XCTAssertEqual(settings.recentReadingCount, 5)

        settings.recentReadingCount = 40
        XCTAssertEqual(settings.recentReadingCount, LibrarySettings.recentReadingRange.upperBound)
        settings.recentReadingCount = 0
        XCTAssertEqual(settings.recentReadingCount, LibrarySettings.recentReadingRange.lowerBound)
    }

    /// The value reaches SQL as a `LIMIT`, and `UserDefaults` is not a place anything can
    /// promise what a previous build — or a restored device — left behind.
    func testAStoredLengthFromOutsideTheRangeIsBroughtBackInside() {
        let defaults = UserDefaults(suiteName: "novelreader.tests.\(UUID().uuidString)")!
        defaults.set(-3, forKey: "library.recentReadingCount")

        XCTAssertEqual(
            LibrarySettings(defaults: defaults).recentReadingCount,
            LibrarySettings.recentReadingRange.lowerBound
        )
    }

    // MARK: - Migration

    /// The upgrade. `lastReadAt` did not exist, so the closest honest reading of an
    /// existing row is what the shelf's "recently read" sort was already using:
    /// `updatedAt`, for books that have a position at all. A book nobody has opened has
    /// no such reading and stays out of the history — inventing a date for it would open
    /// the app on a list of books the reader has never seen.
    func testTheHistoryIsBackfilledFromWhatTheOldSortWasApproximating() throws {
        let queue = try DatabaseQueue()
        let migrator = AppDatabase.migrator
        try migrator.migrate(queue, upTo: "v7.readingShare")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO book (id, siteId, siteBookId, title, addedAt, updatedAt,
                                  lastReadSiteChapterId, lastReadParagraph, lastReadCharacterOffset)
                VALUES ('demo|1', 'demo', '1', '讀過', '2024-01-01 00:00:00.000',
                        '2024-05-01 00:00:00.000', '3', 0, 0)
                """)
            try db.execute(sql: """
                INSERT INTO book (id, siteId, siteBookId, title, addedAt, updatedAt)
                VALUES ('demo|2', 'demo', '2', '沒讀過', '2024-01-01 00:00:00.000',
                        '2024-06-01 00:00:00.000')
                """)
        }

        try migrator.migrate(queue)

        let books = try queue.read { db in try Book.order(Column("id")).fetchAll(db) }
        XCTAssertEqual(books.map(\.lastReadAt), [books[0].updatedAt, nil])
        XCTAssertNotNil(books[0].lastReadAt)
    }

    // MARK: - Helpers

    private func finished(chapterIndex: Int?, of count: Int, fraction: Double?) -> Bool {
        entry(chapterIndex: chapterIndex, of: count, fraction: fraction).isFinished
    }

    private func entry(chapterIndex: Int?, of count: Int, fraction: Double?) -> RecentRead {
        var book = Book(
            id: "demo|\(chapterIndex ?? -1)|\(count)", siteId: "demo", siteBookId: "1",
            kind: .novel, title: "書", displayName: nil, author: nil, coverURL: nil,
            addedAt: epoch, updatedAt: epoch,
            lastReadSiteChapterId: "\((chapterIndex ?? 0) + 1)", lastReadParagraph: 0,
            lastReadCharacterOffset: 0, lastReadFraction: fraction,
            lastReadAt: epoch, catalogUpdatedAt: epoch
        )
        if chapterIndex == nil { book.lastReadSiteChapterId = "gone" }
        return RecentRead(
            book: book,
            chapterTitle: chapterIndex.map { "第\($0 + 1)章" },
            chapterIndex: chapterIndex,
            chapterCount: count
        )
    }
}
