import XCTest
@testable import NovelReader

/// A feed document is a *window*, not an index — it lists the last ten or fifty items and
/// nothing else. Everything here exists because that one fact makes a subscription's
/// catalog behave unlike a novel's, and because getting it wrong is not a cosmetic
/// failure: run through `replaceCatalog`, a reader's archive would be deleted every time
/// the publisher posted, taking the downloaded text, the bookmarks and the highlights
/// with it.
final class FeedCatalogTests: XCTestCase {
    private var database: AppDatabase!
    private var repo: LibraryRepo!

    override func setUpWithError() throws {
        database = try AppDatabase.makeInMemory()
        repo = LibraryRepo(database: database)
    }

    private func subscribe() throws -> Book {
        try repo.bookmark(
            siteId: Book.feedSiteId,
            siteBookId: "https://example.com/feed.xml",
            kind: .feed,
            title: "Example Blog"
        )
    }

    private func entry(
        _ id: String, _ published: String, title: String? = nil
    ) -> (siteChapterId: String, title: String, url: String, publishedAt: Date?) {
        (id, title ?? "Article \(id)", "https://example.com/\(id)", date(published))
    }

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    // MARK: - The window

    /// The whole reason this function exists. An article that has scrolled out of the
    /// feed is not an article the publisher withdrew.
    func testArticlesThatFallOutOfTheFeedStay() throws {
        let book = try subscribe()
        try repo.mergeCatalog(bookId: book.id, entries: [
            entry("a", "2026-09-01T00:00:00Z"),
            entry("b", "2026-09-02T00:00:00Z"),
        ])
        // The next fetch: `a` has aged out of the publisher's window, `c` is new.
        try repo.mergeCatalog(bookId: book.id, entries: [
            entry("b", "2026-09-02T00:00:00Z"),
            entry("c", "2026-09-03T00:00:00Z"),
        ])

        let chapters = try repo.chapters(bookId: book.id)
        XCTAssertEqual(chapters.map(\.siteChapterId), ["a", "b", "c"])
    }

    /// The consequence that matters most: an article the reader downloaded and marked up
    /// keeps its text and its marks when the publisher's window moves past it.
    func testAnArchivedArticleKeepsItsDownloadAndItsMarks() throws {
        let book = try subscribe()
        try repo.mergeCatalog(bookId: book.id, entries: [entry("a", "2026-09-01T00:00:00Z")])
        let stored = try XCTUnwrap(try repo.chapters(bookId: book.id).first)
        try repo.addReadingBookmark(
            bookId: book.id,
            position: ReadingPosition(
                siteChapterId: stored.siteChapterId, anchor: TextAnchor(paragraph: 2, characterOffset: 0)
            )
        )

        try repo.mergeCatalog(bookId: book.id, entries: [entry("b", "2026-09-02T00:00:00Z")])

        XCTAssertEqual(try repo.chapters(bookId: book.id).count, 2)
        XCTAssertEqual(try repo.readingBookmarks(bookId: book.id).count, 1)
    }

    /// Refreshing a feed that has published nothing must be a no-op, not a rewrite. This
    /// is the case that runs every time the app is opened.
    func testRefreshingAnUnchangedFeedChangesNothing() throws {
        let book = try subscribe()
        let entries = [entry("a", "2026-09-01T00:00:00Z"), entry("b", "2026-09-02T00:00:00Z")]
        try repo.mergeCatalog(bookId: book.id, entries: entries)
        let before = try repo.chapters(bookId: book.id)

        try repo.mergeCatalog(bookId: book.id, entries: entries)
        let after = try repo.chapters(bookId: book.id)

        XCTAssertEqual(before.map(\.id), after.map(\.id))
        XCTAssertEqual(before.map(\.index), after.map(\.index))
        XCTAssertEqual(before.map(\.addedAt), after.map(\.addedAt))
    }

    // MARK: - Order

