import UIKit

/// One chapter as a continuous column of laid-out text.
///
/// The scrolling reader's counterpart to `ChapterPaginator` — which is this same TextKit 2
/// column with page breaks derived on top of it. There are no pages here: the window is
/// the screen, and it moves continuously rather than jumping.
///
/// Laid out **once, completely**, and then never again. That is the entire reason this
/// type exists. The renderer it replaces built one SwiftUI `Text` per paragraph inside a
/// `LazyVStack`, so every row entering the viewport paid for its own layout as it
/// arrived: measured at 58ms of main-thread work per tapped turn, owned by no structural
/// mutation, and fixed for the life of the session rather than growing (see PITFALLS,
/// 2026-08-27). Here that work is paid once per chapter, off the main thread, and
/// scrolling is drawing glyphs that were laid out minutes ago.
///
/// Deliberately not `@MainActor`, and built on a background queue on purpose:
/// `NSTextLayoutManager` is not thread-safe, but it is perfectly usable from *one*
/// thread. The contract is ownership handoff — a column is created and laid out on a
/// background queue, and from the moment it is handed to the main thread that is the
/// only thread which may touch it. Nothing here is safe to call concurrently.
final class ChapterColumn {
    let text: ChapterText
    /// The measure the text was laid out in. A change means this column describes a
    /// width nobody is reading at, and a new one has to be built.
    let width: CGFloat

    /// Total height of the laid-out column. Zero until `layOut()` has run.
    private(set) var height: CGFloat = 0

    /// Where each paragraph sits in the column, in the same index a `TextAnchor` stores.
    ///
    /// Precomputed rather than derived per query: the scrolling reader asks "which
    /// paragraphs are on screen" on every frame it moves, and that question used to be
    /// answered by a `GeometryReader` behind every row. This is the replacement, and it
    /// is a binary search over an array rather than a preference tree walk.
    private(set) var paragraphFrames: [ParagraphFrame] = []

    /// One paragraph's vertical extent in the column.
    struct ParagraphFrame: Equatable {
        /// Index within the chapter — what `TextAnchor` stores.
        let paragraph: Int
        let minY: CGFloat
        let maxY: CGFloat
    }

    private let contentStorage = NSTextContentStorage()
    private let layoutManager = NSTextLayoutManager()

    /// One laid-out line: where it starts in the string, and where it sits in the column.
    ///
    /// Line granularity rather than paragraph, for the same reason `ChapterPaginator`
    /// keeps it: a paragraph can be taller than the window, and both "where is the reader"
    /// and "what is on screen" have to be answerable inside one.
    private struct Line {
        let start: Int
        let top: CGFloat
        let bottom: CGFloat
    }

    private var lines: [Line] = []

    init(text: ChapterText, width: CGFloat) {
        self.text = text
        self.width = width
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(
            size: CGSize(width: max(width, 0), height: .greatestFiniteMagnitude)
        )
        // The reader owns its own margins; the container's default padding would narrow
        // the text by 5pt a side for no reason anyone chose.
        container.lineFragmentPadding = 0
        layoutManager.textContainer = container
        contentStorage.attributedString = text.attributed
    }

    // MARK: - Layout

    /// Lays the whole chapter out and records every line.
    ///
    /// All of it, unlike `ChapterPaginator.paginateNextChunk` — and the difference is
    /// the point rather than an oversight. A paginated reader can measure four pages
    /// ahead because it only ever shows one page and knows which; a scroll view has to
    /// state a `contentSize` before it can be scrolled at all, and a content size that
    /// grows as the reader travels is a scroll bar that lies and a `contentOffset` that
    /// means something different each time it is read.
    ///
    /// Affordable because it does not run on the main thread. Call it on the background
    /// queue that built the column, before handing it over.
    func layOut() {
        guard width > 0, lines.isEmpty else { return }
        let start = contentStorage.documentRange.location
        _ = layoutManager.enumerateTextLayoutFragments(
            from: start, options: [.ensuresLayout]
        ) { fragment in
            append(fragment)
            return true
        }
        height = lines.last?.bottom ?? 0
        buildParagraphFrames()
    }

    /// Records one laid-out paragraph as its individual lines.
    ///
    /// Clamped and required to advance, exactly as in `ChapterPaginator`: these offsets
    /// are the only link between layout and stored positions, and a line claiming to
    /// start outside its own paragraph would corrupt every anchor after it.
    private func append(_ fragment: NSTextLayoutFragment) {
        let fragmentStart = offset(of: fragment.rangeInElement.location)
        let fragmentEnd = offset(of: fragment.rangeInElement.endLocation)
        let frame = fragment.layoutFragmentFrame
        for line in fragment.textLineFragments {
            let start = min(
                max(fragmentStart + line.characterRange.location, fragmentStart), fragmentEnd
            )
            let top = frame.minY + line.typographicBounds.minY
            let bottom = frame.minY + line.typographicBounds.maxY
            guard let last = lines.last else {
                lines.append(Line(start: start, top: top, bottom: bottom))
                continue
            }
            guard start > last.start else { continue }
            lines.append(Line(start: start, top: top, bottom: bottom))
        }
    }

