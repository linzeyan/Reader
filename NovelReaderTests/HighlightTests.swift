import GRDB
import UIKit
import XCTest
@testable import NovelReader

/// What a highlight has to guarantee.
///
/// A highlight is the first thing in the app that stores a *pair* of text anchors, and
/// it is drawn by two renderers that share no drawing code: TextKit 2 bands behind
/// laid-out glyphs in paged mode, a tinted `AttributedString` run in scrolling mode. So
/// the failures worth catching here are not "does it draw" — they are "do the two draw
/// the same characters", and "does a mark still sit on the same words after the reader
/// changes the type size, rotates the phone, or comes back a week later".
@MainActor
final class HighlightTests: XCTestCase {
    // MARK: - Fixtures

    /// Sentence-punctuated Chinese prose with dialogue in 「」, which is what the sites
    /// this app reads actually look like — and what picking out words has to cope with.
    private let prose = [
        "雪停了。他推開門，看見渡口的燈在雪裡亮著。像一句沒有說完的話。",
        "「你還是來了。」船夫沒有回頭。他把槳擱在膝上，等著。",
        "河面很靜",
        "第四段。第五句。第六句。",
    ]

    private func typography(size: CGFloat = 19) -> ReaderTypography {
        ReaderTypography(
            body: .systemFont(ofSize: size),
            title: .systemFont(ofSize: size + 4, weight: .semibold),
            lineSpacing: 9,
            paragraphSpacing: 14,
            color: .black
        )
    }

    private func chapterText(
        _ paragraphs: [String], size: CGFloat = 19, alignment: NSTextAlignment = .justified,
        script: ChineseScript = .off
    ) -> ChapterText {
        ChapterText(
            title: "第十七章　渡口", paragraphs: paragraphs, typography: typography(size: size),
            alignment: alignment, script: script
        )
    }

    /// A long chapter, so that a highlight can be put well past the first page.
    private func longChapter() -> [String] {
        (0..<190).map { index in
            let sentence = "他推開門，看見渡口的燈在雪裡亮著，像一句沒有說完的話。"
            return String(repeating: sentence, count: index % 5 + 1) + "第\(index)段。"
        }
    }

    private let pageSize = CGSize(width: 350, height: 600)

    /// A highlight over a range, made the way the app makes one: through the selection
    /// the bar commits.
    private func highlight(
        _ text: ChapterText, _ range: NSRange, siteChapterId: String = "1"
    ) throws -> TextHighlight {
        let selection = try XCTUnwrap(text.selection(for: range))
        return TextHighlight(
            bookId: "demo|1", siteChapterId: siteChapterId, selection: selection, createdAt: Date()
        )
    }

    /// A highlight over what a press and slide between two positions picks out.
    private func mark(
        _ text: ChapterText, from: Int, to: Int, siteChapterId: String = "1"
    ) throws -> TextHighlight {
        try highlight(
            text, try XCTUnwrap(text.wordSelection(from: from, to: to)),
            siteChapterId: siteChapterId
        )
    }

    /// A highlight over exactly the characters between two carets — what the grips make.
    private func markCharacters(_ text: ChapterText, from: Int, to: Int) throws -> TextHighlight {
        try highlight(text, try XCTUnwrap(text.caretSelection(fixed: from, moving: to)))
    }

    private func composed(_ text: ChapterText, _ range: NSRange) -> String {
        (text.attributed.string as NSString).substring(with: range)
    }

    /// The characters the paginated renderer would paint bands behind.
    private func paintedOnPages(_ highlight: TextHighlight, in text: ChapterText) -> [String] {
        let composed = text.attributed.string as NSString
        return text.ranges(of: highlight).map { composed.substring(with: $0) }
    }

    /// The characters the scrolling renderer would tint, asked for exactly the way
    /// `ReaderView.paragraphText` asks for them.
    private func paintedInScroll(_ highlight: TextHighlight, in paragraphs: [String]) -> [String] {
        paragraphs.enumerated().compactMap { index, paragraph in
            let text = paragraph as NSString
            guard let range = highlight.range(inParagraph: index, length: text.length) else {
                return nil
            }
            return text.substring(with: range)
        }
    }

    /// The offset of the first character of one paragraph in the composed chapter.
    private func start(ofParagraph index: Int, in text: ChapterText) -> Int {
        text.paragraphRanges[index].location
    }

    // MARK: - One mark, two renderers

