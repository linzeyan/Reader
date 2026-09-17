import XCTest

/// The two claims about a paginated book being read with no hand on it that only a
/// running app can settle: that the page turns itself at the reader's pace, and that it
/// turns itself to keep up with a voice.
///
/// Everything underneath them is asserted without a screen — how long a page of text is
/// worth, which page an anchor is on, which characters the band covers. What none of that
/// can see is a wait that never elapses or a turn that never reaches the renderer, and
/// either of those is a reader looking at one page for ever while a control tells them the
/// book is moving. That is the same shape of failure the scrolling walks exist for.
///
/// Offline throughout: the fictional demo library, so no site rule and no network.
final class PaginatedAutoReadingGestureTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    /// The renderer and the speed come from launch arguments rather than from tapping the
    /// settings, which would persist the choice into this simulator for every later test.
    /// Each walk sets its own speed, which is why launching is not in `setUp`.
    private func launch(_ speed: [String]) {
        app.launchArguments = ["-NovelReaderDemoSeed", "-reader.mode", "paginated"] + speed
        app.launch()
    }

    /// The pace is the fastest the strip itself offers: at the default, one page of prose
    /// is well over a minute of a walk waiting to be allowed to look.
    func testThePagesTurnThemselvesAtTheReadersPace() throws {
        launch(["-reader.autoScrollPace", "60"])
        openTheDemoBook()
        showControls()

        let control = app.descendants(matching: .any)
            .matching(identifier: "reader.autoScroll").firstMatch
        XCTAssertTrue(
            control.waitForExistence(timeout: 5),
            "the paginated renderer's control bar should offer to turn the pages"
        )

        let opened = progress()
        control.tap()
        XCTAssertTrue(
            movedOn(from: opened, within: 90),
            "the pages were told to turn themselves and the reader is still on the first one"
        )

        control.tap()
        let stopped = progress()
        // Longer than a page is worth at this pace, so a switch that did not really go off
        // would have turned one by now.
        Thread.sleep(forTimeInterval: 40)
        XCTAssertEqual(
            progress(), stopped,
            "pages switched off have to stay where the reader stopped them"
        )
    }

    /// Reading a whole page aloud is what this costs, and there is no shortcut worth
    /// taking: a walk that turned the page itself and then watched the voice pull it back
    /// would prove the page can follow a sentence without ever proving that the voice
    /// reaches the foot of a page and carries on. So the budget is a page of prose read at
    /// the fastest pace the strip offers, with the poll below answering the moment it
    /// happens.
    func testTheVoiceTurnsThePagesItReadsPast() throws {
        launch(["-reader.speechPace", "0.8"])
        openTheDemoBook()
        showControls()

        let control = app.descendants(matching: .any)
            .matching(identifier: "reader.speech").firstMatch
        XCTAssertTrue(
            control.waitForExistence(timeout: 5),
            "the paginated renderer's control bar should offer to read the book aloud"
        )

        let opened = progress()
        control.tap()
        // The pace strip is the one thing on screen that says listening began.
        let pace = app.descendants(matching: .any)
            .matching(identifier: "reader.speech.rate").firstMatch
        XCTAssertTrue(
            pace.waitForExistence(timeout: 10),
            "tapping the control should have started a voice in this book"
        )

        XCTAssertTrue(
            movedOn(from: opened, within: 180),
            "the page was read aloud to its foot and the reader is still looking at it"
        )

        control.tap()
        let stopped = progress()
        Thread.sleep(forTimeInterval: 20)
        XCTAssertEqual(
            progress(), stopped,
            "a voice the reader paused has to stop turning their pages"
        )
    }

    private func openTheDemoBook() {
        // The app opens on the reading history, which the demo seed always leaves
        // something unfinished in. These walks start from the shelf, so they ask for it.
        app.openLibraryTab()
        let book = app.demoNovelRow()
        XCTAssertTrue(book.waitForExistence(timeout: 20), "the demo library should be seeded")
        book.tap()
        let read = app.descendants(matching: .any).matching(identifier: "book.read").firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 20))
        read.tap()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "reader.page")
                .firstMatch.waitForExistence(timeout: 20),
            "the paginated renderer should be showing"
        )
        XCTAssertGreaterThan(progress(), 0, "the reader should be showing where it opened")
    }

    /// The middle band shows the chrome however pages are turned — the two quarters at the
    /// sides turn them, and this is deliberately clear of both.
    private func showControls() {
        app.descendants(matching: .any).matching(identifier: "reader.page").firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .tap()
    }

    /// Whether the reader has left the page they were on, within the time given.
    ///
    /// Polled rather than slept through: each query is an accessibility snapshot that
    /// blocks the app while it is taken, so a walk that asked once after a fixed wait would
    /// be measuring the snapshot as much as the reading.
    private func movedOn(from page: Int, within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if progress() != page { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    /// The reader's own progress figure as a whole number of percent, which is the only
    /// thing on a page that says which page it is — see `CrossPageSelectionGestureTests`,
    /// which reads it the same way and for the same reason.
    private func progress() -> Int {
        let figure = app.descendants(matching: .any)
            .matching(identifier: "reader.pageNumber").firstMatch
        guard figure.waitForExistence(timeout: 10) else { return -1 }
        return Int(figure.label.filter(\.isNumber)) ?? -1
    }
}
