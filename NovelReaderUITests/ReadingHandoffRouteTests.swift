import XCTest

/// The book screen a swipe out of the reader reveals, reached two ways.
///
/// Opening a book from the reading history lays down the shelf's route for it — book
/// screen, then reader — while opening it from the shelf pushes one screen at a time. The
/// reader cannot tell which way they came in, so the screen behind the reader has to be
/// the same either way. It was not: with the whole route laid down in one assignment, the
/// book screen got its first layout inside the swipe back and came out of it with its
/// search drawer open — a bar 54 pt taller and the list pushed down beneath it (measured
/// on iOS 26: bar 108, first row 170, against the shelf route's 54 and 116), which on
/// iOS 18 put the search field over the cover.
///
/// Compared route against route rather than against those numbers: the bar's height is
/// the OS's to choose, and the claim is only that the way in does not change it.
///
/// Offline: the fictional demo library.
final class ReadingHandoffRouteTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            // The stress book, because it is the one the history opens.
            "-NovelReaderDemoSeed", "-NovelReaderDemoStress", "-reader.mode", "scroll",
            // The edge swipe is the gesture the jump was reported on, and it is off by
            // default. Passed as an argument so it does not persist into other walks.
            "-reader.swipeToGoBack", "YES",
        ]
        app.launch()
    }

    func testTheBookScreenBehindTheReaderIsTheSameFromTheHistoryAsFromTheShelf() throws {
        // Each route on a launch of its own, the history's first — which is how it was
        // reported: open the app, open the book from the history. Run second on the same
        // launch, after the shelf route had already shown a book screen in this stack, the
        // old one-assignment handoff measured exactly like the shelf and this test passed
        // against the bug it is here for.
        let recent = app.descendants(matching: .any).matching(identifier: "recent.book").firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 20), "the stress book should be in the history")
        recent.tap()
        let fromHistory = layoutAfterSwipingBack()

        app.terminate()
        app.launch()
        app.openLibraryTab()
        let row = app.descendants(matching: .any).matching(identifier: "library.book")
            .containing(.staticText, identifier: "長夜行").firstMatch
        app.reveal(row)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the stress book should be on the shelf")
        row.tap()
        let read = app.descendants(matching: .any).matching(identifier: "book.read").firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 20), "the book screen should offer reading")
        read.tap()
        let fromShelf = layoutAfterSwipingBack()

        print("ROUTE shelf bar=\(fromShelf.bar) row=\(fromShelf.firstRow) "
              + "history bar=\(fromHistory.bar) row=\(fromHistory.firstRow)")
        XCTAssertEqual(fromHistory.bar, fromShelf.bar, "the same navigation bar either way in")
        XCTAssertEqual(fromHistory.firstRow, fromShelf.firstRow, "and the list starting in the same place")
    }

    /// Waits for the reader, swipes out of it from the edge the way a thumb does, and reads
    /// where the book screen's bar and first row came to rest.
    private func layoutAfterSwipingBack() -> (bar: CGFloat, firstRow: CGFloat) {
        let reader = app.otherElements["reader.text"]
        XCTAssertTrue(reader.waitForExistence(timeout: 20), "the reader should open")
        // Past the push, so the swipe is a pop and not an interrupted transition.
        Thread.sleep(forTimeInterval: 1)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: 2, dy: 0))
            .press(
                forDuration: 0.05,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)),
                withVelocity: 200,
                thenHoldForDuration: 0
            )
        XCTAssertTrue(reader.waitForNonExistence(timeout: 10), "the swipe should leave the reader")
        // The bar settles after the pop does.
        Thread.sleep(forTimeInterval: 1)
        let bar = app.navigationBars.firstMatch
        let row = app.cells.firstMatch
        XCTAssertTrue(bar.exists, "the book screen should be showing")
        XCTAssertTrue(row.exists, "with its list")
        return (bar.frame.height, row.frame.minY)
    }
}
