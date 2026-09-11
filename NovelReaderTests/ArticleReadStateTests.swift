import GRDB
import XCTest
@testable import NovelReader

/// What one device tells another about which articles have been read.
///
/// The rules live in `LibraryRepo` rather than in `CloudSync`, which is plumbing around
/// them: a compact payload (the *unread* ids, plus how far the sender's catalog reached)
/// and two ways of applying it. Both halves have a failure mode that is invisible until
/// somebody has two devices, so both are pinned here.
final class ArticleReadStateTests: XCTestCase {
    private let first = Date(timeIntervalSince1970: 1_700_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    private func makeRepo() throws -> LibraryRepo {
        LibraryRepo(database: try AppDatabase.makeInMemory())
    }

    /// A subscription with `ids` articles, published a day apart, oldest first.
    @discardableResult
    private func makeFeed(in repo: LibraryRepo, articles ids: [String]) throws -> Book {
        let feed = try repo.bookmark(
            siteId: Book.feedSiteId, siteBookId: "https://demo.test/feed.xml",
            kind: .feed, title: "feed"
        )
        try repo.mergeCatalog(
            bookId: feed.id,
            entries: ids.enumerated().map { offset, id in
                (
                    siteChapterId: id, title: "Article \(id)",
                    url: "https://demo.test/\(id)",
                    publishedAt: first.addingTimeInterval(Double(offset) * day)
                )
            },
            now: first
        )
        return feed
    }

    // MARK: - What gets published

    /// The unread set, not the read one, and the newest date this device knows about.
    ///
    /// Those two are what the payload is: the read state is the complement of the first
    /// *within* the second, which is what makes it compact enough to sync at all.
    func testWhatIsPublishedIsTheUnreadSetAndTheCatalogsEdge() throws {
        let repo = try makeRepo()
        let feed = try makeFeed(in: repo, articles: ["a", "b", "c"])
        try repo.setArticlesRead(true, bookId: feed.id, siteChapterIds: ["a", "b"])

        XCTAssertEqual(try repo.unreadArticleIds(bookId: feed.id), ["c"])
        XCTAssertEqual(
            try repo.newestArticleDate(bookId: feed.id), first.addingTimeInterval(2 * day)
        )
    }

    func testASubscriptionWithNoArticlesHasNoEdgeToPublish() throws {
        let repo = try makeRepo()
        let feed = try repo.bookmark(
            siteId: Book.feedSiteId, siteBookId: "https://demo.test/feed.xml",
            kind: .feed, title: "feed"
        )
        XCTAssertNil(
            try repo.newestArticleDate(bookId: feed.id),
            "nothing to say, which is what stops the other device applying a cutoff of zero"
        )
    }

    // MARK: - Applying it

    func testARemoteStateMarksEverythingItDidNotCallUnread() throws {
        let repo = try makeRepo()
        let feed = try makeFeed(in: repo, articles: ["a", "b", "c"])

        try repo.applyRemoteReadState(
            bookId: feed.id, unread: ["c"],
            through: first.addingTimeInterval(2 * day), monotonic: false
        )

        XCTAssertEqual(
            try repo.chapters(bookId: feed.id).filter(\.isUnread).map(\.siteChapterId), ["c"]
        )
    }

    /// The cutoff, which is the whole reason a bare list of unread ids is not enough.
    ///
    /// A refresh on this device can easily beat the sync: the other device wrote its list
    /// yesterday, this one fetched two new articles this morning, and neither of those is
    /// on the list — not because they were read, but because they did not exist. Without
    /// the cutoff every refresh that won the race would silently mark its own new articles
    /// read, which is the worst failure this feature has: it hides the thing the reader
    /// subscribed for.
    func testArticlesNewerThanTheSendersCatalogAreLeftAlone() throws {
        let repo = try makeRepo()
        let feed = try makeFeed(in: repo, articles: ["a", "b", "c", "d"])

        // The other device had only seen as far as "b".
        try repo.applyRemoteReadState(
            bookId: feed.id, unread: [],
            through: first.addingTimeInterval(day), monotonic: false
        )

        XCTAssertEqual(
            try repo.chapters(bookId: feed.id).filter(\.isUnread).map(\.siteChapterId),
            ["c", "d"],
            "the two it had never seen stay unread"
        )
    }

    /// A record with no cutoff — one written before this feature existed — applies nothing.
    func testARecordWithNoCutoffChangesNothing() throws {
        let repo = try makeRepo()
        let feed = try makeFeed(in: repo, articles: ["a", "b"])

        try repo.applyRemoteReadState(
            bookId: feed.id, unread: [], through: nil, monotonic: false
        )

        XCTAssertEqual(try repo.newChapterCount(bookId: feed.id), 2)
    }

    /// The two directions, and why there are two.
    ///
    /// On the sync's own path a record that won last-writer-wins may say both things: an
    /// article it calls unread was put back to unread on the other device more recently
    /// than anything here. On the "fill in what arrived late" path — a new device whose
    /// books synced before its articles were fetched — the same record is old news, and
    /// must only be allowed to recover read state, never to reach forward over a mark made
    /// here since.
    func testOnlyTheSyncsOwnPathMayPutAnArticleBackToUnread() throws {
        let repo = try makeRepo()
        let feed = try makeFeed(in: repo, articles: ["a", "b"])
        try repo.markAllRead(bookId: feed.id)
        let through = first.addingTimeInterval(day)

        try repo.applyRemoteReadState(
            bookId: feed.id, unread: ["a"], through: through, monotonic: true
        )
        XCTAssertEqual(
            try repo.newChapterCount(bookId: feed.id), 0,
            "a late fill-in cannot un-read what this device has read"
        )

        try repo.applyRemoteReadState(
            bookId: feed.id, unread: ["a"], through: through, monotonic: false
        )
        XCTAssertEqual(
            try repo.chapters(bookId: feed.id).filter(\.isUnread).map(\.siteChapterId), ["a"],
            "the sync's own path is an arbitration, and this record won it"
        )
    }

    /// Re-confirming a read article does not restamp it: `readAt` records when *this*
    /// device read the piece, which is a truer answer than the moment a sync arrived.
    func testReconfirmingAReadArticleKeepsItsOriginalStamp() throws {
        let repo = try makeRepo()
        let feed = try makeFeed(in: repo, articles: ["a"])
        let readAt = Date(timeIntervalSince1970: 1_600_000_000)
        try repo.setArticlesRead(true, bookId: feed.id, siteChapterIds: ["a"], now: readAt)

        try repo.applyRemoteReadState(
            bookId: feed.id, unread: [], through: first, monotonic: false, now: Date()
        )

        let stored = try XCTUnwrap(repo.chapters(bookId: feed.id).first)
        XCTAssertEqual(stored.readAt, readAt)
    }
}
