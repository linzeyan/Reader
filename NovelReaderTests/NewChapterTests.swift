import GRDB
import XCTest
@testable import NovelReader

/// Which chapters count as "the site published this while you were away".
///
/// The whole value of the red marker is that it is rare. Anything that marks a
/// chapter the reader could already see — a first catalog, a re-fetch of a
/// catalog that did not change, an update of the app itself — turns the shelf
/// into a wall of red and the marker into decoration, so each of those is
/// pinned separately here.
final class NewChapterTests: XCTestCase {
    private let day: TimeInterval = 24 * 60 * 60

    private func makeRepo() throws -> LibraryRepo {
        LibraryRepo(database: try AppDatabase.makeInMemory())
    }

    private func entries(_ ids: [String]) -> [(siteChapterId: String, title: String, url: String)] {
        ids.map { (siteChapterId: $0, title: "chapter \($0)", url: "https://demo.test/1/\($0)") }
    }

    private func entries(_ count: Int) -> [(siteChapterId: String, title: String, url: String)] {
        entries((1...count).map(String.init))
    }

    private func chapter(_ siteChapterId: String, of repo: LibraryRepo, bookId: String) throws -> Chapter {
        let chapters = try repo.chapters(bookId: bookId)
        return try XCTUnwrap(chapters.first { $0.siteChapterId == siteChapterId })
    }

    /// The per-row rule the way a screen asks it: resolve the reader's stored position
    /// against the catalog, then compare. That resolution is the half `newChapterCounts`
    /// does with a join, so asking it this way is what makes the two comparable.
    private func newChapters(
        of bookId: String, in repo: LibraryRepo, now: Date = .now
    ) throws -> [Chapter] {
        let book = try XCTUnwrap(repo.book(id: bookId))
        let chapters = try repo.chapters(bookId: bookId)
        let lastReadIndex = book.lastReadIndex(in: chapters)
        return chapters.filter { $0.isNew(lastReadIndex: lastReadIndex, now: now) }
    }

    // MARK: - Migration

