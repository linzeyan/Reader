import XCTest

/// What an hour of being read to costs the app itself, measured rather than reasoned
/// about.
///
/// Opt-in, and its verdict is not an assertion: it is the `[DEBUG-ap1]` timeline in the
/// unified log — `bodyRate` (how often the reader's view is re-evaluated), `lost%` (main
/// thread spent past the stall threshold), `loaded` (chapters the model is holding) and
/// `rss` (resident megabytes). Run it with the kit armed:
///
/// ```
/// NOVELREADER_PROBE=1 xcodebuild test ... \
///   -only-testing:NovelReaderUITests/ReaderListeningProbeTests
/// xcrun simctl spawn "iPhone 17" log show --style compact \
///   --predicate 'eventMessage CONTAINS "[DEBUG-ap1]"' --last 15m
/// ```
///
/// The one thing it cannot measure is the synthesiser: on a simulator that runs on the
/// host's CPU, and a Mac's idea of what a voice costs is not a phone's. What transfers is
/// everything on this side of it — the work the app does *because* a voice is reading, and
/// what the session accumulates while nobody is touching it.
///
/// Nothing is asked of the app once listening has started. An XCUI query takes an
/// accessibility snapshot, which blocks the main thread for as long as it takes to build —
/// and main-thread time is precisely what is being counted here.
final class ReaderListeningProbeTests: XCTestCase {
    private var app: XCUIApplication!

    /// Long enough to cross a chapter or two in the demo book, which is what makes the
    /// `loaded=` and `rss=` columns say anything about where a long session ends up.
    private static let listenFor: TimeInterval = 8 * 60

    func testWhatListeningCostsWithNobodyTouchingIt() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["NOVELREADER_PROBE"] == "1",
            "The listening probe is opt-in: arm the kit, run it, then read the "
                + "[DEBUG-ap1] lines out of the unified log."
        )
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-NovelReaderDemoSeed", "-reader.mode", "scroll",
            "-reader.speechPace", "0.8", "-reader.probe", "1"
        ]
        app.launch()

        app.openLibraryTab()
        let book = app.demoNovelRow()
        XCTAssertTrue(book.waitForExistence(timeout: 20), "the demo library should be seeded")
        book.tap()
        let read = app.descendants(matching: .any).matching(identifier: "book.read").firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 20))
        read.tap()
        XCTAssertTrue(app.otherElements["reader.text"].waitForExistence(timeout: 20))

        // The chrome, then the voice. Both by coordinate rather than by query where it can
        // be: the fewer snapshots taken before the window being measured, the less of the
        // first summary is the walk's own doing.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let control = app.descendants(matching: .any)
            .matching(identifier: "reader.speech").firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 10))
        control.tap()

        Thread.sleep(forTimeInterval: Self.listenFor)

        // One query, at the end, by which time the timeline is already written.
        XCTAssertTrue(
            app.otherElements["reader.text"].exists,
            "the walk should end still inside the book it was being read"
        )
    }
}
