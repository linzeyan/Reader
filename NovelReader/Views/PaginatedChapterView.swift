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
    let onAnchorChange: (TextAnchor) -> Void
    let onTapCenter: () -> Void
    let onTurnPast: (PageEdge) -> Void

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
                ChapterPageRenderer(paginator: paginator, pageIndex: pageIndex)
                    .id(pageIndex)
                    .transition(.asymmetric(
                        insertion: .move(edge: turningForward ? .trailing : .leading),
                        removal: .move(edge: turningForward ? .leading : .trailing)
                    ))
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
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { dragOffset = $0.translation.width }
                .onEnded { value in
                    dragOffset = 0
                    guard abs(value.translation.width) > 40 else { return }
                    turn(value.translation.width < 0 ? 1 : -1)
                }
        )
        // Simultaneous, so the tap targets keep working while a drag is possible.
        // The edges turn pages and the middle shows the controls: the same tap that
        // reveals the chrome in the scrolling reader.
        .simultaneousGesture(
            SpatialTapGesture().onEnded { value in
                if value.location.x < size.width * 0.25 {
                    turn(-1)
                } else if value.location.x > size.width * 0.75 {
                    turn(1)
                } else {
                    onTapCenter()
                }
            }
        )
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

/// Draws one page of an already-measured chapter.
private struct ChapterPageRenderer: UIViewRepresentable {
    let paginator: ChapterPaginator
    let pageIndex: Int

    func makeUIView(context: Context) -> ChapterPageView {
        let view = ChapterPageView()
        view.show(page: pageIndex, from: paginator)
        return view
    }

    func updateUIView(_ view: ChapterPageView, context: Context) {
        view.show(page: pageIndex, from: paginator)
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
    }

    /// Never loaded from a nib: the reader builds this view in code.
    required init?(coder: NSCoder) { nil }

    func show(page: Int, from paginator: ChapterPaginator) {
        self.paginator = paginator
        pageIndex = page
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        paginator?.draw(page: pageIndex, in: context, clippedTo: bounds)
    }
}
