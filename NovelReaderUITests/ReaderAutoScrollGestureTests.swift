import XCTest

/// The claim only a running app can settle about a page that moves on its own: that the
/// control in the bar starts it, and that the same control stops it.
///
/// Offline throughout: the fictional demo library, so no site rule and no network.
final class ReaderAutoScrollGestureTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    /// The renderer comes from the launch arguments, never from tapping the setting —
    /// tapping would persist the choice into this simulator for every later test. The pace
    /// comes the same way, and is the fastest the panel itself offers: a walk that waited
    /// out the default speed would be waiting for a paragraph boundary that is half a
    /// minute of reading away. Each walk names its own way of moving.
    private func launch(_ moving: [String]) {
        app.launchArguments = ["-NovelReaderDemoSeed", "-reader.mode", "scroll"] + moving
        app.launch()
    }

    func testTheControlBarStartsAndStopsThePageMovingOnItsOwn() throws {
        launch(["-reader.autoScrollPace", "60"])
        let control = openTheDemoBookAndFindTheControl()

        let start = app.topParagraphLabel()
        control.tap()
        XCTAssertTrue(
            movedAway(from: start, within: 20),
            "the page was told to move and the same paragraph is still at the top"
        )

        control.tap()
        let stopped = app.topParagraphLabel()
        // Long enough that the pace under test would have carried the reader past a
        // paragraph several times over.
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(
            app.topParagraphLabel(), stopped,
            "a page switched off has to stay where the reader stopped it"
        )
    }

    /// The same control, asked for pages: nothing moves until the interval is up, and then
    /// a whole page goes at once — the turn a tap on the next-page zone makes.
    func testThePageTurnsAPageAtATimeWhenAskedTo() throws {
        launch(["-reader.autoAdvance", "pages", "-reader.autoTurnInterval", "5"])
        let control = openTheDemoBookAndFindTheControl()

        let start = app.topParagraphLabel()
        control.tap()
        XCTAssertTrue(
            movedAway(from: start, within: 20),
            "the page was told to turn itself and the same paragraph is still at the top"
        )

        control.tap()
        let stopped = app.topParagraphLabel()
        // Longer than the interval, so a switch that did not really go off would have
        // turned a page by now.
        Thread.sleep(forTimeInterval: 8)
        XCTAssertEqual(
            app.topParagraphLabel(), stopped,
            "pages switched off have to stay where the reader stopped them"
        )
    }

    private func openTheDemoBookAndFindTheControl() -> XCUIElement {
        app.openLibraryTab()
        let book = app.demoNovelRow()
        XCTAssertTrue(book.waitForExistence(timeout: 20), "the demo library should be seeded")
        book.tap()
        let read = app.descendants(matching: .any).matching(identifier: "book.read").firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 20))
        read.tap()

        XCTAssertTrue(
            app.otherElements["reader.text"].waitForExistence(timeout: 20),
            "the scrolling renderer should be showing"
        )
        XCTAssertFalse(app.topParagraphLabel().isEmpty, "the reader should have text on screen")

        showControls()
        let control = app.descendants(matching: .any)
            .matching(identifier: "reader.autoScroll").firstMatch
        XCTAssertTrue(
            control.waitForExistence(timeout: 5),
            "the scrolling renderer's control bar should offer to move the page"
        )
        return control
    }

    /// Brings the chrome up by tapping text in the band that asks for it.
    ///
    /// The same rule `ReaderChromeGestureTests` walks by, and for its reasons: only the
    /// middle of the page shows the controls now that every renderer answers one page-turn
    /// setting, and a paragraph has to be clear of both ends of the window to be tappable
    /// without XCUITest scrolling it into view first.
    private func showControls() {
        let paragraphs = app.descendants(matching: .any).matching(identifier: "reader.paragraph")
        XCTAssertTrue(paragraphs.firstMatch.waitForExistence(timeout: 20))
        let window = app.windows.firstMatch.frame
        let reachable = window.insetBy(dx: 0, dy: 120)
        let band = window.insetBy(dx: window.width * 0.4, dy: window.height * 0.4)
        let paragraph = (0..<paragraphs.count)
            .map { paragraphs.element(boundBy: $0) }
            .first {
                reachable.contains($0.frame)
                    && band.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
            }
        paragraph?.tap()
    }

    /// Whether the text at the top of the window has changed within the time given.
    ///
    /// Polled rather than slept through: each query is an accessibility snapshot that
    /// blocks the app while it is taken, so a walk that asked once after a fixed wait would
    /// be measuring the snapshot as much as the scrolling.
    private func movedAway(from label: String, within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if app.topParagraphLabel() != label { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }
}
