import XCTest
@testable import NovelReader

/// The two things a reader can change about a chapter list, and the row that must
/// survive both.
///
/// The report behind these: a serial with thirteen hundred chapters opens at chapter
/// one every time, and getting back to where you were is a scroll of your own making.
/// So the list gained a direction and a pinned row — and the pinned row is only worth
/// anything if it stays put when the direction changes.
final class BookCatalogTests: XCTestCase {
    private let chapters = [
        chapter(index: 0, id: "c1", title: "第一章 出發"),
        chapter(index: 1, id: "c2", title: "第二章 山路"),
        chapter(index: 2, id: "c3", title: "第三章 抵達"),
    ]

    func testAscendingIsTheCatalogAsTheSiteOrderedIt() {
        let catalog = BookCatalog(
            chapters: chapters, query: "", descending: false, lastReadSiteChapterId: nil
        )
        XCTAssertEqual(catalog.chapters.map(\.siteChapterId), ["c1", "c2", "c3"])
    }

    /// What a reader following a serial for its updates asked for: the newest chapter
    /// is the one they came back for, so it is the one at the top.
    func testDescendingPutsTheNewestChapterFirst() {
        let catalog = BookCatalog(
            chapters: chapters, query: "", descending: true, lastReadSiteChapterId: nil
        )
        XCTAssertEqual(catalog.chapters.map(\.siteChapterId), ["c3", "c2", "c1"])
    }

    /// The point of pinning: the row is above the list in both directions, so coming
    /// back to a book never means hunting for where you were.
    func testWhereTheReaderLeftOffIsPinnedInEitherOrder() {
        for descending in [false, true] {
            let catalog = BookCatalog(
                chapters: chapters, query: "", descending: descending,
                lastReadSiteChapterId: "c2"
            )
            XCTAssertEqual(
                catalog.lastRead?.siteChapterId, "c2",
                "the pinned chapter is not the order's to move"
            )
            XCTAssertEqual(
                catalog.chapters.count, chapters.count,
                "pinning it must not take it out of the list it belongs in"
            )
        }
    }

    /// The same "no place in this catalog" every other screen has to handle: the site
    /// dropped the chapter the position names. Nothing is pinned, and nothing is invented.
    func testAChapterTheSiteNoLongerListsPinsNothing() {
        let catalog = BookCatalog(
            chapters: chapters, query: "", descending: false, lastReadSiteChapterId: "gone"
        )
        XCTAssertNil(catalog.lastRead)
    }

    func testNeverOpenedPinsNothing() {
        let catalog = BookCatalog(
            chapters: chapters, query: "", descending: false, lastReadSiteChapterId: nil
        )
        XCTAssertNil(catalog.lastRead)
    }

    /// While a search is running the list is a finder, and everything on it should be a
    /// match — including the pinned row, which is why there is not one.
    func testASearchShowsMatchesAndNothingBesides() {
        let catalog = BookCatalog(
            chapters: chapters, query: " 山路 ", descending: false, lastReadSiteChapterId: "c1"
        )
        XCTAssertEqual(catalog.chapters.map(\.siteChapterId), ["c2"])
        XCTAssertNil(catalog.lastRead, "the pinned row is not a search result")
    }

    /// Order applies to what the search left, not to the catalog it came from.
    func testSearchResultsComeBackInTheChosenOrder() {
        let catalog = BookCatalog(
            chapters: chapters, query: "第", descending: true, lastReadSiteChapterId: nil
        )
        XCTAssertEqual(catalog.chapters.map(\.siteChapterId), ["c3", "c2", "c1"])
    }

    // MARK: - Where the order is kept

    /// Per book, because one shelf holds both kinds of reading — see
    /// `LibrarySettings.catalogDescending`.
    func testOrderIsRememberedPerBookAndNothingElseHears() {
        let settings = makeSettings()
        settings.setCatalogDescending(true, bookId: "site|serial")

        XCTAssertTrue(settings.isCatalogDescending(bookId: "site|serial"))
        XCTAssertFalse(
            settings.isCatalogDescending(bookId: "site|novel"),
            "a book nobody has touched reads from chapter one, as every catalog did before"
        )
    }

    func testTheChosenOrderSurvivesALaunch() throws {
        let suite = "BookCatalogTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        LibrarySettings(defaults: defaults).setCatalogDescending(true, bookId: "site|serial")

        XCTAssertTrue(LibrarySettings(defaults: defaults).isCatalogDescending(bookId: "site|serial"))
    }

    /// Ascending is stored as nothing at all, so changing the order and changing it back
    /// leaves no trace — otherwise the defaults accumulate a row per book ever opened.
    func testGoingBackToAscendingLeavesNothingBehind() {
        let settings = makeSettings()
        settings.setCatalogDescending(true, bookId: "site|serial")
        settings.setCatalogDescending(false, bookId: "site|serial")

        XCTAssertTrue(settings.catalogDescending.isEmpty)
    }

    /// A book that is removed and added again must not come back with an order the
    /// reader never chose for it.
    func testDeletingABookForgetsItsOrder() {
        let settings = makeSettings()
        settings.setCatalogDescending(true, bookId: "site|gone")
        settings.setCatalogDescending(true, bookId: "site|kept")

        settings.forgetCatalogOrder(bookId: "site|gone")

        XCTAssertFalse(settings.isCatalogDescending(bookId: "site|gone"))
        XCTAssertTrue(settings.isCatalogDescending(bookId: "site|kept"))
    }

    // MARK: - Helpers

    private func makeSettings() -> LibrarySettings {
        LibrarySettings(defaults: UserDefaults(suiteName: "novelreader.tests.\(UUID().uuidString)")!)
    }

    private static func chapter(index: Int, id: String, title: String) -> Chapter {
        Chapter(
            id: "book|\(id)", bookId: "book", siteChapterId: id, index: index,
            title: title, url: "https://example.com/\(id)", addedAt: nil, downloadedAt: nil
        )
    }
}
