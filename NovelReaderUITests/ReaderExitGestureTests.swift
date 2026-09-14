import XCTest

/// How a reader gets out of a book, which `ReaderSettings.swipeToGoBack` gives two
/// answers to.
///
/// A walk rather than a unit test because the interesting half is UIKit's: the edge swipe
/// belongs to `UINavigationController`, and it refuses to run for a screen that has
/// declared `navigationBarBackButtonHidden`. Nothing in this app's own code says so, so
/// nothing but driving the gesture can prove the modifier is off when the setting is on —
/// and the cost of being wrong is a reader shut inside a book with the button gone too.
///
/// The setting arrives as a launch argument, never by tapping it: tapping would persist
/// the choice into this simulator and hand it to every test that runs afterwards. See
/// `ReaderChromeGestureTests`.
///
/// Offline throughout: the fictional demo library, so no site rule and no network.
final class ReaderExitGestureTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func testTheEdgeSwipeLeavesTheBookWhenTheReaderHasAskedForIt() throws {
        launch(swipeToGoBack: true)
        let reader = try openTheDemoBook()

        // Tapped up first: the bar is not on screen until the text is tapped, so
        // asserting the button's absence without this would pass for the wrong reason.
        reader.tap()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "reader.chapterTitle")
                .firstMatch.waitForExistence(timeout: 5),
            "a tap on the text should bring the chrome up"
        )
        XCTAssertFalse(
            app.buttons["reader.back"].exists,
            "the control bar should not also carry a button for what the swipe does"
        )
        reader.tap()

        swipeInFromTheLeadingEdge()

        XCTAssertTrue(
            reader.waitForNonExistence(timeout: 10),
            "swiping from the leading edge should close the book\n\(app.debugDescription)"
        )
    }

    /// The other half, and the reason the setting is off to begin with: nothing about
    /// leaving a book changes for a reader who never turns it on.
    func testTheButtonIsThereAndTheEdgeIsInertWhenItIsNot() throws {
        launch(swipeToGoBack: false)
        let reader = try openTheDemoBook()

        // Brought up by a tap on the text, like every other control here.
        reader.tap()
        let back = app.buttons["reader.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "the control bar should offer a way out")

        swipeInFromTheLeadingEdge()
        XCTAssertTrue(
            reader.exists,
            "with the setting off the edge belongs to the book, not to the navigation stack"
        )

        back.tap()
        XCTAssertTrue(reader.waitForNonExistence(timeout: 10), "the button should close the book")
    }

    // MARK: - Fixtures

    private func launch(swipeToGoBack: Bool) {
        app.launchArguments = [
            "-NovelReaderDemoSeed",
            // The renderer, stated rather than inherited: `reader.text` is published by
            // the scrolling one alone, and the mode is a persisted setting.
            "-reader.mode", "scroll",
            "-reader.swipeToGoBack", swipeToGoBack ? "YES" : "NO",
        ]
        app.launch()
    }

    /// The shelf route rather than the history's, because this walk is about one book and
    /// the history offers whichever the demo seed left unfinished.
    private func openTheDemoBook() throws -> XCUIElement {
        app.openLibraryTab()
        let book = app.demoNovelRow()
        XCTAssertTrue(book.waitForExistence(timeout: 20), "the demo library should be seeded")
        book.tap()

        let read = app.descendants(matching: .any).matching(identifier: "book.read").firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 20))
        read.tap()

        let reader = app.otherElements["reader.text"]
        XCTAssertTrue(reader.waitForExistence(timeout: 20), "the reader should render chapter text")
        return reader
    }

    /// Begun against the edge itself, which is the only band UIKit watches — a stroke that
    /// starts in the middle of the page is a different gesture and must leave the book
    /// alone whichever way the setting is set.
    private func swipeInFromTheLeadingEdge() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: 2, dy: 0))
            .press(
                forDuration: 0.05,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
            )
    }
}
