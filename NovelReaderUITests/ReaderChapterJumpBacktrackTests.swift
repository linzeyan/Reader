import XCTest

/// What the first backward drag after a chapter jump does.
///
/// It began as one report — the drag landed the reader at the *previous* chapter's
/// opening, and kept going, a chapter per drag, toward the front of the book — and the
/// claim has since grown a second half. A jump leaves exactly one chapter loaded, so
/// that first drag has nothing above it to move into: it must neither walk backwards
/// (the report) nor refuse to move at all (the wall that fixing the report left behind).
/// Both halves are one measurement, how far the text travelled, and only the band
/// between them is a reader going back the way they came.
///
/// Inserting a chapter above the reader is the shape this file's history keeps coming
/// back to — see `docs/PITFALLS.md`.
///
/// The gesture is a slow drag with the finger still down at the end, not `swipeDown()`:
/// a flick has lifted long before the chapter arrives, and a correction that only works
/// once the glass is free is exactly the bug being chased.
///
/// Offline throughout: the stress book is a hundred and sixty chapters, all on disk.
final class ReaderChapterJumpBacktrackTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-NovelReaderDemoSeed", "-NovelReaderDemoStress", "-reader.mode", "scroll",
        ]
        app.launch()
    }

    func testAnUpwardDragAfterAChapterJumpMovesOneScreen() throws {
        // The stress book's progress row is the newest in the history the app opens on.
        let book = app.descendants(matching: .any).matching(identifier: "recent.book").firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20), "the stress book should be seeded")
        book.tap()
        let text = app.otherElements["reader.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 20), "the scrolling renderer should show")
        // Let the opening position land: while it is still re-aiming, everything below
        // measures the landing rather than the gesture.
        Thread.sleep(forTimeInterval: 2)

        // The chrome, then the jump. The next-chapter button is the same `jump` the
        // catalog makes, and it needs no localized label to find.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let next = app.descendants(matching: .any)
            .matching(identifier: "reader.nextChapter").firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 5), "the control bar should be up")
        next.tap()
        Thread.sleep(forTimeInterval: 2)
        // And put the chrome away again, so the floating capsule cannot be mistaken for
        // the heading in the text below.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 1)

        // The heading of the chapter the jump landed in: the one thing on screen whose
        // travel says how far the drag actually took the reader. Named rather than taken
        // by index — the reader's accessibility elements are built from what is on
        // screen, so an index names a different heading after every move, and asking
        // XCUITest for an off-screen element scrolls it into view, which is the very
        // state under test (`docs/PITFALLS.md`).
        //
        // 第3章 because the stress book's stored position is 第2章 and the walk jumps once.
        let landing = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "第3章")
        ).firstMatch
        XCTAssertTrue(landing.waitForExistence(timeout: 10), "the jump should land in 第3章")
        let before = landing.frame
        let window = app.windows.firstMatch.frame

        // A reader's own backward drag: slow, and still held at the end — the moment
        // the previous chapter arrives is the moment the finger is still on the glass.
        let from = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let to = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        from.press(
            forDuration: 0.4, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 2.0
        )
        Thread.sleep(forTimeInterval: 2)

        XCTAssertTrue(
            landing.exists,
            "the heading of the chapter the reader is in must still be on the page"
        )
        let travelled = landing.frame.minY - before.minY
        // Half a screen of drag may not move the text by more than one screen. Landing a
        // whole chapter earlier is what the report describes, and a chapter is several.
        XCTAssertLessThan(
            travelled, window.height,
            "an upward drag of half a screen must not move the text more than a screen"
        )
        // And it has to move. A drag with nothing above it to move into rubber-bands and
        // springs back to exactly where it started, which is what this reads as: the
        // chapter the reader wants arrives only after the finger lifts, so their way back
        // is always one gesture late. The chapter behind a landing is put in at the
        // landing for this — see `ReaderModel.loadStoredPrevious`.
        XCTAssertGreaterThan(
            travelled, window.height / 4,
            "the drag should read back into the chapter above, not rubber-band"
        )
    }
}
