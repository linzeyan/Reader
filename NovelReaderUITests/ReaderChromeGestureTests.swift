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
        // The app opens on the reading history, which the demo seed always leaves
        // something unfinished in. This walk starts from the shelf, so it asks for it.
        app.openLibraryTab()
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
        // A paragraph wholly inside the window, and clear of both ends of it, rather
        // than a fixed index. The demo book opens where its reader left off, part-way
        // into the chapter, so the paragraphs before it sit above the window — and
        // tapping one of those makes XCUITest scroll it into view, which moves the very
        // text this test is watching. The margin keeps the tap out from under the
        // capsule and the control bar, which appear over the page after the first tap.
        let paragraphs = app.descendants(matching: .any).matching(identifier: "reader.paragraph")
        XCTAssertTrue(paragraphs.firstMatch.waitForExistence(timeout: 20))
        let reachable = app.windows.firstMatch.frame.insetBy(dx: 0, dy: 120)
        let paragraph = try XCTUnwrap(
            (0..<paragraphs.count)
                .map { paragraphs.element(boundBy: $0) }
                .first { reachable.contains($0.frame) },
            "the reader should have a paragraph fully on screen to watch"
        )
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