    /// The reason the coverage arithmetic lives in one function on `TextHighlight`. The
    /// two renderers are unrelated code paths, so nothing but a shared answer can keep
    /// a mark made on a page looking like the same passage after the reader switches to
    /// scrolling — and a mark that moves when the mode changes is worse than no mark.
    func testAHighlightMarksTheSameCharactersInBothRenderers() throws {
        let text = chapterText(prose)
        // From inside the last sentence of paragraph 0 into the first of paragraph 1:
        // the split that only exists because a highlight is a *pair* of anchors.
        let highlight = try mark(
            text,
            from: start(ofParagraph: 0, in: text) + 20,
            to: start(ofParagraph: 1, in: text) + 3
        )

        XCTAssertEqual(
            paintedOnPages(highlight, in: text), paintedInScroll(highlight, in: prose),
            "one highlight must be one passage in both modes"
        )
    }

    /// The common way to draw a line: from the end of one paragraph into the start of
    /// the next. It has to mark the tail of the first, all of anything between, and the
    /// head of the last — and nothing outside.
    func testASelectionAcrossParagraphsMarksTheTailAndTheHead() throws {
        let text = chapterText(prose)
        // 「像」 is the 22nd character of the first paragraph; the passage runs to the end
        // of the third.
        let highlight = try markCharacters(
            text,
            from: start(ofParagraph: 0, in: text) + 21,
            to: NSMaxRange(text.paragraphRanges[2])
        )

        let painted = paintedInScroll(highlight, in: prose)
        XCTAssertEqual(painted.count, 3, "the passage runs through three paragraphs")
        XCTAssertEqual(painted[0], "像一句沒有說完的話。", "only the tail of the first paragraph")
        XCTAssertEqual(painted[1], prose[1], "all of the paragraph in between")
        XCTAssertEqual(painted[2], prose[2], "and the whole of the last, which has no full stop")
        XCTAssertNil(
            highlight.range(inParagraph: 3, length: (prose[3] as NSString).length),
            "the paragraph after the passage must not be marked"
        )
    }

    /// A stored mark can outlive the text it named: a chapter re-fetched from the site
    /// can come back with shorter paragraphs. The renderers are handed these ranges
    /// directly, so an unclamped one is a crash rather than a cosmetic fault.
    func testAHighlightIsClampedToTextThatCameBackShorter() throws {
        let text = chapterText(prose)
        let highlight = try markCharacters(
            text, from: start(ofParagraph: 1, in: text), to: start(ofParagraph: 1, in: text) + 6
        )

        let shortened = 4
        let range = try XCTUnwrap(highlight.range(inParagraph: 1, length: shortened))
        XCTAssertLessThanOrEqual(
            NSMaxRange(range), shortened, "a mark may never point past the end of the text"
        )
        XCTAssertNil(
            highlight.range(inParagraph: 1, length: 0),
            "a paragraph that came back empty has nothing to mark"
        )
    }

    // MARK: - What a press picks out

    /// A press picks out a word, and it has to be the word the finger is on: the reader
    /// asked for "these characters", and a sentence — what a press used to pick — was
    /// usually far more than that.
    ///
    /// Latin text for the exact answer, because its word boundaries are not a matter of
    /// dictionary; the Chinese properties are pinned by the sweep below.
    func testAPressSelectsTheWordItLandsIn() throws {
        let text = chapterText(["The ferryman did not look back."])
        let paragraph = text.paragraphRanges[0]
        // Inside "ferryman".
        let range = try XCTUnwrap(text.word(at: paragraph.location + 6))
        XCTAssertEqual(composed(text, range), "ferryman")
        XCTAssertEqual(
            text.wordSelection(from: paragraph.location + 6, to: paragraph.location + 6), range,
            "a press that does not slide is exactly the word"
        )
    }

    /// Every position in Chinese prose picks out something that contains it, stays in its
    /// own paragraph, and is smaller than the sentence around it — the change this whole
    /// grain exists for. Swept over every position rather than sampled: the segmenter is
    /// a dictionary, and one lucky sample says nothing about the rest.
    func testEveryPositionInAParagraphPicksOutAWordThatContainsIt() throws {
        let text = chapterText(prose)
        var misses: [String] = []
        for (index, paragraph) in text.paragraphRanges.enumerated() {
            for offset in paragraph.location..<NSMaxRange(paragraph) {
                guard let word = text.word(at: offset) else {
                    misses.append("p\(index)+\(offset - paragraph.location): nothing")
                    continue
                }
                if !NSLocationInRange(offset, word) {
                    misses.append("p\(index)+\(offset - paragraph.location): \(word) misses it")
                }
                if NSIntersectionRange(word, paragraph) != word {
                    misses.append("p\(index)+\(offset - paragraph.location): \(word) leaves the paragraph")
                }
                if composed(text, word).contains("。") && word.length > 1 {
                    misses.append("p\(index)+\(offset - paragraph.location): \(composed(text, word)) runs over a full stop")
                }
            }
        }
        XCTAssertEqual(misses, [])
    }

