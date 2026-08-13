import XCTest
@testable import NovelReader

/// Positions the reader saved on purpose, and the rules that keep the list worth
/// opening: no duplicates, book order, and nothing left behind by a deleted book.
final class BookmarkTests: XCTestCase {
    private func makeRepo() throws -> LibraryRepo {
        LibraryRepo(database: try AppDatabase.makeInMemory())
    }

    /// A bookmarked book *with a catalog*, because reading order belongs to the catalog:
    /// a bookmark stores which chapter it is in, and only the chapter rows say what
    /// number that is. A book with nothing indexed has no order for its bookmarks to
    /// come back in — and no way for a reader to have opened a chapter in the first
    /// place.
    private func makeBook(
        _ repo: LibraryRepo, siteId: String = "demo", siteBookId: String = "1", chapters: Int = 10
    ) throws -> Book {
        let book = try repo.bookmark(siteId: siteId, siteBookId: siteBookId, title: "t")
        try repo.replaceCatalog(
            bookId: book.id,
            entries: (1...chapters).map {
                (siteChapterId: "\($0)", title: "第\($0)章", url: "https://demo.test/1/\($0)")
            }
        )
        return book
    }

    private func position(_ siteChapterId: String, _ paragraph: Int, offset: Int = 0) -> ReadingPosition {
        ReadingPosition(
            siteChapterId: siteChapterId,
            anchor: TextAnchor(paragraph: paragraph, characterOffset: offset)
        )
    }

    func testASavedPositionComesBackWithItsAnchorAndExcerpt() throws {
        let repo = try makeRepo()
        let book = try makeBook(repo)

        try repo.addReadingBookmark(
            bookId: book.id, position: position("3", 12), excerpt: "「你還是來了。」"
        )

        let stored = try XCTUnwrap(repo.readingBookmarks(bookId: book.id).first)
        XCTAssertEqual(stored.position, position("3", 12))
        XCTAssertEqual(stored.excerpt, "「你還是來了。」")
    }

    /// The reader's one bookmark button has to be safe to tap on a page that is
    /// already saved. Identity is the position itself, so a second save is the same
    /// row rather than a second entry pointing at the same sentence.
    func testSavingTheSamePositionTwiceKeepsOneBookmark() throws {
        let repo = try makeRepo()
        let book = try makeBook(repo)

        try repo.addReadingBookmark(bookId: book.id, position: position("3", 12), excerpt: "first")
        try repo.addReadingBookmark(bookId: book.id, position: position("3", 12), excerpt: "second")

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
        let book = try makeBook(repo)

        try repo.addReadingBookmark(bookId: book.id, position: position("3", 12, offset: 0))
        try repo.addReadingBookmark(bookId: book.id, position: position("3", 12, offset: 40))

        XCTAssertEqual(try repo.readingBookmarks(bookId: book.id).count, 2)
    }

    /// Reading order, not creation order: the list is used to jump back into the
    /// book, and one that runs the way the book runs is the one a reader can scan.
    func testBookmarksComeBackInReadingOrder() throws {
        let repo = try makeRepo()
        let book = try makeBook(repo)
        let now = Date()

        // Saved out of order on purpose, and with the later chapter saved first.
        try repo.addReadingBookmark(bookId: book.id, position: position("9", 1), now: now)
        try repo.addReadingBookmark(
            bookId: book.id, position: position("2", 30), now: now.addingTimeInterval(60)
        )
        try repo.addReadingBookmark(
            bookId: book.id, position: position("2", 4), now: now.addingTimeInterval(120)
        )

        XCTAssertEqual(
            try repo.readingBookmarks(bookId: book.id).map { "\($0.siteChapterId)/\($0.paragraph)" },
            ["2/4", "2/30", "9/1"]
        )
    }

    func testDeletingABookmarkRemovesOnlyThatOne() throws {
        let repo = try makeRepo()
        let book = try makeBook(repo)
        let kept = try repo.addReadingBookmark(bookId: book.id, position: position("1", 1))
        let doomed = try repo.addReadingBookmark(bookId: book.id, position: position("2", 2))

        try repo.removeReadingBookmark(id: doomed.id)

        XCTAssertEqual(try repo.readingBookmarks(bookId: book.id).map(\.id), [kept.id])
    }

    /// A bookmark into a book that is no longer on the shelf has nowhere to jump, and
    /// a row that outlived its book would come back to life under the same derived id
    /// if the reader ever bookmarked the book again.
    func testRemovingABookTakesItsBookmarksWithIt() throws {
        let repo = try makeRepo()
        let book = try makeBook(repo)
        let other = try makeBook(repo, siteBookId: "2")
        try repo.addReadingBookmark(bookId: book.id, position: position("1", 1))
        try repo.addReadingBookmark(bookId: other.id, position: position("1", 1))

        try repo.removeBookmark(bookId: book.id)

        XCTAssertEqual(try repo.readingBookmarks(bookId: book.id).count, 0)
        XCTAssertEqual(
            try repo.readingBookmarks(bookId: other.id).count, 1,
            "another book's bookmarks are none of this delete's business"
        )
    }

    /// Bookmarks belong to one book. The library groups the same novel bookmarked on
    /// two sites as two books on purpose, and their saved positions cannot be shared:
    /// the chapter ids come from different sites.
    func testBookmarksAreScopedToTheirBook() throws {
        let repo = try makeRepo()
        let alpha = try makeBook(repo, siteId: "alpha")
        let beta = try makeBook(repo, siteId: "beta")
        try repo.addReadingBookmark(bookId: alpha.id, position: position("5", 5))

        XCTAssertEqual(try repo.readingBookmarks(bookId: alpha.id).count, 1)
        XCTAssertEqual(try repo.readingBookmarks(bookId: beta.id).count, 0)
    }
}
