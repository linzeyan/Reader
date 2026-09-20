import UIKit
import XCTest
@testable import NovelReader

/// What the stack of laid-out columns has to guarantee.
///
/// One thing above all: a chapter arriving *above* the reader must not move the
/// sentence they are looking at. That single guarantee is what the renderer this
/// replaces could not make, and the whole of `ScrollCorrection` — a stated row, an
/// anchor point inside it, a three-frame settle, a re-state against its own miss, an
/// abandon threshold — existed to approximate it. It could not be made exact, because a
/// lazy container would not say how tall the rows it had just built were; the residue
/// showed up as the page flinching backwards at every seam, and as a reader dragging
/// upward after a jump walking backwards through the book one chapter per gesture.
///
/// Here it is arithmetic, so it can simply be asserted.
@MainActor
final class ReaderScrollCoordinatorTests: XCTestCase {
    private var settings: ReaderSettings!
    private var defaultsName: String!
    /// Held by the test, because `ReaderScrollCoordinator.view` is weak — SwiftUI owns
    /// the view in the app, and a coordinator whose view has gone measures a width of
    /// zero and lays nothing out at all.
    private var view: ReaderTextScrollView!
    private var coordinator: ReaderScrollCoordinator!
    private var trace: TraceLog!
    private var traceRoot: URL!

    /// A window the size of a phone, so `textWidth` and `visibleHeight` are real
    /// numbers rather than zero.
    private let window = CGRect(x: 0, y: 0, width: 390, height: 700)