    /// Oldest first, so a subscription behaves like a book that gains chapters: the
    /// reading position, the unread count and "next chapter" are then the ones every
    /// other medium already uses.
    func testReadingOrderIsChronologicalWhateverOrderTheFeedListedThemIn() throws {
        let book = try subscribe()
        // As a feed publishes them: newest first.
        try repo.mergeCatalog(bookId: book.id, entries: [
            entry("newest", "2026-09-03T00:00:00Z"),
            entry("middle", "2026-09-02T00:00:00Z"),
            entry("oldest", "2026-09-01T00:00:00Z"),
        ])

        XCTAssertEqual(
            try repo.chapters(bookId: book.id).map(\.siteChapterId),
            ["oldest", "middle", "newest"]
        )
    }

    /// A backdated article lands in the middle of the numbering, which is the case a
    /// direct write cannot do at all: `chapter_book_index` is unique and checked row by
    /// row, so the number being written is still held by the row that has to move next.
    func testABackdatedArticleIsInsertedIntoTheMiddleOfTheOrder() throws {
        let book = try subscribe()
        try repo.mergeCatalog(bookId: book.id, entries: [
            entry("first", "2026-09-01T00:00:00Z"),
            entry("third", "2026-09-03T00:00:00Z"),
        ])

        try repo.mergeCatalog(bookId: book.id, entries: [entry("second", "2026-09-02T00:00:00Z")])

        let chapters = try repo.chapters(bookId: book.id)
        XCTAssertEqual(chapters.map(\.siteChapterId), ["first", "second", "third"])
        XCTAssertEqual(chapters.map(\.index), [0, 1, 2])
    }

    /// Two articles arriving in one refresh are two inserts, and both need a number no
    /// other row holds before the final ordering is worked out.
    func testTwoNewArticlesInOneRefreshBothLand() throws {
        let book = try subscribe()
        try repo.mergeCatalog(bookId: book.id, entries: [entry("a", "2026-09-01T00:00:00Z")])

        try repo.mergeCatalog(bookId: book.id, entries: [
            entry("b", "2026-09-02T00:00:00Z"),
            entry("c", "2026-09-03T00:00:00Z"),
        ])

        XCTAssertEqual(
            try repo.chapters(bookId: book.id).map(\.siteChapterId), ["a", "b", "c"]
        )
    }

    /// Publishers batch-publish with identical timestamps and reorder freely between two
    /// fetches. `index` is what every mark resolves through, so an order that moved on
    /// refresh would slide the reader's place onto a neighbouring article.
    func testArticlesSharingATimestampKeepAStableOrder() throws {
        let book = try subscribe()
        let sameMoment = "2026-09-01T09:00:00Z"
        try repo.mergeCatalog(bookId: book.id, entries: [
            entry("x", sameMoment), entry("y", sameMoment), entry("z", sameMoment),
        ])
        let first = try repo.chapters(bookId: book.id).map(\.siteChapterId)

        // The same three, listed the other way round.
        try repo.mergeCatalog(bookId: book.id, entries: [
            entry("z", sameMoment), entry("y", sameMoment), entry("x", sameMoment),
        ])

        XCTAssertEqual(try repo.chapters(bookId: book.id).map(\.siteChapterId), first)
    }

    // MARK: - Dates

    /// An undated article holds the moment it first arrived — the only honest thing known
    /// about when it appeared. Re-stamping it on every refresh would march it up the list
    /// forever, which for a feed is the same as scrambling the order.
    func testAnUndatedArticleKeepsTheMomentItFirstArrived() throws {
        let book = try subscribe()
        let arrival = date("2026-09-01T12:00:00Z")
        let undated = (
            siteChapterId: "a", title: "Untimed", url: "https://example.com/a",
            publishedAt: Date?.none
        )
        try repo.mergeCatalog(bookId: book.id, entries: [undated], now: arrival)

        try repo.mergeCatalog(
            bookId: book.id, entries: [undated], now: date("2026-09-09T12:00:00Z")
        )

        XCTAssertEqual(try repo.chapters(bookId: book.id).first?.publishedAt, arrival)
    }

