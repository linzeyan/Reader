import XCTest

/// The one claim about highlighting that arithmetic cannot support: that the long
/// press which starts a selection actually reaches the text.
///
/// A page carries three gestures over the same pixels — a drag that turns pages, tap
/// zones at both edges, a tap in the middle for the controls — and the press that
/// picks out text belongs to the UIKit view underneath all of them. Every offset,
/// range and rectangle is covered offline by `HighlightTests` and `PaginationTests`;
/// if the arbitration between those gestures is wrong, all of it stays green and the
/// feature is simply unreachable. That is what this walks.
///
/// Offline throughout: the fictional demo library, so no site rule and no network.
final class HighlightGestureTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Paginated mode comes from the launch arguments rather than from tapping the
        // setting. Tapping it would *persist* the choice in this simulator, and the
        // reading mode decides which renderer every later test gets — the live smoke
        // walk asserts on the scrolling reader's text, so this test would quietly
        // break it. The argument domain lasts exactly as long as this launch.
        app.launchArguments = ["-NovelReaderDemoSeed", "-reader.mode", "paginated"]
        app.launch()
    }

    func testPressingAndSlidingOnAPageOffersToMarkThePassage() throws {
        let book = app.descendants(matching: .any).matching(identifier: "library.book").firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20), "the demo library should be seeded")
        book.tap()
        let read = app.descendants(matching: .any).matching(identifier: "book.read").firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 20))
        read.tap()

        let page = app.descendants(matching: .any).matching(identifier: "reader.page").firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 20), "the paginated renderer should be showing")

        // Press and slide along a line. Held well past the press recognizer's delay,
        // and far enough that the page-turn drag would happily claim it.
        let line = { (x: CGFloat) in page.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.45)) }
        line(0.25).press(forDuration: 0.8, thenDragTo: line(0.75))

        let action = app.buttons["reader.highlight.action"]
        XCTAssertTrue(
            action.waitForExistence(timeout: 5),
            "press-and-slide must offer to mark the passage; failing here means the page's own gestures swallowed it"
        )
        action.tap()
        XCTAssertFalse(action.exists, "committing the highlight should put the bar away")

        // A plain tap on the passage now has to bring a bar back. Nothing else on the
        // page does that — the middle of the page toggles the controls — so this is the
        // highlight itself being stored, drawn and hit-testable.
        line(0.5).tap()
        XCTAssertTrue(
            action.waitForExistence(timeout: 5),
            "tapping a marked passage should offer to remove it"
        )
    }
}