    /// Punctuation is no word, but it is something a reader can point at — the end of a
    /// quotation they want to take with them. It is picked out on its own.
    func testPressingOnPunctuationPicksOutJustThatMark() throws {
        let text = chapterText(prose)
        // "第四段。" — the full stop is the fourth character of the paragraph.
        let stop = start(ofParagraph: 3, in: text) + 3
        let range = try XCTUnwrap(text.word(at: stop))
        XCTAssertEqual(composed(text, range), "。")
    }

    /// A press on blank space picks out nothing. An indent is not a word, and a mark on
    /// it would paint nothing, quote nothing, and have no ink to be tapped away by.
    func testAPressOnBlankSpacePicksOutNothing() {
        let text = chapterText(["　　河面很靜", "   ", "有字"])
        XCTAssertNil(text.word(at: start(ofParagraph: 0, in: text)), "the indent")
        XCTAssertNotNil(text.word(at: start(ofParagraph: 0, in: text) + 2), "the first word after it")
        XCTAssertNil(text.word(at: start(ofParagraph: 1, in: text) + 1), "a paragraph of spaces")
        XCTAssertNil(
            text.wordSelection(from: start(ofParagraph: 1, in: text), to: start(ofParagraph: 1, in: text)),
            "and a press there selects nothing at all"
        )
    }

    /// A slide grows a word at a time: both ends of what it picks out are word
    /// boundaries, whichever way the finger went, so a passage never starts or stops
    /// halfway through a word.
    func testASlideNeverSplitsAWord() throws {
        let text = chapterText(prose)
        let first = start(ofParagraph: 0, in: text)
        let last = NSMaxRange(text.paragraphRanges[1])
        for (from, to) in [(first + 5, first + 13), (first + 13, first + 5), (first + 6, last - 3)] {
            let range = try XCTUnwrap(text.wordSelection(from: from, to: to))
            XCTAssertEqual(
                text.word(at: range.location)?.location, range.location,
                "\(from)→\(to) starts on a word boundary"
            )
            XCTAssertEqual(
                text.word(at: NSMaxRange(range) - 1).map(NSMaxRange), NSMaxRange(range),
                "\(from)→\(to) ends on one"
            )
            XCTAssertTrue(NSLocationInRange(min(from, to), range) && NSLocationInRange(max(from, to), range))
        }
    }

    /// The chapter heading sits before the first paragraph, so no `TextAnchor` can name
    /// it. A highlight there would be stored pointing at paragraph 0 and would reappear
    /// over the wrong words, so the selection has to refuse instead.
    func testTheChapterHeadingCannotBeHighlighted() {
        let text = chapterText(prose)
        XCTAssertNil(text.word(at: 1), "the title is not part of any paragraph")
        XCTAssertNil(text.wordSelection(from: 1, to: 2))
        XCTAssertNil(text.caretSelection(fixed: 0, moving: 3), "not by a grip either")
    }

    /// A drag that began on the heading still marks text, starting at the first
    /// paragraph: the reader asked for a passage, and the part of it that can be stored
    /// is better than nothing happening.
    func testADragThatBeganOnTheHeadingMarksFromTheFirstParagraph() throws {
        let text = chapterText(prose)
        let first = start(ofParagraph: 0, in: text)
        let range = try XCTUnwrap(text.wordSelection(from: 1, to: first + 2))

        XCTAssertEqual(range.location, first)
        XCTAssertTrue(NSLocationInRange(first + 2, range), "as far as the word the finger reached")
        XCTAssertLessThanOrEqual(NSMaxRange(range), first + 3, "and not over the full stop after it")
    }

    // MARK: - What a grip moves

    /// A grip moves one end a character at a time and holds the other still, in either
    /// order: dragging the start past the end turns it into the end, the way a reader's
    /// thumb expects, rather than into an empty or inverted passage.
    func testAGripPicksOutExactlyTheCharactersBetweenTheTwoEnds() throws {
        let text = chapterText(prose)
        let paragraph = text.paragraphRanges[0]
        let fixed = paragraph.location + 9
        for moving in paragraph.location...NSMaxRange(paragraph) where moving != fixed {
            let range = try XCTUnwrap(text.caretSelection(fixed: fixed, moving: moving))
            XCTAssertEqual(
                range, NSRange(location: min(fixed, moving), length: abs(fixed - moving)),
                "moving to \(moving - paragraph.location)"
            )
        }
    }

