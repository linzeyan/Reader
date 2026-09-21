import XCTest

/// The walk the App Store preview is a recording of.
///
/// The host records the simulator's screen around this test (`make previews`) and cuts
/// the video at the two marks it prints, so everything between them is what a buyer
/// watches — every pause here is screen time, and the whole walk has to fit in the 30
/// seconds the store allows. Nothing in it is asserted beyond what the next step needs
/// to find: this is a film, and `ScreenshotTests` and the gesture walks are the tests.
///
/// Driven over the fictional demo library for the reason the screenshots are, and with
/// the touch indicator on so the video shows a person using the app rather than an app
/// animating by itself.
///
/// Gestures are aimed by coordinate while the page is on screen, and elements are queried
/// only between moves: every query is an accessibility snapshot that stalls the app while
/// it is taken, which in a recording is a visible hitch.
final class AppPreviewTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["NOVELREADER_PREVIEW"] == "1",
            "Run `make previews`."
        )
        continueAfterFailure = false
        app = XCUIApplication()
        // The renderer is fixed rather than inherited: the scrolling one is what the
        // preview shows, and a simulator's last walk could have left it paged.
        app.launchArguments = [
            "-NovelReaderDemoSeed", "-NovelReaderShowTouches", "-reader.mode", "scroll",
        ]
        if let language = ProcessInfo.processInfo.environment["NOVELREADER_SHOT_LANG"] {
            app.launchArguments += ["-AppleLanguages", "(\(language))"]
        }
        app.launch()
    }

    func testWalkForTheAppPreview() throws {
        // The history, where the app opens: a buyer's first second is the app's.
        let book = app.descendants(matching: .any).matching(identifier: "recent.book")
            .containing(.staticText, identifier: "星河渡口").firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 30), "The demo library should be seeded")
        mark("begin")
        hold(1.0)

        // Straight back into the book, at the paragraph it was left on.
        book.tap()
        XCTAssertTrue(appears(app.otherElements["reader.text"], within: 20))
        hold(0.6)

        // Reading: one unhurried stroke that stops before lifting, so the page moves as far
        // as the finger does and no fling carries it off. No hold after it: XCUITest waits
        // for the page to settle, and that wait is already on screen.
        drag(from: 0.72, to: 0.36)

        // Read aloud. The band walking down the page is the feature; three seconds is a
        // sentence or two at the voice's own pace.
        at(0.5, 0.5).tap()
        let speech = element("reader.speech")
        XCTAssertTrue(appears(speech))
        hold(0.4)
        speech.tap()
        XCTAssertTrue(appears(element("reader.speech.rate")))
        hold(3.0)
        speech.tap()
        hold(0.3)

        // The type panel, over the page it changes, and the change is the dark theme: the
        // whole page turning over behind the panel reads at a glance, where a size change
        // shows in the eight lines left above a half-height sheet and costs four seconds.
        //
        // The themes are below the fold — and a list does not build rows it has not shown,
        // so they are not there to be found until it is scrolled. One long stroke from the
        // font row, because that is a plain row: a stroke that starts on a slider or a
        // segmented control moves the control instead of the list.
        element("reader.settings").tap()
        let font = element("reader.settings.font")
        XCTAssertTrue(appears(font))
        hold(0.5)
        font.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.05,
            thenDragTo: at(0.5, 0.22),
            withVelocity: XCUIGestureVelocity(900),
            thenHoldForDuration: 0.1
        )
        let themes = element("reader.settings.themes")
        if !(appears(themes, within: 2) && themes.isHittable) {
            // The list's own margin, left of every row's content: no control starts there,
            // whichever rows the first stroke happened to leave in view.
            at(0.045, 0.9).press(
                forDuration: 0.05,
                thenDragTo: at(0.045, 0.62),
                withVelocity: XCUIGestureVelocity(900),
                thenHoldForDuration: 0.1
            )
        }
        XCTAssertTrue(themes.isHittable, "the themes should have scrolled into the panel")
        // By position — system, light, dark, custom — because the names are localized.
        themes.buttons.element(boundBy: 2).tap()
        hold(0.8)
        at(0.5, 0.15).tap()
        hold(0.5)

        drag(from: 0.70, to: 0.40)
        hold(0.5)
        mark("end")
        // The cut runs a little past the mark, and the test's end closes the app: without
        // this the last frames of the preview are the home screen.
        hold(1.0)
    }

    // MARK: - Steps

    /// A line the host's cutter reads out of the test log. Wall-clock seconds, because
    /// the simulator shares the host's clock and the recording is timed on the host.
    private func mark(_ name: String) {
        print(String(format: "PREVIEW-MARK %@ %.3f", name, Date().timeIntervalSince1970))
    }

    private func hold(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// Whether an element turns up in time, asked as often as a query allows.
    ///
    /// Not `waitForExistence`, which measured a second before its first look even for an
    /// element already on screen — a second of dead film at every step, and the walk has
    /// thirty in all.
    private func appears(_ element: XCUIElement, within seconds: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !element.exists {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return true
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func at(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }

    /// One vertical stroke on the page, down the middle.
    private func drag(from start: CGFloat, to end: CGFloat) {
        at(0.5, start).press(
            forDuration: 0.05,
            thenDragTo: at(0.5, end),
            withVelocity: XCUIGestureVelocity(700),
            thenHoldForDuration: 0.15
        )
    }
}
