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

    // MARK: - The title is not a paragraph

    /// An article's title carries a link, and nothing about where it is drawn can be
    /// found by asking which paragraph the finger is in.
    ///
    /// This is the fact `ReaderScrollCoordinator` was wrong about. Its link lookup
    /// narrowed the search to the tapped paragraph — right and cheap for a link inside a
    /// sentence — while the title's range sits ahead of every paragraph and its band has
    /// no `ParagraphFrame` at all, so `hit` returned nil and the lookup never ran. The
    /// scrolling reader could therefore never open a title the paginated one always
    /// could, which looks a link up over a whole page.
    ///
    /// Pinned here rather than at the coordinator because this is where the asymmetry is
    /// created. If the title ever becomes an ordinary paragraph, the coordinator's
    /// fallback turns into dead code and this is the test that says so.
    func testAnArticlesTitleLinkSitsOutsideEveryParagraph() throws {
        let link = try XCTUnwrap(URL(string: "https://example.com/piece"))
        let text = ChapterText(
            title: "渡口的燈",
            titleLink: link,
            blocks: ["第一段。", "第二段。"].map(ArticleBlock.paragraph),
            typography: typography(),
            alignment: .natural
        )

        let title = try XCTUnwrap(
            text.links.first { $0.url == link },
            "the title has to carry its link, or there is nothing for any tap to find"
        )
        XCTAssertFalse(
            text.paragraphRanges.contains { NSIntersectionRange($0, title.range).length > 0 },
            "a lookup narrowed to a paragraph can never reach the title"
        )
        XCTAssertGreaterThan(
            try XCTUnwrap(text.paragraphRanges.first).location, 0,
            "the head the coordinator falls back to is what holds the title, so it cannot be empty"
        )

        let column = ChapterColumn(text: text, width: 350)
        column.layOut()
        XCTAssertEqual(
            column.paragraphFrames.count, 2,
            "frames are built one per paragraph, so the title has none to be hit by"
        )
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

    /// Renders one window the way the reader does: the caller places the column, and
    /// `draw` only says which part of it to put there. See `ChapterColumn.draw` — doing
    /// this at both ends is the bug these tests could not see.
    private func render(_ column: ChapterColumn, window: CGRect) -> Data? {
        UIGraphicsImageRenderer(size: window.size).pngData { context in
            context.cgContext.translateBy(x: 0, y: -window.minY)
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

    // MARK: - Saying when a draw came out empty

    /// The one thing a device can tell us about drawing that a simulator cannot, and the
    /// reason it is worth a line in a shippable trace at all.
    ///
    /// The window is in column coordinates, and the caller has already placed the column;
    /// applying the offset at both ends pushes the text a whole window off once the reader
    /// is one screen into a chapter. On the phone that read as every chapter showing its
    /// first page and then going black. Nothing about the drawn output says so — it is
    /// simply empty — so the column has to notice and say it itself.
    func testAWindowThatMissesTheTextEntirelySaysSo() throws {
        let column = column(paragraphs())
        var reports: [String] = []
        column.onNothingDrawn = { reports.append($0) }

        // Where a doubled offset puts the window: past the foot of the column.
        let lost = CGRect(x: 0, y: column.height + 700, width: 350, height: 600)
        _ = render(column, window: lost)

        XCTAssertEqual(reports.count, 1)
        let report = try XCTUnwrap(reports.first)
        XCTAssertTrue(report.contains("win="), report)
        XCTAssertTrue(
            report.contains("frags="),
            "the window alone does not say it should have drawn something: \(report)"
        )
        XCTAssertTrue(report.contains("lastY="), "nor where the text actually ends: \(report)")
    }

    /// Once per column, whatever happens afterwards. Drawing runs at frame rate, and a
    /// fault that survives one frame survives thousands — the first line says everything
    /// the ten-thousandth would, and the other 9,999 would fill the trace instead.
    func testAColumnSaysItOnceNoMatterHowManyFramesItIsDrawnWrongFor() {
        let column = column(paragraphs())
        var reports = 0
        column.onNothingDrawn = { _ in reports += 1 }

        let lost = CGRect(x: 0, y: column.height + 700, width: 350, height: 600)
        for _ in 0..<200 { _ = render(column, window: lost) }

        XCTAssertEqual(reports, 1)
    }

    /// And a healthy column says nothing at all, which is what makes the line above worth
    /// reading: a trace with a `draw` event in it has already told you there is a fault.
    func testDrawingAWindowWithTextInItReportsNothing() {
        let column = column(paragraphs())
        var reports: [String] = []
        column.onNothingDrawn = { reports.append($0) }

        var top: CGFloat = 0
        while top < column.height {
            _ = render(column, window: CGRect(x: 0, y: top, width: 350, height: 600))
            top += 200
        }

        XCTAssertTrue(reports.isEmpty, "every window in this column has text in it: \(reports)")
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

    // MARK: - How wide a line is set

    /// The widths a real device actually offers, so the claims below are about glass
    /// somebody reads on rather than about arithmetic.
    private enum Glass {
        static let phone: CGFloat = 393
        static let padPortrait: CGFloat = 834
        static let padLandscape: CGFloat = 1366
    }

    private func measure(_ available: CGFloat, at size: CGFloat = 19) -> CGFloat {
        ReaderTextScrollView.textWidth(in: available, fontSize: size)
    }

    /// The rule this cap exists for. A column set the full width of an iPad is over
    /// thirteen hundred points of unbroken text, and the eye finishing such a line has
    /// no reliable way back to the start of the next one — it lands on the line just
    /// read. Nothing else in the reader notices, which is why this is pinned here.
    func testALineIsNeverSetLongerThanTheEyeCanFollowBackToTheNextOne() {
        let characters = measure(Glass.padLandscape) / 19
        XCTAssertLessThanOrEqual(
            characters, ReaderTextScrollView.maxCharactersPerLine,
            "an iPad line has to be capped in characters, not left at the width of the glass"
        )
        XCTAssertGreaterThan(
            characters, 20, "capped is not the same as cramped — this is a reading measure"
        )
    }

    /// The other half, and the one that makes this safe to ship: a phone never reaches
    /// the cap, so every reader already holding one sees the identical column. A change
    /// to the reading measure that moved the text on a phone would be a redesign of the
    /// app's main screen rather than an iPad fix.
    func testAPhoneIsReadingExactlyTheColumnItWasBeforeTheCapExisted() {
        XCTAssertEqual(
            measure(Glass.phone), Glass.phone - ReaderTextScrollView.textMargin * 2,
            "on a phone the measure is still the glass less the margins, to the point"
        )
    }

    /// Counted in characters rather than points, which is the whole reason the rule takes
    /// a font size. Someone reading at 32pt and someone at 13pt should lose their place
    /// at the same *word*, and a cap fixed in points would give the first of them a third
    /// of the line the second gets.
    func testTheCapIsTheSameNumberOfCharactersWhateverSizeTheReaderSetsIt() {
        let small = measure(Glass.padLandscape, at: 13) / 13
        let large = measure(Glass.padLandscape, at: 32) / 32
        XCTAssertEqual(
            small, large, accuracy: 0.01,
            "the measure has to hold the same number of characters at either size"
        )
        XCTAssertGreaterThan(
            measure(Glass.padLandscape, at: 32), measure(Glass.padLandscape, at: 13),
            "and bigger type therefore has to occupy a wider column, not the same one"
        )
    }

    /// The first layout pass, before any config has reached the coordinator. Capping
    /// against a size nobody has stated yet would set the column to nothing — and a
    /// chapter laid out at zero width measures nothing, which the test above this file's
    /// `width: 0` case already shows is a reader with no text and no position.
    func testAWidthAskedForBeforeAnyoneSaidTheSizeIsTheFullMeasureRatherThanNothing() {
        XCTAssertEqual(
            measure(Glass.padPortrait, at: 0),
            Glass.padPortrait - ReaderTextScrollView.textMargin * 2,
            "an unstated size means 'not said yet', never 'a column zero points wide'"
        )
    }

    /// Both renderers reach for the same two constants rather than matching numbers, so
    /// that a reader switching modes mid-chapter lands on the same line. This pins the
    /// arithmetic they share; `PaginatedChapterView` composes it out of the same names.
    func testTheTwoRenderersAreSetToOneMeasure() {
        let capped = ReaderTextScrollView.maxCharactersPerLine * 19
        XCTAssertEqual(
            measure(Glass.padLandscape), capped,
            "wide glass gives the cap itself, which is what the paginated frame is set to"
        )
        XCTAssertLessThan(
            capped, Glass.padLandscape - ReaderTextScrollView.textMargin * 2,
            "and the cap has to actually bite on an iPad, or none of this does anything"
        )
    }
}