    /// Nothing between the two ends is not a passage. The caller keeps the one it had,
    /// so a grip dragged onto the other one does not leave the reader with a selection
    /// of nothing — and neither does a grip that has only crossed the gap between two
    /// paragraphs.
    func testAGripThatEnclosesNothingKeepsTheLastRealPassage() {
        let text = chapterText(prose)
        let end = NSMaxRange(text.paragraphRanges[0])
        XCTAssertNil(text.caretSelection(fixed: end, moving: end))
        XCTAssertNil(
            text.caretSelection(fixed: end, moving: start(ofParagraph: 1, in: text)),
            "only the separator between two paragraphs"
        )
    }

    /// A grip dragged past the last line stops at the end of the chapter rather than
    /// asking for characters that are not there.
    func testAGripDraggedPastTheEndStopsAtTheLastCharacter() throws {
        let text = chapterText(prose)
        let fixed = start(ofParagraph: 3, in: text)
        let range = try XCTUnwrap(text.caretSelection(fixed: fixed, moving: fixed + 10_000))
        XCTAssertEqual(NSMaxRange(range), NSMaxRange(text.paragraphRanges[3]))
    }

    // MARK: - Copying

    /// Copying a stored mark gives exactly the characters it covers, with the paragraph
    /// break where the page has one — not the excerpt, which is capped for the list.
    func testCopyingAMarkGivesItsWholeTextAcrossParagraphs() throws {
        let long = String(repeating: "字", count: 400)
        let text = chapterText([long, "下一段。"])
        let highlight = try markCharacters(
            text, from: start(ofParagraph: 0, in: text), to: start(ofParagraph: 1, in: text) + 3
        )

        let copied = try XCTUnwrap(text.text(of: highlight))
        XCTAssertEqual(copied, long + "\n下一段", "the whole passage, separator and all")
        XCTAssertLessThan(highlight.excerpt.count, copied.count, "which the excerpt is not")
    }

    /// And in the script the reader is reading in now: a mark made over simplified text
    /// is copied as traditional once the reader has switched, because what goes on the
    /// pasteboard is what the page shows.
    func testCopyingAMarkGivesTheTextAsThePageShowsIt() throws {
        let served = ["头发很长。"]
        let highlight = try markCharacters(
            chapterText(served), from: start(ofParagraph: 0, in: chapterText(served)),
            to: NSMaxRange(chapterText(served).paragraphRanges[0])
        )
        let shown = chapterText(
            served, script: ChineseScript(depth: .characters, target: .traditional)
        )
        XCTAssertEqual(try XCTUnwrap(shown.text(of: highlight)), "頭髮很長。")
    }

    // MARK: - Marks survive the reader changing the page

    /// The invariant paragraph coordinates exist for, now applied to a pair of them.
    /// Type size and spacing move every glyph on screen and re-break every page; none of
    /// them may move the characters a mark covers.
    func testAHighlightCoversTheSameCharactersAtEveryTypeSize() throws {
        let source = chapterText(prose)
        let highlight = try mark(
            source,
            from: start(ofParagraph: 0, in: source) + 20,
            to: start(ofParagraph: 1, in: source) + 3
        )
        let expected = paintedOnPages(highlight, in: source)
        XCTAssertFalse(expected.joined().isEmpty)

        for size in [ReaderSettings.fontSizeRange.lowerBound, 19, ReaderSettings.fontSizeRange.upperBound] {
            XCTAssertEqual(
                paintedOnPages(highlight, in: chapterText(prose, size: CGFloat(size))), expected,
                "the mark must cover the same words at size \(size)"
            )
        }
    }

    /// The layout side of the same promise: after a re-measure at a different type size
    /// or in landscape, the bands are drawn on the page that shows the passage and stay
    /// inside it. A rect left in the old column's coordinates would paint a stripe over
    /// unrelated text — visible only to someone looking at that page.
    func testTheBandsAreDrawnOnThePageShowingThePassage() throws {
        let paragraphs = longChapter()
        let source = chapterText(paragraphs)
        let highlight = try mark(
            source,
            from: start(ofParagraph: 40, in: source) + 5,
            to: start(ofParagraph: 40, in: source) + 5
        )

        for size in [CGSize(width: 350, height: 600), CGSize(width: 700, height: 300)] {
            for typeSize in [CGFloat(13), 19, 30] {
                let paginator = ChapterPaginator(
                    text: chapterText(paragraphs, size: typeSize), pageSize: size
                )
                paginator.paginateAll()
                let ranges = paginator.text.ranges(of: highlight)
                let drawnOn = paginator.pages.indices.filter { page in
                    ranges.contains { !paginator.rects(for: $0, onPage: page).isEmpty }
                }

                let showing = paginator.pageIndex(for: highlight.start)
                XCTAssertEqual(
                    drawnOn.first, showing,
                    "the mark must first appear on the page a jump to it opens (\(size), \(typeSize)pt)"
                )
                for page in drawnOn {
                    for range in ranges {
                        for rect in paginator.rects(for: range, onPage: page) {
                            XCTAssertTrue(
                                rect.maxY > 0 && rect.minY < size.height,
                                "a band must overlap the page it is drawn on"
                            )
                            XCTAssertTrue(
                                rect.minX >= -1 && rect.maxX <= size.width + 1,
                                "and must stay inside the text column"
                            )
                        }
                    }
                }
            }
        }
    }

