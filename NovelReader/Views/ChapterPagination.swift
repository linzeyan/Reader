import SwiftUI
import UIKit

/// The appearance settings as text attributes.
///
/// A value of its own rather than a read of `ReaderSettings` because pagination has
/// to be measurable without `UserDefaults` or a running app, and because breaking a
/// chapter into pages needs `UIFont` metrics that SwiftUI's `Font` does not expose.
struct ReaderTypography: Equatable {
    let body: UIFont
    let title: UIFont
    let lineSpacing: CGFloat
    let paragraphSpacing: CGFloat
    let color: UIColor

    init(body: UIFont, title: UIFont, lineSpacing: CGFloat, paragraphSpacing: CGFloat, color: UIColor) {
        self.body = body
        self.title = title
        self.lineSpacing = lineSpacing
        self.paragraphSpacing = paragraphSpacing
        self.color = color
    }

    /// The same faces, sizes and spacings the scrolling reader draws, so the two
    /// renderers are the same book in two shapes rather than two typefaces.
    init(settings: ReaderSettings) {
        let size = settings.fontSize
        body = settings.fontName.flatMap { UIFont(name: $0, size: size) } ?? .systemFont(ofSize: size)
        // Headings stay on the system face even when the body has a chosen font,
        // matching the scrolling reader's chapter titles.
        title = .systemFont(ofSize: size + 4, weight: .semibold)
        lineSpacing = settings.lineSpacing
        paragraphSpacing = settings.paragraphSpacing
        // Bridged rather than restated: a second copy of the nine palettes is how
        // the paginated reader ends up a shade off the scrolling one. Dynamic
        // colours survive the bridge and resolve against the drawing view's traits.
        color = UIColor(settings.theme.foreground)
    }
}

/// One chapter as a single attributed string, plus the map back to paragraph
/// coordinates.
///
/// The map is the whole point: layout works in UTF-16 offsets into one string, and
/// a stored `TextAnchor` names a paragraph and an offset inside it. Keeping the two
/// side by side in one value means no other type has to know how the chapter was
/// stitched together.
struct ChapterText {
    let attributed: NSAttributedString
    /// Range of each paragraph, indexed the way the site rule split them — the same
    /// index a `TextAnchor` stores. Excludes the newline that separates paragraphs,
    /// so an offset inside a range is always an offset inside real text.
    let paragraphRanges: [NSRange]

    init(title: String, paragraphs: [String], typography: ReaderTypography) {
        let composed = NSMutableAttributedString()
        var ranges: [NSRange] = []

        let titleStyle = NSMutableParagraphStyle()
        titleStyle.lineSpacing = typography.lineSpacing
        // A heading needs more air under it than between two paragraphs, or the
        // first line of the chapter reads as part of the title.
        titleStyle.paragraphSpacing = typography.paragraphSpacing + 8
        composed.append(NSAttributedString(
            string: title,
            attributes: [
                .font: typography.title,
                .foregroundColor: typography.color,
                .paragraphStyle: titleStyle,
            ]
        ))

        let bodyStyle = NSMutableParagraphStyle()
        bodyStyle.lineSpacing = typography.lineSpacing
        bodyStyle.paragraphSpacing = typography.paragraphSpacing
        // Justified, unlike the scrolling column: a fixed page has a visible right
        // edge, and a ragged one reads as a rendering fault rather than as a choice.
        // CJK text justifies without gaps because the glyphs are uniform width.
        bodyStyle.alignment = .justified
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: typography.body,
            .foregroundColor: typography.color,
            .paragraphStyle: bodyStyle,
        ]

        for paragraph in paragraphs {
            // The separator goes in front of each paragraph rather than behind it:
            // a trailing newline would leave an empty final element, which lays out
            // as a blank line and can push a page break past the end of the text.
            composed.append(NSAttributedString(string: "\n", attributes: bodyAttributes))
            let start = composed.length
            composed.append(NSAttributedString(string: paragraph, attributes: bodyAttributes))
            ranges.append(NSRange(location: start, length: composed.length - start))
        }

        attributed = composed
        paragraphRanges = ranges
    }
}

/// Breaks one chapter into pages with TextKit 2, and converts between pages and
/// stored `TextAnchor`s.
///
/// Layout runs in a single column of unbounded height and pages are windows onto
/// it. The alternative — a chain of fixed-height containers — would need the whole
/// chapter laid out before the first page could be drawn, and a 190-paragraph
/// chapter is common enough in the wild that this shows up as a stall on opening.
/// Windows onto one column can be found one at a time, which is what makes
/// `paginate(through:)` cheap.
///
/// Main-thread only. Deliberately not `@MainActor`: `NSTextLayoutManager` is not
/// thread-safe, but the annotation would buy nothing here and the unit suite drives
/// this type directly.
final class ChapterPaginator {
    /// A vertical window onto the laid-out column.
    struct Page: Equatable {
        /// UTF-16 range of the text on this page, in the composed chapter string.
        var range: NSRange
        /// Where the window starts in the column, used to position drawing.
        var top: CGFloat
        var height: CGFloat
    }

