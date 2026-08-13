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
    /// The composed text as an `NSString`. Held rather than bridged on demand because
    /// every offset in this type is a UTF-16 index, and a press-and-drag asks for
    /// characters dozens of times a second.
    private let characters: NSString

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
        characters = composed.string as NSString
    }
}

// MARK: - Text coordinates

/// Converting between stored anchors and offsets into the composed chapter.
///
/// Lives on the text rather than on the paginator because none of it depends on
/// layout: the scrolling reader needs the same answers, and a copy of this arithmetic
/// on the other side of the app is how one highlight ends up covering two different
/// passages.
extension ChapterText {
    /// UTF-16 offset into the composed chapter for an anchor.
    ///
    /// Clamps rather than fails: a stored anchor can outlive the text it named when a
    /// chapter comes back from the site shorter than it was, and the end of the right
    /// chapter is closer to the truth than refusing to open it. Mirrors the scrolling
    /// reader's `landingAnchor`.
    func offset(for anchor: TextAnchor) -> Int {
        guard !paragraphRanges.isEmpty else { return 0 }
        let index = min(max(anchor.paragraph, 0), paragraphRanges.count - 1)
        let range = paragraphRanges[index]
        return range.location + min(max(anchor.characterOffset, 0), range.length)
    }

    /// The anchor for a position in the composed chapter.
    ///
    /// Never rounds *forward* to the next paragraph. Switching renderers loses the
    /// character offset — a scroll view can only put a whole paragraph at the top of
    /// the screen — so an anchor that erred forwards would let a mode switch skip
    /// text. Erring backwards re-shows a line the reader has already read, which they
    /// will forgive.
    func anchor(atOffset offset: Int) -> TextAnchor {
        // Before the first paragraph is the chapter heading, which belongs to the
        // start of the chapter rather than to a paragraph of its own.
        guard let index = paragraphRanges.lastIndex(where: { $0.location <= offset }) else {
            return .start
        }
        let range = paragraphRanges[index]
        return TextAnchor(
            paragraph: index,
            characterOffset: min(offset - range.location, range.length)
        )
    }

    /// The composed ranges one highlight covers, one per paragraph it touches.
    ///
    /// Per paragraph rather than a single run from start to end, so the separators
    /// between paragraphs are left unpainted. The scrolling reader draws paragraphs as
    /// separate views and has no separator to paint; painting one here would make the
    /// same highlight look like a different shape in each mode.
    func ranges(of highlight: TextHighlight) -> [NSRange] {
        guard !paragraphRanges.isEmpty else { return [] }
        let lower = max(highlight.startParagraph, 0)
        let upper = min(highlight.endParagraph, paragraphRanges.count - 1)
        guard lower <= upper else { return [] }
        return (lower...upper).compactMap { index in
            let paragraph = paragraphRanges[index]
            guard let inParagraph = highlight.range(
                inParagraph: index, length: paragraph.length
            ) else { return nil }
            return NSRange(
                location: paragraph.location + inParagraph.location, length: inParagraph.length
            )
        }
    }

    /// The anchor pair and quoted text a composed range names.
    ///
    /// The quote keeps the separators the painting drops: a passage that runs from the
    /// end of one paragraph into the next reads as two lines in the marks list, which
    /// is what it looked like on the page.
    func selection(for range: NSRange) -> TextSelection? {
        guard range.length > 0, NSMaxRange(range) <= characters.length else { return nil }
        return TextSelection(
            start: anchor(atOffset: range.location),
            end: anchor(atOffset: NSMaxRange(range)),
            text: characters.substring(with: range)
        )
    }
}

// MARK: - Sentence snapping

