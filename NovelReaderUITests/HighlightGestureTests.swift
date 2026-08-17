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
        // The app opens on the reading history, which the demo seed always leaves
        // something unfinished in. This walk starts from the shelf, so it asks for it.
        app.openLibraryTab()
        let book = app.descendants(matching: .any).matching(identifier: "library.book").firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20), "the demo library should be seeded")
        book.tap()
        let read = app.descendants(matching: .any).matching(identifier: "book.read").firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 20))
        read.tap()

        let page = app.descendants(matching: .any).matching(identifier: "reader.page").firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 20), "the paginated renderer should be showing")

        // Press and slide across several lines. Held well past the press recognizer's
        // delay, and far enough that the page-turn drag would happily claim it.
        //
        // Down the page as well as across it, so the passage is a band rather than one
        // line. A single line is not a target this walk can hit afterwards: the point it
        // starts from may be the gap between two paragraphs, where there are no glyphs and
        // so no ink, and the mark then begins on the line below the finger.
        let at = { (x: CGFloat, y: CGFloat) in
            page.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
        }
        at(0.25, 0.45).press(forDuration: 0.8, thenDragTo: at(0.75, 0.6))

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
        //
        // Tapped on the line the slide *ended* on. Sentence snapping only ever widens a
        // passage, so that line is inside the mark whatever the text is; the line it began
        // on is not, because a press can start in the gap between two paragraphs and the
        // mark then starts below it.
        at(0.5, 0.6).tap()
        XCTAssertTrue(
            action.waitForExistence(timeout: 5),
            "tapping a marked passage should offer to remove it"
        )
    }
}
