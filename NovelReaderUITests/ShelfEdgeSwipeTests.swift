import XCTest

/// Switching shelves with a swipe in from the screen's edge, while a sideways swipe on a
/// book stays that book's own.
///
/// The second half is the reason the first is at the edge at all: a shelf row already
/// answers a swipe to either side, and a full one to the left deletes the book. A shelf
/// switch that also fired on a row's swipe would be one gesture doing two things, one of
/// them destructive.
final class ShelfEdgeSwipeTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-NovelReaderDemoSeed", "-library.home", "library", "-library.defaultMediaMode", "novel",
        ]
    }

    @MainActor
    func testASwipeFromTheEdgeSwitchesShelvesAndASwipeOnARowDoesNot() {
        app.launch()
        app.openLibraryTab()
        let row = app.demoNovelRow()
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the demo library should be seeded")
        assertShelf("novel", "the walk starts on the novels")

        // Inside the row and short of a full swipe: opens the row's buttons, nothing else.
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)))
        assertShelf("novel", "a swipe that starts on a row belongs to the row")
        // Closes the row's buttons again; a tap on the list's background does.
        app.navigationBars.firstMatch.tap()

        swipeIn(fromRight: true)
        assertShelf("comic", "in from the right edge goes to the next shelf")
        swipeIn(fromRight: true)
        assertShelf("feed", "…and the one after")
        swipeIn(fromRight: true)
        assertShelf("feed", "the last shelf stays put rather than wrapping round to the first")

        swipeIn(fromRight: false)
        assertShelf("comic", "in from the left edge goes back one")
    }

    /// A drag from the very edge of the screen to its middle, at list height — where the
    /// rows are, which is the case that has to be told apart.
    private func swipeIn(fromRight: Bool) {
        let y = 0.6
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: fromRight ? 0.995 : 0.005, dy: y))
        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: y))
        edge.press(forDuration: 0.05, thenDragTo: middle, withVelocity: .default, thenHoldForDuration: 0.1)
    }

    private func assertShelf(_ mode: String, _ message: String, line: UInt = #line) {
        let button = app.buttons["library.mode.\(mode)"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), line: line)
        // The switch's own highlight, the thing a reader sees change.
        let deadline = Date().addingTimeInterval(2)
        while !button.isSelected, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(button.isSelected, message, line: line)
    }
}