    /// A passage that wraps is marked line by line rather than as one block over the
    /// column, so the shape follows the text the way a marker pen would.
    func testAWrappedPassageIsMarkedLineByLine() throws {
        let paragraphs = longChapter()
        let paginator = ChapterPaginator(text: chapterText(paragraphs), pageSize: pageSize)
        paginator.paginateAll()
        // Paragraph 4 is the longest of the repeating shapes, so its first sentence —
        // twenty-seven characters — certainly wraps at this width.
        let highlight = try markCharacters(
            paginator.text,
            from: start(ofParagraph: 4, in: paginator.text),
            to: start(ofParagraph: 4, in: paginator.text) + 27
        )
        let range = try XCTUnwrap(paginator.text.ranges(of: highlight).first)
        let page = paginator.pageIndex(for: highlight.start)

        XCTAssertGreaterThan(
            paginator.rects(for: range, onPage: page).count, 1,
            "a sentence longer than a line must be marked as several lines"
        )
    }

    /// Touching a mark has to find the mark. This is the whole of "tap a highlight to
    /// remove it": the tap is turned into a character offset and matched against the
    /// stored ranges, so a hit test off by a line would leave a highlight that cannot be
    /// undone from the page it is on.
    func testTouchingAMarkedLineFindsACharacterInsideIt() throws {
        let paginator = ChapterPaginator(text: chapterText(longChapter()), pageSize: pageSize)
        paginator.paginateAll()
        // Swept rather than sampled at one page: this is a claim about the arithmetic,
        // and a single sample only ever says that one geometry happened to work out.
        var misses: [String] = []
        for page in stride(from: 1, to: min(paginator.pages.count, 24), by: 1) {
            let span = paginator.pages[page].range
            let middle = span.location + span.length / 2
            // Six characters, and the widest band of them: the middle of a one-character
            // band is the boundary a caret rounds across, which is not the question here.
            guard let range = paginator.text.caretSelection(fixed: middle, moving: middle + 6),
                  let rect = paginator.rects(for: range, onPage: page).max(by: { $0.width < $1.width })
            else { continue }
            let touched = paginator.offset(at: CGPoint(x: rect.midX, y: rect.midY), onPage: page)
            guard let touched, NSLocationInRange(touched, range) else {
                misses.append("page \(page): touched \(touched.map(String.init) ?? "nil") "
                    + "outside \(range) for rect \(rect)")
                continue
            }
        }
        XCTAssertEqual(
            misses, [],
            "a touch in the middle of a marked line must land inside the mark"
        )
    }

    /// A touch on a line the mark does not reach must not find it, or every tap on the
    /// page would offer to delete something.
    func testTouchingAnUnmarkedLineFindsNothingOfTheMark() throws {
        let paginator = ChapterPaginator(text: chapterText(longChapter()), pageSize: pageSize)
        paginator.paginateAll()
        let highlight = try mark(
            paginator.text,
            from: start(ofParagraph: 0, in: paginator.text) + 2,
            to: start(ofParagraph: 0, in: paginator.text) + 2
        )
        let ranges = paginator.text.ranges(of: highlight)
        let marked = try XCTUnwrap(paginator.rects(for: ranges[0], onPage: 0).first)

        // A couple of lines below the mark, still well inside the first page's text.
        let below = CGPoint(x: marked.midX, y: marked.maxY + marked.height * 2)
        let touched = try XCTUnwrap(paginator.offset(at: below, onPage: 0))
        XCTAssertFalse(
            ranges.contains { NSLocationInRange(touched, $0) },
            "a touch below the marked sentence must not count as touching it"
        )
    }

    // MARK: - Marks made while scrolling

