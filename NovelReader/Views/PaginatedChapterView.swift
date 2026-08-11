import SwiftUI
import UIKit

/// Which edge of a chapter a page turn ran off.
enum PageEdge {
    case start
    case end
}

/// Where a freshly opened chapter should land.
enum PageLanding: Equatable {
    case anchor(TextAnchor)
    /// The last page — the one place a `ReadingPosition` cannot name, because how many
    /// pages a chapter has depends on the type size it is being read at. Only reached
    /// by turning back past the first page of the following chapter.
    case lastPage
}

/// One chapter, one page at a time.
///
/// Deliberately dumb about books: it is handed a chapter's text and reports where the
/// reader is and when they have run off either end. Chapter changes, read-ahead and
/// persistence stay in `ReaderModel`, which the scrolling reader already drives —
/// two renderers may not mean two copies of the chapter logic.
struct PaginatedChapterView: View {
    let title: String
    let paragraphs: [String]
    /// Identity of the chapter on screen. A change here means the pages measured so
    /// far describe text that is no longer being shown.
    let chapterKey: String
    let settings: ReaderSettings
    let landing: PageLanding
    /// This chapter's stored highlights. Painted here and created here — see
    /// `ChapterPaginator.offset(at:onPage:)` for why creation cannot live in the
    /// scrolling renderer.
    let highlights: [TextHighlight]
    let onAnchorChange: (TextAnchor) -> Void
    let onTapCenter: () -> Void
    let onTurnPast: (PageEdge) -> Void
    let onHighlight: (TextSelection) -> Void
    let onRemoveHighlight: (TextHighlight) -> Void

    /// Not `@State`-observed: `ChapterPaginator` is a plain class, so the counters the
    /// page label reads are mirrored into state explicitly. Making it observable would
    /// re-render the page on every measured chunk, which is exactly the work the
    /// progressive measuring exists to keep off the screen.
    @State private var paginator: ChapterPaginator?
    @State private var renderedKey: String?
    @State private var pageIndex = 0
    @State private var pageCount = 0
    @State private var isComplete = false
    @State private var turningForward = true
    @State private var dragOffset: CGFloat = 0
    @State private var completion: Task<Void, Never>?
    /// The composed-string range the reader is picking out, held as a range rather than
    /// as anchors because it is redrawn on every movement of the finger and only has to
    /// become a storable pair once, at the moment it is committed.
    @State private var selection: NSRange?
    /// True while the finger is still down, which is what tells the difference between
    /// a selection being dragged and one waiting for an answer.
    @State private var isDragging = false
    /// The highlight a tap landed on, waiting to be removed or dismissed.
    @State private var picked: TextHighlight?

