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

    /// A window the size of a phone, so `textWidth` and `visibleHeight` are real
    /// numbers rather than zero.
    private let window = CGRect(x: 0, y: 0, width: 390, height: 700)

    override func setUpWithError() throws {
        defaultsName = "ReaderScrollCoordinatorTests-\(UUID().uuidString)"
        settings = ReaderSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: defaultsName)))
        view = ReaderTextScrollView(frame: window)
        coordinator = ReaderScrollCoordinator()
        view.coordinator = coordinator
        coordinator.view = view
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removePersistentDomain(forName: defaultsName)
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

    private func text(_ chapters: [ReaderModel.LoadedChapter]) -> ReaderScrollingText {
        ReaderScrollingText(
            chapters: chapters, settings: settings, highlights: [:], marked: nil,
            target: nil, footer: .none,
            onPlaceChange: { _ in }, onNeedsNext: {}, onNeedsPrevious: {},
            onTouch: { _ in }, onTap: { _ in false }, onMark: { _, _ in },
            onTargetReached: {}
        )
    }

    /// Feeds the coordinator a window of chapters and waits for every column to land.
    ///
    /// The wait is the contract, not a workaround: columns are laid out on a background
    /// queue and handed over, which is the only reason a whole chapter can be measured
    /// at once. Awaiting yields the main actor, which is what lets them arrive.
    private func show(_ chapters: [ReaderModel.LoadedChapter]) async throws {
        coordinator.update(with: text(chapters))
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
}