    /// The upgrade path. Chapters indexed before the column existed have no
    /// honest `addedAt`, and inventing one would greet every reader with a
    /// library where every book claims to have new chapters.
    func testChaptersIndexedBeforeTheColumnExistedAreNotNew() throws {
        let queue = try DatabaseQueue()
        let migrator = AppDatabase.migrator
        try migrator.migrate(queue, upTo: "v2.catalogFreshness")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO book (id, siteId, siteBookId, title, addedAt, updatedAt, catalogUpdatedAt)
                VALUES ('demo|1', 'demo', '1', 't', '2024-01-01 00:00:00.000',
                        '2024-01-01 00:00:00.000', '2024-01-01 00:00:00.000')
                """)
            try db.execute(sql: """
                INSERT INTO chapter (id, bookId, siteChapterId, "index", title, url)
                VALUES ('demo|1|1', 'demo|1', '1', 0, 'one', 'https://demo.test/1/1')
                """)
        }

        try migrator.migrate(queue)

        let (book, chapter) = try queue.read { db in
            (try Book.fetchOne(db, key: "demo|1"), try Chapter.fetchOne(db, key: "demo|1|1"))
        }
        let stored = try XCTUnwrap(chapter)
        XCTAssertNil(stored.addedAt, "There is no honest answer for a row written before the column")
        XCTAssertFalse(stored.isNew(lastReadIndex: try XCTUnwrap(book).lastReadIndex(in: [stored])))
    }

    // MARK: - Catalog diff

    /// A book bookmarked today has a catalog full of chapters the reader has
    /// never seen, and none of them is news.
    func testTheFirstCatalogMarksNothingAsNew() throws {
        let repo = try makeRepo()
        let book = try repo.bookmark(siteId: "demo", siteBookId: "1", title: "t")

        try repo.replaceCatalog(bookId: book.id, entries: entries(3))

        let chapters = try repo.chapters(bookId: book.id)
        XCTAssertEqual(chapters.count, 3)
        XCTAssertTrue(chapters.allSatisfy { $0.addedAt == nil })
        XCTAssertTrue(try newChapters(of: book.id, in: repo).isEmpty)
    }

    /// The actual feature: only the ids that were not in the previous catalog.
    func testASecondCatalogMarksOnlyTheChaptersThatAppeared() throws {
        let repo = try makeRepo()
        let book = try repo.bookmark(siteId: "demo", siteBookId: "1", title: "t")
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        try repo.replaceCatalog(bookId: book.id, entries: entries(2), now: first)

        let second = first.addingTimeInterval(day)
        try repo.replaceCatalog(bookId: book.id, entries: entries(3), now: second)

        XCTAssertNil(try chapter("1", of: repo, bookId: book.id).addedAt)
        XCTAssertNil(try chapter("2", of: repo, bookId: book.id).addedAt)
        let added = try chapter("3", of: repo, bookId: book.id)
        XCTAssertEqual(
            try XCTUnwrap(added.addedAt).timeIntervalSince1970,
            second.timeIntervalSince1970,
            accuracy: 1
        )
        // Asked at the moment it appeared: the marker expires a day later, and this
        // fixture is deliberately dated in the past.
        XCTAssertEqual(try newChapters(of: book.id, in: repo, now: second).map(\.id), [added.id])
    }

    /// The marker also expires on its own, and it has to: reading past a chapter is not
    /// always available to dismiss it — the reader's own catalog sheet is drawn from the
    /// book it was opened with, so chapters read in that session keep their dot until
    /// the reader leaves — and a chapter the site published last month is not news
    /// however you got there.
    func testAChapterStopsBeingNewADayAfterItAppeared() throws {
        let repo = try makeRepo()
        let book = try repo.bookmark(siteId: "demo", siteBookId: "1", title: "t")
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        try repo.replaceCatalog(bookId: book.id, entries: entries(2), now: first)
        let appeared = first.addingTimeInterval(day)
        try repo.replaceCatalog(bookId: book.id, entries: entries(3), now: appeared)

        let added = try chapter("3", of: repo, bookId: book.id)
        let inTime = appeared.addingTimeInterval(day - 60)
        let tooLate = appeared.addingTimeInterval(day + 60)

        XCTAssertEqual(try newChapters(of: book.id, in: repo, now: inTime).map(\.id), [added.id])
        XCTAssertTrue(try newChapters(of: book.id, in: repo, now: tooLate).isEmpty)
        // The shelf count restates the rule in SQL, so it has to expire on the same
        // schedule — otherwise the badge and the number it shows disagree for a day.
        XCTAssertEqual(try repo.newChapterCounts(now: inTime)[book.id], 1)
        XCTAssertNil(try repo.newChapterCounts(now: tooLate)[book.id])
    }

    /// Re-stamping known chapters on every refresh is the failure mode that
    /// would matter most: these catalogs are re-read daily, so the marker would
    /// come back forever on chapters the reader has already dismissed by reading
    /// past them — or be wiped before they ever saw it.
    func testARefreshLeavesTheStampOnChaptersItAlreadyKnew() throws {
        let repo = try makeRepo()
        let book = try repo.bookmark(siteId: "demo", siteBookId: "1", title: "t")
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        try repo.replaceCatalog(bookId: book.id, entries: entries(1), now: first)
        let second = first.addingTimeInterval(day)
        try repo.replaceCatalog(bookId: book.id, entries: entries(2), now: second)

        // A day later the site published nothing, and then one more chapter.
        let third = second.addingTimeInterval(day)
        try repo.replaceCatalog(bookId: book.id, entries: entries(2), now: third)
        let fourth = third.addingTimeInterval(day)
        try repo.replaceCatalog(bookId: book.id, entries: entries(3), now: fourth)

        XCTAssertNil(try chapter("1", of: repo, bookId: book.id).addedAt, "Still from the first catalog")
        XCTAssertEqual(
            try XCTUnwrap(chapter("2", of: repo, bookId: book.id).addedAt).timeIntervalSince1970,
            second.timeIntervalSince1970,
            accuracy: 1,
            "The stamp must stay at the refresh that first saw the chapter"
        )
        XCTAssertEqual(
            try XCTUnwrap(chapter("3", of: repo, bookId: book.id).addedAt).timeIntervalSince1970,
            fourth.timeIntervalSince1970,
            accuracy: 1
        )
    }

    /// A catalog is not append-only. Sites publish a chapter they had skipped, withdraw
    /// one they posted early, and occasionally reverse a whole volume — and every index
    /// after the change moves. `chapter_book_index` is unique and checked row by row, so
    /// a refresh that hands out new numbers while old ones are still in place fails
    /// outright: the book keeps yesterday's catalog, and the refresh that noticed is the
    /// silent background one, so nobody is told.
    func testARefreshRenumbersTheCatalogAroundInsertionsAndRemovals() throws {
        let repo = try makeRepo()
        let book = try repo.bookmark(siteId: "demo", siteBookId: "1", title: "t")
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        try repo.replaceCatalog(bookId: book.id, entries: entries(3), now: first)

        // Inserted in the middle, which is the case that pushes an existing chapter onto
        // a number another chapter is still holding.
        try repo.replaceCatalog(
            bookId: book.id, entries: entries(["1", "1b", "2", "3"]),
            now: first.addingTimeInterval(day)
        )
        XCTAssertEqual(
            try repo.chapters(bookId: book.id).map { "\($0.index):\($0.siteChapterId)" },
            ["0:1", "1:1b", "2:2", "3:3"]
        )

        // Withdrawn from the middle, which is the same collision running the other way.
        try repo.replaceCatalog(
            bookId: book.id, entries: entries(["1", "2", "3"]),
            now: first.addingTimeInterval(2 * day)
        )
        XCTAssertEqual(
            try repo.chapters(bookId: book.id).map { "\($0.index):\($0.siteChapterId)" },
            ["0:1", "1:2", "2:3"]
        )

        // And reversed, where every row has to swap with another.
        try repo.replaceCatalog(
            bookId: book.id, entries: entries(["3", "2", "1"]),
            now: first.addingTimeInterval(3 * day)
        )
        XCTAssertEqual(
            try repo.chapters(bookId: book.id).map { "\($0.index):\($0.siteChapterId)" },
            ["0:3", "1:2", "2:1"]
        )
        XCTAssertNil(
            try chapter("1", of: repo, bookId: book.id).addedAt,
            "a chapter that only moved is not a chapter that appeared"
        )
    }

    // MARK: - Display rule

    /// Reading past a chapter is what dismisses its marker — no flag is cleared
    /// in the database, so this has to hold as a pure function of the two rows.
    func testAChapterTheReaderHasPassedIsNoLongerNew() throws {
        let repo = try makeRepo()
        let book = try repo.bookmark(siteId: "demo", siteBookId: "1", title: "t")
        try repo.replaceCatalog(bookId: book.id, entries: entries(2), now: Date())
        try repo.replaceCatalog(bookId: book.id, entries: entries(4), now: Date())
        try repo.updateProgress(bookId: book.id, position: .chapterStart("3"))

        // Chapters 3 and 4 (indexes 2 and 3) are the new ones; the reader is on
        // chapter 3, so only index 3 is still ahead of them.
        XCTAssertEqual(try newChapters(of: book.id, in: repo).map(\.index), [3])
    }

    /// The site inserting a chapter *behind* the reader must not revive the marker on
    /// chapters they have already read. A stored index did exactly that: everything
    /// after the insertion shifted up by one, so a position recorded as "index 2" now
    /// named the chapter before it, and the chapter the reader had just finished came
    /// back as news.
    func testAChapterInsertedBehindTheReaderDoesNotReviveChaptersTheyPassed() throws {
        let repo = try makeRepo()
        let book = try repo.bookmark(siteId: "demo", siteBookId: "1", title: "t")
        try repo.replaceCatalog(bookId: book.id, entries: entries(4), now: Date())
        try repo.replaceCatalog(bookId: book.id, entries: entries(5), now: Date())
        // Reading up to chapter 4, which is index 3 — for now.
        try repo.updateProgress(bookId: book.id, position: .chapterStart("4"))
        XCTAssertEqual(try newChapters(of: book.id, in: repo).map(\.siteChapterId), ["5"])

        // The site slots a chapter in between 2 and 3. Every chapter after it moves up
        // one, the reader's own included.
        try repo.replaceCatalog(bookId: book.id, entries: entries(["1", "2", "2b", "3", "4", "5"]))

        XCTAssertEqual(
            try newChapters(of: book.id, in: repo).map(\.siteChapterId), ["5"],
            """
            Only chapter 5 is ahead of the reader. Under a stored index this said 4 and 5:
            the position still read "index 3", which the insertion had turned into
            chapter 3, so the chapter they had just finished came back as news. The
            inserted chapter is not news either — it landed behind them.
            """
        )
        XCTAssertEqual(
            try repo.newChapterCounts()[book.id], 1,
            "and the shelf has to count the same one"
        )
    }

    /// The site *removing* the chapter the reader was in leaves nothing to compare
    /// against, and both statements of the rule have to say the same thing about it:
    /// the reader has no place in this catalog, so every recent chapter is ahead of
    /// them. What neither may do is keep a stale number and answer from it.
    func testACatalogThatDroppedTheReadChapterFallsBackToUnreadOnBothSides() throws
    {
        let repo = try makeRepo()
        let book = try repo.bookmark(siteId: "demo", siteBookId: "1", title: "t")
        try repo.replaceCatalog(bookId: book.id, entries: entries(2), now: Date())
        try repo.replaceCatalog(bookId: book.id, entries: entries(4), now: Date())
        try repo.updateProgress(bookId: book.id, position: .chapterStart("3"))

        try repo.replaceCatalog(bookId: book.id, entries: entries(["1", "2", "4"]))

        let reloaded = try XCTUnwrap(repo.book(id: book.id))
        XCTAssertEqual(
            reloaded.lastReadSiteChapterId, "3",
            "the position is kept: the reader did read that chapter, wherever it went"
        )
        XCTAssertNil(reloaded.lastReadIndex(in: try repo.chapters(bookId: book.id)))
        XCTAssertEqual(try newChapters(of: book.id, in: repo).map(\.siteChapterId), ["4"])
        XCTAssertEqual(try repo.newChapterCounts()[book.id], 1)
    }

    /// The library shelf counts new chapters with one grouped query, which means the rule
    /// is written twice — once in SQL and once in `Chapter.isNew(lastReadIndex:)`, each
    /// resolving the reader's stored chapter to a place in reading order its own way.
    /// This is what catches the two drifting apart.
    func testTheShelfCountAgreesWithThePerRowRule() throws {
        let repo = try makeRepo()
        let read = try repo.bookmark(siteId: "demo", siteBookId: "1", title: "read")
        let untouched = try repo.bookmark(siteId: "demo", siteBookId: "2", title: "untouched")
        let quiet = try repo.bookmark(siteId: "demo", siteBookId: "3", title: "quiet")
        for book in [read, untouched, quiet] {
            try repo.replaceCatalog(bookId: book.id, entries: entries(2), now: Date())
        }
        try repo.replaceCatalog(bookId: read.id, entries: entries(5), now: Date())
        try repo.replaceCatalog(bookId: untouched.id, entries: entries(4), now: Date())
        try repo.updateProgress(bookId: read.id, position: .chapterStart("4"))
        // A fourth book to make the two sides disagree if either mishandles a position
        // that no longer resolves: read, then the site dropped that chapter.
        let orphaned = try repo.bookmark(siteId: "demo", siteBookId: "4", title: "orphaned")
        try repo.replaceCatalog(bookId: orphaned.id, entries: entries(2), now: Date())
        try repo.replaceCatalog(bookId: orphaned.id, entries: entries(4), now: Date())
        try repo.updateProgress(bookId: orphaned.id, position: .chapterStart("3"))
        try repo.replaceCatalog(bookId: orphaned.id, entries: entries(["1", "2", "4"]))

        let counts = try repo.newChapterCounts()

        XCTAssertEqual(counts[read.id], 1, "Only chapter 5 is past the reading position")
        XCTAssertEqual(counts[untouched.id], 2, "Never opened, so both additions still count")
        XCTAssertNil(counts[quiet.id], "A book that gained nothing is absent, not zero")
        XCTAssertEqual(counts[orphaned.id], 1, "No resolvable position, so chapter 4 counts")
        for book in [read, untouched, quiet, orphaned] {
            let byRow = try newChapters(of: book.id, in: repo).count
            XCTAssertEqual(counts[book.id] ?? 0, byRow, "SQL and Swift must agree for \(book.title)")
        }
    }
}
