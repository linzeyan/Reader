import XCTest

/// Captures the App Store screenshots by driving the real app.
///
/// Driving the UI rather than mocking it means the listing can never show a
/// screen the app does not actually have. The library it walks is fictional
/// (`DemoSeed`, Debug-only): the store page must not name a content source, and
/// the app's whole premise is that it ships pointing at none.
///
/// Opt-in — `make screenshots` — because it is slow and only useful when the
/// listing is being prepared.
final class ScreenshotTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["NOVELREADER_SCREENSHOTS"] == "1",
            "Run `make screenshots`."
        )
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-NovelReaderDemoSeed"]
        // The listing needs one set per storefront language; the runner picks
        // which by env var so the same walk produces all three.
        if let language = ProcessInfo.processInfo.environment["NOVELREADER_SHOT_LANG"] {
            app.launchArguments += ["-AppleLanguages", "(\(language))"]
        }
        app.launch()
    }

    /// Scrolling to a row below the fold is `XCUIApplication.reveal`. Shooting the small
    /// phones is what turned that need up — on a 4.7" screen the appearance row is
    /// several sections down — and the smoke walk has since needed the same thing, which
    /// is why it lives next to the tab navigation rather than here.
    private func reveal(_ element: XCUIElement, swipingUp: Bool = true) {
        app.reveal(element, swipingUp: swipingUp)
    }

    func testCaptureStoreScreenshots() throws {
        // 0. The reading history, which is where the app opens: one of the demo books
        // has a position part-way into a chapter, so there is always something to
        // carry on with. Shot first because it is the first thing a user sees.
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "recent.book")
            .firstMatch.waitForExistence(timeout: 20), "The demo library should be seeded")
        capture("00-recent")

        // 1. The library: bookmarks grouped by source.
        app.openLibraryTab()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "library.book")
            .firstMatch.waitForExistence(timeout: 20), "The demo library should be seeded")
        capture("01-library")

        // 2. A book: chapter index with the downloaded ones marked.
        app.descendants(matching: .any).matching(identifier: "library.book").firstMatch.tap()
        let read = app.descendants(matching: .any).matching(identifier: "book.read").firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 20))
        capture("02-book")

        // 3. The reader, opened at the stored reading position.
        read.tap()
        let reader = app.otherElements["reader.text"]
        XCTAssertTrue(reader.waitForExistence(timeout: 20))
        capture("03-reader")

        // 4. The same page with the one-handed control bar revealed.
        reader.tap()
        capture("04-reader-controls")

        // Relaunch rather than navigate back: the reader hides both the
        // navigation bar and the tab bar, and its own control bar is addressed
        // only by localized labels. A relaunch is deterministic in every
        // language, and the seed is idempotent.
        app.terminate()
        app.launch()

        // 5. Type controls.
        let settings = app.tabButton(.settings)
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.tap()
        let reading = app.buttons["settings.appearance"]
        reveal(reading)
        XCTAssertTrue(reading.waitForExistence(timeout: 10))
        reading.tap()
        XCTAssertTrue(app.sliders.firstMatch.waitForExistence(timeout: 10))
        capture("05-reading-settings")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // 6. Sources — the part that makes the app work at all.
        // Back at the top of the list it was scrolled down, and the first section
        // has been left behind the same way the sixth one was.
        let sources = app.buttons["settings.sources"]
        reveal(sources, swipingUp: false)
        XCTAssertTrue(sources.waitForExistence(timeout: 10))
        sources.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "sources.row")
            .firstMatch.waitForExistence(timeout: 10))
        capture("06-sources")

        // 7. Adding a source by pasting a book link — the derivation screen.
        app.navigationBars.buttons.element(boundBy: 1).tap()
        let derive = app.buttons["sources.derive"]
        XCTAssertTrue(derive.waitForExistence(timeout: 10))
        derive.tap()
        XCTAssertTrue(app.textViews["derive.url"].waitForExistence(timeout: 10)
                      || app.textFields["derive.url"].waitForExistence(timeout: 2))
        capture("07-derive")
    }

    /// Full-screen, device-resolution captures, kept in the result bundle so the
    /// Makefile can export them by name.
    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
