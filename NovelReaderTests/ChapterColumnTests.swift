import UIKit
import XCTest
@testable import NovelReader

/// What the scrolling column has to guarantee.
///
/// `ChapterColumn` replaces a `LazyVStack` of SwiftUI `Text` with one laid-out TextKit 2
/// column, which moves three things that used to be the container's job into arithmetic
/// this app owns: where a paragraph sits, which paragraphs are on screen, and which
/// paragraph a scroll offset is inside. All three were previously answered by a
/// `GeometryReader` behind every row — wrong answers there showed up as the reader's
/// stored position drifting, not as a layout fault, which is why they are pinned here
/// rather than left to a walk.
@MainActor
final class ChapterColumnTests: XCTestCase {
    private func typography(size: CGFloat = 19) -> ReaderTypography {
        ReaderTypography(
            body: .systemFont(ofSize: size),
            title: .systemFont(ofSize: size + 4, weight: .semibold),
            lineSpacing: 9,
            paragraphSpacing: 14,
            color: .black
        )
    }

    /// Mixed-length Chinese paragraphs, the shape the real sites serve — including one
    /// long enough to be taller than any window, which is the case every "which
    /// paragraph is on screen" rule has to survive.
    private func paragraphs(_ count: Int = 40) -> [String] {
        (0..<count).map { index in
            let sentence = "他推開門，看見渡口的燈在雪裡亮著，像一句沒有說完的話。"
            return String(repeating: sentence, count: index % 6 + 1) + "第\(index)段。"
        }
    }

    private func column(_ paragraphs: [String], width: CGFloat = 350) -> ChapterColumn {
        let column = ChapterColumn(
            text: ChapterText(
                title: "第十七章　渡口",
                paragraphs: paragraphs,
                typography: typography(),
                alignment: .natural
            ),
            width: width
        )
        column.layOut()
        return column
    }

    // MARK: - Layout

    func testLayingOutGivesEveryParagraphAPlaceInTheColumn() {
        let text = paragraphs()
        let column = column(text)

        XCTAssertGreaterThan(column.height, 0, "a laid-out chapter has to have a height")
        XCTAssertEqual(
            column.paragraphFrames.count, text.count,
            "every paragraph needs an extent, or the reader's position cannot be named"
        )
        XCTAssertEqual(
            column.paragraphFrames.map(\.paragraph), Array(0..<text.count),
            "extents must stay in reading order and in the index a TextAnchor stores"
        )
    }

    /// The column is read top to bottom, so the extents have to be too. A paragraph
    /// that started above the one before it would send `paragraphs(in:)` — a binary
    /// search — somewhere arbitrary.
    func testParagraphExtentsRunDownThePageWithoutOverlapping() {
        let column = column(paragraphs())

        for (above, below) in zip(column.paragraphFrames, column.paragraphFrames.dropFirst()) {
            XCTAssertLessThan(
                above.minY, below.minY,
                "paragraph \(below.paragraph) must start below paragraph \(above.paragraph)"
            )
            XCTAssertLessThanOrEqual(
                above.maxY, below.minY,
                "paragraph \(above.paragraph) must end before paragraph \(below.paragraph) begins"
            )
            XCTAssertGreaterThan(
                above.maxY, above.minY, "paragraph \(above.paragraph) must have height"
            )
        }
        let last = column.paragraphFrames.last
        XCTAssertEqual(last?.maxY ?? 0, column.height, accuracy: 1,
                       "the last paragraph must reach the foot of the column")
    }

    /// The chapter heading sits above the first paragraph and belongs to no paragraph
    /// index — a `TextAnchor` cannot name it. It still has to take up room, or every
    /// position in the chapter would be one title too high.
    func testTheTitleTakesRoomAboveTheFirstParagraph() {
        let column = column(paragraphs())
        XCTAssertGreaterThan(
            column.paragraphFrames.first?.minY ?? 0, 0,
            "the first paragraph must start below the chapter heading"
        )
    }

    /// The gap between two paragraphs must be the spacing the reader chose, and nothing
    /// else added on top.
    ///
    /// The report behind this: "same settings, same type size, but the line spacing and
    /// paragraph spacing differ between the two modes". The two renderers have always
    /// been two independent implementations of the same numbers — SwiftUI's
    /// `.lineSpacing()` plus `.padding(.bottom,)` on one side, `NSParagraphStyle` on the
    /// other — and identical inputs through different machinery do not have to come out
    /// the same. Now that both draw from this column, the number has one meaning, and
    /// this is what pins it.
    func testTheGapBetweenParagraphsIsExactlyTheSpacingTheReaderChose() {
        let spacing = 14.0
        let column = column(paragraphs(8))

        for (above, below) in zip(column.paragraphFrames, column.paragraphFrames.dropFirst()) {
            XCTAssertEqual(
                below.minY - above.maxY, spacing, accuracy: 1.5,
                "the gap under paragraph \(above.paragraph) must be the chosen paragraph "
                    + "spacing, not the spacing plus a line's worth of leading"
            )
        }
    }