    /// Everything that changes where the page breaks fall. Bundled so one comparison
    /// covers a rotation, a font change, a spacing change and a new chapter — and so
    /// Dynamic Type is covered too: the page counter grows, the text area shrinks, and
    /// that shows up here as a size change.
    private struct LayoutKey: Equatable {
        let chapterKey: String
        let width: CGFloat
        let height: CGFloat
        let fontName: String?
        let fontSize: Double
        let lineSpacing: Double
        let paragraphSpacing: Double
    }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                page(in: geo.size)
                    .onChange(of: key(for: geo.size), initial: true) { _, _ in
                        rebuild(size: geo.size)
                    }
            }
            pageLabel
        }
        // Matches the scrolling reader's text inset, so switching modes does not move
        // the left margin of the book.
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .onDisappear { completion?.cancel() }
    }

    private func page(in size: CGSize) -> some View {
        ZStack {
            if let paginator, pageIndex < paginator.pages.count {
                ChapterPageRenderer(
                    paginator: paginator,
                    pageIndex: pageIndex,
                    highlights: highlights.flatMap { paginator.text.ranges(of: $0) },
                    selection: selection,
                    highlightColor: UIColor(settings.theme.highlight),
                    selectionColor: UIColor(settings.theme.selection),
                    onSelectionDrag: { drag in select(drag, in: paginator) }
                )
                .id(pageIndex)
                .transition(.asymmetric(
                    insertion: .move(edge: turningForward ? .trailing : .leading),
                    removal: .move(edge: turningForward ? .leading : .trailing)
                ))
            }
            if isChoosing {
                // Swallows the taps and presses the page would otherwise read as turns,
                // so "tap anywhere" puts the bar away instead of moving the book.
                Color.clear
                    .contentShape(.rect)
                    .onTapGesture { clearSelection() }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        // A small nudge under the finger rather than a page dragged to the edge:
        // the turn itself is the animation, and a page that follows the finger all
        // the way needs the neighbouring pages drawn to look like anything.
        .offset(x: dragOffset / 4)
        .contentShape(.rect)
        .accessibilityIdentifier("reader.page")
        // Masked while text is being picked out: a slide that is extending a selection
        // must not also be a page turn, and the long press that starts one is a
        // gesture on the page view underneath.
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { dragOffset = $0.translation.width }
                .onEnded { value in
                    dragOffset = 0
                    guard abs(value.translation.width) > 40 else { return }
                    turn(value.translation.width < 0 ? 1 : -1)
                },
            including: isSelectingText ? .subviews : .all
        )
        // Simultaneous, so the tap targets keep working while a drag is possible.
        // The edges turn pages and the middle shows the controls: the same tap that
        // reveals the chrome in the scrolling reader.
        .simultaneousGesture(
            SpatialTapGesture().onEnded { value in
                if let hit = highlight(at: value.location) {
                    picked = hit
                } else if value.location.x < size.width * 0.25 {
                    turn(-1)
                } else if value.location.x > size.width * 0.75 {
                    turn(1)
                } else {
                    onTapCenter()
                }
            },
            including: isSelectingText ? .subviews : .all
        )
        .overlay(alignment: .bottom) { actionBar }
        .animation(.snappy(duration: 0.18), value: isChoosing)
    }

    // MARK: - Highlights

    /// True while a bar is waiting for an answer about a passage or a tapped highlight.
    private var isChoosing: Bool {
        picked != nil || (selection != nil && !isDragging)
    }

    private var isSelectingText: Bool { isDragging || isChoosing }

    /// The one control the highlight feature has, and it only exists once there is
    /// something to act on.
    ///
    /// No permanent button in the reader's control bar: marking a passage needs to say
    /// *which* passage, so the gesture has to come first and a button that could only
    /// ever report "select something first" would be a button that never works.
    @ViewBuilder
    private var actionBar: some View {
        if let picked {
            bar("reader.highlight.remove", icon: "trash") {
                onRemoveHighlight(picked)
                clearSelection()
            }
        } else if let selection, !isDragging {
            bar("reader.highlight.add", icon: "highlighter") {
                commit(selection)
            }
        }
    }

    private func bar(
        _ title: LocalizedStringKey, icon: String, action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Button(action: action) {
                Label(title, systemImage: icon).font(.footnote.weight(.medium))
            }
            .accessibilityIdentifier("reader.highlight.action")
            Divider().frame(height: 18)
            Button("common.cancel") { clearSelection() }
                .font(.footnote)
                .tint(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar, in: .capsule)
        // Clear of the reader's own control bar, which may well be up when a passage is
        // marked: two bars stacked on each other at the bottom of the screen is the one
        // way to make a confirm button unhittable. Lands where the end-of-book notice
        // lands, and for the same reason.
        .padding(.bottom, 60)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// Turns a press-and-slide into a sentence-bounded selection.
    ///
    /// The range is not clipped to the page: a sentence that runs over the page break
    /// is still one sentence, and marking half of it because the other half is not on
    /// screen would store a highlight the reader never chose.
    private func select(_ drag: TextSelectionDrag, in paginator: ChapterPaginator) {
        switch drag.phase {
        case .cancelled:
            clearSelection()
            return
        case .active, .finished:
            isDragging = drag.phase == .active
        }
        picked = nil
        guard let from = paginator.offset(at: drag.start, onPage: pageIndex),
              let to = paginator.offset(at: drag.end, onPage: pageIndex)
        else { return }
        selection = paginator.text.sentenceRange(from: from, to: to)
    }

    private func commit(_ range: NSRange) {
        defer { clearSelection() }
        guard let made = paginator?.text.selection(for: range) else { return }
        onHighlight(made)
    }

    private func clearSelection() {
        selection = nil
        isDragging = false
        picked = nil
    }

    /// The stored highlight under a point, if any. Checked before the page-turn zones
    /// so a mark answers the tap that lands on it — the reader put it there, and a
    /// highlight that ignores being touched has no way to be undone from the page.
    private func highlight(at point: CGPoint) -> TextHighlight? {
        guard !highlights.isEmpty, let paginator,
              let offset = paginator.offset(at: point, onPage: pageIndex)
        else { return nil }
        return highlights.first { highlight in
            paginator.text.ranges(of: highlight).contains { NSLocationInRange(offset, $0) }
        }
    }

    /// The only progress indicator a page has. A scroll bar cannot exist here, so the
    /// page counter is what tells the reader how much of the chapter is left.
    ///
    /// Digits are not translated, so the pair is drawn verbatim; the accessibility
    /// label carries the sentence. The trailing `+` is honest rather than tidy: the
    /// rest of the chapter has not been measured yet, and a total invented before the
    /// text was laid out would be a guess that changes under the reader.
    private var pageLabel: some View {
        Text(verbatim: isComplete ? "\(pageIndex + 1) / \(pageCount)" : "\(pageIndex + 1) / \(pageCount)+")
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(settings.theme.foreground.opacity(0.45))
            .accessibilityIdentifier("reader.pageNumber")
            .accessibilityLabel(
                isComplete
                    ? Text("reader.page \(pageIndex + 1) \(pageCount)")
                    : Text("reader.page.partial \(pageIndex + 1) \(pageCount)")
            )
    }

    // MARK: - Paging

    private func turn(_ delta: Int) {
        guard let paginator else { return }
        // A selection belongs to the page it was drawn on; carrying it across a turn
        // would leave a bar offering to mark text that is no longer on screen.
        clearSelection()
        let target = pageIndex + delta
        guard target >= 0 else {
            onTurnPast(.start)
            return
        }
        paginator.paginate(through: target)
        pageCount = paginator.pages.count
        isComplete = paginator.isComplete
        guard target < paginator.pages.count else {
            // Past the end of a fully measured chapter is the next chapter. Past the
            // end of one still being measured is nothing at all: the page simply is
            // not known yet, and the next tap will find it.
            if paginator.isComplete { onTurnPast(.end) }
            return
        }
        turningForward = delta > 0
        withAnimation(.snappy(duration: 0.22)) { pageIndex = target }
        onAnchorChange(paginator.anchor(at: target))
    }

    // MARK: - Measuring

    private func key(for size: CGSize) -> LayoutKey {
        LayoutKey(
            chapterKey: chapterKey,
            width: size.width,
            height: size.height,
            fontName: settings.fontName,
            fontSize: settings.fontSize,
            lineSpacing: settings.lineSpacing,
            paragraphSpacing: settings.paragraphSpacing
        )
    }

    /// Re-measures the chapter and stays where the reader was.
    ///
    /// An appearance change, a rotation and a new window size all land here. The place
    /// is kept as an anchor across the rebuild rather than as a page number: page 7 of
    /// the old layout has nothing to do with page 7 of the new one.
    private func rebuild(size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        completion?.cancel()
        // Offsets into the old composed text mean nothing in the new one.
        clearSelection()
        let fresh = renderedKey != chapterKey
        let carried = fresh ? nil : paginator?.anchor(at: pageIndex)
        let next = ChapterPaginator(
            text: ChapterText(
                title: title, paragraphs: paragraphs, typography: ReaderTypography(settings: settings)
            ),
            pageSize: size
        )
        renderedKey = chapterKey
        paginator = next

        switch (carried, landing) {
        case (.some(let anchor), _), (nil, .anchor(let anchor)):
            pageIndex = next.pageIndex(for: anchor)
        case (nil, .lastPage):
            // The only case that has to measure the whole chapter before it can draw
            // anything: there is no other way to know which page is the last one.
            next.paginateAll()
            pageIndex = max(0, next.pages.count - 1)
        }
        pageCount = next.pages.count
        isComplete = next.isComplete
        onAnchorChange(next.anchor(at: pageIndex))
        measureRest(next)
    }

    /// Finishes measuring the chapter one chunk per runloop turn, so the page count
    /// fills in without the first page waiting on the last one.
    private func measureRest(_ paginator: ChapterPaginator) {
        guard !paginator.isComplete else { return }
        completion = Task { @MainActor in
            while !paginator.isComplete {
                guard !Task.isCancelled else { return }
                paginator.paginateNextChunk()
                pageCount = paginator.pages.count
                isComplete = paginator.isComplete
                await Task.yield()
            }
        }
    }
}

/// One press-and-slide over a page's text.
///
/// Points rather than character offsets: the view reports where the finger is and the
/// reader view decides what that means, so the sentence-snapping rules live next to
/// the text that defines them instead of inside a `UIView`.
struct TextSelectionDrag {
    enum Phase {
        case active
        case finished
        /// The system took the gesture away — a call, a notification, another
        /// recogniser. Distinct from `finished` because nothing was chosen, so no bar
        /// should appear asking about it.
        case cancelled
    }

    let start: CGPoint
    let end: CGPoint
    let phase: Phase
}

/// Draws one page of an already-measured chapter.
private struct ChapterPageRenderer: UIViewRepresentable {
    let paginator: ChapterPaginator
    let pageIndex: Int
    /// Composed-string ranges of the stored highlights, already mapped out of anchors.
    let highlights: [NSRange]
    let selection: NSRange?
    let highlightColor: UIColor
    let selectionColor: UIColor
    let onSelectionDrag: (TextSelectionDrag) -> Void

    func makeUIView(context: Context) -> ChapterPageView {
        let view = ChapterPageView()
        update(view)
        return view
    }

    func updateUIView(_ view: ChapterPageView, context: Context) {
        update(view)
    }

    private func update(_ view: ChapterPageView) {
        view.onSelectionDrag = onSelectionDrag
        view.show(
            page: pageIndex,
            from: paginator,
            highlights: highlights,
            selection: selection,
            highlightColor: highlightColor,
            selectionColor: selectionColor
        )
    }
}

/// A plain `UIView` rather than a `UITextView`.
///
/// A text view would bring a scroll view, a selection system and its own idea of how
/// tall the text is — all three of which fight a paginated layout. Drawing the layout
/// fragments directly is what TextKit 2 is for, and it keeps the page a single
/// composited layer.
final class ChapterPageView: UIView {
    private var paginator: ChapterPaginator?
    private var pageIndex = 0
    private var highlights: [NSRange] = []
    private var selection: NSRange?
    private var highlightColor: UIColor = .clear
    private var selectionColor: UIColor = .clear
    /// Where the press that is being tracked started. Held here because
    /// `UILongPressGestureRecognizer` reports only the current point.
    private var pressOrigin = CGPoint.zero

    var onSelectionDrag: ((TextSelectionDrag) -> Void)?

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        // Dynamic colours resolve when they are drawn, so a light/dark switch has to
        // repaint. `traitCollectionDidChange` is deprecated on iOS 17.
        _ = registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ChapterPageView, _) in
            view.setNeedsDisplay()
        }
        // A UIKit recogniser rather than a SwiftUI long press: this one reports the
        // location it began at, which is the anchor of the whole selection. A SwiftUI
        // `LongPressGesture` reports no location at all, and the sequenced-drag
        // workaround only gets one once the finger has moved — so a press that marks a
        // sentence without moving would select nothing.
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePress))
        // Long enough that a page-turn tap never trips it, short enough that marking a
        // sentence feels like a decision rather than a wait.
        press.minimumPressDuration = 0.4
        addGestureRecognizer(press)
    }

    /// Never loaded from a nib: the reader builds this view in code.
    required init?(coder: NSCoder) { nil }

    func show(
        page: Int,
        from paginator: ChapterPaginator,
        highlights: [NSRange],
        selection: NSRange?,
        highlightColor: UIColor,
        selectionColor: UIColor
    ) {
        self.paginator = paginator
        self.highlights = highlights
        self.selection = selection
        self.highlightColor = highlightColor
        self.selectionColor = selectionColor
        pageIndex = page
        setNeedsDisplay()
    }

    @objc private func handlePress(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            pressOrigin = point
            onSelectionDrag?(TextSelectionDrag(start: point, end: point, phase: .active))
        case .changed:
            onSelectionDrag?(TextSelectionDrag(start: pressOrigin, end: point, phase: .active))
        case .ended:
            onSelectionDrag?(TextSelectionDrag(start: pressOrigin, end: point, phase: .finished))
        case .cancelled, .failed:
            onSelectionDrag?(
                TextSelectionDrag(start: pressOrigin, end: point, phase: .cancelled)
            )
        default:
            break
        }
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let paginator else { return }
        // Behind the glyphs, in that order: a band painted over the text would wash out
        // the words it is there to point at.
        fill(highlights, with: highlightColor, from: paginator)
        fill(selection.map { [$0] } ?? [], with: selectionColor, from: paginator)
        paginator.draw(page: pageIndex, in: context, clippedTo: bounds)
    }

    /// Fills the bands behind a set of ranges. Draws through `UIBezierPath`, which
    /// paints into the context `draw(_:)` is already running in — the same context the
    /// text goes into, so the two cannot end up in different layers.
    private func fill(_ ranges: [NSRange], with color: UIColor, from paginator: ChapterPaginator) {
        guard !ranges.isEmpty else { return }
        color.setFill()
        for range in ranges {
            for rect in paginator.rects(for: range, onPage: pageIndex) {
                // Rounded and inset a hair: the segment rects include line spacing, so
                // squared-off bands on consecutive lines read as one solid block rather
                // than as a stroke over the text.
                let path = UIBezierPath(
                    roundedRect: rect.insetBy(dx: 0, dy: 0.5), cornerRadius: 3
                )
                path.fill()
            }
        }
    }
}