    /// The scrolling column answers the two questions a finger asks of a line. A press is
    /// over a character, anywhere on it. A grip is a caret: the character's own index on
    /// its left half, the next one on its right — so taking hold of a grip, whose aim
    /// starts on the boundary it was drawn at, moves nothing.
    ///
    /// Swept over every character of forty paragraphs, collecting every miss: a geometry
    /// claim tested at one point says only that one point happened to work, which is how
    /// the paginator's lookup was off by a whole line for months.
    func testAPointOnTheScrollingColumnIsTheCharacterUnderItOrTheNearestCaret() throws {
        let text = chapterText(longChapter(), alignment: .natural)
        let column = ChapterColumn(text: text, width: pageSize.width)
        column.layOut()
        var misses: [String] = []
        for paragraph in text.paragraphRanges.prefix(40) {
            for offset in paragraph.location..<NSMaxRange(paragraph) {
                guard let glyph = column.rects(for: NSRange(location: offset, length: 1)).first
                else {
                    misses.append("\(offset): no rect")
                    continue
                }
                let left = CGPoint(x: glyph.minX + glyph.width / 4, y: glyph.midY)
                let right = CGPoint(x: glyph.maxX - glyph.width / 4, y: glyph.midY)
                let found = [
                    column.offset(at: left), column.offset(at: right),
                    column.offset(at: left, caret: true), column.offset(at: right, caret: true),
                ]
                if found != [offset, offset, offset, offset + 1] {
                    misses.append("\(offset): \(found)")
                }
            }
        }
        XCTAssertEqual(Array(misses.prefix(20)), [], "\(misses.count) misses in all")
    }

    /// The same caret on a page, where the paginated reader's grips are dragged: every
    /// character of a page well into the chapter, on justified lines.
    func testAPointOnAPageIsTheNearestCaretForAGrip() throws {
        let paginator = ChapterPaginator(text: chapterText(longChapter()), pageSize: pageSize)
        paginator.paginateAll()
        let page = 5
        var misses: [String] = []
        let range = paginator.pages[page].range
        let composed = paginator.text.attributed.string as NSString
        for offset in range.location..<NSMaxRange(range) {
            let character = NSRange(location: offset, length: 1)
            guard composed.substring(with: character) != "\n",
                  let glyph = paginator.rects(for: character, onPage: page).first
            else { continue }
            let left = CGPoint(x: glyph.minX + glyph.width / 4, y: glyph.midY)
            let right = CGPoint(x: glyph.maxX - glyph.width / 4, y: glyph.midY)
            let found = [
                paginator.offset(at: left, onPage: page, caret: true),
                paginator.offset(at: right, onPage: page, caret: true),
            ]
            if found != [offset, offset + 1] { misses.append("\(offset): \(found)") }
        }
        XCTAssertEqual(Array(misses.prefix(20)), [], "\(misses.count) misses in all")
    }

    /// A grip dragged off the column — above the heading, past the last line, out into
    /// the margins — still lands somewhere in the chapter. `characterIndex(for:)` answers
    /// `NSNotFound`, which is `Int.max`, for a point it cannot place, and adding anything
    /// to that traps the process: the paginator found that out from a finger dragged off
    /// the bottom of a page.
    func testNoPointOnOrOffTheScrollingColumnCanTrapTheLookup() throws {
        let text = chapterText(Array(longChapter().prefix(12)), alignment: .natural)
        let column = ChapterColumn(text: text, width: pageSize.width)
        column.layOut()
        let length = text.attributed.length
        var misses: [String] = []
        for x in [-40, 0, pageSize.width / 2, pageSize.width, pageSize.width + 40] as [CGFloat] {
            for y in stride(from: CGFloat(-100), through: column.height + 100, by: 3) {
                let offset = column.offset(at: CGPoint(x: x, y: y))
                if offset < 0 || offset > length { misses.append("(\(x), \(y)) → \(offset)") }
            }
        }
        XCTAssertEqual(misses, [])

        let fixed = text.paragraphRanges[3].location
        let above = try XCTUnwrap(
            text.caretSelection(fixed: fixed, moving: column.offset(at: CGPoint(x: 10, y: -50)))
        )
        XCTAssertEqual(
            above.location, text.paragraphRanges[0].location,
            "a grip dragged above the heading stops at the first character of the text"
        )
        let last = try XCTUnwrap(text.paragraphRanges.last)
        let below = try XCTUnwrap(text.caretSelection(
            fixed: fixed, moving: column.offset(at: CGPoint(x: 10, y: column.height + 50))
        ))
        XCTAssertTrue(
            NSMaxRange(below) >= last.location && NSMaxRange(below) <= NSMaxRange(last),
            "and one dragged past the last line stops on it"
        )
    }