/// Growing a press-and-drag into something worth marking.
///
/// Selection is snapped to whole sentences rather than to characters, and that is the
/// reason the paginated reader needs no drag handles. A finger covers the text it is
/// selecting, so character-precise dragging on a phone means aiming at glyphs the hand
/// is hiding; sentences are boundaries a reader can see before they press. It also
/// means a highlight can never start mid-word or end mid-clause, which is the failure
/// mode of every handle-free selection that snaps to nothing.
extension ChapterText {
    /// What ends a sentence.
    ///
    /// The CJK terminators this app mostly reads, plus the Latin ones. `.` is included
    /// knowing it splits "Mr. Smith" wrongly: over-splitting is recoverable by sliding
    /// the finger further, whereas a paragraph with no terminator at all can only be
    /// marked whole.
    private static let terminators = Set("。．！？!?；;…⋯.".unicodeScalars.map { UInt16($0.value) })

    /// Punctuation that belongs to the sentence it closes, so 「…。」 ends after the
    /// bracket rather than between the two marks.
    private static let closers = Set("」』〉》】）)］]｝}”’\"'".unicodeScalars.map { UInt16($0.value) })

    /// Expands two character positions into the whole sentences they fall in.
    ///
    /// Returns nil for anything a `TextAnchor` cannot name — the chapter heading sits
    /// before the first paragraph, and a highlight on it could not be stored, let alone
    /// found again.
    func sentenceRange(from: Int, to: Int) -> NSRange? {
        guard let first = paragraphRanges.first else { return nil }
        let lower = min(from, to)
        let upper = max(from, to)
        guard upper >= first.location else { return nil }
        let startParagraph = paragraphRanges[anchor(atOffset: max(lower, first.location)).paragraph]
        let endParagraph = paragraphRanges[anchor(atOffset: upper).paragraph]
        let head = sentenceStart(at: lower, in: startParagraph)
        let tail = sentenceEnd(at: upper, in: endParagraph)
        guard tail > head else { return nil }
        return NSRange(location: head, length: tail - head)
    }

    /// The sentence boundary at or before `offset`, never leaving the paragraph.
    private func sentenceStart(at offset: Int, in paragraph: NSRange) -> Int {
        var index = clamp(offset, to: paragraph)
        while index > paragraph.location, !endsSentence(before: index, in: paragraph) {
            index -= 1
        }
        return index
    }

    /// The sentence boundary after `offset`, never leaving the paragraph.
    ///
    /// Starts one past the offset so that pressing *on* a full stop selects the
    /// sentence it ends rather than the one after it.
    private func sentenceEnd(at offset: Int, in paragraph: NSRange) -> Int {
        let end = NSMaxRange(paragraph)
        var index = min(clamp(offset, to: paragraph) + 1, end)
        while index < end, !endsSentence(before: index, in: paragraph) {
            index += 1
        }
        return index
    }

    /// Whether a sentence finishes immediately before `index`.
    private func endsSentence(before index: Int, in paragraph: NSRange) -> Bool {
        let end = NSMaxRange(paragraph)
        guard index > paragraph.location, index <= end else { return false }
        // A closer sitting at this position still belongs to the sentence being closed,
        // so the boundary is on the far side of it.
        if index < end, Self.closers.contains(characters.character(at: index)) { return false }
        var scan = index - 1
        while scan >= paragraph.location, Self.closers.contains(characters.character(at: scan)) {
            scan -= 1
        }
        guard scan >= paragraph.location else { return false }
        return Self.terminators.contains(characters.character(at: scan))
    }

    private func clamp(_ offset: Int, to paragraph: NSRange) -> Int {
        min(max(offset, paragraph.location), NSMaxRange(paragraph))
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
    /// False while the tail of the chapter has not been measured yet. What it answers for
    /// the reader is whether turning past the last known page is the end of the chapter
    /// or merely the end of what has been laid out so far.
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

    /// Measures the whole chapter. The one caller that cannot avoid paying for it is a
    /// backwards chapter turn, which has to land on the last page.
    func paginateAll() {
        while !isComplete { paginateNextChunk() }
    }

    /// Measures the next few pages' worth of lines and re-derives the page breaks.
    ///
    /// A chunk at a time rather than the chapter at once: the page in front of the
    /// reader has to be on screen in the first frame, and laying out the remaining
    /// eighty pages of a long chapter is not worth a dropped one when nothing on screen
    /// is waiting for them.
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
        let target = text.offset(for: anchor)
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
        return text.anchor(atOffset: pages[pageIndex].range.location)
    }

