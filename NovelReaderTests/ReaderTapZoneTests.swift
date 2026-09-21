import XCTest
@testable import NovelReader

/// Where a tap lands, and where the text goes when it does.
///
/// The zones exist because one tap has to answer three questions, and the corners are the
/// part a reader discovers by accident: a tap meant for the controls that turns a page
/// instead moves the text they were reading. So the rule is stated once, here, rather
/// than left implicit in a gesture handler.
final class ReaderTapZoneTests: XCTestCase {
    private let window = CGSize(width: 400, height: 800)

    private func zone(_ x: CGFloat, _ y: CGFloat) -> ReaderTapZone.Zone {
        ReaderTapZone.zone(at: CGPoint(x: x, y: y), in: window)
    }

    /// One chapter throughout: the geometry rules do not care which chapter a frame is
    /// in, so only the paragraph number — which is how a turn names what it aims at — is
    /// given.
    private func paragraph(
        _ number: Int, minY: CGFloat, maxY: CGFloat
    ) -> ReaderTapZone.VisibleParagraph {
        ReaderTapZone.VisibleParagraph(
            chapterIndex: 0, paragraph: number, minY: minY, maxY: maxY
        )
    }

    func testTheMiddleOfTheScreenAsksForTheControls() {
        XCTAssertEqual(zone(200, 400), .controls)
    }

    /// The reader's own description of the layout: the right side and the bottom go on,
    /// the left side and the top go back.
    func testTheSidesAndTheEndsTurnPages() {
        XCTAssertEqual(zone(380, 400), .next, "right of the middle band")
        XCTAssertEqual(zone(200, 780), .next, "below it")
        XCTAssertEqual(zone(20, 400), .previous, "left of it")
        XCTAssertEqual(zone(200, 20), .previous, "above it")
    }

    /// Rows are decided before columns, so each corner has exactly one answer rather than
    /// being an argument between "left means back" and "bottom means on".
    func testEveryCornerHasOneAnswer() {
        XCTAssertEqual(zone(0, 0), .previous)
        XCTAssertEqual(zone(400, 0), .previous, "top-right is top, not right")
        XCTAssertEqual(zone(0, 800), .next, "bottom-left is bottom, not left")
        XCTAssertEqual(zone(400, 800), .next)
    }

    /// A window with no size is a view that has not been laid out yet. Nothing may be
    /// turned on the strength of a tap measured against nothing.
    func testAnUnlaidOutWindowTurnsNothing() {
        XCTAssertEqual(ReaderTapZone.zone(at: .zero, in: .zero), .controls)
    }

    // MARK: - Turning a page

    /// Half-visible paragraphs are the reason this is not "scroll by 800 points": the
    /// paragraph the reader could only partly see comes back whole at the top of the next
    /// page instead of being cut in half by the turn.
    func testGoingOnPutsTheLastParagraphThatStartedOnScreenAtTheTop() {
        let visible = [
            paragraph(0, minY: -100, maxY: 200),
            paragraph(1, minY: 200, maxY: 600),
            paragraph(2, minY: 600, maxY: 900),
        ]
        let scroll = ReaderTapZone.pageScroll(.next, over: visible, viewport: 800)
        XCTAssertEqual(
            scroll, ReaderTapZone.PageScroll(chapterIndex: 0, paragraph: 2, anchor: .top)
        )
    }

    /// Going back aims the top paragraph at the bottom of the window, which lands a page
    /// earlier and keeps the line the reader was on in sight. A page turn that overlaps is
    /// one nobody has to double-check.
    func testGoingBackPutsTheTopParagraphAtTheBottom() {
        let visible = [
            paragraph(0, minY: -100, maxY: 200),
            paragraph(1, minY: 200, maxY: 600),
        ]
        let scroll = ReaderTapZone.pageScroll(.previous, over: visible, viewport: 800)
        XCTAssertEqual(
            scroll, ReaderTapZone.PageScroll(chapterIndex: 0, paragraph: 0, anchor: .bottom)
        )
    }

    /// Paragraphs scrolled past are still reported by the preference key that collects
    /// them; a turn that counted those would jump backwards through text already read.
    func testParagraphsOffScreenAreNotCandidates() {
        let visible = [
            paragraph(0, minY: -900, maxY: -100),
            paragraph(1, minY: 100, maxY: 400),
            paragraph(2, minY: 900, maxY: 1200),
        ]
        XCTAssertEqual(
            ReaderTapZone.pageScroll(.next, over: visible, viewport: 800)?.paragraph, 1,
            "the one on screen, not the one scrolled past or the one still below"
        )
        XCTAssertEqual(
            ReaderTapZone.pageScroll(.previous, over: visible, viewport: 800)?.paragraph, 1
        )
    }

    /// A paragraph taller than the window — a wall of dialogue, or a chapter the site
    /// serves as one block — has no neighbour on screen to aim at, so the move has to be
    /// made inside it. The anchor is what `scrollTo` lines up with the same point of the
    /// window: for a paragraph of 2400 in a window of 800, a window's travel is a third
    /// of the way through what can be scrolled.
    func testATallParagraphIsWalkedThroughFromInside() {
        let tall = [paragraph(7, minY: 0, maxY: 2400)]
        let onwards = ReaderTapZone.pageScroll(.next, over: tall, viewport: 800)
        XCTAssertEqual(onwards?.paragraph, 7)
        XCTAssertEqual(onwards?.anchor.y ?? 0, 0.5, accuracy: 0.0001)

        // And it stops at the paragraph's own ends rather than walking off them.
        let atTheTop = [paragraph(7, minY: 0, maxY: 2400)]
        XCTAssertEqual(
            ReaderTapZone.pageScroll(.previous, over: atTheTop, viewport: 800)?.anchor.y, 0
        )
    }

    /// The controls band is not a page turn, and an empty screen is not a page turn
    /// either — a scroll view mid-rebuild reports nothing visible.
    func testNothingToTurnIsNoScroll() {
        let visible = [paragraph(0, minY: 0, maxY: 400)]
        XCTAssertNil(ReaderTapZone.pageScroll(.controls, over: visible, viewport: 800))
        XCTAssertNil(ReaderTapZone.pageScroll(.next, over: [], viewport: 800))
    }
}
