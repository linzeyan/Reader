import UIKit
import XCTest
@testable import NovelReader

/// What a selection that runs past the bottom of a page has to guarantee.
///
/// Storing and drawing a highlight across a page break already worked — a highlight is a
/// pair of paragraph anchors and knows nothing about pages. What did not was *making*
/// one: `ChapterPaginator.offset(at:onPage:)` clamps a finger to the page it is on, on
/// purpose, so a drag that reached the bottom edge simply stopped there. Extending it
/// means turning the page and asking the new one, which puts two things at risk that no
/// screenshot would show — the rule that decides when the book moves under a resting
/// finger, and whether the two halves of the mark that comes out still add up to exactly
/// the passage the reader picked.
@MainActor
final class CrossPageSelectionTests: XCTestCase {
    // MARK: - Fixtures

    /// Roughly the shape of the real thing: a long chapter of mixed-length Chinese
    /// paragraphs, long enough that page breaks fall inside paragraphs rather than
    /// conveniently between them.
    private func longChapter() -> [String] {
        (0..<190).map { index in
            let sentence = "他推開門，看見渡口的燈在雪裡亮著，像一句沒有說完的話。"
            return String(repeating: sentence, count: index % 5 + 1) + "第\(index)段。"
        }
    }

    private func typography(size: CGFloat = 19) -> ReaderTypography {
        ReaderTypography(
            body: .systemFont(ofSize: size),
            title: .systemFont(ofSize: size + 4, weight: .semibold),
            lineSpacing: 9,
            paragraphSpacing: 14,
            color: .black
        )
    }

    private func chapterText(_ paragraphs: [String], typeSize: CGFloat = 19) -> ChapterText {
        ChapterText(
            title: "第十七章　渡口", paragraphs: paragraphs, typography: typography(size: typeSize)
        )
    }

    /// An iPhone-sized text area, inset the way the reader insets it.
    private let pageSize = CGSize(width: 350, height: 600)

    private func paginator(
        paragraphs: [String], size: CGSize? = nil, typeSize: CGFloat = 19
    ) -> ChapterPaginator {
        let paginator = ChapterPaginator(
            text: chapterText(paragraphs, typeSize: typeSize), pageSize: size ?? pageSize
        )
        paginator.paginateAll()
        return paginator
    }

    /// The shipping rule, so the numbers under test are the ones the reader's thumb meets.
    private let rule = SelectionEdgeRule()