    override func setUpWithError() throws {
        defaultsName = "ReaderScrollCoordinatorTests-\(UUID().uuidString)"
        settings = ReaderSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: defaultsName)))
        view = ReaderTextScrollView(frame: window)
        // A trace of its own, switched off, over a directory nothing else touches: these
        // tests are about the renderer, and a developer with diagnostics on must not find
        // a suite's worth of relayouts in the file they were collecting.
        traceRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ReaderScrollCoordinatorTests-\(UUID().uuidString)")
        trace = TraceLog(
            directory: traceRoot,
            defaults: try XCTUnwrap(UserDefaults(suiteName: traceRoot.lastPathComponent))
        )
        coordinator = ReaderScrollCoordinator(trace: trace)
        view.coordinator = coordinator
        coordinator.view = view
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removePersistentDomain(forName: defaultsName)
        UserDefaults.standard.removePersistentDomain(forName: traceRoot.lastPathComponent)
        try? FileManager.default.removeItem(at: traceRoot)
        view = nil
        coordinator = nil
    }

    // MARK: - Fixtures

    private func chapter(_ index: Int, paragraphs count: Int) -> ReaderModel.LoadedChapter {
        ReaderModel.LoadedChapter(
            chapter: Chapter(
                id: "book|c\(index)", bookId: "book", siteChapterId: "c\(index)",
                index: index, title: "第\(index)章　渡口", url: "https://alpha/\(index)",
                addedAt: nil, downloadedAt: nil
            ),
            paragraphs: (0..<count).map { paragraph in
                let sentence = "他推開門，看見渡口的燈在雪裡亮著，像一句沒有說完的話。"
                return String(repeating: sentence, count: paragraph % 4 + 1)
                    + "第\(index)章第\(paragraph)段。"
            }
        )
    }

    /// A chapter whose paragraphs are given outright, for the shapes the generated
    /// fixture cannot make — here, one paragraph several windows tall.
    private func chapter(_ index: Int, paragraphs: [String]) -> ReaderModel.LoadedChapter {
        ReaderModel.LoadedChapter(
            chapter: Chapter(
                id: "book|c\(index)", bookId: "book", siteChapterId: "c\(index)",
                index: index, title: "第\(index)章　渡口", url: "https://alpha/\(index)",
                addedAt: nil, downloadedAt: nil
            ),
            paragraphs: paragraphs
        )
    }

    private func text(
        _ chapters: [ReaderModel.LoadedChapter],
        palette: ReaderPalette = .light,
        onPlaceChange: @escaping (ReaderPlace) -> Void = { _ in },
        onNeedsNext: @escaping () -> Void = {},
        onRanOut: @escaping () -> Void = {},
        autoScroll: CGFloat = 0,
        onAutoScrollEnded: @escaping () -> Void = {},
        speaking: SpokenSentence? = nil
    ) -> ReaderScrollingText {
        ReaderScrollingText(
            chapters: chapters,
            metrics: settings.metrics(forBook: "book", kind: .novel),
            palette: palette,
            highlights: [:], marked: nil,
            target: nil, footer: .none,
            onPlaceChange: onPlaceChange, onNeedsNext: onNeedsNext, onNeedsPrevious: {},
            onRanOut: onRanOut,
            onTouch: { _ in }, onTap: { _ in false }, onMark: { _, _ in },
            onTargetReached: {},
            autoScroll: autoScroll, onAutoScrollEnded: onAutoScrollEnded,
            speaking: speaking,
            trace: trace
        )
    }

    /// Feeds the coordinator a window of chapters and waits for every column to land.
    ///
    /// The wait is the contract, not a workaround: columns are laid out on a background
    /// queue and handed over, which is the only reason a whole chapter can be measured
    /// at once. Awaiting yields the main actor, which is what lets them arrive.
    private func show(
        _ chapters: [ReaderModel.LoadedChapter],
        onNeedsNext: @escaping () -> Void = {},
        onRanOut: @escaping () -> Void = {}
    ) async throws {
        coordinator.update(
            with: text(chapters, onNeedsNext: onNeedsNext, onRanOut: onRanOut)
        )
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while coordinator.placed.count < chapters.count {
            guard ContinuousClock.now < deadline else {
                return XCTFail(
                    "only \(coordinator.placed.count) of \(chapters.count) columns "
                        + "finished laying out"
                )
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Wanting more, and running out

    /// The next chapter is asked for two windows early so that it is there before the
    /// reader arrives. Running out is a different moment entirely, and everything the
    /// reader sees when that fetch fails turns on the two being told apart: at the first
    /// there is a page and a half still to read and nothing worth interrupting them for,
    /// at the second there is nothing under them at all. Reporting a failed look-ahead as
    /// though it were the second is what put a full-screen verification wall over a
    /// chapter somebody was 88% of the way through.
    func testWantingTheNextChapterAndRunningOutAreDifferentMoments() async throws {
        var wantedMore = 0
        var ranOut = 0
        try await show(
            [chapter(1, paragraphs: 80)],
            onNeedsNext: { wantedMore += 1 },
            onRanOut: { ranOut += 1 }
        )
        let screen = view.visibleHeight
        // Tall enough to have a bottom the reader can be well short of.
        XCTAssertGreaterThan(coordinator.contentHeight, screen * 4)

        // Inside the lead, a page and a half of text still below the window.
        view.contentOffset.y = coordinator.contentHeight - screen - screen * 1.5
        coordinator.scrolled()
        XCTAssertGreaterThan(wantedMore, 0, "the next chapter should be fetched early")
        XCTAssertEqual(ranOut, 0, "but there is still a page and a half to read")

        // The foot of the loaded text, with nothing under them.
        view.contentOffset.y = coordinator.contentHeight - screen
        coordinator.scrolled()
        XCTAssertGreaterThan(ranOut, 0, "now the reader has arrived at the seam")
    }

    /// A stack that is still being built is not asked how far the reader has to go.
    ///
    /// `contentHeight` is how far the columns have landed, and a rebuild — which is what
    /// coming back to the app after switching away turns into, once the snapshot has had
    /// its way with the width — grows it from nothing while the scroll offset still
    /// describes the old content. The distance below the reader then reads as a large
    /// negative number, which is "no measurement yet" and not "nearly out of text".
    ///
    /// Read as the latter it says the reader is waiting, and that is what put a
    /// full-screen verification wall over a chapter somebody was 59% of the way through:
    /// the look-ahead's failure was supposed to be held quietly, and a spurious "they ran
    /// out" is exactly the thing that un-holds it.
    ///
    /// Driven here by adding a chapter rather than by flipping the appearance, because
    /// the half-built moment is then deterministic: the new column is laid out on another
    /// queue, so it cannot have landed by the time `update` returns.
    func testAHalfBuiltStackIsNotAskedHowFarTheReaderHasToGo() async throws {
        var ranOut = 0
        let window = [chapter(1, paragraphs: 40), chapter(2, paragraphs: 40)]
        try await show(window, onRanOut: { ranOut += 1 })

        // At the foot of what is loaded, which is where running out is honestly true.
        view.contentOffset.y = coordinator.contentHeight - view.visibleHeight
        coordinator.scrolled()
        XCTAssertGreaterThan(ranOut, 0, "the reader really is at the bottom of the stack")

        ranOut = 0
        coordinator.update(
            with: text(window + [chapter(3, paragraphs: 40)], onRanOut: { ranOut += 1 })
        )
        coordinator.scrolled()

        XCTAssertLessThan(
            coordinator.placed.count, 3, "the third column cannot have landed yet"
        )
        XCTAssertEqual(
            ranOut, 0,
            "a stack part way through being built has no answer about where the reader is"
        )
    }

    // MARK: - The guarantee

    func testAChapterArrivingAboveTheReaderDoesNotMoveTheTextTheyAreReading() async throws {
        try await show([chapter(1, paragraphs: 30), chapter(2, paragraphs: 30)])

        // Well into the second chapter, where an insert at the head of the window has a
        // whole chapter's worth of length to shove them by.
        coordinator.scroll(to: TextAnchor(paragraph: 11, characterOffset: 0), inChapter: 2,
                           animated: false)
        let before = try XCTUnwrap(coordinator.currentPlace())
        XCTAssertEqual(before.chapterIndex, 2)
        XCTAssertEqual(before.anchor.paragraph, 11)
        let offsetBefore = view.readingOffset

        try await show(
            [chapter(0, paragraphs: 30), chapter(1, paragraphs: 30), chapter(2, paragraphs: 30)]
        )

        XCTAssertEqual(
            coordinator.currentPlace(), before,
            "a chapter put in above the reader must leave them on the same sentence"
        )
        XCTAssertGreaterThan(
            view.readingOffset, offsetBefore,
            "the offset has to have moved by the length that arrived — an unchanged one "
                + "would mean the content was not actually inserted above"
        )
    }

    /// The other direction: chapters given back under memory pressure shorten the text
    /// above the reader, which is the same problem with the sign flipped. The renderer
    /// this replaces could only re-aim at a paragraph boundary, so this was the eviction
    /// that visibly slid the page backwards.
    func testDroppingChaptersAboveTheReaderDoesNotMoveThemEither() async throws {
        try await show(
            [chapter(0, paragraphs: 30), chapter(1, paragraphs: 30), chapter(2, paragraphs: 30)]
        )
        coordinator.scroll(to: TextAnchor(paragraph: 7, characterOffset: 0), inChapter: 2,
                           animated: false)
        let before = try XCTUnwrap(coordinator.currentPlace())

        try await show([chapter(1, paragraphs: 30), chapter(2, paragraphs: 30)])

        XCTAssertEqual(
            coordinator.currentPlace(), before,
            "giving a chapter back must cost the reader nothing but the chapter"
        )
    }

    /// Leaving the app must not cost the reader the chapters they read in this session.
    ///
    /// Reported from a phone, twice: switch away mid-book, come back, and the reader is
    /// at chapter 384 with 395 the last thing they read — the head of the loaded window,
    /// which is where the session started. Both numbers then went to the database,
    /// because the place a rebuild reads part-way through is reported like any other.
    ///
    /// The trigger is iOS snapshotting the app for the switcher in *both* appearances, so
    /// a reader on the system theme gets two ink changes back to back. The first empties
    /// the stack to rebuild; the second finds nothing to ask where the reader is and used
    /// to carry that nothing into the rebuild as the place to restore.
    func testAnAppearanceFlipWhileTheColumnsAreRebuildingLeavesTheReaderWhereTheyWere() async throws {
        let window = [chapter(1, paragraphs: 30), chapter(2, paragraphs: 30),
                      chapter(3, paragraphs: 30)]
        try await show(window)
        coordinator.scroll(to: TextAnchor(paragraph: 9, characterOffset: 0), inChapter: 3,
                           animated: false)
        let before = try XCTUnwrap(coordinator.currentPlace())
        XCTAssertEqual(before.chapterIndex, 3)

        // Light, dark, light — the pair of trait changes a trip to the background makes,
        // both landing before a single column has been laid out again.
        var reported: [ReaderPlace] = []
        coordinator.update(with: text(window, palette: .dark, onPlaceChange: { reported.append($0) }))
        coordinator.update(with: text(window, palette: .light, onPlaceChange: { reported.append($0) }))
        XCTAssertTrue(coordinator.placed.isEmpty, "the second flip has to land mid-rebuild")

        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while coordinator.placed.count < window.count {
            guard ContinuousClock.now < deadline else {
                return XCTFail("the rebuild never finished")
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(
            coordinator.currentPlace(), before,
            "coming back from the background must land on the sentence the reader left"
        )
        XCTAssertTrue(
            reported.allSatisfy { $0.chapterIndex == before.chapterIndex },
            "a half-built stack must report nothing: the model writes the first place it "
                + "is told down, and the throttle then refuses the correction — which is "
                + "how a bogus chapter reaches the database, got \(reported.map(\.chapterIndex))"
        )
    }

    // MARK: - Where the reader is

    /// A stored anchor becomes a scroll offset, and the offset becomes the same anchor
    /// again. Drift here is a book that reopens a little further back every time — and,
    /// across a mode switch, the reported "different chapter, different percentage".
    func testAnAnchorSurvivesBeingScrolledToAndReadBack() async throws {
        try await show([chapter(1, paragraphs: 40)])

        for paragraph in stride(from: 0, to: 40, by: 7) {
            let anchor = TextAnchor(paragraph: paragraph, characterOffset: 0)
            coordinator.scroll(to: anchor, inChapter: 1, animated: false)
            XCTAssertEqual(
                coordinator.currentPlace()?.anchor.paragraph, paragraph,
                "paragraph \(paragraph) must be what its own scroll offset reports back"
            )
        }
    }

    /// The share is measured over the composed chapter, which is the denominator
    /// `PaginatedChapterView.fraction(atPage:)` uses. They used to be two different
    /// numbers — the composed string against the paragraph array alone — so the same
    /// sentence was a different percentage in each mode, by a title plus one character
    /// per paragraph.
    func testTheShareReadRunsFromNothingToTheWholeChapter() async throws {
        let only = chapter(1, paragraphs: 40)
        try await show([only])

        coordinator.scroll(to: .start, inChapter: 1, animated: false)
        let opening = try XCTUnwrap(coordinator.currentPlace()).fraction
        XCTAssertGreaterThan(opening, 0, "a screen of text is some of the chapter")
        XCTAssertLessThan(opening, 0.5, "and one screen of forty paragraphs is not half of it")

        coordinator.scroll(
            to: TextAnchor(paragraph: only.paragraphs.count - 1, characterOffset: 0),
            inChapter: 1, animated: false
        )
        XCTAssertEqual(
            try XCTUnwrap(coordinator.currentPlace()).fraction, 1,
            "the last screen of a chapter has to read as the whole of it, or no scrolled "
                + "book could ever be finished"
        )
    }

    // MARK: - Drawing

    /// Renders one window the way `ReaderTextCanvas` does, and says whether anything
    /// landed in it. The window is in content coordinates and the context's origin is
    /// its top-left corner, which is exactly the canvas's arrangement.
    private func hasInk(in window: CGRect) -> Bool {
        let blank = UIGraphicsImageRenderer(size: window.size).pngData { _ in }
        let drawn = UIGraphicsImageRenderer(size: window.size).pngData { context in
            coordinator.draw(window, in: context.cgContext)
        }
        return drawn != blank
    }

    /// Text has to reach the foot of the window however far into a chapter the reader is.
    ///
    /// The report this exists for, from a device: correct at the top of a chapter,
    /// emptier the further in, wholly blank once a window in, and the next chapter's
    /// opening correct again. It was the reader's distance into the chapter being
    /// subtracted twice — once here and once inside the column — so the text was pushed
    /// up by exactly that distance. Nothing in `ChapterColumnTests` could see it: those
    /// call the column directly, which applies the offset once and looks perfect.
    ///
    /// The simulator hid it too, because a demo chapter is barely taller than one window
    /// and the error only shows past that. So the fixture here is deliberately long.
    func testTextReachesTheFootOfTheWindowHoweverFarIntoAChapterTheReaderIs() async throws {
        try await show([chapter(1, paragraphs: 60)])

        for paragraph in [0, 10, 25, 40] {
            coordinator.scroll(
                to: TextAnchor(paragraph: paragraph, characterOffset: 0),
                inChapter: 1, animated: false
            )
            let top = view.readingOffset
            XCTAssertTrue(
                hasInk(in: CGRect(
                    x: 0, y: top, width: view.textWidth, height: view.visibleHeight
                )),
                "the window opened at paragraph \(paragraph) must have text in it"
            )
            // The foot first, because that is the end a doubled offset empties.
            XCTAssertTrue(
                hasInk(in: CGRect(
                    x: 0, y: top + view.visibleHeight - 60,
                    width: view.textWidth, height: 60
                )),
                "and text at its foot — a window opened at paragraph \(paragraph) that is "
                    + "full at the top and empty at the bottom is the reported blank screen"
            )
        }
    }

    // MARK: - Turning pages

    /// A tapped turn lands on the paragraph `ReaderTapZone` names, at the exact height
    /// its rule asks for.
    ///
    /// The rule is unchanged and already has its own tests; what is new is the landing.
    /// A `ScrollViewProxy` could only be pointed at a view and never said where it put
    /// it, which is why an over-tall paragraph — routine in these books — had to be
    /// moved *inside* by an anchor fraction and hope. Here the destination is a number,
    /// so it can be read back.
    func testATappedTurnLandsExactlyWhereTheRuleAsksFor() async throws {
        try await show([chapter(1, paragraphs: 40)])
        coordinator.scroll(to: .start, inChapter: 1, animated: false)

        let onScreen = coordinator.visibleParagraphs()
        let bottomBefore = try XCTUnwrap(onScreen.last).paragraph
        let forward = try XCTUnwrap(coordinator.pageTurnDestination(.next))
        XCTAssertGreaterThan(forward, view.readingOffset, "going on has to move forward")

        view.setReadingOffset(forward, animated: false)
        let top = try XCTUnwrap(coordinator.visibleParagraphs().first)
        XCTAssertLessThanOrEqual(
            top.paragraph, bottomBefore,
            "the paragraph the reader could only half see must arrive whole, not be skipped"
        )
        XCTAssertGreaterThan(top.paragraph, 0, "and the page must actually have turned")
        XCTAssertEqual(
            top.minY, 0, accuracy: 1,
            "the paragraph the turn aimed at must sit against the top of the window"
        )

        // And back overlaps rather than jumping a clean window: a page turn that shows
        // the line the reader was on is one nobody has to double-check.
        let back = try XCTUnwrap(coordinator.pageTurnDestination(.previous))
        XCTAssertLessThan(back, view.readingOffset)
        XCTAssertGreaterThan(
            back + view.visibleHeight, view.readingOffset,
            "going back a whole window with no overlap would lose the line they were on"
        )
    }

    /// While there is text on the other side of the window, a tap has to move it.
    ///
    /// Going on aims the last paragraph that starts on screen at the top of the window,
    /// and a paragraph taller than the window is the same paragraph every time: nothing
    /// else begins inside the window to take its place. So the first tap puts it at the
    /// top and every tap after that names the position it is already in — off by the
    /// fraction of a point the scroll view rounds away, which is what made it permanent
    /// rather than one wasted tap. The reader was left tapping a page that would not
    /// turn, having to scroll by hand to get out. Reported as page turning "sometimes"
    /// failing inside a code block: `<pre>` is extracted whole, so a listing is one
    /// paragraph and reliably several windows tall.
    ///
    /// Stated as a walk in both directions rather than as that one position, because the
    /// position is a consequence of the geometry and the guarantee is not: whatever the
    /// rule aims at, a reader who has text below them and taps must end up further down
    /// it.
    func testTappingThroughAParagraphTallerThanTheWindowIsNeverADeadEnd() async throws {
        let sentence = "他推開門，看見渡口的燈在雪裡亮著，像一句沒有說完的話。"
        try await show([chapter(1, paragraphs: [
            sentence,
            String(repeating: sentence, count: 90),
            sentence, sentence, sentence
        ])])
        let tall = try XCTUnwrap(coordinator.placed.first).column.paragraphFrames[1]
        XCTAssertGreaterThan(
            tall.maxY - tall.minY, view.visibleHeight * 2,
            "the fixture must hold a paragraph several windows tall, or it tests nothing"
        )

        coordinator.scroll(to: .start, inChapter: 1, animated: false)
        let lastWindow = coordinator.contentHeight - view.visibleHeight
        var taps = 0
        while view.readingOffset < lastWindow - 1 {
            taps += 1
            // A bound rather than an assertion, because a page that will not turn is a
            // loop that does not end: unfixed, this walked the same two points of the
            // same paragraph twenty-three million times before the run was killed.
            guard taps < 40 else {
                return XCTFail("a chapter this long cannot need forty taps to walk down")
            }
            try tap(.next, number: taps)
        }

        while view.readingOffset > 1 {
            taps += 1
            guard taps < 80 else {
                return XCTFail("nor eighty to walk it in both directions")
            }
            try tap(.previous, number: taps)
        }
    }

    // MARK: - Moving with nobody touching it

    /// The wiring, which no amount of arithmetic in `AutoScrollDriver` can stand in for: a
    /// page told to move on its own has to travel *through the scroll offset*, so that
    /// everything which follows from where the reader is — the place reports, the next
    /// chapter being asked for, which paragraphs are drawn — is reached by the path a
    /// finger would have taken rather than by a second one written for this feature.
    ///
    /// Switching it off is half the test. A driver that cannot be stopped is worse than one
    /// that never started: the reader taps the control, the glyph changes, and the book
    /// keeps walking away from them.
    func testAPageToldToMoveOnItsOwnTravelsThroughTheScrollOffsetAndStopsWhenAsked() async throws {
        let window = [chapter(0, paragraphs: 40)]
        try await show(window)
        XCTAssertEqual(view.readingOffset, 0)

        coordinator.update(with: text(window, autoScroll: 600))
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while view.readingOffset <= 0 {
            guard ContinuousClock.now < deadline else {
                return XCTFail("the page was told to move and never did")
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        coordinator.update(with: text(window, autoScroll: 0))
        let stopped = view.readingOffset
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(view.readingOffset, stopped, "a page switched off has to stay put")
    }

    // MARK: - What it writes down about itself

    /// The two lines somebody reads a device trace for, with the fields that make them
    /// worth reading.
    ///
    /// `col … noLines=0` is the whole of the 2026-08-28 device bug: a fragment whose line
    /// fragments TextKit has taken back leaves the copied geometry with holes in it, and
    /// it is *always* zero here, because a simulator is never short enough of memory to
    /// reclaim anything. The number has to be on the line so that a phone can say
    /// otherwise.
    ///
    /// `relayout why=size` is the 2026-09-06 one: a rebuild throws every column away and
    /// has to put the reader back, and the report that followed one put a reader several
    /// chapters behind where they had been. `why` is what tells a rebuild the reader asked
    /// for from one nobody asked for.
    func testALaidOutChapterAndARebuildBothSayEnoughToBeJudged() async throws {
        trace.isOn = true
        try await show([chapter(1, paragraphs: 30)])

        let columns = lines(matching: "col ")
        XCTAssertEqual(columns.count, 1, "one chapter, one layout pass, one line")
        let column = try XCTUnwrap(columns.first)
        XCTAssertTrue(column.contains("idx=1"), column)
        XCTAssertTrue(column.contains("noLines=0"), "the field the device answers: \(column)")
        for field in ["ms=", "paras=", "chars=", "frags=", "h="] {
            XCTAssertTrue(column.contains(field), "missing \(field) in: \(column)")
        }

        // The reader made the text bigger, which is every column describing a measure
        // nobody is reading at.
        settings.fontSize += 4
        try await show([chapter(1, paragraphs: 30)])

        let rebuilds = lines(matching: "relayout ")
        XCTAssertEqual(rebuilds.count, 2, "the first build and the resize")
        XCTAssertTrue(rebuilds[0].contains("why=first"), rebuilds[0])
        XCTAssertTrue(
            rebuilds[1].contains("why=size"),
            "a rebuild has to name what moved, or nobody can tell whether the reader "
                + "asked for it: \(rebuilds[1])"
        )
        XCTAssertTrue(rebuilds[1].contains("placed=1"), "what is being thrown away")
    }

    /// A tap that turns a page says where it meant to go, where it could go, and how much
    /// was left underneath — which is the difference between the loaded text running out
    /// and the layout drifting, and those two were confused for a fortnight in August.
    func testATurnSaysWhatItAskedForAndWhatItCouldHave() async throws {
        trace.isOn = true
        try await show([chapter(1, paragraphs: 40)])
        coordinator.turnPage(.next)

        let turn = try XCTUnwrap(lines(matching: "turn ").last)
        XCTAssertTrue(turn.contains("dir=next"), turn)
        for field in ["want=", "got=", "below=", "ms="] {
            XCTAssertTrue(turn.contains(field), "missing \(field) in: \(turn)")
        }
    }

    private func lines(matching event: String) -> [String] {
        String(data: trace.contents(), encoding: .utf8)?
            .split(separator: "\n")
            .filter { $0.contains(event) }
            .map(String.init) ?? []
    }

    // MARK: - Keeping up with the voice

    /// The rule that decides when a page follows what is being read out.
    ///
    /// Following every sentence is the obvious implementation and the wrong one: each
    /// sentence is a line or two of text, so the page would step under the reader's eye
    /// every few seconds for the whole book. Nothing moves until the voice has walked
    /// down to two thirds of the window, and then the sentence goes back up to a third —
    /// one deliberate movement, several sentences apart.
    func testThePageOnlyFollowsTheVoiceOnceItHasWalkedDownTheWindow() async throws {
        let window = [chapter(0, paragraphs: 40)]
        try await show(window)
        let column = try XCTUnwrap(coordinator.placed.first).column
        let screen = view.visibleHeight

        // A sentence the reader can comfortably see: the page has no business moving.
        let near = try XCTUnwrap(sentence(inParagraph: 1, of: window[0]))
        XCTAssertLessThan(column.y(for: near.anchor), screen * 2 / 3)
        XCTAssertNil(coordinator.speechDestination(for: near))

        // One well below the fold, which the reader cannot be following along with.
        let below = try XCTUnwrap(sentence(inParagraph: 12, of: window[0]))
        XCTAssertGreaterThan(column.y(for: below.anchor), screen)
        let destination = try XCTUnwrap(coordinator.speechDestination(for: below))
        XCTAssertEqual(
            column.y(for: below.anchor) - destination, screen / 3, accuracy: 0.5,
            "the sentence being read has to land a third of the way down the window"
        )
    }

    /// The wiring, for `AutoScrollDriver`'s reason: a rule that works out the right
    /// number and a page that never moves are indistinguishable to a reader, and only one
    /// of the two is something a unit test notices. What is asserted here is the offset
    /// itself, reached by handing the coordinator a sentence exactly as the voice does.
    func testThePageMovesItselfWhenTheVoiceWalksOutOfTheWindow() async throws {
        let window = [chapter(0, paragraphs: 40)]
        try await show(window)
        XCTAssertEqual(view.readingOffset, 0)

        let below = try XCTUnwrap(sentence(inParagraph: 12, of: window[0]))
        let destination = try XCTUnwrap(coordinator.speechDestination(for: below))
        coordinator.update(with: text(window, speaking: below))

        // Animated, so it arrives over several frames of the runloop rather than at once.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while abs(view.readingOffset - destination) > 1 {
            guard ContinuousClock.now < deadline else {
                return XCTFail(
                    "the voice moved on and the page stayed at \(view.readingOffset), "
                        + "\(destination) away from the sentence being read"
                )
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The same sentence, said again by the next `updateUIView`, must not move anything:
    /// a place report, a highlight, any of the dozen things that re-run this view happen
    /// while one sentence is being read, and a page that re-aimed on each of them would
    /// fight a reader who scrolled ahead.
    func testThePageIsNotMovedTwiceForOneSentence() async throws {
        let window = [chapter(0, paragraphs: 40)]
        try await show(window)
        let below = try XCTUnwrap(sentence(inParagraph: 12, of: window[0]))
        coordinator.update(with: text(window, speaking: below))
        try await Task.sleep(for: .milliseconds(400))

        let landed = view.readingOffset
        view.contentOffset.y = landed + 400
        coordinator.update(with: text(window, speaking: below))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(view.readingOffset, landed + 400, accuracy: 1)
    }

    /// The first sentence of a paragraph, as the voice would be handed it.
    private func sentence(
        inParagraph paragraph: Int, of chapter: ReaderModel.LoadedChapter
    ) -> SpokenSentence? {
        SpeechScript.sentences(
            chapterIndex: chapter.chapter.index,
            siteChapterId: chapter.chapter.siteChapterId,
            title: chapter.chapter.title,
            paragraphs: chapter.paragraphs,
            script: .off
        ).first { $0.paragraph == paragraph && !$0.isTitle }
    }

    /// One tapped turn, asserted on what the reader is left looking at rather than on
    /// what the rule worked out.
    ///
    /// The difference is the whole bug. At the top of an over-tall paragraph the rule
    /// returns a destination a fraction of a point past where the reader is — the
    /// paragraph's own top, which a scroll view resting on a device pixel cannot reach.
    /// Every such turn is forward by the arithmetic and motionless on the glass, so a
    /// test that compared the two numbers would have watched the page fail to turn and
    /// called it a page turn. Measured: it does exactly that, for as many taps as the
    /// loop is willing to take.
    private func tap(_ zone: ReaderTapZone.Zone, number: Int) throws {
        let before = view.readingOffset
        let destination = try XCTUnwrap(
            coordinator.pageTurnDestination(zone),
            "tap \(number), at \(before), had text to move into and was told there was "
                + "nowhere to go"
        )
        view.setReadingOffset(destination, animated: false)
        let moved = view.readingOffset - before
        XCTAssertGreaterThan(
            zone == .next ? moved : -moved, 1,
            "tap \(number), at \(before), moved the page \(moved) points"
        )
    }
}
