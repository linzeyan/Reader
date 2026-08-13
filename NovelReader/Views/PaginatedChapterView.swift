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

/// Which way a page turn goes.
///
/// Distinct from `PageEdge`, which names a turn that ran *off* the chapter: this one
/// always lands on another page of the same chapter.
enum PageTurn: Equatable {
    case backward
    case forward
}

/// When a selection dragged against the top or bottom of a page turns it.
///
/// A value of its own, and pure: the caller keeps the clock and passes in how long the
/// finger has rested in an edge strip, so the rule that decides when the book moves
/// under a reader's finger can be exercised without a page, a gesture or a simulator.
struct SelectionEdgeRule {
    /// Depth of the strip along the top and bottom of the page.
    ///
    /// Top and bottom rather than the sides, even though pages turn sideways: a strip
    /// down the right-hand edge is the end of every line on the page, so a finger
    /// resting in it would mean "the next page" while it almost always means "the end of
    /// this line". Text carries on below the bottom of the page, which is where a finger
    /// extending a selection ends up anyway. Deep enough to rest a thumb in, shallow
    /// enough that the last line of the page is still somewhere a selection can stop.
    let stripHeight: CGFloat
    /// How long the finger has to rest in the strip before the page moves.
    ///
    /// The same wait as the press that starts a selection, and for the same reason:
    /// holding still is how this page is told "I mean this". Turning on contact instead
    /// would make one quick slide down the page into three page turns, which loses the
    /// reader their place and the passage they were picking out with it.
    let dwell: TimeInterval

    init(stripHeight: CGFloat = 40, dwell: TimeInterval = 0.4) {
        self.stripHeight = stripHeight
        self.dwell = dwell
    }

    /// The strip a point falls in, or nil for the body of the page.
    ///
    /// Points beyond the page count as being in the strip they left through: a finger
    /// dragged clean off the bottom has not stopped asking for the text that follows.
    func strip(at point: CGPoint, in size: CGSize) -> PageTurn? {
        // Two strips and no text between them would turn the page under every press.
        guard size.height > stripHeight * 2 else { return nil }
        if point.y >= size.height - stripHeight { return .forward }
        if point.y <= stripHeight { return .backward }
        return nil
    }

    /// The strip a finger has just arrived in, having come from the body of the page.
    ///
    /// What arms a turn, rather than merely being in the strip. Holding still is what a
    /// press *is*, so position alone would turn the page under a reader pressing on the
    /// last line of it — which is a reader marking that line, not asking for the next
    /// page. Arriving somewhere is something only a drag can do.
    func arrival(at point: CGPoint, from previous: CGPoint?, in size: CGSize) -> PageTurn? {
        guard let arrived = strip(at: point, in: size),
              let previous, strip(at: previous, in: size) == nil
        else { return nil }
        return arrived
    }

    /// The turn a resting finger has earned, or nil to stay on this page.
    ///
    /// Stops at both ends of the chapter rather than turning past them. Carrying a
    /// selection into the next chapter would need a highlight whose two anchors named
    /// different chapters, which is not a thing this app can store.
    func turn(
        at point: CGPoint,
        in size: CGSize,
        heldFor elapsed: TimeInterval,
        page: Int,
        of pageCount: Int
    ) -> PageTurn? {
        guard elapsed >= dwell, let strip = strip(at: point, in: size) else { return nil }
        switch strip {
        case .backward: return page > 0 ? .backward : nil
        case .forward: return page + 1 < pageCount ? .forward : nil
        }
    }
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
    /// This chapter's stored highlights. Painted here, and created here to sentence
    /// precision — see `ChapterPaginator.offset(at:onPage:)` for why the scrolling
    /// renderer can only mark a paragraph whole.
    let highlights: [TextHighlight]
    let onAnchorChange: (TextAnchor) -> Void
    let onTapCenter: () -> Void
    let onTurnPast: (PageEdge) -> Void
    let onHighlight: (TextSelection) -> Void
    let onRemoveHighlight: (TextHighlight) -> Void

