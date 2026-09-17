import XCTest

/// The claim only a running app can settle about a comic that moves on its own: that the
/// control in the bar starts it, and that the same control stops it.
///
/// The driver underneath is the text reader's, and its arithmetic is asserted without a
/// screen in `AutoScrollTests` — but nothing there knows whether it was ever wired to this
/// scroll view, whether a pace stated in screens survives the trip through a view that
/// magnifies, or whether the page the reader is on ever changes. A comic column is built on
/// estimated heights and corrected as images land, which is a second way for a surface to
/// look like one that is moving while the reader stays put.
///
/// Offline throughout: the fictional demo library, whose one downloaded comic chapter is
/// drawn on the spot — so no site rule and no network.
final class ComicAutoScrollGestureTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // The pace comes from the launch arguments rather than from dragging the slider,
        // which would persist the choice into this simulator for every later test. It is
        // the fastest the strip itself offers: at the default a walk would be waiting out
        // twenty seconds a screen.
        app.launchArguments = ["-NovelReaderDemoSeed", "-reader.comicScrollPace", "8"]
        app.launch()
    }

    func testTheControlBarStartsAndStopsThePagesMovingOnTheirOwn() throws {
        openTheDemoComic()
        // Brings the chrome up. The middle band shows the controls however pages are
        // turned — the same tap `ScreenshotTests` uses to photograph this bar.
        app.tap()
        let control = app.descendants(matching: .any)
            .matching(identifier: "comic.autoScroll").firstMatch
        XCTAssertTrue(
            control.waitForExistence(timeout: 10),
            "the comic reader's control bar should offer to move the pages"
        )

        let opened = whereTheReaderIs()
        XCTAssertFalse(opened.isEmpty, "the capsule should say which page this is")
        control.tap()
        // The strip is the one thing on screen that says the switch really went on.
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "comic.autoScroll.speed")
                .firstMatch.waitForExistence(timeout: 5),
            "starting the pages should offer the speed they move at"
        )
        XCTAssertTrue(
            movedOn(from: opened, within: 60),
            "the pages were told to move and the reader is still on the same one"
        )

        control.tap()
        let stopped = whereTheReaderIs()
        // Long enough that the pace under test would have carried the reader past a page.
        Thread.sleep(forTimeInterval: 15)
        XCTAssertEqual(
            whereTheReaderIs(), stopped,
            "pages switched off have to stay where the reader stopped them"
        )
    }

    /// The seeded comic whose pages are on the device. Opened by name for the reason the
    /// screenshot walk names it: a comic with nothing downloaded gives an empty reader on
    /// a run with no network, which reads as a renderer that failed to come up.
    private func openTheDemoComic() {
        app.openLibraryTab()
        let comics = app.buttons["library.mode.comic"]
        XCTAssertTrue(comics.waitForExistence(timeout: 20), "the comic shelf should be there")
        comics.tap()
        let comic = app.descendants(matching: .any).matching(identifier: "library.book")
            .containing(.staticText, identifier: "霜降之城").firstMatch
        XCTAssertTrue(comic.waitForExistence(timeout: 20), "the demo comics should be seeded")
        comic.tap()
        let read = app.descendants(matching: .any).matching(identifier: "book.read").firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 20))
        read.tap()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "comic.page")
                .firstMatch.waitForExistence(timeout: 20),
            "the downloaded chapter should lay its pages out"
        )
        // A page is drawn before its bytes are decoded — the column stacks on estimates and
        // corrects them — and those corrections move the content. Letting them land first
        // is what keeps this walk about the driver.
        Thread.sleep(forTimeInterval: 2)
    }

    /// Which chapter and page the capsule says the reader is on. The only thing on screen
    /// that answers "where am I" in a medium with no text to read back.
    private func whereTheReaderIs() -> String {
        app.descendants(matching: .any).matching(identifier: "comic.chapterTitle")
            .firstMatch.label
    }

    /// Polled rather than slept through: each query is an accessibility snapshot that
    /// blocks the app while it is taken, so a walk that asked once after a fixed wait would
    /// be measuring the snapshot as much as the scrolling.
    private func movedOn(from place: String, within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if whereTheReaderIs() != place { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }
}
