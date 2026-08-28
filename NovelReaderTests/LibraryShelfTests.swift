import XCTest
@testable import NovelReader

/// The shelf's arrangement rules.
///
/// These live in a pure function precisely so they can be pinned here: every one
/// of them is an ordering someone would call broken if it were wrong, and none of
/// them is visible in a screenshot until a reader with forty bookmarks hits it.
final class LibraryShelfTests: XCTestCase {
    // MARK: - Title order

    /// The whole reason the title sort uses `localizedStandardCompare`. Chinese web
    /// novels number their volumes in Arabic digits, and Swift's `<` compares scalar
    /// by scalar: it files 第10部 above 第2部 because "1" precedes "2". A shelf that
    /// puts volume ten before volume two is a shelf nobody trusts to be sorted.
    func testTitleSortReadsNumbersInChineseTitlesAsNumbers() {
        let books = [
            book(id: "c", title: "劍來 第10部"),
            book(id: "a", title: "劍來 第2部"),
            book(id: "b", title: "劍來 第9部"),
        ]

        let sorted = LibrarySort.title.applied(to: books).map(\.title)

        XCTAssertEqual(sorted, ["劍來 第2部", "劍來 第9部", "劍來 第10部"])
        XCTAssertNotEqual(
            sorted, books.map(\.title).sorted(),
            "plain string ordering is the bug this sort exists to avoid"
        )
    }

    /// The row shows `shownName`, so that is what the sort has to agree with —
    /// otherwise renaming a book moves it somewhere the alphabet does not explain.
    func testTitleSortFollowsTheRenamedTitleNotTheSiteOne() {
        var renamed = book(id: "z", title: "誅仙")
        renamed.displayName = "白馬"

        let sorted = LibrarySort.title.applied(to: [book(id: "a", title: "青囊"), renamed])

        XCTAssertEqual(sorted.map(\.shownName), ["白馬", "青囊"])
    }

    // MARK: - Recently read

    /// A book that has never been opened has nothing to be recent about. `updatedAt`
    /// alone would not know that: it is bumped by a rename and by a catalog refresh
    /// too, so an untouched-but-renamed book would sit above the novel the reader was
    /// in last night. That is precisely why the sort reads `lastReadAt`, which is
    /// written only when a reading position is.
    func testRecentlyReadKeepsUnreadBooksBelowReadOnes() {
        let read = read(book(id: "read", title: "讀過"), at: day(1))
        // Renamed a moment ago and never opened: the most recently *touched* book,
        // and the one that must not be at the top.
        let neverOpened = book(id: "unread", title: "沒讀過", updatedAt: day(9))

        let sorted = LibrarySort.recentlyRead.applied(to: [neverOpened, read]).map(\.id)

        XCTAssertEqual(sorted, ["read", "unread"])
    }

    func testRecentlyReadOrdersReadBooksByWhenProgressWasRecorded() {
        let older = read(book(id: "older", title: "舊", updatedAt: day(9)), at: day(2))
        // Touched longest ago and read most recently — the two timestamps pulling in
        // opposite directions, which is the whole reason there are two of them.
        let newer = read(book(id: "newer", title: "新", updatedAt: day(1)), at: day(7))

        let sorted = LibrarySort.recentlyRead.applied(to: [older, newer]).map(\.id)

        XCTAssertEqual(sorted, ["newer", "older"])
    }

    /// Clearing the reading history takes every book out of it, and the sort has to
    /// degrade to the shelf's default order rather than keep an order drawn from a
    /// record the reader has just deleted.
    func testRecentlyReadFallsBackToNewestFirstOnceTheHistoryIsCleared() {
        let old = read(book(id: "old", title: "舊", addedAt: day(1)), at: day(8))
        let new = read(book(id: "new", title: "新", addedAt: day(5)), at: day(2))
        // What `LibraryRepo.clearReadingHistory` writes: the timestamps go, the
        // positions stay.
        let cleared = [old, new].map { book -> Book in
            var book = book
            book.lastReadAt = nil
            return book
        }

        let sorted = LibrarySort.recentlyRead.applied(to: cleared).map(\.id)

        XCTAssertEqual(sorted, ["new", "old"])
        XCTAssertTrue(
            cleared.allSatisfy { $0.lastReadSiteChapterId != nil },
            "clearing the history must not throw away where the reader got to"
        )
    }

    /// With nothing read at all the sort has to degrade to the shelf's default
    /// order rather than to whatever the array happened to hold.
    func testRecentlyReadFallsBackToNewestFirstWhenNothingHasBeenRead() {
        let old = book(id: "old", title: "舊", addedAt: day(1))
        let new = book(id: "new", title: "新", addedAt: day(5))

        let sorted = LibrarySort.recentlyRead.applied(to: [old, new]).map(\.id)

        XCTAssertEqual(sorted, ["new", "old"])
    }

    // MARK: - Filtering

    /// The filter narrows the sections; it must not merge them. Grouping is what
    /// tells two bookmarks of the same novel apart, and a filter that flattened the
    /// shelf would take that away exactly when the shelf is at its shortest.
    func testFilteringKeepsEachSourceInItsOwnSection() {
        let sources = [
            LibrarySource(siteId: "alpha", name: "Alpha", books: [
                book(id: "a1", title: "有新章"), book(id: "a2", title: "沒新章"),
            ]),
            LibrarySource(siteId: "beta", name: "Beta", books: [book(id: "b1", title: "也有新章")]),
        ]

        let sections = LibraryShelf.sections(
            from: sources, sort: .added, groupBySource: true,
            onlyWithNewChapters: true, newChapterCounts: ["a1": 2, "b1": 5]
        )

        XCTAssertEqual(sections.map(\.id), ["alpha", "beta"])
        XCTAssertEqual(sections.map(\.name), ["Alpha", "Beta"])
        XCTAssertEqual(sections.map { $0.books.map(\.id) }, [["a1"], ["b1"]])
    }

