import XCTest

/// The "?" after a settings title, which is where every explanation longer than a
/// sentence now lives.
///
/// Walked on the sync switch because that is the placement most likely to fail: a
/// button inside a `Toggle`'s label, where SwiftUI could as easily fold it into the
/// switch — leaving the explanation drawn on screen and impossible to open. A header's
/// "?" has nothing around it to be swallowed by.
final class SettingsHelpTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func testTheSyncSwitchExplainsItselfAndPutsTheExplanationAway() throws {
        app.openTab(.settings)
        let sync = app.switches["settings.icloud"]
        app.reveal(sync)
        XCTAssertTrue(sync.waitForExistence(timeout: 5), "Settings should offer iCloud sync")

        // The "?" on the switch's own row, not whichever one is first on the screen.
        let help = try XCTUnwrap(
            app.buttons.matching(identifier: "help").allElementsBoundByIndex
                .first { abs($0.frame.midY - sync.frame.midY) < 22 },
            "the sync switch should carry a ? of its own, reachable apart from the switch"
        )
        let wasOn = sync.value as? String
        help.tap()
        let text = app.staticTexts["help.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5), "the ? should open its explanation")
        XCTAssertEqual(sync.value as? String, wasOn, "opening the help must not flip the switch")

        text.tap()
        XCTAssertTrue(text.waitForNonExistence(timeout: 5), "a tap on the bubble should put it away")

        // Left alone, it goes by itself after ten seconds.
        help.tap()
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        XCTAssertTrue(text.waitForNonExistence(timeout: 15), "an unattended bubble should close itself")
    }

    /// Below the settings root as well. SwiftUI's own `.popover` put the bubble up and took
    /// it straight down again on every pushed screen while working on the root — see
    /// `HelpButton` — so a walk of the root alone says nothing about the rest.
    func testAHelpOnAPushedScreenStaysUpUntilItIsTapped() throws {
        app.openTab(.settings)
        let start = app.buttons["settings.start"]
        app.reveal(start)
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertTrue(
            app.buttons["settings.recent.clear"].waitForExistence(timeout: 5),
            "the launch settings should be on screen"
        )

        let help = try XCTUnwrap(
            app.buttons.matching(identifier: "help").allElementsBoundByIndex.first { $0.isHittable },
            "the reading history section should carry a ?"
        )
        help.tap()
        let text = app.staticTexts["help.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5), "the ? should open its explanation")
        sleep(2)
        XCTAssertTrue(text.exists, "the bubble must stay up, not close as it opens")
        text.tap()
        XCTAssertTrue(text.waitForNonExistence(timeout: 5))
    }
}
