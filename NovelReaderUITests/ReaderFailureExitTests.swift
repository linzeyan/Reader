import XCTest

/// One report: a site that demands verification leaves the reader on a screen with a
/// message, a retry button, and no way off it — the app had to be killed.
///
/// The screen is the same one any failed chapter produces, so it can be reached without
/// a challenge at all: a demo book with nothing on disk points at a host that does not
/// resolve. What matters is the state, not what caused it — no text, so no tap can bring
/// the floating controls up, and the navigation bar is hidden on this screen by design.
///
/// The retry is asserted too, because it used to be a button that could not act: with
/// nothing loaded there is no "next" chapter to ask for, which is the only thing it knew
/// how to do.
final class ReaderFailureExitTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-NovelReaderDemoSeed", "-reader.mode", "scroll"]
        app.launch()
    }

    func testAChapterThatWillNotLoadCanBeLeft() {
        app.openLibraryTab()
        // The demo book with no chapters on disk: opening it has to go to the network,
        // and its host is fictional.
        let book = app.staticTexts["霧都舊事"]
        XCTAssertTrue(book.waitForExistence(timeout: 20), "the demo library should be seeded")
        book.tap()
        let read = app.descendants(matching: .any).matching(identifier: "book.read").firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 20))
        read.tap()

        // The fetch has to fail first, and it is allowed a politeness pause and a
        // navigation timeout before it does.
        let retry = app.buttons["reader.retry"]
        XCTAssertTrue(
            retry.waitForExistence(timeout: 90),
            "a chapter that cannot be fetched should say so"
        )
        XCTAssertTrue(retry.isHittable, "the retry must be reachable, not merely present")

        // That the retry *asks again* is `ReaderRetryTests`, offline and deterministic:
        // here the second attempt fails as fast as the first, so the button is back
        // before a query can see it gone, and asserting on that would be timing the
        // simulator's DNS rather than the reader.

        // The way out, which is the whole report: this screen has no navigation bar and
        // no text to tap, so without this button it is a dead end.
        let back = app.buttons["reader.failure.back"]
        XCTAssertTrue(back.exists, "a failed chapter must offer a way back")
        back.tap()

        XCTAssertTrue(
            read.waitForExistence(timeout: 10),
            "leaving the failed chapter should land back on the book"
        )
    }
}
