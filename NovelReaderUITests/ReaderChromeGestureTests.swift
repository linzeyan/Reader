import XCTest

/// The one claim about the reader's chrome that only a running app can settle: that
/// bringing the controls up leaves the text exactly where it was.
///
/// This is the report that produced the change. The controls used to be a navigation bar,
/// and a bar that appears takes its height out of the safe area — so every line of the
/// chapter slid down while the reader was looking at it, and slid back when the controls
/// went away. Nothing offline can catch that: the position model, the anchors and the
/// paragraph ids are all unaffected by it. Only the frame of a paragraph on screen knows.
///
/// Offline throughout: the fictional demo library, so no site rule and no network.
final class ReaderChromeGestureTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // The renderer comes from the launch arguments, never from tapping the setting:
        // tapping would persist the choice into this simulator and decide which renderer
        // every later test gets. See `ScrollHighlightGestureTests`.
        app.launchArguments = ["-NovelReaderDemoSeed", "-reader.mode", "scroll"]
        app.launch()
    }

    func testBringingUpTheControlsLeavesTheTextWhereItWas() throws {
        let book = app.descendants(matching: .any).matching(identifier: "library.book").firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20), "the demo library should be seeded")
        book.tap()
        let read = app.descendants(matching: .any).matching(identifier: "book.read").firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 20))
        read.tap()

        XCTAssertTrue(
            app.otherElements["reader.text"].waitForExistence(timeout: 20),
            "the scrolling renderer should be showing"
        )
        // The second paragraph rather than the first: clear of the chapter heading, and of
        // the top of the screen where a bar would have pushed it.
        let paragraph = app.descendants(matching: .any)
            .matching(identifier: "reader.paragraph").element(boundBy: 1)
        XCTAssertTrue(paragraph.waitForExistence(timeout: 20))
        let before = paragraph.frame

        paragraph.tap()

        let capsule = app.descendants(matching: .any)
            .matching(identifier: "reader.chapterTitle").firstMatch
        XCTAssertTrue(
            capsule.waitForExistence(timeout: 5),
            "a tap on unmarked text should bring the chrome up"
        )
        XCTAssertEqual(
            paragraph.frame.minY, before.minY, accuracy: 0.5,
            "the chapter must not move under the reader when the controls appear"
        )

        // And going away must not move it back, which is the other half of the same
        // complaint: the text bounced in both directions.
        paragraph.tap()
        XCTAssertFalse(capsule.waitForExistence(timeout: 2), "the chrome should be gone again")
        XCTAssertEqual(paragraph.frame.minY, before.minY, accuracy: 0.5)
    }
}
