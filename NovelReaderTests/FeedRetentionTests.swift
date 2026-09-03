import XCTest
@testable import NovelReader

/// What a subscription throws away, and — mostly — what it refuses to.
///
/// Every case below is a way the obvious implementation ("keep the newest ten") destroys
/// something the reader would not get back: their place in the feed, an article they
/// marked, or an article that comes straight back and is announced as new for ever. The
/// rules are pure, so they are pinned here without a database.
final class FeedRetentionTests: XCTestCase {
    private let day: TimeInterval = 24 * 60 * 60
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func policy(
        keep: Int = 3, graceDays: Double = 7, unreadDays: Double? = 30
    ) -> FeedRetention.Policy {
        FeedRetention.Policy(
            keepCount: keep,
            grace: graceDays * day,
            unreadRetention: unreadDays.map { $0 * day }
        )
    }

    /// A catalog of `count` articles, oldest first, each `daysOld` older than the last and
    /// all of them well past any grace period.
    private func articles(_ count: Int, oldestDaysAgo: Double = 400) -> [Chapter] {
        (0..<count).map { index in
            let age = (oldestDaysAgo - Double(index)) * day
            return Chapter(
                id: "feed|1|\(index)", bookId: "feed|1", siteChapterId: "\(index)",
                index: index, title: "Article \(index)",
                url: "https://example.com/\(index)",
                addedAt: now.addingTimeInterval(-age),
                publishedAt: now.addingTimeInterval(-age),
                downloadedAt: now.addingTimeInterval(-age)
            )
        }
    }

    private func purgeable(
        _ chapters: [Chapter],
        lastReadIndex: Int? = nil,
        marked: Set<String> = [],
        // Defaults to "the publisher lists nothing this old any more", which is the state
        // every article below is in: an archive the feed document has moved past. The
        // cases where that is *not* true have a test of their own.
        stillPublished: Date? = nil,
        policy: FeedRetention.Policy? = nil
    ) -> [String] {
        FeedRetention.purgeable(
            from: chapters, lastReadIndex: lastReadIndex, marked: marked,
            stillPublished: stillPublished ?? now, policy: policy ?? self.policy(), now: now
        ).map(\.siteChapterId)
    }

    // MARK: - The limit

    /// The feature itself: a subscription read for a year is thousands of articles of text
    /// on disk, and the newest few are the ones anyone opens.
    func testOnlyArticlesPastTheLimitGo() {
        // Everything read, so the unread clock is not what is being measured here.
        XCTAssertEqual(purgeable(articles(6), lastReadIndex: 5), ["0", "1", "2"])
    }

    func testAFeedInsideItsLimitLosesNothing() {
        XCTAssertTrue(purgeable(articles(3), lastReadIndex: 2).isEmpty)
    }

    /// Off is a setting the reader must be able to choose, and it has to mean *nothing*.
    func testKeepingEverythingDeletesNothing() {
        XCTAssertTrue(
            purgeable(articles(500), lastReadIndex: 499, policy: policy(keep: 0)).isEmpty
        )
    }

    // MARK: - The grace period

    /// Nothing is deleted the moment it falls over the line. A reader who opens the app,
    /// finds forty unread and works through six of them over a week has to find the rest
    /// where they left them.
    func testAnArticleOverTheLimitIsLeftAloneUntilTheGracePeriodHasPassed() {
        // Everything arrived in the last three days, under a seven-day grace period.
        let recent = articles(6, oldestDaysAgo: 3)

        XCTAssertTrue(purgeable(recent, lastReadIndex: 5).isEmpty)
        XCTAssertEqual(
            purgeable(recent, lastReadIndex: 5, policy: policy(graceDays: 1)),
            ["0", "1", "2"],
            "and a shorter grace period is the reader saying they meant it"
        )
    }

    // MARK: - Unread

    /// The reader has not had their turn with these yet, so they get a clock of their own.
    func testUnreadArticlesAreKeptLongerThanReadOnes() {
        // Read up to index 1; 2 and 3 are unread, and everything is 40 days old.
        let catalog = articles(6, oldestDaysAgo: 45)

        XCTAssertEqual(
            purgeable(catalog, lastReadIndex: 1, policy: policy(unreadDays: 90)),
            ["0"],
            """
            only the read article goes — 1 is the reader's own position and the rest are \
            unread, inside their own 90 days
            """
        )
        XCTAssertEqual(
            purgeable(catalog, lastReadIndex: 1, policy: policy(unreadDays: 30)),
            ["0", "2"],
            "past their own clock, unread articles are surplus like any other"
        )
    }

    /// For the reader whose subscriptions are a list of things they still mean to read.
    func testUnreadArticlesCanBeKeptForever() {
        XCTAssertTrue(
            purgeable(articles(60), lastReadIndex: nil, policy: policy(unreadDays: nil)).isEmpty,
            "a feed nobody has opened is entirely unread"
        )
    }

    // MARK: - What is never deleted

    /// Deleting the article the reader is standing in leaves their stored position naming
    /// something that no longer exists — which every count and every "next chapter"
    /// resolves through. The unread badge would go from four to four hundred.
    func testTheArticleTheReaderIsInIsNeverDeleted() {
        XCTAssertEqual(purgeable(articles(6), lastReadIndex: 1), ["0", "2"])
    }

    /// A bookmark or a highlight is the one unambiguous statement a reader makes about an
    /// article being worth keeping — and the marks cascade away with the row.
    func testMarkedArticlesAreNeverDeleted() {
        XCTAssertEqual(purgeable(articles(6), lastReadIndex: 5, marked: ["1"]), ["0", "2"])
    }

    /// The trap that makes a naive limit worse than no limit at all: a feed document is a
    /// window, so an article deleted while the publisher still lists it is fetched again
    /// on the next refresh, marked unread again, and deleted again — every launch, for
    /// ever. A limit smaller than the feed's own window is "keep at least this many".
    func testArticlesThePublisherStillListsAreNeverDeleted() {
        let catalog = articles(6)
        // The publisher's document still carries everything from article 1 onwards.
        let windowFloor = try? XCTUnwrap(catalog[1].publishedAt)

        XCTAssertEqual(
            purgeable(catalog, lastReadIndex: 5, stillPublished: windowFloor), ["0"]
        )
    }

    /// And a feed this device has never successfully parsed has no window to compare
    /// against. Nothing is deleted, which is the safe direction to be wrong in: a feed
    /// whose host has gone is exactly the one whose articles exist nowhere else, and it
    /// is the one a rule that guessed would empty a launch at a time.
    func testNothingIsDeletedWhileTheWindowIsUnknown() {
        XCTAssertTrue(
            FeedRetention.purgeable(
                from: articles(60), lastReadIndex: 59, marked: [],
                stillPublished: nil, policy: policy(), now: now
            ).isEmpty
        )
    }
}
