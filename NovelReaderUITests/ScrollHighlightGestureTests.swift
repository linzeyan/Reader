import XCTest

/// The one claim about marking a paragraph that arithmetic cannot support: that a long
/// press inside a scroll view reaches the paragraph instead of being eaten by the scroll.
///
/// A `ScrollView` and a long press want the same touch, and the paragraph's tap has to
/// coexist with the tap that shows the reader's controls. Every anchor, range and excerpt
/// behind the feature is covered offline by `HighlightTests`; if this arbitration is
/// wrong, all of it stays green while the feature is unreachable. `HighlightGestureTests`
/// is the paginated renderer's version of this walk, and exists for the same reason.
///
/// Offline throughout: the fictional demo library, so no site rule and no network.
final class ScrollHighlightGestureTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // The renderer comes from the launch arguments rather than from tapping the
        // setting. Tapping it would *persist* the choice in this simulator, and the
        // reading mode decides which renderer every later test gets. The argument domain
        // lasts exactly as long as this launch.
        app.launchArguments = ["-NovelReaderDemoSeed", "-reader.mode", "scroll"]
        app.launch()
    }

    func testPressingAParagraphOffersToMarkItAndTappingItOffersToRemoveIt() throws {
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
        // A paragraph wholly inside the window, not a fixed index. The demo book opens
        // part-way into its chapter, so the low indices name rows above the window —
        // and XCUITest reaches an off-screen row by scrolling it into view, which can
        // pull the previous chapter in above and renumber every index this test would
        // then re-resolve. The same pick `ReaderChromeGestureTests` makes, for the
        // same reason.
        let paragraphs = app.descendants(matching: .any).matching(identifier: "reader.paragraph")
        XCTAssertTrue(paragraphs.firstMatch.waitForExistence(timeout: 20))
        let reachable = app.windows.firstMatch.frame.insetBy(dx: 0, dy: 120)
        let paragraph = try XCTUnwrap(
            (0..<paragraphs.count)
                .map { paragraphs.element(boundBy: $0) }
                .first { reachable.contains($0.frame) },
            "the reader should have a paragraph fully on screen to mark"
        )

        // Held well past the press recogniser's delay, and without moving: a press that
        // travels is a scroll, which is the arbitration this whole test is about.
        paragraph.press(forDuration: 0.8)

        let action = app.buttons["reader.highlight.action"]
        XCTAssertTrue(
            action.waitForExistence(timeout: 5),
            "a long press must offer to mark the paragraph; failing here means the scroll view swallowed it"
        )
        action.tap()
        XCTAssertFalse(action.exists, "committing the mark should put the bar away")

        // A plain tap on the marked paragraph has to bring a bar back. Nothing else on
        // this screen does that — a tap on unmarked text toggles the reader's controls —
        // so this is the mark itself being stored, drawn, and answering for its paragraph.
        paragraph.tap()
        XCTAssertTrue(
            action.waitForExistence(timeout: 5),
            "tapping a marked paragraph should offer to remove it"
        )
    }
}