    let text: ChapterText
    let pageSize: CGSize
    private(set) var pages: [Page] = []
    /// False while the tail of the chapter has not been measured yet, which is what
    /// makes the page count a lower bound rather than a total.
    private(set) var isComplete = false

    private let contentStorage = NSTextContentStorage()
    private let layoutManager = NSTextLayoutManager()

    /// One line of laid-out text: where it starts in the string, and where it sits
    /// in the column. Pages are a greedy grouping of these.
    private struct Line {
        let start: Int
        let top: CGFloat
        let bottom: CGFloat
    }

    private var lines: [Line] = []
    private var resume: NSTextLocation?
    private var scannedAll = false
    /// How far ahead one scan measures, in pages. Small enough that opening a
    /// chapter costs a handful of lines of layout, large enough that a page turn
    /// almost never has to measure anything.
    private let chunkPages = 4

    init(text: ChapterText, pageSize: CGSize) {
        self.text = text
        self.pageSize = pageSize
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(
            size: CGSize(width: pageSize.width, height: .greatestFiniteMagnitude)
        )
        // The reader owns its own margins; the container's default padding would
        // narrow the text by 5pt on each side for no reason anyone chose.
        container.lineFragmentPadding = 0
        layoutManager.textContainer = container
        contentStorage.attributedString = text.attributed
        resume = contentStorage.documentRange.location
        if pageSize.width <= 0 || pageSize.height <= 0 {
            // Nothing can be measured in a zero-sized area, and pretending
            // otherwise would cache page breaks the first real layout must undo.
            scannedAll = true
            isComplete = true
        }
    }

    // MARK: - Measuring

    /// Measures far enough to know page `index`, or to reach the end of the chapter.
    func paginate(through index: Int) {
        while !isComplete && pages.count <= index { paginateNextChunk() }
    }

    /// Measures the whole chapter. Callers that need a total — the page counter, and
    /// a backwards chapter turn that has to land on the last page — pay for it here.
    func paginateAll() {
        while !isComplete { paginateNextChunk() }
    }

    /// Measures the next few pages' worth of lines and re-derives the page breaks.
    ///
    /// Split out so a view can spend one chunk per runloop turn: the page in front of
    /// the reader has to be on screen in the first frame, and counting the remaining
    /// pages of a long chapter is not worth a dropped one.
    func paginateNextChunk() {
        guard !scannedAll, let from = resume else {
            scannedAll = true
            rebuildPages()
            return
        }
        let target = (lines.last?.bottom ?? 0) + CGFloat(chunkPages) * pageSize.height
        let documentEnd = offset(of: contentStorage.documentRange.endLocation)
        let lineCountBefore = lines.count
        var reachedEnd = true
        _ = layoutManager.enumerateTextLayoutFragments(
            from: from, options: [.ensuresLayout]
        ) { fragment in
            append(fragment)
            resume = fragment.rangeInElement.endLocation
            guard (lines.last?.bottom ?? 0) >= target else { return true }
            reachedEnd = offset(of: fragment.rangeInElement.endLocation) >= documentEnd
            return false
        }
        // No new lines means the enumeration has nothing left to give; without this
        // the loops above would spin forever on text the layout manager declines to
        // measure.
        if reachedEnd || lines.count == lineCountBefore { scannedAll = true }
        rebuildPages()
    }

    /// Records one laid-out paragraph as its individual lines.
    ///
    /// Line granularity, not fragment granularity: a text layout fragment is a whole
    /// paragraph, and breaking pages only between paragraphs would leave a page with
    /// one line of text whenever the next paragraph is long.
    private func append(_ fragment: NSTextLayoutFragment) {
        let fragmentStart = offset(of: fragment.rangeInElement.location)
        let fragmentEnd = offset(of: fragment.rangeInElement.endLocation)
        let frame = fragment.layoutFragmentFrame
        for line in fragment.textLineFragments {
            // Clamped and required to advance: the offsets below are the only link
            // between layout and stored positions, and a line that claimed to start
            // outside its own paragraph would corrupt every anchor after it.
            let start = min(max(fragmentStart + line.characterRange.location, fragmentStart), fragmentEnd)
            guard let last = lines.last else {
                lines.append(Line(
                    start: start,
                    top: frame.minY + line.typographicBounds.minY,
                    bottom: frame.minY + line.typographicBounds.maxY
                ))
                continue
            }
            guard start > last.start else { continue }
            lines.append(Line(
                start: start,
                top: frame.minY + line.typographicBounds.minY,
                bottom: frame.minY + line.typographicBounds.maxY
            ))
        }
    }

