import UIKit
import XCTest
@testable import NovelReader

/// What paginated reading has to guarantee.
///
/// Pagination is a screen feature, but the part that can silently lose a reader's
/// place is arithmetic: which page a stored anchor opens on, and which anchor a page
/// reports back. Both renderers write the same `ReadingPosition`, so a mistake here
/// does not look like a layout bug — it looks like the book reopening in the wrong
/// place, or a bookmark made in one mode landing somewhere else in the other.
@MainActor
final class PaginationTests: XCTestCase {
    // MARK: - Fixtures

    /// Roughly the shape of the real thing: a long chapter of mixed-length Chinese
    /// paragraphs. 190 is not arbitrary — chapters that size exist on the sites this
    /// app reads, and they are what the progressive measuring below has to survive.
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

    /// An iPhone-sized text area, inset the way the reader insets it.
    private let pageSize = CGSize(width: 350, height: 600)

    private func paginator(
        paragraphs: [String],
        size: CGSize? = nil,
        typeSize: CGFloat = 19,
        complete: Bool = true
    ) -> ChapterPaginator {
        let paginator = ChapterPaginator(
            text: ChapterText(
                title: "第十七章　渡口", paragraphs: paragraphs, typography: typography(size: typeSize)
            ),
            pageSize: size ?? pageSize
        )
        if complete { paginator.paginateAll() }
        return paginator
    }

    // MARK: - Pages cover the chapter

    /// Every character of the chapter is on exactly one page. A gap between two pages
    /// is a line of the novel the reader can never see, and an overlap is a line they
    /// read twice at a page turn — neither is visible in a screenshot.
    func testThePagesCoverTheChapterWithoutGapsOrOverlap() {
        let paginator = paginator(paragraphs: longChapter())
        XCTAssertTrue(paginator.isComplete)
        XCTAssertGreaterThan(paginator.pages.count, 1, "a 190-paragraph chapter is more than one page")
        XCTAssertEqual(paginator.pages.first?.range.location, 0)
        for (index, page) in paginator.pages.enumerated().dropLast() {
            XCTAssertEqual(
                NSMaxRange(page.range), paginator.pages[index + 1].range.location,
                "page \(index + 1) must end where page \(index + 2) begins"
            )
        }
        XCTAssertEqual(
            NSMaxRange(paginator.pages[paginator.pages.count - 1].range),
            paginator.text.attributed.length,
            "the last page must reach the end of the chapter"
        )
    }

    /// A page is filled with lines, not with one paragraph.
    ///
    /// Breaking only where paragraphs end is much easier to implement and passes every
    /// coverage check above, but it leaves a two-line page whenever the next paragraph
    /// is long. So a chapter of 190 paragraphs has to come out as far fewer pages than
    /// it has paragraphs.
    func testAPageIsFilledWithLinesRatherThanWithOneParagraph() {
        let paragraphs = longChapter()
        let paginator = paginator(paragraphs: paragraphs)
        XCTAssertGreaterThan(paginator.pages.count, 1)
        XCTAssertLessThan(
            paginator.pages.count, paragraphs.count / 2,
            "pages must be packed with lines, not broken at every paragraph"
        )
    }

    /// A chapter with no text still has a page: the title is on it. Zero pages would
    /// leave the renderer with nothing to draw and no page number to show.
    func testAChapterWithNoParagraphsIsStillOnePage() {
        let paginator = paginator(paragraphs: [])
        XCTAssertEqual(paginator.pages.count, 1)
        XCTAssertEqual(paginator.anchor(at: 0), .start)
    }

    // MARK: - Pages and anchors

    /// The invariant that makes the page counter and the saved position agree: the
    /// anchor a page reports has to open that same page again. If it did not, closing
    /// the book and reopening it would shift the reader by a page every time.
    func testThePageAPositionOpensIsThePageThatReportedIt() {
        let paginator = paginator(paragraphs: longChapter())
        for index in paginator.pages.indices {
            let anchor = paginator.anchor(at: index)
            XCTAssertEqual(
                paginator.pageIndex(for: anchor), index,
                "the anchor reported by page \(index + 1) must reopen page \(index + 1)"
            )
        }
    }

    /// A page's anchor carries a real character offset, which is the whole reason the
    /// anchor has that field. The scrolling reader can only ever store 0 — it knows
    /// which paragraph appeared, not which character — so if pagination stored 0 too,
    /// nothing in the app would ever exercise the position format it was migrated to.
    func testAPageReportsWhereInTheParagraphItActuallyStarts() {
        let paginator = paginator(paragraphs: longChapter())
        let offsets = paginator.pages.indices.map { paginator.anchor(at: $0).characterOffset }
        XCTAssertTrue(
            offsets.contains { $0 > 0 },
            "paragraphs longer than a page must produce pages that open mid-paragraph"
        )
    }

