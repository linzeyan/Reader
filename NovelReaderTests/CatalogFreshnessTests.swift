import XCTest
@testable import NovelReader

/// When the app is allowed to reuse a stored chapter index instead of asking
/// the site again.
///
/// Getting this wrong is quietly expensive in both directions: too eager and
/// every book opening becomes a page load on a WAF-protected host, too lazy and
/// a daily reader keeps hitting an end of the book that is not the end.
final class CatalogFreshnessTests: XCTestCase {
    private func makeBook(catalogUpdatedAt: Date?) -> Book {
        Book(
            id: "demo|1", siteId: "demo", siteBookId: "1", title: "t", displayName: nil,
            author: nil, coverURL: nil, addedAt: Date(), updatedAt: Date(),
            lastReadChapterIndex: nil, lastReadParagraph: nil,
            lastReadCharacterOffset: nil, catalogUpdatedAt: catalogUpdatedAt
        )
    }

    /// "Never fetched" is not the same as "fetched a long time ago", but both
    /// mean fetch — the difference is only whether there is a list to show while
    /// it happens.
    func testABookWithNoCatalogIsStale() {
        XCTAssertTrue(makeBook(catalogUpdatedAt: nil).isCatalogStale)
    }

    func testAFreshlyFetchedCatalogIsNotStale() {
        XCTAssertFalse(makeBook(catalogUpdatedAt: Date()).isCatalogStale)
    }

    func testACatalogOlderThanADayIsStale() {
        let old = Date().addingTimeInterval(-Book.catalogMaxAge - 60)
        XCTAssertTrue(makeBook(catalogUpdatedAt: old).isCatalogStale)
    }

    func testACatalogFromThisMorningIsNotStale() {
        let earlier = Date().addingTimeInterval(-Book.catalogMaxAge / 2)
        XCTAssertFalse(makeBook(catalogUpdatedAt: earlier).isCatalogStale)
    }

    /// The stamp is written by the same transaction that writes the chapters.
    /// A caller that had to remember to stamp it separately would eventually
    /// forget, and the book would look permanently stale.
    func testWritingACatalogStampsTheBook() throws {
        let repo = LibraryRepo(database: try AppDatabase.makeInMemory())
        let book = try repo.bookmark(siteId: "demo", siteBookId: "1", title: "t")
        XCTAssertNil(book.catalogUpdatedAt, "A new bookmark has no catalog yet")
        XCTAssertTrue(book.isCatalogStale)

        try repo.replaceCatalog(
            bookId: book.id,
            entries: [(siteChapterId: "1", title: "one", url: "https://demo.test/txt/1/1")]
        )

        let reloaded = try XCTUnwrap(repo.book(id: book.id))
        XCTAssertNotNil(reloaded.catalogUpdatedAt)
        XCTAssertFalse(reloaded.isCatalogStale)
    }

    /// A catalog refresh is the site's doing, not the user's, so it must not
    /// bump `updatedAt` — that field decides iCloud last-writer-wins, and a
    /// background refresh must never beat a rename made on another device.
    func testARefreshDoesNotCountAsAUserEdit() throws {
        let repo = LibraryRepo(database: try AppDatabase.makeInMemory())
        // A bookmark edited long ago, so "did the refresh touch this" is a gap
        // of years rather than of milliseconds — SQLite stores dates to the
        // millisecond, and comparing two "now"s would only test rounding.
        let edited = Date(timeIntervalSince1970: 1_000_000)
        let book = try repo.bookmark(siteId: "demo", siteBookId: "1", title: "t", now: edited)
        try repo.replaceCatalog(
            bookId: book.id,
            entries: [(siteChapterId: "1", title: "one", url: "https://demo.test/txt/1/1")]
        )
        let reloaded = try XCTUnwrap(repo.book(id: book.id))
        XCTAssertEqual(reloaded.updatedAt.timeIntervalSince1970, edited.timeIntervalSince1970, accuracy: 1)
        XCTAssertNotNil(reloaded.catalogUpdatedAt, "…while the catalog stamp did move")
    }
}
