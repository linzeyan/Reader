import GRDB
import XCTest
@testable import NovelReader

/// What a stored reading position means, and what it has to survive.
///
/// The point of anchoring to paragraph coordinates is that the position keeps
/// naming the same sentence when the reader changes how the page looks — and keeps
/// naming it when the text engine underneath is replaced. A position stored as a
/// scroll distance passes no test here at all, which is why the migration exists.
final class ReadingPositionTests: XCTestCase {
    // MARK: - Anchors are text coordinates, not layout ones

    /// The invariant the whole design exists for: type size, line spacing and theme
    /// move every sentence on screen, and none of them may move what the stored
    /// position points at.
    func testAnAnchorNamesTheSameParagraphAtEveryTypeSize() throws {
        let paragraphs = ["雪停了。", "他推開門，看見渡口的燈。", "「你還是來了。」"]
        let anchor = TextAnchor(paragraph: 1, characterOffset: 0)
        // A private suite so exercising the appearance settings cannot leave the
        // simulator's real defaults changed.
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ReadingPositionTests"))
        defer { defaults.removePersistentDomain(forName: "ReadingPositionTests") }
        let settings = ReaderSettings(defaults: defaults)

        for size in [ReaderSettings.fontSizeRange.lowerBound, 19, ReaderSettings.fontSizeRange.upperBound] {
            settings.fontSize = size
            settings.lineSpacing = size / 2
            settings.theme = size > 20 ? .night : .paper
            XCTAssertEqual(
                anchor.excerpt(in: paragraphs), paragraphs[1],
                "the anchor must still name the same paragraph at size \(size)"
            )
            XCTAssertEqual(
                anchor.scrollID(chapterId: "book|1"), "book|1#1",
                "and must still resolve to the same scroll destination"
            )
        }
    }

    /// The first paragraph resolves to the chapter, not to the paragraph, so a
    /// chapter opened from the catalog shows its own heading. Landing below the title
    /// reads as having jumped to the wrong place.
    func testTheStartOfAChapterScrollsToItsHeading() {
        XCTAssertEqual(TextAnchor.start.scrollID(chapterId: "book|3"), "book|3")
    }

    /// The reader's paragraph ids and the scroll target derived from an anchor come
    /// from one function precisely so that this holds; if they drifted apart, jumps
    /// would silently do nothing.
    func testAParagraphIdMatchesTheAnchorThatTargetsIt() {
        let anchor = TextAnchor(paragraph: 12, characterOffset: 0)
        XCTAssertEqual(
            anchor.scrollID(chapterId: "book|3"),
            TextAnchor.paragraphID(chapterId: "book|3", paragraph: 12)
        )
    }

    /// An anchor can outlive the paragraph it named — a chapter re-fetched from the
    /// site can come back shorter. Nothing may claim an excerpt it cannot read.
    func testAnAnchorPastTheEndOfTheTextHasNoExcerpt() {
        XCTAssertNil(TextAnchor(paragraph: 9, characterOffset: 0).excerpt(in: ["one", "two"]))
    }

    /// The excerpt exists to be recognised in a list, so a long paragraph is cut
    /// with a visible mark rather than silently truncated.
    func testALongParagraphIsTrimmedForTheList() throws {
        let long = String(repeating: "字", count: 200)
        let excerpt = try XCTUnwrap(TextAnchor.start.excerpt(in: [long], limit: 10))
        XCTAssertEqual(excerpt, String(repeating: "字", count: 10) + "…")
    }

    // MARK: - How far into the chapter

    /// The share exists because "chapter 12" is not an answer to "how far in are you".
    /// It is measured in the unit the offset is already stored in, so a reader who
    /// changes type size mid-chapter does not watch their progress move.
    func testTheShareCountsTheTextBeforeTheAnchor() {
        // Ten UTF-16 units per paragraph, so the arithmetic is checkable by eye.
        let paragraphs = [String(repeating: "字", count: 10), String(repeating: "字", count: 10)]
        XCTAssertEqual(TextAnchor.start.fraction(in: paragraphs), 0)
        XCTAssertEqual(TextAnchor(paragraph: 1, characterOffset: 0).fraction(in: paragraphs), 0.5)
        XCTAssertEqual(TextAnchor(paragraph: 1, characterOffset: 5).fraction(in: paragraphs), 0.75)
    }

    /// A chapter with nothing in it divides by zero if this is got wrong, and a chapter
    /// that failed to extract is exactly the case that reaches the reader.
    func testAnEmptyChapterIsNoShareRatherThanACrash() {
        XCTAssertEqual(TextAnchor.start.fraction(in: []), 0)
        XCTAssertEqual(TextAnchor(paragraph: 3, characterOffset: 8).fraction(in: ["", ""]), 0)
    }