    /// A position written by the scrolling reader — paragraph index, offset 0 — has to
    /// open the page that shows that paragraph. This is "continue reading" after the
    /// reader switched modes between sessions.
    func testAScrollPositionOpensThePageShowingThatParagraph() {
        let paragraphs = longChapter()
        let paginator = paginator(paragraphs: paragraphs)
        for paragraph in paragraphs.indices {
            let anchor = TextAnchor(paragraph: paragraph, characterOffset: 0)
            let page = paginator.pages[paginator.pageIndex(for: anchor)]
            let offset = paginator.offset(for: anchor)
            XCTAssertTrue(
                page.range.location <= offset && offset < NSMaxRange(page.range),
                "paragraph \(paragraph) must be visible on the page its anchor opens"
            )
        }
    }

    /// The cross-mode round trip, and the one asymmetry that is allowed.
    ///
    /// Going to the scrolling reader throws the character offset away: a scroll view can
    /// only put a whole paragraph at the top of the screen. Coming back may therefore
    /// land a page earlier — the reader re-reads a few lines. It must never land a page
    /// *later*, because that is text they never saw.
    func testSwitchingRenderersNeverSkipsText() {
        let paginator = paginator(paragraphs: longChapter())
        for index in paginator.pages.indices {
            let paged = paginator.anchor(at: index)
            // What the scrolling reader records once it has restored and scrolled.
            let scrolled = TextAnchor(paragraph: paged.paragraph, characterOffset: 0)
            let back = paginator.pageIndex(for: scrolled)
            XCTAssertLessThanOrEqual(
                back, index, "returning from the scrolling reader must not skip past page \(index + 1)"
            )
            XCTAssertGreaterThanOrEqual(
                back, index - 1, "and must not throw the reader back further than the page before"
            )
        }
    }

    /// A stored anchor can outlive the text it named when a chapter comes back from the
    /// site shorter than it was. It has to land inside the chapter: an anchor no page
    /// can satisfy would leave the reader looking at nothing.
    func testAnAnchorPastTheEndOfTheChapterLandsOnTheLastPage() {
        let paginator = paginator(paragraphs: Array(longChapter().prefix(12)))
        let stranded = TextAnchor(paragraph: 900, characterOffset: 4000)
        XCTAssertEqual(paginator.pageIndex(for: stranded), paginator.pages.count - 1)
    }

    // MARK: - Appearance changes

    /// Changing type size, spacing or window size re-measures every page break. The
    /// reader must come out of it looking at the same sentence — which is exactly what
    /// paragraph coordinates buy, and what a stored page number could not.
    func testAnAppearanceChangeKeepsTheReaderOnTheSameText() {
        let paragraphs = longChapter()
        let before = paginator(paragraphs: paragraphs)
        let landscape = CGSize(width: 700, height: 300)

        for page in [1, 4, 9] where page < before.pages.count {
            let anchor = before.anchor(at: page)
            for after in [
                paginator(paragraphs: paragraphs, typeSize: 30),
                paginator(paragraphs: paragraphs, typeSize: 13),
                paginator(paragraphs: paragraphs, size: landscape),
            ] {
                let landed = after.pages[after.pageIndex(for: anchor)]
                let offset = after.offset(for: anchor)
                XCTAssertTrue(
                    landed.range.location <= offset && offset < NSMaxRange(landed.range),
                    "the text the reader was on must still be on the page they land on"
                )
            }
        }
    }

    /// Sanity that the appearance settings reach the layout at all: bigger text means
    /// more pages. A paginator that ignored typography would pass every test above.
    func testALargerTypeSizeMakesMorePages() {
        let paragraphs = Array(longChapter().prefix(40))
        XCTAssertGreaterThan(
            paginator(paragraphs: paragraphs, typeSize: 30).pages.count,
            paginator(paragraphs: paragraphs, typeSize: 13).pages.count
        )
    }

    // MARK: - Progressive measuring

    /// Opening a chapter must not cost a whole chapter of layout. 190 paragraphs laid
    /// out in one go is the stall this design exists to avoid, so the first page has to
    /// arrive with the chapter still unmeasured.
    func testTheFirstPageDoesNotCostAWholeChapterOfLayout() {
        let paragraphs = longChapter()
        let partial = paginator(paragraphs: paragraphs, complete: false)
        partial.paginate(through: 0)

        XCTAssertGreaterThan(partial.pages.count, 0, "the page in front of the reader has to exist")
        XCTAssertFalse(partial.isComplete, "and the rest of the chapter must still be unmeasured")
        XCTAssertLessThan(
            partial.pages.count, paginator(paragraphs: paragraphs).pages.count,
            "only a window of the chapter may have been laid out"
        )
    }

    /// Measuring in chunks has to find the same page breaks as measuring in one pass.
    /// If it did not, the page a reader is on would move as the rest of the chapter
    /// caught up behind them.
    func testMeasuringInChunksFindsTheSameBreaksAsOnePass() {
        let paragraphs = longChapter()
        let progressive = paginator(paragraphs: paragraphs, complete: false)
        progressive.paginate(through: 0)
        progressive.paginate(through: 3)
        progressive.paginateAll()

        XCTAssertEqual(progressive.pages, paginator(paragraphs: paragraphs).pages)
    }

    // MARK: - Bookmarks across modes

