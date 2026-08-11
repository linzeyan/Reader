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
        app.launchArguments = ["-NovelReaderDemoSeed"]
        app.launch()
    }

    /// The tab bar is a bottom bar on iPhone and a row of plain buttons at the top on
    /// iPad. SwiftUI names each tab after its SF Symbol, which is the same on both.
    private func tab(_ symbol: String) -> XCUIElement {
        let inBar = app.tabBars.buttons[symbol]
        return inBar.exists ? inBar : app.buttons[symbol].firstMatch
    }

    func testPressingAndSlidingOnAPageOffersToMarkThePassage() throws {
        // Paginated mode is chosen from Settings, not from the reader's own sheet: the
        // reader's control bar is addressable only by localized labels.
        let settings = tab("gearshape")
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.tap()
        let appearance = app.buttons["settings.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 10))
        appearance.tap()
        let mode = app.segmentedControls["reader.settings.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 10))
        // By index, not by title: `Mode.allCases` is scroll then paginated, and the
        // titles are translated.
        mode.buttons.element(boundBy: 1).tap()

        tab("books.vertical").tap()
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
