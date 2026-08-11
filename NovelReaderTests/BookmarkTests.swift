import XCTest
@testable import NovelReader

/// Positions the reader saved on purpose, and the rules that keep the list worth
/// opening: no duplicates, book order, and nothing left behind by a deleted book.
final class BookmarkTests: XCTestCase {
    private func makeRepo() throws -> LibraryRepo {
        LibraryRepo(database: try AppDatabase.makeInMemory())
    }

    private func position(_ chapter: Int, _ paragraph: Int, offset: Int = 0) -> ReadingPosition {
        ReadingPosition(
            chapterIndex: chapter, anchor: TextAnchor(paragraph: paragraph, characterOffset: offset)
        )
    }

    func testASavedPositionComesBackWithItsAnchorAndExcerpt() throws {
        let repo = try makeRepo()
        let book = try repo.bookmark(siteId: "demo", siteBookId: "1", title: "t")

        try repo.addReadingBookmark(
            bookId: book.id, position: position(3, 12), excerpt: "「你還是來了。」"
        )

        let stored = try XCTUnwrap(repo.readingBookmarks(bookId: book.id).first)
        XCTAssertEqual(stored.position, position(3, 12))
        XCTAssertEqual(stored.excerpt, "「你還是來了。」")
    }

    /// The reader's one bookmark button has to be safe to tap on a page that is
    /// already saved. Identity is the position itself, so a second save is the same
    /// row rather than a second entry pointing at the same sentence.
    func testSavingTheSamePositionTwiceKeepsOneBookmark() throws {
        let repo = try makeRepo()
        let book = try repo.bookmark(siteId: "demo", siteBookId: "1", title: "t")

        try repo.addReadingBookmark(bookId: book.id, position: position(3, 12), excerpt: "first")
        try repo.addReadingBookmark(bookId: book.id, position: position(3, 12), excerpt: "second")

        let stored = try repo.readingBookmarks(bookId: book.id)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(
            stored.first?.excerpt, "first",
            "the excerpt recorded the text as the reader saw it and must not be overwritten"
        )
    }

    /// Two positions in the same paragraph are two places once character offsets
    /// exist — which is what the offset is in the identity for.
    func testPositionsInTheSameParagraphAreDifferentBookmarks() throws {
        let repo = try makeRepo()
        let book = try repo.bookmark(siteId: "demo", siteBookId: "1", title: "t")

        try repo.addReadingBookmark(bookId: book.id, position: position(3, 12, offset: 0))
        try repo.addReadingBookmark(bookId: book.id, position: position(3, 12, offset: 40))

        XCTAssertEqual(try repo.readingBookmarks(bookId: book.id).count, 2)
    }

    /// Reading order, not creation order: the list is used to jump back into the
    /// book, and one that runs the way the book runs is the one a reader can scan.
    func testBookmarksComeBackInReadingOrder() throws {
        let repo = try makeRepo()
        let book = try repo.bookmark(siteId: "demo", siteBookId: "1", title: "t")
        let now = Date()

        // Saved out of order on purpose, and with the later chapter saved first.
        try repo.addReadingBookmark(bookId: book.id, position: position(9, 1), now: now)
        try repo.addReadingBookmark(
            bookId: book.id, position: position(2, 30), now: now.addingTimeInterval(60)
        )
        try repo.addReadingBookmark(
            bookId: book.id, position: position(2, 4), now: now.addingTimeInterval(120)
        )

        XCTAssertEqual(
            try repo.readingBookmarks(bookId: book.id).map { ($0.chapterIndex, $0.paragraph) }
                .map { "\($0.0)/\($0.1)" },
            ["2/4", "2/30", "9/1"]
        )
    }

    func testDeletingABookmarkRemovesOnlyThatOne() throws {
        let repo = try makeRepo()
        let book = try repo.bookmark(siteId: "demo", siteBookId: "1", title: "t")
        let kept = try repo.addReadingBookmark(bookId: book.id, position: position(1, 1))
        let doomed = try repo.addReadingBookmark(bookId: book.id, position: position(2, 2))

        try repo.removeReadingBookmark(id: doomed.id)

        XCTAssertEqual(try repo.readingBookmarks(bookId: book.id).map(\.id), [kept.id])
    }

    /// A bookmark into a book that is no longer on the shelf has nowhere to jump, and
    /// a row that outlived its book would come back to life under the same derived id
    /// if the reader ever bookmarked the book again.
    func testRemovingABookTakesItsBookmarksWithIt() throws {
        let repo = try makeRepo()
        let book = try repo.bookmark(siteId: "demo", siteBookId: "1", title: "t")
        let other = try repo.bookmark(siteId: "demo", siteBookId: "2", title: "other")
        try repo.addReadingBookmark(bookId: book.id, position: position(1, 1))
        try repo.addReadingBookmark(bookId: other.id, position: position(1, 1))

        try repo.removeBookmark(bookId: book.id)

        XCTAssertEqual(try repo.readingBookmarks(bookId: book.id).count, 0)
        XCTAssertEqual(
            try repo.readingBookmarks(bookId: other.id).count, 1,
            "another book's bookmarks are none of this delete's business"
        )
    }

    /// Bookmarks belong to one book. The library groups the same novel bookmarked on
    /// two sites as two books on purpose, and their saved positions cannot be shared:
    /// the chapter indexes come from different catalogs.
    func testBookmarksAreScopedToTheirBook() throws {
        let repo = try makeRepo()
        let alpha = try repo.bookmark(siteId: "alpha", siteBookId: "1", title: "t")
        let beta = try repo.bookmark(siteId: "beta", siteBookId: "1", title: "t")
        try repo.addReadingBookmark(bookId: alpha.id, position: position(5, 5))

        XCTAssertEqual(try repo.readingBookmarks(bookId: alpha.id).count, 1)
        XCTAssertEqual(try repo.readingBookmarks(bookId: beta.id).count, 0)
    }
}