    // MARK: - Touching text

    /// The character under a point on a page, in the page's own coordinates.
    ///
    /// The one thing only the paginated renderer can answer, and therefore the reason
    /// only a page can mark a *sentence*: a scroll view of SwiftUI `Text` knows which
    /// paragraph is on screen — so it marks one whole — while this knows which character
    /// is under a finger.
    ///
    /// Clamped into the page rather than allowed to run off it, so a finger dragged
    /// past the bottom edge selects to the end of what the reader can see instead of
    /// silently marking text on a page they have not turned to. A selection that carries
    /// on to the next page gets there by that page being turned to first — see
    /// `SelectionEdgeRule` — and then asking *it* for the offset, so the clamp never has
    /// to be relaxed for a passage to span a page break.
    func offset(at point: CGPoint, onPage index: Int) -> Int? {
        guard pages.indices.contains(index) else { return nil }
        let page = pages[index]
        let inColumn = CGPoint(x: point.x, y: point.y + page.top)
        guard let fragment = layoutManager.textLayoutFragment(for: inColumn) else { return nil }
        let frame = fragment.layoutFragmentFrame
        let local = CGPoint(x: inColumn.x - frame.minX, y: inColumn.y - frame.minY)
        guard let line = fragment.textLineFragments.last(where: {
            $0.typographicBounds.minY <= local.y
        }) ?? fragment.textLineFragments.first else { return nil }
        let bounds = line.typographicBounds
        let inLine = CGPoint(x: local.x - bounds.minX, y: local.y - bounds.minY)
        // Both of these answer `NSNotFound` for a point or a location they cannot place,
        // and `NSNotFound` is `Int.max`: adding anything to it overflows and traps the
        // process. A finger dragged past the bottom of a page is such a point, which is
        // how the cross-page selection walk brought the app down. Neither sentinel is a
        // failure worth reporting to the reader — the answer they want is the nearest real
        // character — so an unplaceable point falls back to the start of the line it landed
        // in, and the clamp below turns that into a position on this page.
        let fragmentStart = offset(of: fragment.rangeInElement.location)
        guard fragmentStart != NSNotFound else { return page.range.location }
        let inLineIndex = line.characterIndex(for: inLine)
        // An unplaceable point takes the end of the line it is past and the start of the
        // one it is short of, rather than one fixed end: the finger is somewhere with no
        // character of its own, and the nearest real position is the one that keeps a drag
        // moving in the direction the hand is moving.
        let withinLine: Int
        if inLineIndex != NSNotFound {
            withinLine = inLineIndex
        } else if inLine.y < 0 || inLine.x < 0 {
            withinLine = 0
        } else {
            withinLine = line.characterRange.length
        }
        let offset = fragmentStart + line.characterRange.location + withinLine
        return min(max(offset, page.range.location), NSMaxRange(page.range))
    }

    /// Rects covering a character range on one page, in the page's own coordinates.
    ///
    /// One rect per line, so a passage that wraps is marked as the lines a reader sees
    /// rather than as one block over the whole column. Empty when the range is on
    /// another page: a highlight that straddles a page break is drawn as its visible
    /// part on each side, from the same stored anchors.
    func rects(for range: NSRange, onPage index: Int) -> [CGRect] {
        guard pages.indices.contains(index), range.length > 0 else { return [] }
        let page = pages[index]
        let visible = NSIntersectionRange(range, page.range)
        guard visible.length > 0,
              let start = location(at: visible.location),
              let end = location(at: NSMaxRange(visible)),
              let textRange = NSTextRange(location: start, end: end)
        else { return [] }
        layoutManager.ensureLayout(for: textRange)
        var rects: [CGRect] = []
        layoutManager.enumerateTextSegments(in: textRange, type: .highlight) { _, rect, _, _ in
            if !rect.isEmpty { rects.append(rect.offsetBy(dx: 0, dy: -page.top)) }
            return true
        }
        return rects
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