    /// The two renderers compose the same chapter with different alignment — ragged in
    /// the column, justified on a page — and a passage picked out in one has to be the
    /// same characters in the other, or a mark would move when the reader switched modes.
    func testAPassagePickedOutWhileScrollingIsTheSamePassageOnAPage() throws {
        let paragraphs = longChapter()
        let scrolling = chapterText(paragraphs, alignment: .natural)
        let column = ChapterColumn(text: scrolling, width: pageSize.width)
        column.layOut()
        let lineOf40 = column.y(for: TextAnchor(paragraph: 40, characterOffset: 0))
        let pressed = column.offset(at: CGPoint(x: 100, y: lineOf40 + 5))
        let highlight = try mark(scrolling, from: pressed, to: pressed)
        XCTAssertEqual(highlight.startParagraph, 40, "the press landed on the paragraph it aimed at")

        let paginator = ChapterPaginator(text: chapterText(paragraphs), pageSize: pageSize)
        paginator.paginateAll()
        XCTAssertEqual(
            paintedOnPages(highlight, in: paginator.text), paintedOnPages(highlight, in: scrolling),
            "one passage in both modes"
        )
        let page = paginator.pageIndex(for: highlight.start)
        XCTAssertFalse(
            paginator.rects(for: try XCTUnwrap(paginator.text.ranges(of: highlight).first), onPage: page)
                .isEmpty,
            "and drawn on the page a jump to it opens"
        )
    }

    // MARK: - Storage

    func testAHighlightSurvivesBeingStoredAndReadBack() throws {
        let repo = LibraryRepo(database: try AppDatabase.makeInMemory())
        let book = try repo.bookmark(siteId: "demo", siteBookId: "1", title: "t")
        let text = chapterText(prose)
        let range = try XCTUnwrap(text.wordSelection(
            from: start(ofParagraph: 0, in: text) + 20, to: start(ofParagraph: 1, in: text) + 3
        ))
        let selection = try XCTUnwrap(text.selection(for: range))

        try repo.addHighlight(bookId: book.id, siteChapterId: "7", selection: selection)
        let stored = try XCTUnwrap(repo.highlights(bookId: book.id).first)

        XCTAssertEqual(stored.start, selection.start, "both ends have to come back")
        XCTAssertEqual(stored.end, selection.end)
        XCTAssertNotEqual(stored.start, stored.end, "a highlight is a span, not a point")
        XCTAssertEqual(stored.excerpt, selection.excerpt, "the list has to be able to quote it")
        XCTAssertEqual(stored.position, ReadingPosition(siteChapterId: "7", anchor: selection.start))
    }

    /// Marking the same passage twice is a gesture a reader will make by accident, and it
    /// has to be a no-op: a second row under the first would be invisible on the page and
    /// would take two deletes to clear.
    func testMarkingTheSamePassageTwiceKeepsOneHighlight() throws {
        let repo = LibraryRepo(database: try AppDatabase.makeInMemory())
        let book = try repo.bookmark(siteId: "demo", siteBookId: "1", title: "t")
        let text = chapterText(prose)
        let range = try XCTUnwrap(text.wordSelection(
            from: start(ofParagraph: 0, in: text), to: start(ofParagraph: 0, in: text)
        ))
        let selection = try XCTUnwrap(text.selection(for: range))

        let first = try repo.addHighlight(
            bookId: book.id, siteChapterId: "1", selection: selection,
            now: Date(timeIntervalSince1970: 0)
        )
        let second = try repo.addHighlight(
            bookId: book.id, siteChapterId: "1", selection: selection,
            now: Date(timeIntervalSince1970: 9_000)
        )

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(try repo.highlights(bookId: book.id).count, 1)
        XCTAssertEqual(
            second.createdAt, first.createdAt,
            "the row the reader already made must not be re-stamped under them"
        )
    }

    /// The list runs the way the book runs, not the way the reader happened to mark it:
    /// a list in creation order cannot be used to find a passage.
    func testHighlightsComeBackInReadingOrder() throws {
        let repo = LibraryRepo(database: try AppDatabase.makeInMemory())
        let book = try repo.bookmark(siteId: "demo", siteBookId: "1", title: "t")
        // The order is the catalog's, so the catalog has to exist — and its ids are
        // deliberately not in the order the chapters are read, which is the whole reason
        // the list cannot sort on them.
        try repo.replaceCatalog(bookId: book.id, entries: [
            (siteChapterId: "z", title: "第一章", url: "https://demo.test/1/z"),
            (siteChapterId: "m", title: "第二章", url: "https://demo.test/1/m"),
            (siteChapterId: "a", title: "第三章", url: "https://demo.test/1/a"),
        ])
        let text = chapterText(prose)
        let spans = [
            (chapter: "a", from: start(ofParagraph: 2, in: text)),
            (chapter: "z", from: start(ofParagraph: 0, in: text)),
            (chapter: "a", from: start(ofParagraph: 0, in: text)),
        ]
        for span in spans {
            let range = try XCTUnwrap(text.wordSelection(from: span.from, to: span.from))
            try repo.addHighlight(
                bookId: book.id, siteChapterId: span.chapter,
                selection: try XCTUnwrap(text.selection(for: range))
            )
        }

        let ordered = try repo.highlights(bookId: book.id)
        XCTAssertEqual(ordered.map(\.siteChapterId), ["z", "a", "a"])
        XCTAssertEqual(ordered.map(\.startParagraph), [0, 0, 2])
    }

