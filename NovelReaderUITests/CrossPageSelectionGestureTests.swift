import XCTest

/// The one claim about cross-page selection that arithmetic cannot support: that a finger
/// held against the bottom of a page turns it *without* losing the selection it is
/// extending.
///
/// The page turn and the press sit on opposite sides of the SwiftUI/UIKit boundary. A turn
/// that hands the drawing view a new identity tears down the recogniser holding the
/// selection open, and if it does, every offset, range and rectangle in
/// `CrossPageSelectionTests` stays green while the feature quietly refuses to cross a
/// break. That is what this walks.
///
/// Offline throughout: the fictional demo library, so no site rule and no network.
final class CrossPageSelectionGestureTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Paginated mode from the launch arguments rather than from tapping the setting.
        // Tapping it would *persist* the choice in this simulator, and the reading mode
        // decides which renderer every later test gets. The argument domain lasts exactly
        // as long as this launch.
        app.launchArguments = ["-NovelReaderDemoSeed", "-reader.mode", "paginated"]
        app.launch()
    }

    func testHoldingASelectionAgainstTheBottomEdgeCarriesItOntoTheNextPage() throws {
        let book = app.descendants(matching: .any).matching(identifier: "library.book").firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20), "the demo library should be seeded")
        book.tap()
        let read = app.descendants(matching: .any).matching(identifier: "book.read").firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 20))
        read.tap()

        let page = app.descendants(matching: .any).matching(identifier: "reader.page").firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 20), "the paginated renderer should be showing")

        let opened = progress()
        XCTAssertGreaterThan(opened, 0, "the reader should be reporting how far through the chapter it is")
        XCTAssertLessThan(
            opened, 100,
            "this walk needs a chapter of more than one page; the demo chapter is no longer one"
        )

        // Press in the middle of the page, slide down into the bottom strip, and rest
        // there. The rest is the gesture: `SelectionEdgeRule` turns the page once the
        // dwell has elapsed, and holding through several dwells is what a reader marking a
        // long passage does.
        let anchor = page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        let edge = page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99))
        anchor.press(
            forDuration: 0.8, thenDragTo: edge, withVelocity: .slow, thenHoldForDuration: 1.6
        )

        XCTAssertGreaterThan(
            progress(), opened,
            "resting against the bottom edge has to turn the page while the selection is still being dragged"
        )
        let action = app.buttons["reader.highlight.action"]
        XCTAssertTrue(
            action.waitForExistence(timeout: 5),
            "the selection must survive the turn; failing here means turning the page cancelled the press"
        )
        action.tap()
        XCTAssertFalse(action.exists, "committing the highlight should put the bar away")

        // Back a page. The mark was made across the break, so the page the press began on
        // has to be carrying its own half of it — which is the whole point of storing one
        // highlight rather than clipping the selection to the page it started on.
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        XCTAssertEqual(
            progress(), opened, "the left edge turns back to the page the selection started on"
        )
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        XCTAssertTrue(
            action.waitForExistence(timeout: 5),
            "the half of the mark left behind on the first page has to be there to be tapped"
        )
    }

    /// The reader's own progress figure as a whole number of percent, which is the only
    /// thing on a page that says which page it is.
    ///
    /// Read out of the accessibility label: the visible text is the bare figure, and the
    /// label is the one place the figure and the sentence around it are put together. The
    /// digits are pulled out rather than the whole label matched, because the sentence is
    /// localised and the figure is not.
    private func progress() -> Int {
        let figure = app.descendants(matching: .any)
            .matching(identifier: "reader.pageNumber").firstMatch
        guard figure.waitForExistence(timeout: 10) else { return -1 }
        return Int(figure.label.filter(\.isNumber)) ?? -1
    }
}
