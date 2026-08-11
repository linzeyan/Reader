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
    /// this app reads actually look like — and what the sentence snapping has to cope
    /// with.
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

    private func chapterText(_ paragraphs: [String], size: CGFloat = 19) -> ChapterText {
        ChapterText(title: "第十七章　渡口", paragraphs: paragraphs, typography: typography(size: size))
    }

    /// A long chapter, so that a highlight can be put well past the first page.
    private func longChapter() -> [String] {
        (0..<190).map { index in
            let sentence = "他推開門，看見渡口的燈在雪裡亮著，像一句沒有說完的話。"
            return String(repeating: sentence, count: index % 5 + 1) + "第\(index)段。"
        }
    }

    private let pageSize = CGSize(width: 350, height: 600)

    /// A highlight over whatever a press-and-drag between two character positions picks
    /// out, which is the only way the app itself can make one.
    private func mark(
        _ text: ChapterText, from: Int, to: Int, chapterIndex: Int = 0
    ) throws -> TextHighlight {
        let range = try XCTUnwrap(text.sentenceRange(from: from, to: to))
        let selection = try XCTUnwrap(text.selection(for: range))
        return TextHighlight(
            bookId: "demo|1", chapterIndex: chapterIndex, selection: selection, createdAt: Date()
        )
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
        let highlight = try mark(
            text,
            from: start(ofParagraph: 0, in: text) + 22,
            to: start(ofParagraph: 2, in: text) + 1
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
        let highlight = try mark(
            text, from: start(ofParagraph: 1, in: text), to: start(ofParagraph: 1, in: text) + 3
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

    /// A press with no drag has to select something worth marking, and sentences are
    /// what a reader can aim at: the finger covers the characters it is pointing at, so
    /// snapping to nothing would mean marking whatever the hand was hiding.
    func testAPressSelectsTheWholeSentenceItLandsIn() throws {
        let text = chapterText(prose)
        let inside = start(ofParagraph: 0, in: text) + 6
        let range = try XCTUnwrap(text.sentenceRange(from: inside, to: inside))

        XCTAssertEqual(
            (text.attributed.string as NSString).substring(with: range), "他推開門，看見渡口的燈在雪裡亮著。"
        )
    }

    /// Closing punctuation belongs to the sentence it closes. Snapping to the full stop
    /// alone would leave the bracket outside the mark, which looks like a rendering
    /// fault rather than like a choice.
    func testASelectionKeepsTheBracketWithTheSentenceItCloses() throws {
        let text = chapterText(prose)
        let inside = start(ofParagraph: 1, in: text) + 2
        let range = try XCTUnwrap(text.sentenceRange(from: inside, to: inside))

        XCTAssertEqual(
            (text.attributed.string as NSString).substring(with: range), "「你還是來了。」"
        )
    }

    /// Pressing *on* the full stop marks the sentence it ends, not the one after it. The
    /// end of a sentence is exactly where a reader aims when they mean "this one".
    func testPressingOnAFullStopSelectsTheSentenceItEnds() throws {
        let text = chapterText(prose)
        // "第四段。" — the full stop is the fourth character of the paragraph.
        let stop = start(ofParagraph: 3, in: text) + 3
        let range = try XCTUnwrap(text.sentenceRange(from: stop, to: stop))

        XCTAssertEqual((text.attributed.string as NSString).substring(with: range), "第四段。")
    }

    /// A paragraph the site handed over without any terminator is one sentence, so it is
    /// marked whole. Falling back to "mark nothing" would leave dialogue lines and
    /// section breaks impossible to highlight at all.
    func testAParagraphWithNoTerminatorIsSelectedWhole() throws {
        let text = chapterText(prose)
        let inside = start(ofParagraph: 2, in: text) + 1
        let range = try XCTUnwrap(text.sentenceRange(from: inside, to: inside))

        XCTAssertEqual((text.attributed.string as NSString).substring(with: range), prose[2])
    }

    /// The chapter heading sits before the first paragraph, so no `TextAnchor` can name
    /// it. A highlight there would be stored pointing at paragraph 0 and would reappear
    /// over the wrong words, so the selection has to refuse instead.
    func testTheChapterHeadingCannotBeHighlighted() {
        let text = chapterText(prose)
        XCTAssertNil(text.sentenceRange(from: 1, to: 2), "the title is not part of any paragraph")
    }

    /// A drag that began on the heading still marks text, starting at the first
    /// paragraph: the reader asked for a passage, and the part of it that can be stored
    /// is better than nothing happening.
    func testADragThatBeganOnTheHeadingMarksFromTheFirstParagraph() throws {
        let text = chapterText(prose)
        let range = try XCTUnwrap(text.sentenceRange(from: 1, to: start(ofParagraph: 0, in: text) + 2))

        XCTAssertEqual(range.location, start(ofParagraph: 0, in: text))
        XCTAssertEqual((text.attributed.string as NSString).substring(with: range), "雪停了。")
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
        // Paragraph 4 is the longest of the repeating shapes, so its first sentence
        // certainly wraps at this width.
        let highlight = try mark(
            paginator.text,
            from: start(ofParagraph: 4, in: paginator.text) + 2,
            to: start(ofParagraph: 4, in: paginator.text) + 2
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
        let page = 3
        let middle = paginator.pages[page].range.location + paginator.pages[page].range.length / 2
        let range = try XCTUnwrap(paginator.text.sentenceRange(from: middle, to: middle))
        let rect = try XCTUnwrap(paginator.rects(for: range, onPage: page).first)

        let touched = try XCTUnwrap(
            paginator.offset(at: CGPoint(x: rect.midX, y: rect.midY), onPage: page)
        )
        XCTAssertTrue(
            NSLocationInRange(touched, range),
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

    // MARK: - Storage

    func testAHighlightSurvivesBeingStoredAndReadBack() throws {
        let repo = LibraryRepo(database: try AppDatabase.makeInMemory())
        let book = try repo.bookmark(siteId: "demo", siteBookId: "1", title: "t")
        let text = chapterText(prose)
        let range = try XCTUnwrap(text.sentenceRange(
            from: start(ofParagraph: 0, in: text) + 20, to: start(ofParagraph: 1, in: text) + 3
        ))
        let selection = try XCTUnwrap(text.selection(for: range))

        try repo.addHighlight(bookId: book.id, chapterIndex: 7, selection: selection)
        let stored = try XCTUnwrap(repo.highlights(bookId: book.id).first)

        XCTAssertEqual(stored.start, selection.start, "both ends have to come back")
        XCTAssertEqual(stored.end, selection.end)
        XCTAssertNotEqual(stored.start, stored.end, "a highlight is a span, not a point")
        XCTAssertEqual(stored.excerpt, selection.excerpt, "the list has to be able to quote it")
        XCTAssertEqual(stored.position, ReadingPosition(chapterIndex: 7, anchor: selection.start))
    }

    /// Marking the same passage twice is a gesture a reader will make by accident, and it
    /// has to be a no-op: a second row under the first would be invisible on the page and
    /// would take two deletes to clear.
    func testMarkingTheSamePassageTwiceKeepsOneHighlight() throws {
        let repo = LibraryRepo(database: try AppDatabase.makeInMemory())
        let book = try repo.bookmark(siteId: "demo", siteBookId: "1", title: "t")
        let text = chapterText(prose)
        let range = try XCTUnwrap(text.sentenceRange(
            from: start(ofParagraph: 0, in: text), to: start(ofParagraph: 0, in: text)
        ))
        let selection = try XCTUnwrap(text.selection(for: range))

        let first = try repo.addHighlight(
            bookId: book.id, chapterIndex: 0, selection: selection,
            now: Date(timeIntervalSince1970: 0)
        )
        let second = try repo.addHighlight(
            bookId: book.id, chapterIndex: 0, selection: selection,
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
        let text = chapterText(prose)
        let spans = [
            (chapter: 3, from: start(ofParagraph: 2, in: text)),
            (chapter: 1, from: start(ofParagraph: 0, in: text)),
            (chapter: 3, from: start(ofParagraph: 0, in: text)),
        ]
        for span in spans {
            let range = try XCTUnwrap(text.sentenceRange(from: span.from, to: span.from))
            try repo.addHighlight(
                bookId: book.id, chapterIndex: span.chapter,
                selection: try XCTUnwrap(text.selection(for: range))
            )
        }

        let ordered = try repo.highlights(bookId: book.id)
        XCTAssertEqual(ordered.map(\.chapterIndex), [1, 3, 3])
        XCTAssertEqual(ordered.map(\.startParagraph), [0, 0, 2])
    }

    /// A highlight into a book that is no longer on the shelf has nothing to point at,
    /// and an orphaned row would come back to life under whatever book next took the
    /// same id.
    func testDeletingABookTakesItsHighlightsWithIt() throws {
        let repo = LibraryRepo(database: try AppDatabase.makeInMemory())
        let book = try repo.bookmark(siteId: "demo", siteBookId: "1", title: "t")
        let text = chapterText(prose)
        let range = try XCTUnwrap(text.sentenceRange(
            from: start(ofParagraph: 0, in: text), to: start(ofParagraph: 0, in: text)
        ))
        try repo.addHighlight(
            bookId: book.id, chapterIndex: 0, selection: try XCTUnwrap(text.selection(for: range))
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
            ReadingPosition(chapterIndex: 4, anchor: TextAnchor(paragraph: 17, characterOffset: 23)),
            "the positions the reader already saved have to come through untouched"
        )
        XCTAssertTrue(
            try repo.highlights(bookId: "demo|1").isEmpty,
            "and no highlight may be invented for a book that never had one"
        )

        let text = chapterText(prose)
        let range = try XCTUnwrap(text.sentenceRange(
            from: start(ofParagraph: 0, in: text), to: start(ofParagraph: 0, in: text)
        ))
        try repo.addHighlight(
            bookId: "demo|1", chapterIndex: 0, selection: try XCTUnwrap(text.selection(for: range))
        )
        XCTAssertEqual(try repo.highlights(bookId: "demo|1").count, 1, "the new table is usable")
    }
}