    /// The same case `landingAnchor` clamps for: a chapter refetched from the site can
    /// come back shorter than when the position was written. An anchor past its end has
    /// read all of it — the one thing it must not report is more than all of it.
    func testAnAnchorPastTheEndOfTheChapterReadsAsAllOfIt() {
        let paragraphs = ["一二三四五", "六七八九十"]
        XCTAssertEqual(TextAnchor(paragraph: 9, characterOffset: 0).fraction(in: paragraphs), 1)
        XCTAssertEqual(
            TextAnchor(paragraph: 1, characterOffset: 999).fraction(in: paragraphs), 1,
            "an offset past the paragraph is clamped to its end, not counted whole"
        )
    }

    // MARK: - Round trip

    func testAPositionSurvivesBeingStoredAndReadBack() throws {
        let repo = LibraryRepo(database: try AppDatabase.makeInMemory())
        let book = try repo.bookmark(siteId: "demo", siteBookId: "1", title: "t")
        XCTAssertNil(book.readingPosition, "a book nobody has opened has no position")

        let position = ReadingPosition(
            siteChapterId: "c4", anchor: TextAnchor(paragraph: 17, characterOffset: 23)
        )
        try repo.updateProgress(bookId: book.id, position: position, fraction: 0.42)

        let stored = try XCTUnwrap(repo.book(id: book.id))
        XCTAssertEqual(stored.readingPosition, position)
        XCTAssertEqual(stored.lastReadFraction, 0.42)
    }

    /// The share belongs to the position it was measured with. A caller that has no text
    /// to measure against — an incoming iCloud record from a device that read further —
    /// must not leave the previous chapter's share sitting under the new chapter.
    func testAPositionWrittenWithoutAShareClearsTheOldOne() throws {
        let repo = LibraryRepo(database: try AppDatabase.makeInMemory())
        let book = try repo.bookmark(siteId: "demo", siteBookId: "1", title: "t")
        try repo.updateProgress(bookId: book.id, position: .chapterStart("c1"), fraction: 0.9)

        try repo.updateProgress(bookId: book.id, position: .chapterStart("c2"))

        XCTAssertNil(try XCTUnwrap(repo.book(id: book.id)).lastReadFraction)
    }

    // MARK: - Migration

    /// `lastReadOffset` was already a paragraph index — the scroll view recorded
    /// which paragraph came into view — so v4 carries it across under its real name.
    /// Resetting it would have thrown away a position the app genuinely knew and put
    /// every reader back at the top of the chapter they were in.
    func testMigrationKeepsTheParagraphTheOldColumnHeld() throws {
        let queue = try storeAtV3(lastReadChapterIndex: 7, lastReadOffset: 42)
        try AppDatabase.migrator.migrate(queue)

        let book = try XCTUnwrap(LibraryRepo(database: try AppDatabase(queue)).book(id: "demo|1"))
        XCTAssertEqual(book.lastReadParagraph, 42)
        XCTAssertEqual(
            book.readingPosition,
            ReadingPosition(siteChapterId: "c7", anchor: TextAnchor(paragraph: 42, characterOffset: 0))
        )
    }

    /// v6's backfill for the reading position: the index it held named a chapter in the
    /// catalog as it stood, and that chapter's own id is the only honest conversion of
    /// it. The number itself cannot be carried over — it is exactly what the site's next
    /// insertion invalidates, which is why it is going.
    func testMigrationConvertsTheStoredIndexToTheChapterItNamed() throws {
        let queue = try storeAtV3(lastReadChapterIndex: 7, lastReadOffset: 42)
        try AppDatabase.migrator.migrate(queue)

        let book = try XCTUnwrap(LibraryRepo(database: try AppDatabase(queue)).book(id: "demo|1"))
        XCTAssertEqual(
            book.lastReadSiteChapterId, "c7",
            "the id of the chapter that was at index 7, not the number 7"
        )
    }

    /// A position whose index names no chapter cannot be converted at all: there is no
    /// id to write, so the book comes out unopened rather than claiming whichever
    /// chapter later lands on that number. The paragraph goes with it — a paragraph
    /// under no chapter is half a position, and half a position is worse than none.
    func testMigrationLeavesAPositionWithNoChapterToNameUnread() throws {
        let queue = try storeAtV3(lastReadChapterIndex: 7, lastReadOffset: 42, chapters: 3)
        try AppDatabase.migrator.migrate(queue)

        let book = try XCTUnwrap(LibraryRepo(database: try AppDatabase(queue)).book(id: "demo|1"))
        XCTAssertNil(book.lastReadSiteChapterId)
        XCTAssertNil(book.readingPosition)
        XCTAssertNil(book.lastReadParagraph)
    }