    // MARK: - Position round trips

    /// The round trip the reading position is made of: a stored anchor becomes a scroll
    /// offset on open, and the offset becomes an anchor again on every frame. Drift here
    /// is a book that reopens a little further back every time.
    func testAnAnchorSurvivesBeingTurnedIntoAHeightAndBack() {
        let column = column(paragraphs())

        for paragraph in stride(from: 0, to: 40, by: 3) {
            let anchor = TextAnchor(paragraph: paragraph, characterOffset: 0)
            let y = column.y(for: anchor)
            XCTAssertEqual(
                column.anchor(atY: y).paragraph, paragraph,
                "paragraph \(paragraph) must be what its own height reports back"
            )
        }
    }

    /// Never forward, and this is the rule that makes a mode switch safe: a scroll view
    /// can only put a whole paragraph at the top of the screen, so an offset that
    /// rounded forwards would let switching renderers skip text the reader has not read.
    /// Erring backwards re-shows a line they have seen, which they forgive.
    func testAHeightInsideAParagraphNamesThatParagraphRatherThanTheNext() {
        let column = column(paragraphs())

        for frame in column.paragraphFrames where frame.maxY - frame.minY > 4 {
            let inside = frame.minY + (frame.maxY - frame.minY) / 2
            XCTAssertLessThanOrEqual(
                column.anchor(atY: inside).paragraph, frame.paragraph,
                "a height inside paragraph \(frame.paragraph) must never name a later one"
            )
        }
    }

    // MARK: - What is on screen

    /// The replacement for the per-row `GeometryReader`: which paragraphs a window
    /// covers. Both ends matter — the top is the reading position, the bottom is what
    /// prefetch measures its lead from.
    func testAWindowReportsExactlyTheParagraphsItCovers() {
        let column = column(paragraphs())
        let window = 600.0
        let top = column.paragraphFrames[10].minY
        let visible = column.paragraphs(in: top..<(top + window))

        XCTAssertFalse(visible.isEmpty, "a window over text must see some of it")
        XCTAssertEqual(
            visible.first?.paragraph, 10,
            "the window opens exactly on the paragraph its top edge sits at"
        )
        for frame in visible {
            XCTAssertTrue(
                frame.maxY > top && frame.minY < top + window,
                "paragraph \(frame.paragraph) was reported but is not in the window"
            )
        }
        // And nothing outside it was left out: the paragraph after the last reported
        // one has to genuinely start past the window's foot.
        if let last = visible.last, last.paragraph + 1 < column.paragraphFrames.count {
            XCTAssertGreaterThanOrEqual(
                column.paragraphFrames[last.paragraph + 1].minY, top + window,
                "the first unreported paragraph must really be below the window"
            )
        }
    }

    /// A paragraph taller than the window is the case that has no "next paragraph" to
    /// fall back on, and it is common in these books.
    func testAParagraphTallerThanTheWindowIsStillTheOneOnScreen() {
        let giant = String(
            repeating: "他推開門，看見渡口的燈在雪裡亮著，像一句沒有說完的話。", count: 60
        )
        let column = column(["短。", giant, "短。"])
        let frame = column.paragraphFrames[1]
        XCTAssertGreaterThan(frame.maxY - frame.minY, 600, "the fixture must be over-tall")

        let inside = frame.minY + 300
        let visible = column.paragraphs(in: inside..<(inside + 600))
        XCTAssertEqual(
            visible.map(\.paragraph), [1],
            "a window entirely inside one paragraph sees that paragraph and nothing else"
        )
        XCTAssertEqual(
            column.anchor(atY: inside).paragraph, 1,
            "and the reading position is inside it too"
        )
    }

    // MARK: - Drawing

    private func render(_ column: ChapterColumn, window: CGRect) -> Data? {
        UIGraphicsImageRenderer(size: window.size).pngData { context in
            column.draw(window, in: context.cgContext)
        }
    }