    /// A bookmark made on a page has to come back out of the database as the same page,
    /// character offset included. `ReadingBookmark`'s identity is built from the
    /// position, so this is also what stops one page being bookmarked twice.
    func testABookmarkMadeOnAPageReopensThatPage() throws {
        let repo = LibraryRepo(database: try AppDatabase.makeInMemory())
        let book = try repo.bookmark(siteId: "demo", siteBookId: "1", title: "t")
        let paginator = paginator(paragraphs: longChapter())
        let page = try XCTUnwrap(paginator.pages.indices.first { paginator.anchor(at: $0).characterOffset > 0 })
        let position = ReadingPosition(chapterIndex: 3, anchor: paginator.anchor(at: page))

        _ = try repo.addReadingBookmark(bookId: book.id, position: position, excerpt: nil)
        let stored = try XCTUnwrap(repo.readingBookmarks(bookId: book.id).first)

        XCTAssertEqual(stored.position, position, "the offset a page reported must survive storage")
        XCTAssertEqual(paginator.pageIndex(for: stored.position.anchor), page)
    }

    /// The same bookmark opened in the scrolling reader has to name the paragraph the
    /// page began on, so both modes send the reader to the same passage.
    func testABookmarkMadeOnAPageScrollsToTheParagraphItOpenedOn() throws {
        let paginator = paginator(paragraphs: longChapter())
        let page = try XCTUnwrap(paginator.pages.indices.first { paginator.anchor(at: $0).characterOffset > 0 })
        let anchor = paginator.anchor(at: page)

        XCTAssertEqual(
            anchor.scrollID(chapterId: "demo|1|3"),
            TextAnchor.paragraphID(chapterId: "demo|1|3", paragraph: anchor.paragraph),
            "the scrolling reader ignores the offset and scrolls to the paragraph"
        )
    }

    // MARK: - Drawing

    /// Pixels of body text on a page, drawn the way the reader's page view draws it.
    ///
    /// An absolute count rather than a proportion, so that totals can be compared
    /// across page sizes below.
    private func ink(page: Int, from paginator: ChapterPaginator) -> Int {
        let bounds = CGRect(origin: .zero, size: paginator.pageSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { context in
            UIColor.white.setFill()
            context.fill(bounds)
            paginator.draw(page: page, in: context.cgContext, clippedTo: bounds)
        }
        guard let rendered = image.cgImage else { return 0 }
        let width = rendered.width
        let height = rendered.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let reader = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 0 }
        reader.draw(rendered, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels.filter { $0 < 128 }.count
    }

    /// The renderer draws the page it was asked for, and nothing at all when the page
    /// does not exist yet. A page view that quietly drew nothing would look exactly
    /// like a chapter that failed to load.
    func testTheRendererDrawsThePageItIsAskedFor() {
        let paginator = paginator(paragraphs: longChapter())
        XCTAssertGreaterThan(ink(page: 5, from: paginator), 0, "a page in the middle of a chapter has text on it")
        XCTAssertEqual(ink(page: paginator.pages.count, from: paginator), 0, "there is no page after the last one")
        XCTAssertEqual(ink(page: -1, from: paginator), 0)
    }

    /// Nothing is drawn twice and nothing is lost.
    ///
    /// The same chapter split into small pages has to carry as much ink as the same
    /// chapter in large ones. The easiest mistake in a windowed layout is to draw from
    /// the top of the column on every page, which would leave the total growing with
    /// the page count instead of staying put — and would show the reader page one over
    /// and over.
    func testTheSameChapterCarriesTheSameInkHoweverItIsSplit() {
        let paragraphs = Array(longChapter().prefix(8))
        let tall = paginator(paragraphs: paragraphs, size: CGSize(width: 350, height: 900))
        let short = paginator(paragraphs: paragraphs, size: CGSize(width: 350, height: 300))
        XCTAssertGreaterThan(short.pages.count, tall.pages.count, "shorter pages must mean more of them")

        let tallInk = tall.pages.indices.reduce(0) { $0 + ink(page: $1, from: tall) }
        let shortInk = short.pages.indices.reduce(0) { $0 + ink(page: $1, from: short) }
        XCTAssertGreaterThan(tallInk, 0)
        XCTAssertEqual(
            Double(shortInk), Double(tallInk), accuracy: Double(tallInk) / 10,
            "the same text drawn over more pages must still be the same text"
        )
    }

    // MARK: - The mode setting

    /// Which renderer a reader chose has to outlive the app. It is the first thing they
    /// see when they reopen a book, and re-choosing it every launch would be worse than
    /// not offering the choice.
    func testTheReadingModeSurvivesRelaunch() throws {
        let suite = "PaginationTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        // A suite domain outlives the process that wrote it, and the cleanup below is
        // not guaranteed to reach disk before the test host exits. So the clean slate
        // this test needs is made here rather than assumed — otherwise the run that
        // leaves `paginated` behind fails the *next* run, which is a test that reports
        // on the previous run instead of on the code.
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(ReaderSettings(defaults: defaults).mode, .scroll, "scrolling stays the default")
        ReaderSettings(defaults: defaults).mode = .paginated
        XCTAssertEqual(ReaderSettings(defaults: defaults).mode, .paginated)
    }
}
