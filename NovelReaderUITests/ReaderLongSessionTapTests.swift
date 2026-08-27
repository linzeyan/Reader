import XCTest

/// Drives tapped page turns against a session-sized loaded window, and nothing more.
///
/// The report this serves: after the app has been in use for a while, a tap stalls for
/// seconds and only the *second* tap puts the page where it belongs. It happens
/// mid-chapter and on fully downloaded books, so what grows with "a while" is the
/// reader's own loaded window — `-reader.stressPreload` rebuilds that state up front,
/// through the same path a real session grows by.
///
/// What these walks settle on their own is that the page keeps moving. That is a question
/// about state rather than timing, which is why it holds with no probes in the app: XCUI
/// waits for the app to idle before every query, which ruins a duration but is exactly
/// right for reading a screen that has settled. A tap that turned nothing is what the
/// report describes, and it is what these assert.
///
/// How *long* a stall lasted is the part no XCUI query can read — an in-test measurement
/// is inflated by the very stalls it is trying to measure, and an earlier version of this
/// walk reported misses on turns a recording showed were frame-perfect. That verdict needs
/// a probe kit inside the app, read out of the unified log. The taps still go through the
/// real event pipeline, which is the part no in-app probe can drive; together they are the
/// loop, and the long walk below is the harness for one — which is why it only runs when
/// it is asked for.
final class ReaderLongSessionTapTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    /// The frontier walk: no preload, tapped turns at reading pace, so `loadNext`
    /// fires the way it does in a real session — with the append landing a page or
    /// two below the viewport, where the lazy stack realizes the new rows at once.
    /// The preload curve above showed appends far below the fold cost nothing the
    /// simulator can see; this is the other half of the device scenario.
    func testTapWalkAcrossTheFrontier() throws {
        launch(preloadChapters: 0)
        openReader()
        Thread.sleep(forTimeInterval: 3)
        drive(turns: 18)
    }

    /// The frontier walk with the control bar up: the reported "with the toolbar
    /// open, every tapped turn stutters". The centre tap summons the controls;
    /// the turns that follow are the same turns the plain walk makes.
    func testTapWalkWithControlsShown() throws {
        launch(preloadChapters: 0)
        openReader()
        Thread.sleep(forTimeInterval: 3)
        // Relative to the app (the screen), not to "reader.text": that element's
        // accessibility frame is the whole scrollable column, thousands of points
        // tall, so its centre is nowhere near the window's centre.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        // The walk is about the controls being up; a missed centre tap would
        // silently re-run the plain walk and compare nothing. The `.any` descendant
        // query is the one `ReaderChromeGestureTests` uses — the capsule's element
        // type is not a static text.
        let capsule = app.descendants(matching: .any)
            .matching(identifier: "reader.chapterTitle").firstMatch
        XCTAssertTrue(
            capsule.waitForExistence(timeout: 5),
            "the control chrome should be up for the whole walk"
        )
        drive(turns: 18)
    }

    /// Hours of an evening's reading, compressed to what actually accumulates: the
    /// chapters crossed. The pace is the same tapped turn every two seconds, so seven
    /// hundred turns is roughly three hours at a real reading speed — and lands about two
    /// fifths of the way through the stress book, whose 160 chapters carry ~200 paragraphs
    /// each, the shape of the real serials the reports come from.
    ///
    /// Opt-in, and deliberately: it costs half an hour, and on its own it can only report
    /// that the page never stopped moving — which the short walks above already ask, for
    /// the price of a minute. The numbers it exists to produce — `loaded=` pinned at the
    /// window, stall sizes and memory the same at chapter seventy as at chapter seven —
    /// come from a probe kit in the app, so it runs when there is one there to read.
    func testAMultiHourReadingSessionCompressed() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["NOVELREADER_SOAK"] == "1",
            "Half an hour of taps with nothing measuring them: run `make test-soak`, "
                + "with a probe kit in the app to read afterwards."
        )
        launch(preloadChapters: 0)
        openReader()
        Thread.sleep(forTimeInterval: 3)
        drive(turns: 700)
    }

    /// The state a long evening of continuous reading arrives at, without the evening.
    func testTapTurnsInAnInflatedSession() throws {
        launch(preloadChapters: 120)
        openReader()
        // The preload runs behind the first frame; the wait covers the disk reads and
        // the layout churn each append causes.
        Thread.sleep(forTimeInterval: 12)
        drive(turns: 20)
    }

    /// The same walk with nothing accumulated — the baseline the probe log is read
    /// against.
    func testTapTurnsInAFreshSession() throws {
        launch(preloadChapters: 0)
        openReader()
        Thread.sleep(forTimeInterval: 3)
        drive(turns: 6)
    }

    private func launch(preloadChapters: Int) {
        // Renderer and tap zones from launch arguments, not Settings taps, so nothing
        // persists into the simulator for later tests — see ReaderPageTurnGestureTests
        // for why the flag is `1` and not `YES`.
        app.launchArguments = [
            "-NovelReaderDemoSeed", "-NovelReaderDemoStress",
            "-reader.mode", "scroll", "-reader.tapToTurnPage", "1",
            "-reader.stressPreload", String(preloadChapters),
        ]
        // A/B arms arrive through the environment (TEST_RUNNER_ prefix on the
        // xcodebuild side), so both arms run the same build and the same walk.
        if let extra = ProcessInfo.processInfo.environment["READER_EXTRA_ARGS"] {
            app.launchArguments += extra.split(separator: " ").map(String.init)
        }
        app.launch()
    }

    private func openReader() {
        // The app opens on the reading history, where the stress book's progress row
        // is the newest and therefore the first — and a history row leads straight
        // into the text.
        let book = app.descendants(matching: .any).matching(identifier: "recent.book").firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20), "the stress book should be seeded")
        book.tap()
        XCTAssertTrue(
            app.otherElements["reader.text"].waitForExistence(timeout: 20),
            "the scrolling renderer should be showing"
        )
    }

    /// Forward taps on a fixed cadence, watching that the text keeps moving under them.
    ///
    /// Two seconds is enough for a healthy turn to land and settle, and short enough that
    /// a stalled one is still stalled when the next tap arrives — which is exactly the
    /// double-tap the report describes.
    ///
    /// Two consecutive turns that move nothing is the failure, not one: the report is a
    /// tap that does nothing *and goes on doing nothing* until the reader swipes, while a
    /// single synthesized tap can miss for reasons of its own.
    ///
    /// Compared turn by turn rather than in strides, because the stress book repeats one
    /// chapter's twenty-nine paragraphs seven times over — a label names a row only
    /// together with a position, and samples far enough apart can land on identical text
    /// four chapters along. A ten-turn stride reported a stuck page on a walk that was
    /// moving perfectly well; one turn moves fifteen to twenty-one paragraphs, which can
    /// never be a whole number of repeats.
    private func drive(turns: Int) {
        let text = app.otherElements["reader.text"]
        var seen = app.topParagraphLabel()
        var unmoved = 0
        for turn in 1...turns {
            // Half way across and most of the way down the *screen*: inside the
            // forward zone, clear of the middle cell that toggles the chrome. App
            // coordinates, because "reader.text" is the whole scrollable column
            // and points on it land wherever the scroll offset happens to put them.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
            Thread.sleep(forTimeInterval: 2.0)
            let now = app.topParagraphLabel()
            unmoved = now == seen ? unmoved + 1 : 0
            seen = now
            XCTAssertLessThan(
                unmoved, 2,
                "turns \(turn - 1) and \(turn) both left the top of the window on the same "
                    + "paragraph — the tap that does nothing, and keeps doing nothing"
            )
        }
        XCTAssertTrue(text.exists, "the walk should end still inside the reader")
    }
}