    /// Drawing must not be a second layout pass.
    ///
    /// The report this exists for: on a device the reader painted about one line per
    /// scrolled frame, fell behind the finger, and then went blank until the next
    /// chapter — while the simulator was perfect. `NSTextLayoutManager` lays out to a
    /// viewport and is free to throw away what is outside one; a phone does, a simulator
    /// with memory to spare does not. A fragment whose layout has been freed answers
    /// `layoutFragmentFrame` with a zero rect, so asking it at draw time drew the whole
    /// rest of the chapter stacked above the window, once per frame.
    ///
    /// Invalidating by hand is the only way to make a machine with memory to spare
    /// behave like the phone that found this.
    func testDrawingSurvivesTheLayoutManagerThrowingItsWorkAway() {
        let column = column(paragraphs())
        // Deep enough that nothing here is the first screen, which is the one place the
        // broken version was still right.
        let window = CGRect(x: 0, y: 1200, width: 350, height: 600)
        let blank = UIGraphicsImageRenderer(size: window.size).pngData { _ in }

        let before = render(column, window: window)
        XCTAssertNotEqual(before, blank, "the window has to have text in it to be worth comparing")

        column.discardLayoutManagerWork()

        XCTAssertEqual(
            render(column, window: window), before,
            "the same window must draw the same pixels after the layout manager has "
                + "dropped its work — otherwise drawing depends on layout the reader's "
                + "device is entitled to free"
        )
    }

    /// The same claim for the bands a mark is drawn in, which are the one thing left that
    /// still asks the layout manager at draw time. If they move when it drops its work, a
    /// highlight lands on words the reader never marked.
    func testAMarksBandsSurviveTheLayoutManagerThrowingItsWorkAway() {
        let column = column(paragraphs())
        let range = column.text.paragraphRanges[12]
        let before = column.rects(for: range)
        XCTAssertFalse(before.isEmpty, "a real paragraph has to have bands to compare")

        column.discardLayoutManagerWork()

        XCTAssertEqual(
            column.rects(for: range), before,
            "a mark's bands must not move when the layout manager drops its work"
        )
    }

    /// A window past the foot of the text draws nothing rather than the last paragraph
    /// over and over: the footer lives down there, and the reader scrolls into it.
    func testAWindowBelowTheColumnDrawsNothing() {
        let column = column(paragraphs())
        let window = CGRect(x: 0, y: column.height + 50, width: 350, height: 600)
        let blank = UIGraphicsImageRenderer(size: window.size).pngData { _ in }

        XCTAssertEqual(render(column, window: window), blank)
    }

    /// Ink has to land where the recorded geometry says it does.
    ///
    /// Everything else in this file measures the geometry, and drawing is told where to
    /// put each line from that same record — so a constant offset between the two (a
    /// baseline taken for a top edge, say) would leave every other test here green while
    /// the reader saw text sitting between the lines it is supposed to be on. Strips
    /// rather than whole windows, because a whole window has ink either way.
    func testTextIsDrawnOnTheLinesTheColumnSaysItIsOn() {
        let column = column(paragraphs())
        func hasInk(from y: CGFloat, height: CGFloat) -> Bool {
            let window = CGRect(x: 0, y: y, width: 350, height: height)
            let blank = UIGraphicsImageRenderer(size: window.size).pngData { _ in }
            return render(column, window: window) != blank
        }

        for frame in column.paragraphFrames.prefix(12) {
            XCTAssertTrue(
                hasInk(from: frame.minY + 1, height: 4),
                "paragraph \(frame.paragraph) must have ink at its own top edge"
            )
        }
        // And the air between two paragraphs is air. Taken from the middle of the gap so
        // that a descender or an antialiased edge is not what this reads.
        for (above, below) in zip(column.paragraphFrames, column.paragraphFrames.dropFirst())
        where below.minY - above.maxY > 6 {
            let middle = (above.maxY + below.minY) / 2
            XCTAssertFalse(
                hasInk(from: middle - 1, height: 2),
                "the gap under paragraph \(above.paragraph) must be empty"
            )
        }
    }

    // MARK: - Degenerate input

    /// A column is built before the reader's window has been measured, and a zero width
    /// must not produce garbage coordinates that the first real layout has to undo.
    func testAColumnWithNoWidthMeasuresNothingRatherThanGuessing() {
        let column = ChapterColumn(
            text: ChapterText(
                title: "t", paragraphs: paragraphs(3), typography: typography(),
                alignment: .natural
            ),
            width: 0
        )
        column.layOut()

        XCTAssertEqual(column.height, 0)
        XCTAssertTrue(column.paragraphFrames.isEmpty)
        XCTAssertEqual(column.anchor(atY: 100), .start, "with nothing measured, nowhere to be")
        XCTAssertTrue(column.paragraphs(in: 0..<600).isEmpty)
    }

    func testAnEmptyChapterHasNoParagraphsAndDoesNotCrash() {
        let column = column([])
        XCTAssertTrue(column.paragraphFrames.isEmpty)
        XCTAssertEqual(column.anchor(atY: 0), .start)
    }
}