    /// A highlight into a book that is no longer on the shelf has nothing to point at,
    /// and an orphaned row would come back to life under whatever book next took the
    /// same id.
    func testDeletingABookTakesItsHighlightsWithIt() throws {
        let repo = LibraryRepo(database: try AppDatabase.makeInMemory())
        let book = try repo.bookmark(siteId: "demo", siteBookId: "1", title: "t")
        let text = chapterText(prose)
        let range = try XCTUnwrap(text.wordSelection(
            from: start(ofParagraph: 0, in: text), to: start(ofParagraph: 0, in: text)
        ))
        try repo.addHighlight(
            bookId: book.id, siteChapterId: "1", selection: try XCTUnwrap(text.selection(for: range))
        )
        XCTAssertEqual(try repo.highlights(bookId: book.id).count, 1)

        try repo.removeBookmark(bookId: book.id)

        XCTAssertTrue(try repo.highlights(bookId: book.id).isEmpty)
    }

    /// The excerpt is an index into the book, not a second copy of it. A reader who marks
    /// a whole page must not put a whole page in the database.
    func testTheExcerptIsCappedRatherThanStoringTheWholePassage() throws {
        let long = String(repeating: "字", count: 400)
        let selection = TextSelection(
            start: .start, end: TextAnchor(paragraph: 0, characterOffset: 400), text: long
        )
        XCTAssertLessThan(selection.excerpt.count, long.count)
        XCTAssertTrue(selection.excerpt.hasSuffix("…"), "a cut has to be visible in the list")
    }

    // MARK: - Migration

    /// v5 only adds a table. Nothing recorded a highlight before it, so there is nothing
    /// to convert — but the saved positions that share the screen with them do exist, and
    /// a migration that disturbed those would empty a list the reader has been using.
    func testTheMigrationAddsHighlightsWithoutDisturbingSavedPositions() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v4.readingAnchors")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO "book" ("id", "siteId", "siteBookId", "title", "addedAt", "updatedAt")
                VALUES ('demo|1', 'demo', '1', 't', '2024-01-01', '2024-01-01')
                """)
            // The catalog the bookmark's index points into. v6 needs it to convert the
            // index to a chapter id; `ChapterIdentityTests` covers what happens when it
            // cannot.
            try db.execute(sql: """
                INSERT INTO "chapter" ("id", "bookId", "siteChapterId", "index", "title", "url")
                VALUES ('demo|1|c4', 'demo|1', 'c4', 4, '第五章', 'https://demo.test/1/5')
                """)
            try db.execute(sql: """
                INSERT INTO "readingBookmark"
                ("id", "bookId", "chapterIndex", "paragraph", "characterOffset", "createdAt", "excerpt")
                VALUES ('demo|1|4|17|23', 'demo|1', 4, 17, 23, '2024-02-01', '雪停了。')
                """)
        }
        XCTAssertFalse(try queue.read { try $0.tableExists(TextHighlight.databaseTableName) })

        try AppDatabase.migrator.migrate(queue)

        let repo = LibraryRepo(database: try AppDatabase(queue))
        let bookmark = try XCTUnwrap(repo.readingBookmarks(bookId: "demo|1").first)
        XCTAssertEqual(
            bookmark.position,
            ReadingPosition(siteChapterId: "c4", anchor: TextAnchor(paragraph: 17, characterOffset: 23)),
            "the positions the reader already saved have to come through untouched"
        )
        XCTAssertTrue(
            try repo.highlights(bookId: "demo|1").isEmpty,
            "and no highlight may be invented for a book that never had one"
        )

        let text = chapterText(prose)
        let range = try XCTUnwrap(text.wordSelection(
            from: start(ofParagraph: 0, in: text), to: start(ofParagraph: 0, in: text)
        ))
        try repo.addHighlight(
            bookId: "demo|1", siteChapterId: "1", selection: try XCTUnwrap(text.selection(for: range))
        )
        XCTAssertEqual(try repo.highlights(bookId: "demo|1").count, 1, "the new table is usable")
    }
}