    /// The index column is dropped rather than kept beside the id, for the same reason
    /// v4 dropped `lastReadOffset`: two answers to "which chapter" is how the two of them
    /// come to disagree, and the number is the one that goes stale on its own.
    func testTheChapterIndexColumnIsGone() throws {
        let queue = try storeAtV3(lastReadChapterIndex: 7, lastReadOffset: 42)
        try AppDatabase.migrator.migrate(queue)

        let columns = try queue.read { db in try db.columns(in: "book").map(\.name) }
        XCTAssertFalse(columns.contains("lastReadChapterIndex"))
        XCTAssertTrue(columns.contains("lastReadSiteChapterId"))
    }

    /// Nothing ever recorded a character offset, so the migration invents none: the
    /// column stays null and reads as the start of the paragraph. A plausible-looking
    /// number here would be a claim about text nobody measured.
    func testMigrationInventsNoCharacterOffset() throws {
        let queue = try storeAtV3(lastReadChapterIndex: 7, lastReadOffset: 42)
        try AppDatabase.migrator.migrate(queue)

        let stored = try queue.read { db in
            try Int.fetchOne(db, sql: #"SELECT "lastReadCharacterOffset" FROM "book""#)
        }
        XCTAssertNil(stored, "no offset was ever measured, so none may be written")
    }

    /// A book nobody had opened must not come out of the migration looking read: the
    /// stored position is what the shelf's "new chapters" badge and its recently-read
    /// sort both gate on.
    func testMigrationLeavesAnUnreadBookUnread() throws {
        let queue = try storeAtV3(lastReadChapterIndex: nil, lastReadOffset: nil)
        try AppDatabase.migrator.migrate(queue)

        let book = try XCTUnwrap(LibraryRepo(database: try AppDatabase(queue)).book(id: "demo|1"))
        XCTAssertNil(book.readingPosition)
        XCTAssertNil(book.lastReadSiteChapterId)
        XCTAssertNil(book.lastReadParagraph)
    }

    /// The old column is dropped, not left alongside the new one. Two columns for one
    /// number is how the two of them end up disagreeing about where the reader is.
    func testTheOldOffsetColumnIsGone() throws {
        let queue = try storeAtV3(lastReadChapterIndex: 7, lastReadOffset: 42)
        try AppDatabase.migrator.migrate(queue)

        let columns = try queue.read { db in try db.columns(in: "book").map(\.name) }
        XCTAssertFalse(columns.contains("lastReadOffset"))
        XCTAssertTrue(columns.contains("lastReadParagraph"))
        XCTAssertTrue(columns.contains("lastReadCharacterOffset"))
    }

    /// v7 adds the share, and adds it empty. Working it out needs the chapter's text,
    /// which for a book read online is on no device at all — so a number here would be
    /// invented, and an invented one would be shown to the reader as fact.
    func testMigrationInventsNoShareForPositionsItAlreadyHad() throws {
        let queue = try storeAtV3(lastReadChapterIndex: 7, lastReadOffset: 42)
        try AppDatabase.migrator.migrate(queue)

        let book = try XCTUnwrap(LibraryRepo(database: try AppDatabase(queue)).book(id: "demo|1"))
        XCTAssertEqual(book.lastReadParagraph, 42, "the position itself is still there")
        XCTAssertNil(book.lastReadFraction, "and it says nothing it cannot know")
    }

    /// A database as it stood before v4, written through raw SQL: the point is to
    /// migrate rows shaped the way the shipped app shaped them, which the current
    /// `Book` type can no longer express.
    ///
    /// - Parameter chapters: how many chapters the book has indexed, with ids that are
    ///   deliberately not the numbers they sit at. v6 resolves the stored index against
    ///   them, so a fixture that stops short of it is a position that cannot be
    ///   converted — a case worth writing on purpose rather than avoiding.
    private func storeAtV3(
        lastReadChapterIndex: Int?, lastReadOffset: Int?, chapters: Int = 10
    ) throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v3.chapterAddedAt")
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO "book"
                    ("id", "siteId", "siteBookId", "title", "addedAt", "updatedAt",
                     "lastReadChapterIndex", "lastReadOffset")
                    VALUES ('demo|1', 'demo', '1', 't', '2024-01-01', '2024-01-01', ?, ?)
                    """,
                arguments: [lastReadChapterIndex, lastReadOffset]
            )
            for index in 0..<chapters {
                try db.execute(
                    sql: """
                        INSERT INTO "chapter"
                        ("id", "bookId", "siteChapterId", "index", "title", "url")
                        VALUES (?, 'demo|1', ?, ?, '第\(index + 1)章', 'https://demo.test/1/\(index)')
                        """,
                    arguments: ["demo|1|c\(index)", "c\(index)", index]
                )
            }
        }
        return queue
    }
}