    /// A named section with no rows under it is a header pointing at nothing.
    func testFilteringDropsSourcesLeftWithNoBooks() {
        let sources = [
            LibrarySource(siteId: "alpha", name: "Alpha", books: [book(id: "a1", title: "有新章")]),
            LibrarySource(siteId: "beta", name: "Beta", books: [book(id: "b1", title: "沒新章")]),
        ]

        let sections = LibraryShelf.sections(
            from: sources, sort: .added, groupBySource: true,
            onlyWithNewChapters: true, newChapterCounts: ["a1": 1]
        )

        XCTAssertEqual(sections.map(\.id), ["alpha"])
    }

    /// Everything filtered out has to come back as no sections at all, which is
    /// what lets the view offer the way out instead of drawing an empty list.
    func testFilteringEverythingOutLeavesNoSections() {
        let sources = [LibrarySource(siteId: "alpha", name: "Alpha", books: [book(id: "a1", title: "書")])]

        let sections = LibraryShelf.sections(
            from: sources, sort: .added, groupBySource: true,
            onlyWithNewChapters: true, newChapterCounts: [:]
        )

        XCTAssertTrue(sections.isEmpty)
    }

    // MARK: - Grouping

    /// Turning grouping off has to reorder *across* sources, not concatenate them.
    /// Sorting each section and then joining would leave the shelf looking grouped
    /// with the headers taken away, which is the one result that would fool a
    /// reader into thinking the sort is broken.
    func testUngroupedShelfSortsAcrossSourcesRatherThanConcatenating() {
        let sources = [
            LibrarySource(siteId: "alpha", name: "Alpha", books: [
                book(id: "a-old", title: "A 舊", addedAt: day(1)),
                book(id: "a-new", title: "A 新", addedAt: day(6)),
            ]),
            LibrarySource(siteId: "beta", name: "Beta", books: [
                book(id: "b-mid", title: "B 中", addedAt: day(4)),
            ]),
        ]

        let sections = LibraryShelf.sections(
            from: sources, sort: .added, groupBySource: false,
            onlyWithNewChapters: false, newChapterCounts: [:]
        )

        XCTAssertEqual(sections.count, 1)
        XCTAssertNil(sections.first?.name, "a flat shelf must not ask for a header")
        XCTAssertEqual(sections.first?.books.map(\.id), ["a-new", "b-mid", "a-old"])
    }

    func testUngroupedShelfStillHonoursTheFilter() {
        let sources = [
            LibrarySource(siteId: "alpha", name: "Alpha", books: [
                book(id: "a1", title: "有新章"), book(id: "a2", title: "沒新章"),
            ]),
            LibrarySource(siteId: "beta", name: "Beta", books: [book(id: "b1", title: "沒新章")]),
        ]

        let sections = LibraryShelf.sections(
            from: sources, sort: .title, groupBySource: false,
            onlyWithNewChapters: true, newChapterCounts: ["a1": 1]
        )

        XCTAssertEqual(sections.first?.books.map(\.id), ["a1"])
    }

    /// The defaults have to reproduce the shelf as it was before any of this
    /// existed: grouped by source, newest bookmark first, nothing hidden.
    func testDefaultArrangementIsTheShelfTheAppAlreadyHad() {
        let settings = LibrarySettings(
            defaults: UserDefaults(suiteName: "novelreader.tests.\(UUID().uuidString)")!
        )
        let sources = [
            LibrarySource(siteId: "alpha", name: "Alpha", books: [
                book(id: "old", title: "舊", addedAt: day(1)),
                book(id: "new", title: "新", addedAt: day(3)),
            ]),
        ]

        XCTAssertEqual(settings.sort, .added)
        XCTAssertTrue(settings.groupBySource)
        XCTAssertFalse(settings.onlyWithNewChapters)

        let sections = LibraryShelf.sections(
            from: sources, sort: settings.sort, groupBySource: settings.groupBySource,
            onlyWithNewChapters: settings.onlyWithNewChapters, newChapterCounts: [:]
        )
        XCTAssertEqual(sections.map(\.name), ["Alpha"])
        XCTAssertEqual(sections.first?.books.map(\.id), ["new", "old"])
    }

    // MARK: - Helpers

    private func book(
        id: String,
        title: String,
        addedAt: Date = Date(timeIntervalSince1970: 0),
        updatedAt: Date = Date(timeIntervalSince1970: 0)
    ) -> Book {
        Book(
            id: id, siteId: "alpha", siteBookId: id, kind: .novel, title: title,
            displayName: nil, author: nil, coverURL: nil,
            addedAt: addedAt, updatedAt: updatedAt,
            lastReadSiteChapterId: nil, lastReadParagraph: nil,
            lastReadCharacterOffset: nil, lastReadFraction: nil,
            lastReadAt: nil, catalogUpdatedAt: nil
        )
    }

    /// Mirrors what `LibraryRepo.updateProgress` writes: a position *and* the moment it
    /// was recorded. Both halves matter — the position is what the row shows and
    /// `lastReadAt` is what the sort orders by.
    ///
    /// A chapter id rather than a number, because that is what a stored position is: it
    /// must keep working for a book whose chapter the site has dropped.
    private func read(_ book: Book, at readAt: Date, chapter siteChapterId: String = "3") -> Book {
        var read = book
        read.lastReadSiteChapterId = siteChapterId
        read.lastReadParagraph = 0
        read.lastReadCharacterOffset = 0
        read.lastReadAt = readAt
        return read
    }

    private func day(_ number: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(number) * 86_400)
    }
}