    // MARK: - What is unread

    /// The first fetch of a subscription is unread in full, unlike a novel's first
    /// catalog. Subscribing is the reader asking for these articles, and an app that
    /// answered "nothing to read" while holding twenty of them would be lying about the
    /// one thing a feed is opened for.
    func testTheFirstFetchIsUnreadInFull() throws {
        let book = try subscribe()
        try repo.mergeCatalog(bookId: book.id, entries: [
            entry("a", "2026-09-01T00:00:00Z"), entry("b", "2026-09-02T00:00:00Z"),
        ])

        XCTAssertEqual(try repo.newChapterCount(bookId: book.id), 2)
    }

    /// And the count falls as they read, because the reading position is the only thing
    /// it is made of.
    func testReadingAnArticleTakesItOutOfTheCount() throws {
        let book = try subscribe()
        try repo.mergeCatalog(bookId: book.id, entries: [
            entry("a", "2026-09-01T00:00:00Z"), entry("b", "2026-09-02T00:00:00Z"),
        ])

        try repo.updateProgress(bookId: book.id, position: .chapterStart("a"))

        XCTAssertEqual(try repo.newChapterCount(bookId: book.id), 1)
        XCTAssertEqual(try repo.newChapterCounts()[book.id], 1)
    }

    /// The arrival stamp is written for every article and never rewritten. It no longer
    /// decides the count, but a column that drifted would still be the thing a retention
    /// policy or a future "since you were away" divider reads.
    func testEveryArticleRecordsWhenItFirstArrivedAndKeepsIt() throws {
        let book = try subscribe()
        let subscribed = date("2026-09-01T12:00:00Z")
        try repo.mergeCatalog(
            bookId: book.id, entries: [entry("a", "2026-09-01T00:00:00Z")], now: subscribed
        )

        let later = date("2026-09-02T12:00:00Z")
        try repo.mergeCatalog(bookId: book.id, entries: [
            entry("a", "2026-09-01T00:00:00Z"), entry("b", "2026-09-02T00:00:00Z"),
        ], now: later)

        let chapters = try repo.chapters(bookId: book.id)
        XCTAssertEqual(chapters.first { $0.siteChapterId == "a" }?.addedAt, subscribed)
        XCTAssertEqual(chapters.first { $0.siteChapterId == "b" }?.addedAt, later)
    }

    // MARK: - Fetch state

    func testFetchStateRoundTripsAndIsReplacedRatherThanDuplicated() throws {
        let book = try subscribe()
        try repo.saveFeedFetchState(
            FeedFetchState(bookId: book.id, etag: "\"abc\"", lastModified: nil, checkedAt: nil)
        )
        try repo.saveFeedFetchState(
            FeedFetchState(
                bookId: book.id, etag: "W/\"def\"",
                lastModified: "Wed, 02 Oct 2002 08:00:00 GMT", checkedAt: date("2026-09-03T00:00:00Z")
            )
        )

        let state = try XCTUnwrap(try repo.feedFetchState(bookId: book.id))
        // Verbatim, quotes and weak-validator prefix intact: a server comparing against a
        // tidied-up ETag answers "changed" every single time.
        XCTAssertEqual(state.etag, "W/\"def\"")
        XCTAssertEqual(state.lastModified, "Wed, 02 Oct 2002 08:00:00 GMT")
    }

    /// It describes one device's last request, so it has no business outliving the
    /// subscription it belongs to.
    func testFetchStateGoesWithTheSubscription() throws {
        let book = try subscribe()
        try repo.saveFeedFetchState(FeedFetchState(bookId: book.id, etag: "\"abc\""))
        try repo.removeBookmark(bookId: book.id)

        XCTAssertNil(try repo.feedFetchState(bookId: book.id))
    }
}
