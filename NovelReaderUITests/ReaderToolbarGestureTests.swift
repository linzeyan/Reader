import XCTest

/// Arranging the bar at the foot of a book, and finding what was arranged away.
///
/// The one claim the unit tests cannot make: that a control folded away in Settings is
/// gone from the bar of a book opened afterwards, and is still reachable there. Everything
/// between those two — the editor writing a layer, the layer resolving, the bar drawing
/// what it resolved — is only worth anything if that holds end to end.
final class ReaderToolbarGestureTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-NovelReaderDemoSeed", "-reader.mode", "scroll"]
        app.launch()
    }

    func testAControlFoldedAwayLeavesTheBarAndIsStillReachable() {
        openTheToolbarEditor()

        // The voice, because it is on every text bar and no comic one — so a walk that
        // finds it missing from a novel's bar has found this setting and not a shelf rule.
        let fold = app.descendants(matching: .any)
            .matching(identifier: "reader.toolbar.speech").firstMatch
        XCTAssertTrue(fold.waitForExistence(timeout: 5), "the editor should list the voice")
        fold.tap()

        openTheDemoBookAndShowTheChrome()

        XCTAssertFalse(
            app.descendants(matching: .any).matching(identifier: "reader.speech")
                .firstMatch.exists,
            "a control folded away should not be on the bar"
        )
        let more = app.descendants(matching: .any).matching(identifier: "reader.more").firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5), "and the bar should offer the way to it")
        more.tap()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "reader.speech")
                .firstMatch.waitForExistence(timeout: 5),
            "folded away is not gone: it has to be in the menu behind the last button"
        )
    }

    /// The bar a reader has not arranged carries no "more" button.
    ///
    /// A control that opens an empty menu is a place on the bar spent on nothing — the
    /// rule the pace strip learned, and the reason this one is conditional at all.
    func testABarNobodyArrangedHasNothingFoldedBehind() {
        openTheDemoBookAndShowTheChrome()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "reader.speech")
                .firstMatch.waitForExistence(timeout: 5),
            "everything is on the bar until somebody folds it away"
        )
        XCTAssertFalse(
            app.descendants(matching: .any).matching(identifier: "reader.more").firstMatch.exists,
            "with nothing folded away there is nothing for a menu to hold"
        )
    }

    // MARK: - Getting there

    private func openTheToolbarEditor() {
        app.tabButton(.settings).tap()
        let appearance = app.buttons["settings.appearance"]
        app.reveal(appearance)
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.tap()
        // Left on the widest scope, which is where the panel opens: what is being tested
        // is the arranging, and the layering has its own tests that need no simulator.
        let toolbar = app.descendants(matching: .any)
            .matching(identifier: "reader.settings.toolbar").firstMatch
        app.reveal(toolbar)
        XCTAssertTrue(toolbar.waitForExistence(timeout: 5), "Settings should offer the bar")
        toolbar.tap()
    }

    private func openTheDemoBookAndShowTheChrome() {
        app.openLibraryTab()
        let book = app.demoNovelRow()
        XCTAssertTrue(book.waitForExistence(timeout: 20), "the demo library should be seeded")
        book.tap()
        let read = app.descendants(matching: .any).matching(identifier: "book.read").firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 20))
        read.tap()
        XCTAssertTrue(app.otherElements["reader.text"].waitForExistence(timeout: 20))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
}