    /// Not `@State`-observed: `ChapterPaginator` is a plain class, so measuring further
    /// into the chapter does not redraw anything. That is the point — the page in front
    /// of the reader is measured before it is shown, and nothing on screen depends on
    /// how much of the tail has been laid out.
    @State private var paginator: ChapterPaginator?
    @State private var renderedKey: String?
    @State private var pageIndex = 0
    @State private var turningForward = true
    /// Identity of the page view, bumped by the turns that should slide.
    ///
    /// A fresh identity is what plays the transition — and also what tears the UIKit view
    /// down, which cancels the press holding a selection open. So a page turned *by* a
    /// selection reaching the edge moves `pageIndex` and leaves this alone: the same view
    /// redraws the new page, the finger keeps its gesture, and the text does not slide
    /// out from under a reader who is aiming at it.
    @State private var pageTransition = 0
    @State private var dragOffset: CGFloat = 0
    /// The composed-string range the reader is picking out, held as a range rather than
    /// as anchors because it is redrawn on every movement of the finger and only has to
    /// become a storable pair once, at the moment it is committed.
    @State private var selection: NSRange?
    /// The end of the selection the finger is *not* holding, as an offset into the
    /// composed chapter.
    ///
    /// Kept rather than re-derived from the point the press began at: once a page has
    /// turned under the finger, that point on screen names a different character. Only
    /// the far end of a selection follows the finger.
    @State private var selectionAnchor: Int?
    /// Where the finger last was, in the page's own coordinates. Re-read while the finger
    /// is still, because standing still is what turns the page here and a gesture
    /// recogniser says nothing at all until the touch moves.
    @State private var dragPoint: CGPoint?
    /// The strip the finger is resting in and when it got there — the whole of the
    /// auto-turn's memory.
    @State private var edgeHold: EdgeHold?
    /// True while the finger is still down, which is what tells the difference between
    /// a selection being dragged and one waiting for an answer.
    @State private var isDragging = false
    /// The highlight a tap landed on, waiting to be removed or dismissed.
    @State private var picked: TextHighlight?

    /// A finger resting against the top or bottom of the page while extending a
    /// selection.
    private struct EdgeHold {
        let turn: PageTurn
        let since: Date
    }

    private static let edgeRule = SelectionEdgeRule()

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
                .id(pageTransition)
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
        // A finger held against an edge is reported once and then never again: a long
        // press recogniser only speaks when the touch moves, and standing still is
        // precisely the gesture that has to turn the page. So while a selection is being
        // dragged the last known point is fed back through the same path a real report
        // takes, which is what lets the dwell elapse without the reader wiggling a thumb.
        .task(id: isDragging) {
            guard isDragging else { return }
            while !Task.isCancelled {
                // Twenty a second: fine enough that the dwell reads as a hold rather than
                // as a lag, coarse enough to cost less than one moving finger already does.
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                guard let paginator, let dragPoint else { return }
                select(TextSelectionDrag(point: dragPoint, phase: .active), in: paginator)
            }
        }
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
    ///
    /// Called again on a timer while the finger rests (see the dwell in `page(in:)`), so
    /// nothing here writes state it is not changing: a page redrawn twenty times a second
    /// to produce identical pixels would be the standing cost of holding still.
    private func select(_ drag: TextSelectionDrag, in paginator: ChapterPaginator) {
        var page = pageIndex
        switch drag.phase {
        case .cancelled:
            clearSelection()
            return
        case .active:
            if !isDragging { isDragging = true }
            // Before `dragPoint` moves on: a turn is armed by the finger *arriving* at the
            // edge, which can only be told from where it was a moment ago.
            page = turnPastEdge(to: drag.point, from: dragPoint, in: paginator)
            if dragPoint != drag.point { dragPoint = drag.point }
        case .finished:
            isDragging = false
            dragPoint = nil
            edgeHold = nil
        }
        if picked != nil { picked = nil }
        guard let to = paginator.offset(at: drag.point, onPage: page) else { return }
        // The anchor is whatever the first report of this press landed on, and it stays
        // put for the rest of the press however many pages the finger travels.
        let from = selectionAnchor ?? to
        if selectionAnchor == nil { selectionAnchor = from }
        let range = paginator.text.sentenceRange(from: from, to: to)
        if selection != range { selection = range }
    }