    /// Turns the line table into one extent per paragraph.
    ///
    /// A paragraph's top is the top of the line its first character fell on, and its
    /// bottom is the bottom of the line its last character fell on — never the next
    /// paragraph's top, which would fold the spacing between them into whichever one was
    /// asked first and make two adjacent paragraphs disagree about where the boundary is.
    private func buildParagraphFrames() {
        paragraphFrames = text.paragraphRanges.enumerated().map { index, range in
            let first = lines[lineIndex(containing: range.location)]
            let last = lines[lineIndex(containing: max(range.location, NSMaxRange(range) - 1))]
            return ParagraphFrame(paragraph: index, minY: first.top, maxY: last.bottom)
        }
    }

    // MARK: - Coordinates

    /// Where a UTF-16 offset sits in the column: the top of the line it falls on.
    func y(forOffset offset: Int) -> CGFloat {
        guard !lines.isEmpty else { return 0 }
        return lines[lineIndex(containing: offset)].top
    }

    /// Where a stored anchor sits in the column.
    func y(for anchor: TextAnchor) -> CGFloat {
        y(forOffset: text.offset(for: anchor))
    }

    /// The offset the text at a given height begins with.
    ///
    /// The first line whose bottom is past `y` — so a height inside a line names that
    /// line rather than the one above it, and the reading position never rounds forward
    /// into text the reader has not reached.
    func offset(atY y: CGFloat) -> Int {
        guard !lines.isEmpty else { return 0 }
        var low = 0
        var high = lines.count - 1
        var found = lines.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].bottom > y {
                found = mid
                high = mid - 1
            } else {
                low = mid + 1
            }
        }
        return lines[found].start
    }

    /// The anchor for a height in the column.
    func anchor(atY y: CGFloat) -> TextAnchor {
        text.anchor(atOffset: offset(atY: y))
    }

    /// The paragraphs with any part inside a vertical range.
    ///
    /// The replacement for the per-row `GeometryReader` the lazy stack needed: same
    /// answer, from a binary search over an array that was built once.
    func paragraphs(in range: Range<CGFloat>) -> ArraySlice<ParagraphFrame> {
        guard !paragraphFrames.isEmpty else { return [] }
        // First paragraph whose bottom reaches into the range.
        var low = 0
        var high = paragraphFrames.count - 1
        var first = paragraphFrames.count
        while low <= high {
            let mid = (low + high) / 2
            if paragraphFrames[mid].maxY > range.lowerBound {
                first = mid
                high = mid - 1
            } else {
                low = mid + 1
            }
        }
        guard first < paragraphFrames.count else { return [] }
        var last = first
        while last + 1 < paragraphFrames.count,
              paragraphFrames[last + 1].minY < range.upperBound {
            last += 1
        }
        return paragraphFrames[first...last]
    }

    /// The line table index whose line contains an offset — the last line starting at or
    /// before it.
    private func lineIndex(containing offset: Int) -> Int {
        var low = 0
        var high = lines.count - 1
        var found = 0
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].start <= offset {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }

    // MARK: - Touching text

    /// Rects covering a character range, in column coordinates. One per line, so a
    /// passage that wraps is marked as the lines a reader sees.
    func rects(for range: NSRange) -> [CGRect] {
        guard range.length > 0,
              let start = location(at: range.location),
              let end = location(at: NSMaxRange(range)),
              let textRange = NSTextRange(location: start, end: end)
        else { return [] }
        layoutManager.ensureLayout(for: textRange)
        var rects: [CGRect] = []
        layoutManager.enumerateTextSegments(in: textRange, type: .highlight) { _, rect, _, _ in
            if !rect.isEmpty { rects.append(rect) }
            return true
        }
        return rects
    }

    // MARK: - Drawing

    /// Draws the part of the column inside `columnRect` into a context whose origin is
    /// that rect's top-left corner.
    ///
    /// A paragraph straddling the top edge is drawn whole and cut by the caller's clip:
    /// TextKit lays a paragraph out as one fragment, and asking for half of one would
    /// mean laying it out twice with two different results.
    func draw(_ columnRect: CGRect, in context: CGContext) {
        guard !lines.isEmpty,
              let start = location(at: offset(atY: columnRect.minY))
        else { return }
        context.saveGState()
        context.translateBy(x: 0, y: -columnRect.minY)
        _ = layoutManager.enumerateTextLayoutFragments(
            from: start, options: [.ensuresLayout]
        ) { fragment in
            fragment.draw(at: fragment.layoutFragmentFrame.origin, in: context)
            return fragment.layoutFragmentFrame.maxY < columnRect.maxY
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
