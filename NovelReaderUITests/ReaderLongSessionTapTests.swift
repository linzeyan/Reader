import XCTest

/// Drives tapped page turns against a session-sized loaded window, and nothing more.
///
/// The report this serves: after the app has been in use for a while, a tap stalls for
/// seconds and only the *second* tap puts the page where it belongs. It happens
/// mid-chapter and on fully downloaded books, so what grows with "a while" is the
/// reader's own loaded window — `-reader.stressPreload` rebuilds that state up front,
/// through the same path a real session grows by.
///
/// This walk deliberately asserts almost nothing. The verdict comes from the
/// [DEBUG-t4p] probes inside the app, read out of the unified log by the diagnosis
/// scripts: XCUITest waits for the app to idle before every query and every synthesized
/// event, so an in-test measurement is inflated by the very stalls it is trying to
/// measure — an earlier version of this walk reported misses on turns a recording
/// showed were frame-perfect. The taps still go through the real event pipeline, which
/// is the part no in-app probe can drive; the app-side clock is the part no XCUI query
/// can read. Together they are the loop.
final class ReaderLongSessionTapTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
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

    /// Forward taps on a fixed cadence. Two seconds is enough for a healthy turn to
    /// land and settle, and short enough that a stalled one is still stalled when the
    /// next tap arrives — which is exactly the double-tap the report describes.
    private func drive(turns: Int) {
        let text = app.otherElements["reader.text"]
        for _ in 1...turns {
            // Half way across and most of the way down: inside the forward zone,
            // clear of the middle cell that toggles the chrome.
            text.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
            Thread.sleep(forTimeInterval: 2.0)
        }
        XCTAssertTrue(text.exists, "the walk should end still inside the reader")
    }
}
