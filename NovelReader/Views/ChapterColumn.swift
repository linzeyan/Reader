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

    /// One laid-out paragraph, held rather than asked for again.
    ///
    /// `NSTextLayoutManager` lays out to a *viewport* and does not promise to keep what
    /// it has already done — on a real phone it frees fragments nobody is looking at,
    /// while a simulator with memory to spare keeps everything and looks perfect. Asking
    /// it per drawn frame therefore made the reader on a device paint one line at a time
    /// and then nothing at all: a fragment whose layout had been freed answers
    /// `layoutFragmentFrame` with a zero rect, which drew every remaining paragraph of
    /// the chapter on top of each other, above the window, once per frame.
    ///
    /// Holding the fragment holds its line fragments, and the frame is recorded from the
    /// one pass that laid the whole chapter out in order. Drawing is then drawing.
    private struct PlacedFragment {
        let fragment: NSTextLayoutFragment
        /// The fragment's own lines, held separately because `textLineFragments` is
        /// emptied when the layout manager drops its work — holding the fragment is not
        /// enough to hold what it was made of.
        let lineFragments: [NSTextLineFragment]
        let origin: CGPoint
        let maxY: CGFloat
        /// The paragraph's span in the composed chapter, so a mark stated in the
        /// chapter's own offsets can be resolved without asking the layout manager
        /// where anything is.
        let start: Int
        let end: Int
    }

    private var fragments: [PlacedFragment] = []

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
        guard width > 0, fragments.isEmpty else { return }
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
        // Recorded here, in the one pass that walks the chapter in order, because this
        // is the only moment the frame is answered by layout that has just happened.
        fragments.append(PlacedFragment(
            fragment: fragment, lineFragments: fragment.textLineFragments,
            origin: frame.origin, maxY: frame.maxY,
            start: fragmentStart, end: fragmentEnd
        ))
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
    ///
    /// Built from the held fragments rather than from `enumerateTextSegments`, for the
    /// same reason drawing is — see `PlacedFragment`. Measured: after the layout manager
    /// drops its work, the segment enumeration puts a paragraph's bands 1600 points from
    /// where the text it marks is actually drawn.
    func rects(for range: NSRange) -> [CGRect] {
        guard range.length > 0 else { return [] }
        let lower = range.location
        let upper = NSMaxRange(range)
        var rects: [CGRect] = []
        for placed in fragments where placed.end > lower && placed.start < upper {
            for line in placed.lineFragments {
                // The line's span in the chapter's offsets. A line fragment's own
                // `characterRange` counts from the start of its paragraph, which is what
                // `locationForCharacter(at:)` indexes as well.
                let lineStart = placed.start + line.characterRange.location
                let lineEnd = placed.start + NSMaxRange(line.characterRange)
                let from = max(lineStart, lower)
                let to = min(lineEnd, upper)
                guard to > from else { continue }
                let bounds = line.typographicBounds
                // The ends of the line are taken from its own bounds rather than asked
                // for by character: the index one past a line is the paragraph's length
                // on its last line, which is not a character anyone can be asked about.
                let x1 = from <= lineStart
                    ? bounds.minX
                    : bounds.minX + line.locationForCharacter(at: from - placed.start).x
                let x2 = to >= lineEnd
                    ? bounds.maxX
                    : bounds.minX + line.locationForCharacter(at: to - placed.start).x
                let rect = CGRect(
                    x: min(x1, x2), y: bounds.minY,
                    width: abs(x2 - x1), height: bounds.height
                ).offsetBy(dx: placed.origin.x, dy: placed.origin.y)
                if !rect.isEmpty { rects.append(rect) }
            }
        }
        return rects
    }

    // MARK: - Drawing

    /// Draws the part of the column inside `columnRect`, **in column coordinates**.
    ///
    /// The caller places the column: the context has to already be positioned so that
    /// this column's y zero is where the caller wants it. `columnRect` says which part
    /// to draw and nothing about where to put it. Translating here as well as there is
    /// what made the reader on a device correct at the top of a chapter and emptier the
    /// further in they got — the same offset applied twice pushes the text a whole
    /// window off the screen once the reader is one window into the chapter, and the
    /// simulator never showed it because a demo chapter is barely taller than one.
    ///
    /// A paragraph straddling the top edge is drawn whole and cut by the caller's clip:
    /// TextKit lays a paragraph out as one fragment, and asking for half of one would
    /// mean laying it out twice with two different results.
    ///
    /// Every position here comes from `fragments`, never from the layout manager — see
    /// `PlacedFragment` for what asking it again per frame cost.
    ///
    /// Line by line rather than `NSTextLayoutFragment.draw(at:in:)`, for the same
    /// reason: a fragment whose lines the layout manager has taken back rebuilds them to
    /// be drawn, which is a paragraph laid out per visible paragraph per frame. A held
    /// line fragment draws itself and asks nobody anything.
    func draw(_ columnRect: CGRect, in context: CGContext) {
        let list = drawList(in: columnRect.minY..<columnRect.maxY)
        #if DEBUG
        ColumnProbe.drew(
            window: columnRect, drawn: list.count, of: fragments.count,
            firstY: list.first?.origin.y, lastY: list.last?.maxY, height: height
        )
        #endif
        for placed in list {
            for line in placed.lineFragments {
                let bounds = line.typographicBounds
                line.draw(
                    at: CGPoint(
                        x: placed.origin.x + bounds.minX, y: placed.origin.y + bounds.minY
                    ),
                    in: context
                )
            }
        }
    }

    /// The fragments with any part inside a vertical range, in reading order.
    private func drawList(in range: Range<CGFloat>) -> ArraySlice<PlacedFragment> {
        guard !fragments.isEmpty else { return [] }
        var low = 0
        var high = fragments.count - 1
        var first = fragments.count
        while low <= high {
            let mid = (low + high) / 2
            if fragments[mid].maxY > range.lowerBound {
                first = mid
                high = mid - 1
            } else {
                low = mid + 1
            }
        }
        guard first < fragments.count else { return [] }
        var last = first
        while last + 1 < fragments.count, fragments[last + 1].origin.y < range.upperBound {
            last += 1
        }
        return fragments[first...last]
    }

    /// Throws away everything the layout manager has computed, the way a device short of
    /// memory does on its own. Nothing this type promises may notice — see
    /// `PlacedFragment`, which exists because drawing used to.
    func discardLayoutManagerWork() {
        layoutManager.invalidateLayout(for: contentStorage.documentRange)
    }

    #if DEBUG
    /// What the one layout pass actually produced. A chapter is laid out once, so this
    /// is a handful of lines a session — see `ColumnProbe`.
    var layoutReport: String {
        String(
            format: "chars=%d width=%.0f height=%.0f fragments=%d(noLines=%d) "
                + "lines=%d paragraphs=%d lastMaxY=%.0f",
            text.attributed.length, width, height, fragments.count,
            fragments.filter(\.lineFragments.isEmpty).count,
            lines.count, paragraphFrames.count, fragments.last?.maxY ?? -1
        )
    }
    #endif

    // MARK: - Offsets

    private func offset(of location: NSTextLocation) -> Int {
        contentStorage.offset(from: contentStorage.documentRange.location, to: location)
    }
}
