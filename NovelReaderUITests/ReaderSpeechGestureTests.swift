import XCTest

/// The claim only a running app can settle about reading a book out loud: that the
/// control in the bar starts a voice, and that the page goes where the voice goes.
///
/// Everything under it can be — and is — asserted without sound: which sentences a
/// chapter breaks into, where each of them sits, when the page should move and to where.
/// None of that touches `AVSpeechSynthesizer`, and a voice that is never actually handed
/// an utterance, or one whose callbacks never come back, would leave every one of those
/// tests green and the reader looking at a page that has stopped for ever. That is the
/// same shape of failure the auto-scroll walk exists for.
///
/// Offline throughout: the fictional demo library, so no site rule and no network.
final class ReaderSpeechGestureTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // The renderer and the pace come from the launch arguments rather than from
        // tapping a control, which would persist the choice into this simulator for every
        // later test. The pace is the fastest the strip itself offers: a walk at the
        // default would be waiting out a page of prose read at conversation speed.
        app.launchArguments = [
            "-NovelReaderDemoSeed", "-reader.mode", "scroll", "-reader.speechPace", "0.8"
        ]
        app.launch()
    }

    func testTheControlBarReadsTheBookOutLoudAndThePageFollowsIt() throws {
        app.openLibraryTab()
        let book = app.demoNovelRow()
        XCTAssertTrue(book.waitForExistence(timeout: 20), "the demo library should be seeded")
        book.tap()
        let read = app.descendants(matching: .any).matching(identifier: "book.read").firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 20))
        read.tap()

        XCTAssertTrue(
            app.otherElements["reader.text"].waitForExistence(timeout: 20),
            "the scrolling renderer should be showing"
        )
        XCTAssertFalse(app.topParagraphLabel().isEmpty, "the reader should have text on screen")

        showControls()
        let control = app.descendants(matching: .any)
            .matching(identifier: "reader.speech").firstMatch
        XCTAssertTrue(
            control.waitForExistence(timeout: 5),
            "the scrolling renderer's control bar should offer to read the book aloud"
        )

        let start = app.topParagraphLabel()
        control.tap()

        // The pace strip is the one thing on screen that says listening began: it is shown
        // for a reader who is listening and for one who has paused, and for nobody else.
        let pace = app.descendants(matching: .any)
            .matching(identifier: "reader.speech.rate").firstMatch
        XCTAssertTrue(
            pace.waitForExistence(timeout: 10),
            "tapping the control should have started a voice in this book"
        )

        // And the voice really is working through the chapter: the page only moves once
        // what is being read has walked down to two thirds of the window, so a page that
        // has moved is several sentences that were really said.
        XCTAssertTrue(
            movedAway(from: start, within: 90),
            "the book was read aloud and the same paragraph is still at the top"
        )

        control.tap()
        let stopped = app.topParagraphLabel()
        // Long enough that the pace under test would have carried the reader past a
        // paragraph several times over.
        Thread.sleep(forTimeInterval: 5)
        XCTAssertEqual(
            app.topParagraphLabel(), stopped,
            "a voice the reader paused has to stop reading them the book"
        )
    }

    /// Brings the chrome up by tapping text in the band that asks for it — see
    /// `ReaderAutoScrollGestureTests`, which does this for the same reasons.
    private func showControls() {
        let paragraphs = app.descendants(matching: .any).matching(identifier: "reader.paragraph")
        XCTAssertTrue(paragraphs.firstMatch.waitForExistence(timeout: 20))
        let window = app.windows.firstMatch.frame
        let reachable = window.insetBy(dx: 0, dy: 120)
        let band = window.insetBy(dx: window.width * 0.4, dy: window.height * 0.4)
        let paragraph = (0..<paragraphs.count)
            .map { paragraphs.element(boundBy: $0) }
            .first {
                reachable.contains($0.frame)
                    && band.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
            }
        paragraph?.tap()
    }

    /// Whether the text at the top of the window has changed within the time given.
    ///
    /// Polled rather than slept through: each query is an accessibility snapshot that
    /// blocks the app while it is taken, so a walk that asked once after a fixed wait
    /// would be measuring the snapshot as much as the reading.
    private func movedAway(from label: String, within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if app.topParagraphLabel() != label { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }
}
