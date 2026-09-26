import GRDB
import XCTest
@testable import NovelReader

/// What one device tells another about how far a subscription has been read.
///
/// The rules live in `LibraryRepo` rather than in `CloudSync`, which is plumbing around
/// them: one date, the newest article read, and one way of applying it. Both halves have a
/// failure mode that is invisible until somebody has two devices, so both are pinned here.
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

    /// The newest article read, not the latest one opened: reading an older piece after a
    /// newer one does not move the other device backwards.
    func testWhatIsPublishedIsWhenTheNewestReadArticleCameOut() throws {
        let repo = try makeRepo()
        let feed = try makeFeed(in: repo, articles: ["a", "b", "c"])
        try repo.setArticlesRead(true, bookId: feed.id, siteChapterIds: ["b"])
        try repo.setArticlesRead(true, bookId: feed.id, siteChapterIds: ["a"])

        XCTAssertEqual(try repo.newestReadArticleDate(bookId: feed.id), first.addingTimeInterval(day))
    }

    func testASubscriptionWithNothingReadHasNothingToPublish() throws {
        let repo = try makeRepo()
        let feed = try makeFeed(in: repo, articles: ["a", "b"])
        XCTAssertNil(
            try repo.newestReadArticleDate(bookId: feed.id),
            "nothing to say, which is what stops the other device marking anything read"
        )
    }

    // MARK: - Applying it

    /// An article skipped past on the other device counts as read here. That is the bargain
    /// that lets one date stand for a whole feed's read state, and the reason there is no
    /// list of ids to grow with it.
    func testEverythingUpToTheDateIsRead() throws {
        let repo = try makeRepo()
        let feed = try makeFeed(in: repo, articles: ["a", "b", "c"])

        try repo.markReadThrough(bookId: feed.id, through: first.addingTimeInterval(day))

        XCTAssertEqual(
            try repo.chapters(bookId: feed.id).filter(\.isUnread).map(\.siteChapterId), ["c"]
        )
    }

    /// Newer articles are left alone, which is the worst failure this could have: a refresh
    /// here can easily beat the sync, and marking what it brought in read would hide the
    /// thing the reader subscribed for.
    func testArticlesNewerThanTheDateStayUnread() throws {
        let repo = try makeRepo()
        let feed = try makeFeed(in: repo, articles: ["a", "b", "c", "d"])

        try repo.markReadThrough(bookId: feed.id, through: first)

        XCTAssertEqual(
            try repo.chapters(bookId: feed.id).filter(\.isUnread).map(\.siteChapterId),
            ["b", "c", "d"]
        )
    }

    /// Re-confirming a read article does not restamp it: `readAt` records when *this*
    /// device read the piece, which is a truer answer than the moment a sync arrived.
    func testReconfirmingAReadArticleKeepsItsOriginalStamp() throws {
        let repo = try makeRepo()
        let feed = try makeFeed(in: repo, articles: ["a"])
        let readAt = Date(timeIntervalSince1970: 1_600_000_000)
        try repo.setArticlesRead(true, bookId: feed.id, siteChapterIds: ["a"], now: readAt)

        try repo.markReadThrough(bookId: feed.id, through: first, now: Date())

        let stored = try XCTUnwrap(repo.chapters(bookId: feed.id).first)
        XCTAssertEqual(stored.readAt, readAt)
    }
}
