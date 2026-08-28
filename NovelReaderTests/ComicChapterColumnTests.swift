import XCTest
@testable import NovelReader

/// The arithmetic the comic reader stands on.
///
/// Every one of these is a rule that is invisible while it holds and reads as the app
/// losing the reader's place when it does not. A comic column starts as a stack of
/// guesses and is corrected page by page, out of order, while the reader is looking at
/// it — so "the numbers still add up after a correction" is not a detail, it is the
/// whole reason the column-stack architecture was chosen over a lazy container that
/// could not answer where anything was (see PITFALLS, 2026-08-17 and 2026-08-27).
final class ComicChapterColumnTests: XCTestCase {
    private let width: CGFloat = 400
    private var estimate: CGFloat { ComicChapterColumn.estimatedHeight(forWidth: 400) }

    /// A chapter is scrollable before a single image has arrived. Without the estimate
    /// the reader opens a comic onto a scroll view with no content, which cannot be
    /// moved and looks exactly like one that failed to load.
    func testAChapterHasHeightBeforeAnyImageArrives() {
        let column = ComicChapterColumn(pageCount: 10, width: width)

        XCTAssertEqual(column.height, estimate * 10)
        XCTAssertTrue(column.isEstimated(page: 0))
        XCTAssertEqual(column.top(ofPage: 3), estimate * 3)
    }

    /// The correction, and the number the coordinator adds to the scroll offset to keep
    /// the reader on the page they were looking at. It has to be the exact difference —
    /// this is the addition that replaced a lazy container's aim-and-measure.
    func testMeasuringAPageReportsExactlyHowMuchTheColumnGrew() {
        let column = ComicChapterColumn(pageCount: 3, width: width)
        let tall = CGSize(width: 800, height: 2400)   // 400 wide → 1200 tall

        let delta = column.setSize(tall, ofPage: 0)

        XCTAssertEqual(delta, 1200 - estimate, accuracy: 0.001)
        XCTAssertEqual(column.height, 1200 + estimate * 2, accuracy: 0.001)
        XCTAssertEqual(column.top(ofPage: 1), 1200, accuracy: 0.001)
    }

    /// The height is derived from the image's shape, not copied from its pixels: pages
    /// are drawn to the reader's width, so a 1600px-wide scan and an 800px-wide one of
    /// the same page must occupy the same space.
    func testTheHeightComesFromTheShapeNotThePixelCount() {
        let small = ComicChapterColumn(pageCount: 1, width: width)
        let large = ComicChapterColumn(pageCount: 1, width: width)

        small.setSize(CGSize(width: 800, height: 1200), ofPage: 0)
        large.setSize(CGSize(width: 1600, height: 2400), ofPage: 0)

        XCTAssertEqual(small.height, large.height)
        XCTAssertEqual(small.height, 600, accuracy: 0.001)
    }

    /// Images arrive in whatever order the network hands them back. The column has to be
    /// correct after each one, not only once they are all in.
    func testPagesMeasuredOutOfOrderStillStack() {
        let column = ComicChapterColumn(pageCount: 4, width: width)

        column.setSize(CGSize(width: 1, height: 2), ofPage: 2)   // 800
        column.setSize(CGSize(width: 1, height: 1), ofPage: 0)   // 400

        XCTAssertEqual(column.top(ofPage: 0), 0)
        XCTAssertEqual(column.top(ofPage: 1), 400, accuracy: 0.001)
        XCTAssertEqual(column.top(ofPage: 2), 400 + estimate, accuracy: 0.001)
        XCTAssertEqual(column.top(ofPage: 3), 400 + estimate + 800, accuracy: 0.001)
        XCTAssertEqual(column.height, 400 + estimate + 800 + estimate, accuracy: 0.001)
    }

    /// Nothing moves when a measurement says what the column already believed. The
    /// coordinator applies every delta to the scroll offset, so a redundant correction
    /// that reported a non-zero number would nudge the reader for free.
    func testRemeasuringTheSamePageChangesNothing() {
        let column = ComicChapterColumn(pageCount: 2, width: width)
        let size = CGSize(width: 1, height: 2)
        column.setSize(size, ofPage: 0)

        XCTAssertEqual(column.setSize(size, ofPage: 0), 0)
        XCTAssertEqual(column.setSize(size, ofPage: 99), 0)
        XCTAssertEqual(column.setSize(.zero, ofPage: 1), 0)
        XCTAssertTrue(column.isEstimated(page: 1))
    }

    /// A height inside a page names that page, never the one after it. The reading
    /// position is written from this: rounding forward would record the reader as having
    /// reached a page they have not seen, and that is what they come back to.
    func testAHeightNamesThePageItIsInside() {
        let column = ComicChapterColumn(pageCount: 3, width: width)

        XCTAssertEqual(column.page(atY: 0), 0)
        XCTAssertEqual(column.page(atY: estimate - 1), 0)
        XCTAssertEqual(column.page(atY: estimate), 1)
        XCTAssertEqual(column.page(atY: estimate * 2 + 5), 2)
        // Past the end, and before the start: both are the nearest page that exists.
        XCTAssertEqual(column.page(atY: estimate * 99), 2)
        XCTAssertEqual(column.page(atY: -50), 0)
    }

    /// What decides which images are decoded and which have their bitmaps released. Too
    /// few and the reader scrolls into blank pages; too many and a comic holds a chapter
    /// of full-size bitmaps, which is the memory ceiling this architecture exists under.
    func testTheVisibleRangeIsEveryPageTheWindowTouches() {
        let column = ComicChapterColumn(pageCount: 5, width: width)

        // A window sitting entirely inside one page.
        XCTAssertEqual(column.pages(in: 10..<(estimate - 10)), 0..<1)
        // One straddling a boundary names both.
        XCTAssertEqual(column.pages(in: (estimate - 10)..<(estimate + 10)), 0..<2)
        // One taller than a page names everything it covers.
        XCTAssertEqual(column.pages(in: 0..<(estimate * 3 + 1)), 0..<4)
        // Entirely past the end of the chapter.
        XCTAssertTrue(column.pages(in: (estimate * 10)..<(estimate * 11)).isEmpty)
    }

    /// The share is counted in pages, not points, so it does not move under the reader
    /// as estimates are replaced by real heights. Page 1 of 4 is 25% read whether or not
    /// pages 2 to 4 have been downloaded.
    func testTheShareIsCountedInPagesSoImagesArrivingDoNotMoveIt() {
        let column = ComicChapterColumn(pageCount: 4, width: width)
        let atPageOne = column.fractionRead(through: 10)

        column.setSize(CGSize(width: 1, height: 6), ofPage: 3)

        XCTAssertEqual(atPageOne, 0.25, accuracy: 0.001)
        XCTAssertEqual(column.fractionRead(through: 10), 0.25, accuracy: 0.001)
        XCTAssertEqual(column.fractionRead(through: column.height + 1), 1)
    }

    /// A chapter whose image list came back empty is a real answer from a rule that has
    /// stopped matching its site. It must not be a crash on the way to the reader.
    func testAChapterWithNoPagesIsNotACrash() {
        let column = ComicChapterColumn(pageCount: 0, width: width)

        XCTAssertEqual(column.height, 0)
        XCTAssertEqual(column.page(atY: 100), 0)
        XCTAssertTrue(column.pages(in: 0..<100).isEmpty)
        XCTAssertEqual(column.fractionRead(through: 0), 0)
    }
}
