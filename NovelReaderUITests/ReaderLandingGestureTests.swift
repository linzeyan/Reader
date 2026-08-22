import XCTest

/// Where a book opens.
///
/// A stored position names a paragraph part-way into a chapter, and landing on it is the
/// one thing the scrolling reader cannot do in a single move: a lazy stack positions rows
/// it has not built from estimates, so the first `scrollTo` lands somewhere near and the
/// content then slides under it as the estimates are corrected. Whatever machinery is
/// responsible for converging on the target, this is the claim it exists to keep.
///
/// Written before that machinery is replaced, so the replacement has something to answer
/// to. Nothing offline in the model can check it — the anchor is right in every version
/// of this bug; only the frame of the paragraph on screen knows where the reader ended up.
final class ReaderLandingGestureTests: XCTestCase {
    private var app: XCUIApplication!

    /// The stress book's stored position, from `DemoSeed`: the middle paragraph of its
    /// second chapter. Written out rather than derived, because a walk that computed it
    /// from the same expression the seed uses could only ever agree with itself.
    private let landingParagraph = "「寫了。」他說，「都沒有寄。」"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-NovelReaderDemoSeed", "-NovelReaderDemoStress", "-reader.mode", "scroll",
        ]
        app.launch()
    }

    func testABookOpensAtTheStoredPositionRatherThanTheChapterHead() throws {
        let book = app.descendants(matching: .any).matching(identifier: "recent.book").firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20), "the stress book should be seeded")
        book.tap()
        XCTAssertTrue(
            app.otherElements["reader.text"].waitForExistence(timeout: 20),
            "the scrolling renderer should be showing"
        )
        // The landing converges over several layout passes; this is the moment it is
        // allowed to have finished by.
        Thread.sleep(forTimeInterval: 3)

        // Every chapter of the demo book carries the same text, and the chapter read
        // ahead is loaded by now — so this string is on the page more than once. The
        // copy nearest the top of the window is the one the landing was aimed at;
        // taking it by position rather than by tree order keeps the claim honest
        // whichever way the accessibility tree happens to be walked.
        let matches = app.staticTexts.matching(
            NSPredicate(format: "label == %@", landingParagraph)
        )
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 10), "the stored paragraph should be built")
        let window = app.windows.firstMatch.frame
        let offsets = (0..<matches.count)
            .map { matches.element(boundBy: $0).frame.minY - window.minY }
        let paragraphOffset = try XCTUnwrap(offsets.min(by: { abs($0) < abs($1) }))
        // Near the top of the window, which is where a landing puts its target. The demo
        // chapter's paragraphs are short enough that this one is *visible* from the head
        // of the chapter too — that is exactly how an earlier version of the arrival gate
        // passed while landing in the wrong place — so being on screen is not the claim.
        //
        // The top third, not the top edge. A landing can only put its target at the very
        // top when there is a screenful of text below it, and the demo chapter is under
        // two screens long — so the scroll clamps against the end of what is loaded and
        // stops a couple of paragraphs short (measured: 188pt). That is the documented
        // end-of-content exit in `ReaderModel.hasArrived`, not a miss.
        //
        // A landing that failed is nowhere near this band: fourteen paragraphs of CJK
        // text is about 1200pt, well past the fold and usually not even built.
        XCTAssertLessThan(
            paragraphOffset, window.height / 3,
            "the book should open on the stored paragraph, not at the chapter head"
        )
        XCTAssertGreaterThan(paragraphOffset, -40, "and not past it either")
    }
}