    private func inStrip(_ turn: PageTurn, of size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2, y: turn == .forward ? size.height - 2 : 2)
    }

    // MARK: - When the page turns

    /// A finger that sweeps through the strip on its way somewhere must not turn the
    /// page. Turning on contact is the whole reason this rule has a dwell at all: one
    /// quick slide down a page would otherwise be three page turns, and the reader would
    /// lose both their place and the passage they were picking out.
    func testAFingerPassingThroughTheEdgeDoesNotTurnThePage() {
        let point = inStrip(.forward, of: pageSize)
        XCTAssertEqual(rule.strip(at: point, in: pageSize), .forward, "the point is in the strip")
        for held in [0, 0.05, rule.dwell / 2, rule.dwell - 0.01] {
            XCTAssertNil(
                rule.turn(at: point, in: pageSize, heldFor: held, page: 3, of: 40),
                "\(held)s in the strip is a finger on its way past, not a request for a page"
            )
        }
    }

    /// And once it has rested there, the page moves — in the direction the reader was
    /// heading. Down is forward because that is where the text carries on.
    func testAFingerRestingAgainstAnEdgeTurnsTheWayTheTextRuns() {
        for turn in [PageTurn.forward, .backward] {
            XCTAssertEqual(
                rule.turn(
                    at: inStrip(turn, of: pageSize), in: pageSize, heldFor: rule.dwell,
                    page: 3, of: 40
                ),
                turn
            )
        }
    }

    /// A long press keeps reporting points after the finger has left the view it began
    /// in, and a finger dragged clean off the bottom of the page has not stopped asking
    /// for the text that follows.
    func testAFingerDraggedOffThePageIsStillRestingAgainstTheEdge() {
        XCTAssertEqual(
            rule.turn(
                at: CGPoint(x: 100, y: pageSize.height + 240), in: pageSize,
                heldFor: rule.dwell, page: 3, of: 40
            ),
            .forward
        )
        XCTAssertEqual(
            rule.turn(
                at: CGPoint(x: 100, y: -180), in: pageSize, heldFor: rule.dwell, page: 3, of: 40
            ),
            .backward
        )
    }

    /// Leaving the strip stops the run. Without this a reader who dragged back into the
    /// text would watch the chapter run to its end under a finger that had gone still
    /// somewhere in the middle of a paragraph.
    func testAFingerInTheBodyOfThePageNeverTurnsItHoweverLongItRests() {
        for y in [rule.stripHeight + 1, pageSize.height / 2, pageSize.height - rule.stripHeight - 1] {
            let point = CGPoint(x: 100, y: y)
            XCTAssertNil(rule.strip(at: point, in: pageSize), "y=\(y) is the body of the page")
            XCTAssertNil(
                rule.turn(at: point, in: pageSize, heldFor: 30, page: 3, of: 40),
                "a finger resting in the text is reading, not asking for the next page"
            )
        }
    }

    /// Neither end of the chapter turns past itself. Forward off the last page would need
    /// a highlight whose two anchors named different chapters, which is not a thing this
    /// app can store; backward off the first is the same in reverse.
    func testTheChapterDoesNotTurnPastEitherOfItsEnds() {
        XCTAssertNil(
            rule.turn(
                at: inStrip(.forward, of: pageSize), in: pageSize, heldFor: 30, page: 39, of: 40
            ),
            "a selection may not run out of the chapter it started in"
        )
        XCTAssertNil(
            rule.turn(
                at: inStrip(.backward, of: pageSize), in: pageSize, heldFor: 30, page: 0, of: 40
            )
        )
        // A bound rather than a refusal to turn: the page before the last one still does.
        XCTAssertEqual(
            rule.turn(
                at: inStrip(.forward, of: pageSize), in: pageSize, heldFor: 30, page: 38, of: 40
            ),
            .forward
        )
        XCTAssertEqual(
            rule.turn(
                at: inStrip(.backward, of: pageSize), in: pageSize, heldFor: 30, page: 1, of: 40
            ),
            .backward
        )
    }

    /// A turn is armed by the finger arriving at the edge, not by it being there. Holding
    /// still is what a press *is*, so a reader who presses on the last line of a page —
    /// which is a reader marking that line — must not have the page turn under them for
    /// doing nothing at all.
    func testAPressThatBeganAtTheEdgeHasNotArrivedThere() {
        let edge = inStrip(.forward, of: pageSize)
        let body = CGPoint(x: 100, y: pageSize.height / 2)

        XCTAssertNil(
            rule.arrival(at: edge, from: nil, in: pageSize),
            "the first report of a press has come from nowhere, so it has arrived nowhere"
        )
        XCTAssertNil(
            rule.arrival(at: edge, from: edge, in: pageSize),
            "and a finger that has not moved has not arrived either"
        )
        XCTAssertEqual(
            rule.arrival(at: edge, from: body, in: pageSize), .forward,
            "a finger dragged out of the text into the strip is the gesture that asks for a page"
        )
        XCTAssertEqual(rule.arrival(at: inStrip(.backward, of: pageSize), from: body, in: pageSize), .backward)
        XCTAssertNil(
            rule.arrival(at: body, from: edge, in: pageSize),
            "a finger dragged back into the text has arrived at no edge"
        )
    }

    /// An area with no room for text between the two strips would turn the page under
    /// every press. It cannot happen on a phone, and it is exactly what a collapsed or
    /// mid-rotation layout looks like.
    func testAPageWithNoRoomForABodyNeverTurns() {
        let sliver = CGSize(width: 350, height: rule.stripHeight * 2)
        XCTAssertNil(rule.strip(at: CGPoint(x: 10, y: 1), in: sliver))
        XCTAssertNil(rule.strip(at: CGPoint(x: 10, y: sliver.height - 1), in: sliver))
        XCTAssertNil(rule.strip(at: .zero, in: .zero))
    }

    // MARK: - Extending past the break

    /// The clamp stays. A finger at the bottom edge still selects only as far as the page
    /// it is on goes — that is what stops a drag marking text the reader has not turned
    /// to — and the same point answers a character further into the chapter once the page
    /// under it has actually been turned. Both halves are the feature.
    func testThePageBeingShownDecidesWhichCharacterTheFingerIsOn() throws {
        let paginator = paginator(paragraphs: longChapter())
        let page = 3
        let edge = inStrip(.forward, of: pageSize)

        let hereAndNow = try XCTUnwrap(paginator.offset(at: edge, onPage: page))
        XCTAssertEqual(
            hereAndNow, NSMaxRange(paginator.pages[page].range),
            "dragging past the bottom of a page selects to the end of that page and no further"
        )

        let afterTheTurn = try XCTUnwrap(paginator.offset(at: edge, onPage: page + 1))
        XCTAssertGreaterThan(afterTheTurn, hereAndNow)
        XCTAssertEqual(
            afterTheTurn, NSMaxRange(paginator.pages[page + 1].range),
            "and on the next page the same point is that page's own end"
        )
    }

    /// Whatever point it is handed, `offset(at:onPage:)` answers with a position on that
    /// page or with nothing at all.
    ///
    /// An invariant sweep, and honestly not the reproducer for the crash that prompted it.
    /// The two UTF-16 lookups this method adds together both answer `NSNotFound` for a
    /// point or a location they cannot place, `NSNotFound` is `Int.max`, and the addition
    /// trapped the process — a finger dragged off the bottom of a page found that point on
    /// the first try. `CrossPageSelectionGestureTests` is where it happened and is what
    /// pins it; no geometry tried here reproduces it, so this pins the property that was
    /// violated rather than pretending to pin the case.
    func testNoPointOnOrOffAPageCanTrapTheOffsetLookup() throws {
        let paginator = paginator(paragraphs: (0..<40).flatMap { index in
            ["「走吧。」他說。", "「等一下。」她忽然說。",
             "第\(index)段。他推開門，看見渡口的燈在雪裡亮著，像一句沒有說完的話。"]
        })
        let xs: [CGFloat] = [-40, 4, pageSize.width / 2, pageSize.width + 40]
        for page in paginator.pages.indices {
            let range = paginator.pages[page].range
            for x in xs {
                for step in -50...Int(pageSize.height + 100) {
                    let point = CGPoint(x: x, y: CGFloat(step))
                    guard let offset = paginator.offset(at: point, onPage: page) else { continue }
                    XCTAssertTrue(
                        offset >= range.location && offset <= NSMaxRange(range),
                        "(\(x), \(step)) on page \(page) answered \(offset), outside \(range)"
                    )
                }
            }
        }
    }

    /// The gesture the whole change is: an anchor pressed on one page, the finger carried
    /// on to the next, one range out of the two. The anchor is held as an offset rather
    /// than as the point the press began at, because that point stops meaning the same
    /// character the moment the page moves.
    func testAnAnchorOnOnePageAndAFingerOnTheNextMakeOneRange() throws {
        let paginator = paginator(paragraphs: longChapter())
        let page = 3
        let boundary = paginator.pages[page + 1].range.location
        let pressed = try XCTUnwrap(paginator.offset(at: CGPoint(x: 40, y: 200), onPage: page))
        // Where the finger ended up after the page turned under it.
        let held = CGPoint(x: 40, y: 120)
        let ended = try XCTUnwrap(paginator.offset(at: held, onPage: page + 1))

        let range = try XCTUnwrap(paginator.text.sentenceRange(from: pressed, to: ended))
        XCTAssertLessThanOrEqual(range.location, pressed, "snapping may only widen the passage")
        XCTAssertGreaterThanOrEqual(NSMaxRange(range), ended)
        XCTAssertTrue(
            range.location < boundary && NSMaxRange(range) > boundary,
            "the passage has to cross the break the reader dragged over"
        )

        XCTAssertLessThan(
            try XCTUnwrap(paginator.offset(at: held, onPage: page)), boundary,
            "read against the page the press started on, that point never reaches the break"
        )
    }

    // MARK: - What comes out of it

    /// The reason this change exists. A passage picked out across a page break is one
    /// highlight; each page draws the part of it that is on that page, and the two parts
    /// have to be exactly the passage — no character painted twice, none lost in the
    /// gutter, and nothing drawn on a page the passage never reached.
    func testAMarkMadeAcrossAPageBreakIsDrawnAsTwoHalvesOfOnePassage() throws {
        let paginator = paginator(paragraphs: longChapter())
        let straddle = try XCTUnwrap(
            self.straddle(in: paginator),
            "the fixture must break at least one page inside a paragraph"
        )
        let first = straddle.page
        let second = first + 1

        let highlight = TextHighlight(
            bookId: "demo|1",
            siteChapterId: "3",
            selection: try XCTUnwrap(paginator.text.selection(for: straddle.range)),
            createdAt: Date()
        )
        XCTAssertEqual(
            paginator.text.ranges(of: highlight), [straddle.range],
            "the stored pair of anchors has to name the passage the reader picked out"
        )

        let halves = [first, second].map {
            NSIntersectionRange(straddle.range, paginator.pages[$0].range)
        }
        XCTAssertGreaterThan(halves[0].length, 0, "part of the passage is on the first page")
        XCTAssertGreaterThan(halves[1].length, 0, "and part of it on the second")
        XCTAssertEqual(halves[0].location, straddle.range.location)
        XCTAssertEqual(
            NSMaxRange(halves[0]), halves[1].location, "no character may fall between the pages"
        )
        XCTAssertEqual(NSMaxRange(halves[1]), NSMaxRange(straddle.range))
        XCTAssertEqual(
            halves[0].length + halves[1].length, straddle.range.length,
            "the two halves must add up to exactly the passage, once each"
        )

        // And the drawing follows the arithmetic: each page marks its own half and only
        // its own half, so asking a page for the whole passage draws the visible part of
        // it rather than a band running off the edge.
        for (page, half) in zip([first, second], halves) {
            let drawn = paginator.rects(for: straddle.range, onPage: page)
            XCTAssertFalse(drawn.isEmpty, "page \(page + 1) shows part of the passage and must mark it")
            XCTAssertEqual(
                drawn, paginator.rects(for: half, onPage: page),
                "page \(page + 1) must draw its own half of the passage"
            )
            for rect in drawn {
                XCTAssertTrue(
                    rect.minY > -1 && rect.maxY < pageSize.height + 1,
                    "a band drawn on page \(page + 1) has to stay on page \(page + 1): \(rect)"
                )
            }
        }
        XCTAssertTrue(
            paginator.rects(for: halves[1], onPage: first).isEmpty,
            "the far half of the passage is not on the near page and must not be painted there"
        )
        for page in [first - 1, second + 1] where paginator.pages.indices.contains(page) {
            XCTAssertTrue(
                paginator.rects(for: straddle.range, onPage: page).isEmpty,
                "no other page may show any of the passage"
            )
        }
    }

    /// Sentence snapping is arithmetic on the composed chapter, so where the page breaks
    /// fall must not change its answer. A sentence cut in half by a page break is still
    /// one sentence: the reader who marks it gets the whole of it, and gets the same whole
    /// of it in a layout where that sentence sits in the middle of a page.
    func testWhereThePagesBreakDoesNotChangeWhichSentenceIsPickedOut() throws {
        let paragraphs = longChapter()
        let paginator = paginator(paragraphs: paragraphs)
        let straddle = try XCTUnwrap(
            self.straddle(in: paginator),
            "the fixture must break at least one page inside a paragraph"
        )

        for size in [CGSize(width: 350, height: 900), CGSize(width: 700, height: 300)] {
            let relaid = self.paginator(paragraphs: paragraphs, size: size)
            XCTAssertEqual(
                relaid.text.sentenceRange(from: straddle.from, to: straddle.to), straddle.range,
                "the same two positions must pick out the same sentence at \(size)"
            )
        }
        for typeSize in [CGFloat(13), 32] {
            XCTAssertEqual(
                chapterText(paragraphs, typeSize: typeSize)
                    .sentenceRange(from: straddle.from, to: straddle.to),
                straddle.range,
                "and at \(typeSize)pt, which re-breaks every page in the chapter"
            )
        }
    }

    // MARK: - Finding a break to drag over

    /// A press-and-drag that lands either side of a page break: the page it starts on, the
    /// two positions the finger touched, and the sentence they snap to.
    private struct Straddle {
        let page: Int
        let from: Int
        let to: Int
        let range: NSRange
    }

    /// The first page break that falls inside a paragraph, with a selection across it.
    ///
    /// Inside a paragraph on purpose: a passage that also crosses a paragraph boundary is
    /// stored as two ranges with the separator between them left unpainted, and the
    /// "two halves, once each" arithmetic above would then be about paragraphs rather than
    /// about pages. `HighlightTests` already covers the paragraph split.
    private func straddle(in paginator: ChapterPaginator) -> Straddle? {
        let reach = 8
        for page in paginator.pages.indices.dropLast().dropFirst() {
            let next = paginator.pages[page + 1]
            let boundary = next.range.location
            let paragraph = paginator.text.paragraphRanges[
                paginator.text.anchor(atOffset: boundary).paragraph
            ]
            guard boundary - paragraph.location > reach, NSMaxRange(paragraph) - boundary > reach,
                  let range = paginator.text.sentenceRange(
                      from: boundary - reach, to: boundary + reach
                  ),
                  // Two pages, not three: a sentence spilling onto a third page would be a
                  // different claim than the one being made.
                  NSMaxRange(range) <= NSMaxRange(next.range)
            else { continue }
            return Straddle(
                page: page, from: boundary - reach, to: boundary + reach, range: range
            )
        }
        return nil
    }
}