    /// The page under the finger, turned first if the finger has rested against an edge
    /// long enough to have asked for one.
    ///
    /// Not `turn(_:)`: that clears the selection, which is right for a tap or a swipe and
    /// exactly wrong here. Nothing is animated either — the slide is what a page does
    /// because the reader swiped it, and playing it under a stationary finger both
    /// contradicts the gesture and pulls the text they are aiming at out from under them.
    ///
    /// Returns the page rather than leaving the caller to re-read `pageIndex`, which is
    /// `@State` and does not report back the value just written to it.
    private func turnPastEdge(
        to point: CGPoint, from previous: CGPoint?, in paginator: ChapterPaginator
    ) -> Int {
        guard let strip = Self.edgeRule.strip(at: point, in: paginator.pageSize) else {
            // Leaving the strip ends the run: a reader who drags back into the text has
            // stopped asking for pages, and a chapter that kept turning would arrive at
            // its end under a finger that had gone still somewhere in the middle.
            if edgeHold != nil { edgeHold = nil }
            return pageIndex
        }
        let now = Date.now
        guard let hold = edgeHold, hold.turn == strip else {
            if let arrived = Self.edgeRule.arrival(
                at: point, from: previous, in: paginator.pageSize
            ) {
                edgeHold = EdgeHold(turn: arrived, since: now)
            }
            return pageIndex
        }
        // Measured one page ahead so that the frontier of a chapter still being laid out
        // is not mistaken for its last page. A no-op once the frontier is past the finger.
        paginator.paginate(through: pageIndex + 1)
        guard let turn = Self.edgeRule.turn(
            at: point,
            in: paginator.pageSize,
            heldFor: now.timeIntervalSince(hold.since),
            page: pageIndex,
            of: paginator.pages.count
        ) else { return pageIndex }
        // Restarted rather than left running: the next page is another dwell away, so a
        // finger that stays put turns pages at a rate the reader can still read.
        edgeHold = EdgeHold(turn: turn, since: now)
        let page = turn == .forward ? pageIndex + 1 : pageIndex - 1
        pageIndex = page
        onAnchorChange(paginator.anchor(at: page))
        return page
    }

    private func commit(_ range: NSRange) {
        defer { clearSelection() }
        guard let made = paginator?.text.selection(for: range) else { return }
        onHighlight(made)
    }

    private func clearSelection() {
        selection = nil
        selectionAnchor = nil
        dragPoint = nil
        edgeHold = nil
        isDragging = false
        picked = nil
    }

    /// The stored highlight under a point, if any. Checked before the page-turn zones
    /// so a mark answers the tap that lands on it — the reader put it there, and a
    /// highlight that ignores being touched has no way to be undone from the page.
    ///
    /// Hit against the bands the mark is *drawn* in rather than against the character
    /// under the finger. Those two disagree exactly where a reader cannot tell them
    /// apart: in the gap between two paragraphs, and past the end of a short line, a point
    /// has no character of its own, so the offset it resolves to is the start or the end of
    /// a neighbouring line — one side of the mark's first character or the other. Asking
    /// "did this land on the ink" is both the reader's own question and a stable answer.
    /// The bands are grown by half the space between lines, so the leading counts as part
    /// of the line it sits under: ink is painted behind glyphs only, and a reader aiming at
    /// a marked line lands as often in the air above it as on it. Half, so two marked lines
    /// meet in the middle and a long passage answers everywhere inside it, while the line
    /// above an unmarked one still belongs to nobody.
    private func highlight(at point: CGPoint) -> TextHighlight? {
        guard !highlights.isEmpty, let paginator else { return nil }
        let slack = (settings.lineSpacing + settings.paragraphSpacing) / 2
        return highlights.first { highlight in
            paginator.text.ranges(of: highlight).contains { range in
                paginator.rects(for: range, onPage: pageIndex).contains {
                    $0.insetBy(dx: 0, dy: -slack).contains(point)
                }
            }
        }
    }

