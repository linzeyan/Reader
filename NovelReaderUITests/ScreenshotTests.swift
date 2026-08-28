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

        // Relaunched again, and for the same reason as before: this walk is inside a
        // sheet on a pushed screen, and unwinding it by hand is several taps that only
        // exist in one language.
        app.terminate()
        app.launch()

        // 8. The comic shelf. Its own shelf rather than more rows on the novel one,
        // which is the product decision this shot exists to show.
        app.openLibraryTab()
        let comics = app.buttons["library.mode.comic"]
        XCTAssertTrue(comics.waitForExistence(timeout: 20))
        comics.tap()
        let comic = app.descendants(matching: .any).matching(identifier: "library.book").firstMatch
        XCTAssertTrue(comic.waitForExistence(timeout: 20), "The demo comics should be seeded")
        capture("08-comic-library")

        // 9. The comic reader, on a chapter that is already on the device — a
        // screenshot run has no network, and the fixture's first row is the book whose
        // pages are seeded for exactly this reason.
        comic.tap()
        let openComic = app.descendants(matching: .any).matching(identifier: "book.read").firstMatch
        XCTAssertTrue(openComic.waitForExistence(timeout: 20))
        openComic.tap()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "comic.page")
                .firstMatch.waitForExistence(timeout: 20),
            "The downloaded chapter should lay its pages out"
        )
        // The first page is drawn before its bytes are decoded — the column stacks on
        // estimates and corrects them — so a shot taken the instant a page element
        // exists can be a shot of an empty frame.
        Thread.sleep(forTimeInterval: 2)
        // With the chapter capsule and the control bar showing. The comic reader gets
        // one slot rather than the novel's two, and pages alone could be a gallery —
        // "第 2 話 · 4 / 6" over them is what says this is a reader.
        app.tap()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "comic.chapterTitle")
                .firstMatch.waitForExistence(timeout: 10)
        )
        capture("09-comic-reader")
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