    /// Greedily groups the measured lines into pages.
    ///
    /// Derived from scratch each time rather than appended to, so that a chunk
    /// measured later cannot produce different breaks from the ones a single pass
    /// over the whole chapter would have found. Progressive layout that paginates
    /// differently from complete layout would move the reader's place on its own.
    private func rebuildPages() {
        var built: [Page] = []
        var pageTop = lines.first?.top ?? 0
        var pageStart = 0
        for line in lines where line.bottom - pageTop > pageSize.height && line.start > pageStart {
            built.append(Page(
                range: NSRange(location: pageStart, length: line.start - pageStart),
                top: pageTop,
                height: pageSize.height
            ))
            pageTop = line.top
            pageStart = line.start
        }
        if scannedAll {
            // The tail is only a page once nothing more can arrive to fill it.
            let end = text.attributed.length
            if end > pageStart || built.isEmpty {
                built.append(Page(
                    range: NSRange(location: pageStart, length: max(0, end - pageStart)),
                    top: pageTop,
                    height: pageSize.height
                ))
            }
            isComplete = true
        }
        pages = built
    }

    // MARK: - Pages and anchors

    /// The page showing the text an anchor names, measuring as far as it takes.
    func pageIndex(for anchor: TextAnchor) -> Int {
        let target = offset(for: anchor)
        var index = 0
        while true {
            paginate(through: index)
            guard index < pages.count else { return max(0, pages.count - 1) }
            if NSMaxRange(pages[index].range) > target { return index }
            if isComplete && index == pages.count - 1 { return index }
            index += 1
        }
    }

    /// The anchor for a page: its first character.
    ///
    /// This is where paginated reading can be honest about `characterOffset` in a way
    /// the scrolling reader cannot. A scroll view only knows which paragraph came into
    /// view, so it stores offset 0; a page knows exactly which character it opens on.
    func anchor(at pageIndex: Int) -> TextAnchor {
        paginate(through: pageIndex)
        guard pages.indices.contains(pageIndex) else { return .start }
        return anchor(atOffset: pages[pageIndex].range.location)
    }

    /// UTF-16 offset into the composed chapter for an anchor.
    ///
    /// Clamps rather than fails: a stored anchor can outlive the text it named when a
    /// chapter comes back from the site shorter than it was, and the end of the right
    /// chapter is closer to the truth than refusing to open it. Mirrors the scrolling
    /// reader's `landingAnchor`.
    func offset(for anchor: TextAnchor) -> Int {
        guard !text.paragraphRanges.isEmpty else { return 0 }
        let index = min(max(anchor.paragraph, 0), text.paragraphRanges.count - 1)
        let range = text.paragraphRanges[index]
        return range.location + min(max(anchor.characterOffset, 0), range.length)
    }

    /// The anchor for a position in the composed chapter.
    ///
    /// Never rounds *forward* to the next paragraph. Switching renderers loses the
    /// character offset — a scroll view can only put a whole paragraph at the top of
    /// the screen — so an anchor that erred forwards would let a mode switch skip
    /// text. Erring backwards re-shows a line the reader has already read, which they
    /// will forgive.
    private func anchor(atOffset offset: Int) -> TextAnchor {
        let ranges = text.paragraphRanges
        // Before the first paragraph is the chapter heading, which belongs to the
        // start of the chapter rather than to a paragraph of its own.
        guard let index = ranges.lastIndex(where: { $0.location <= offset }) else { return .start }
        let range = ranges[index]
        return TextAnchor(
            paragraph: index,
            characterOffset: min(offset - range.location, range.length)
        )
    }

    // MARK: - Drawing

    /// Draws one page into a context whose origin is the top-left of the text area.
    ///
    /// The renderer draws from the layout manager that measured the pages. A second
    /// layout would be a second set of page breaks, and the two would disagree about
    /// which line the page starts on.
    func draw(page index: Int, in context: CGContext, clippedTo rect: CGRect) {
        guard pages.indices.contains(index) else { return }
        let page = pages[index]
        guard let start = location(at: page.range.location) else { return }
        context.saveGState()
        // A paragraph that straddles a page break is drawn whole and cut by the clip:
        // TextKit lays a paragraph out as one fragment, and asking for half of one
        // would mean laying it out twice with different results.
        context.clip(to: rect)
        context.translateBy(x: 0, y: -page.top)
        let bottom = page.top + page.height
        _ = layoutManager.enumerateTextLayoutFragments(
            from: start, options: [.ensuresLayout]
        ) { fragment in
            fragment.draw(at: fragment.layoutFragmentFrame.origin, in: context)
            return fragment.layoutFragmentFrame.maxY < bottom
        }
        context.restoreGState()
    }

    // MARK: - Offsets

    private func location(at offset: Int) -> NSTextLocation? {
        contentStorage.location(contentStorage.documentRange.location, offsetBy: offset)
    }

    private func offset(of location: NSTextLocation) -> Int {
        contentStorage.offset(from: contentStorage.documentRange.location, to: location)
    }
}