    /// The only progress indicator a page has: a scroll bar cannot exist here, and this
    /// is what tells the reader how much of the chapter is left.
    ///
    /// A share of the chapter's text rather than "page 7 of 42". A page total is a
    /// property of the current type size, line spacing and window, not of the book, so
    /// the same chapter would be 42 pages to one reader and 90 to another and would
    /// renumber itself under anyone who nudged the size slider. It also cannot be stated
    /// at all until the whole chapter has been laid out, which is why it used to be
    /// shown as a lower bound that crept upwards while the reader watched. A share of
    /// the text is exact on the first page and means the same thing at every size.
    ///
    /// Formatted by the locale and drawn verbatim, with the accessibility label
    /// carrying the sentence around it.
    private var pageLabel: some View {
        let figure = fractionRead.formatted(.percent.precision(.fractionLength(0)))
        return Text(verbatim: figure)
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(settings.theme.foreground.opacity(0.45))
            .accessibilityIdentifier("reader.pageNumber")
            .accessibilityLabel(Text("reader.progress \(figure)"))
    }

    /// How far the end of the current page is through the chapter.
    ///
    /// Measured to the end of the page rather than its start, so the last page reads as
    /// the whole chapter instead of stopping short of it. Rounded down, because "100%"
    /// with text still to come would be the one number the reader could catch out.
    private var fractionRead: Double {
        guard let paginator, paginator.pages.indices.contains(pageIndex) else { return 0 }
        let total = paginator.text.attributed.length
        guard total > 0 else { return 0 }
        let read = Double(NSMaxRange(paginator.pages[pageIndex].range)) / Double(total)
        return min(1, (read * 100).rounded(.down) / 100)
    }

    // MARK: - Paging

    private func turn(_ delta: Int) {
        guard let paginator else { return }
        // A tap or a swipe that turns the page is the reader leaving the passage behind,
        // and the bar would be left offering to mark text that is no longer on screen. A
        // turn the selection itself asked for is the opposite intent and goes through
        // `turnPastEdge`, which keeps it.
        clearSelection()
        let target = pageIndex + delta
        guard target >= 0 else {
            onTurnPast(.start)
            return
        }
        paginator.paginate(through: target)
        guard target < paginator.pages.count else {
            // Past the end of a fully measured chapter is the next chapter. Past the
            // end of one still being measured is nothing at all: the page simply is
            // not known yet, and the next tap will find it.
            if paginator.isComplete { onTurnPast(.end) }
            return
        }
        turningForward = delta > 0
        withAnimation(.snappy(duration: 0.22)) {
            // The new identity is what plays the slide; see `pageTransition`.
            pageTransition += 1
            pageIndex = target
        }
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
        onAnchorChange(next.anchor(at: pageIndex))
    }
}

/// One press-and-slide over a page's text.
///
/// A point rather than character offsets: the view reports where the finger is and the
/// reader view decides what that means, so the sentence-snapping rules live next to
/// the text that defines them instead of inside a `UIView`.
///
/// The current point only, not the pair. The far end of a selection is the finger; the
/// near end is an offset the reader view remembers, because the page under the finger can
/// change mid-press and the point the press began at would then name another character.
struct TextSelectionDrag {
    enum Phase {
        case active
        case finished
        /// The system took the gesture away — a call, a notification, another
        /// recogniser. Distinct from `finished` because nothing was chosen, so no bar
        /// should appear asking about it.
        case cancelled
    }

    let point: CGPoint
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
        case .began, .changed:
            onSelectionDrag?(TextSelectionDrag(point: point, phase: .active))
        case .ended:
            onSelectionDrag?(TextSelectionDrag(point: point, phase: .finished))
        case .cancelled, .failed:
            onSelectionDrag?(TextSelectionDrag(point: point, phase: .cancelled))
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
