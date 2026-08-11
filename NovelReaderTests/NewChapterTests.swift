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

    private func entries(_ count: Int) -> [(siteChapterId: String, title: String, url: String)] {
        (1...count).map { (siteChapterId: "\($0)", title: "chapter \($0)", url: "https://demo.test/1/\($0)") }
    }

    private func chapter(_ siteChapterId: String, of repo: LibraryRepo, bookId: String) throws -> Chapter {
        let chapters = try repo.chapters(bookId: bookId)
        return try XCTUnwrap(chapters.first { $0.siteChapterId == siteChapterId })
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
        XCTAssertFalse(stored.isNew(in: try XCTUnwrap(book)))
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
        let reloaded = try XCTUnwrap(repo.book(id: book.id))
        XCTAssertTrue(chapters.allSatisfy { !$0.isNew(in: reloaded) })
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
        XCTAssertTrue(added.isNew(in: try XCTUnwrap(repo.book(id: book.id)), now: second))
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

        let reloaded = try XCTUnwrap(repo.book(id: book.id))
        let added = try chapter("3", of: repo, bookId: book.id)
        let inTime = appeared.addingTimeInterval(day - 60)
        let tooLate = appeared.addingTimeInterval(day + 60)

        XCTAssertTrue(added.isNew(in: reloaded, now: inTime))
        XCTAssertFalse(added.isNew(in: reloaded, now: tooLate))
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

    // MARK: - Display rule

    /// Reading past a chapter is what dismisses its marker — no flag is cleared
    /// in the database, so this has to hold as a pure function of the two rows.
    func testAChapterTheReaderHasPassedIsNoLongerNew() throws {
        let repo = try makeRepo()
        let book = try repo.bookmark(siteId: "demo", siteBookId: "1", title: "t")
        try repo.replaceCatalog(bookId: book.id, entries: entries(2), now: Date())
        try repo.replaceCatalog(bookId: book.id, entries: entries(4), now: Date())
        try repo.updateProgress(bookId: book.id, position: .chapterStart(2))
        let reloaded = try XCTUnwrap(repo.book(id: book.id))

        let chapters = try repo.chapters(bookId: book.id)
        // Chapters 3 and 4 (indexes 2 and 3) are the new ones; the reader is on
        // index 2, so only index 3 is still ahead of them.
        XCTAssertEqual(chapters.filter { $0.isNew(in: reloaded) }.map(\.index), [3])
    }

    /// The library shelf counts new chapters with one grouped query, which means
    /// the rule is written twice — once in SQL and once in `Chapter.isNew(in:)`.
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
        try repo.updateProgress(bookId: read.id, position: .chapterStart(3))

        let counts = try repo.newChapterCounts()

        XCTAssertEqual(counts[read.id], 1, "Only chapter 5 is past the reading position")
        XCTAssertEqual(counts[untouched.id], 2, "Never opened, so both additions still count")
        XCTAssertNil(counts[quiet.id], "A book that gained nothing is absent, not zero")
        for book in [read, untouched, quiet] {
            let reloaded = try XCTUnwrap(repo.book(id: book.id))
            let byRow = try repo.chapters(bookId: book.id).filter { $0.isNew(in: reloaded) }.count
            XCTAssertEqual(counts[book.id] ?? 0, byRow, "SQL and Swift must agree for \(book.title)")
        }
    }
}
