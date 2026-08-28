import UIKit

/// The scroll view the reading column lives in.
///
/// A plain `UIScrollView` with a canvas exactly one screen tall riding on top of it.
/// The content is tens of thousands of points; a view that size is past what a single
/// `CALayer` backing store will take, so the canvas is moved and redrawn instead of
/// being grown. Redrawing it costs a draw of already-laid-out glyphs, which is the
/// whole point of the surgery — the renderer this replaces was laying text out as it
/// scrolled, at 58ms per tapped turn.
final class ReaderTextScrollView: UIScrollView {
    weak var coordinator: ReaderScrollCoordinator? {
        didSet { canvas.coordinator = coordinator }
    }

    /// The reader's own margin, matching what the paginated renderer insets by, so
    /// switching modes does not move the left edge of the book.
    static let textMargin: CGFloat = 20

    private let canvas = ReaderTextCanvas()
    private let footer = ReaderTextFooter()
    private var lastOffset: CGFloat = 0
    private var lastWidth: CGFloat = 0

    /// Whether the last movement carried the reader towards the front of the book.
    private(set) var isMovingUp = false

    /// The measure text is laid out in.
    var textWidth: CGFloat { max(0, bounds.width - Self.textMargin * 2) }

    /// Where the top of the window sits in the content. The reading position, exactly,
    /// with no container to ask and nothing to correct for.
    var readingOffset: CGFloat { contentOffset.y }

    var visibleHeight: CGFloat { bounds.height }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        // The reader hides every bar, so there is nothing for the system to inset
        // against and an automatic inset would silently move the text.
        contentInsetAdjustmentBehavior = .never
        showsVerticalScrollIndicator = true
        delegate = self
        addSubview(canvas)
        addSubview(footer)
        canvas.coordinator = coordinator

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        // Nothing else here claims a single tap, but the recogniser must not swallow
        // the touches the scroll view pans with.
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)

        let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePress))
        // Long enough that a page-turn tap never trips it, short enough that marking a
        // paragraph feels like a decision rather than a wait — the same 0.4s the
        // paginated renderer uses.
        press.minimumPressDuration = 0.4
        press.cancelsTouchesInView = false
        // Alongside the pan rather than instead of it. A recogniser that wins outright
        // takes the touch away from the scroll view for the rest of that gesture, so a
        // reader whose thumb rests half a second before they drag gets a page that will
        // not move at all. The question a press raises is withdrawn the moment a drag
        // actually begins — see `scrollViewWillBeginDragging`.
        press.delegate = self
        addGestureRecognizer(press)
    }

    /// Never loaded from a nib.
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        positionCanvas()
        // A new measure means every column describes a width nobody is reading at.
        // Reported from here because SwiftUI has no reason to call `updateUIView`
        // again once the layout pass that resized this view has run.
        guard bounds.width != lastWidth else { return }
        lastWidth = bounds.width
        coordinator?.viewResized()
    }

    /// Puts the canvas over the visible slice and lines the footer up under the text.
    private func positionCanvas() {
        canvas.frame = CGRect(
            x: Self.textMargin, y: contentOffset.y,
            width: textWidth, height: bounds.height
        )
        canvas.columnOrigin = contentOffset.y
        footer.frame = CGRect(
            x: Self.textMargin, y: coordinator?.contentHeight ?? 0,
            width: textWidth, height: ReaderTextFooter.height
        )
    }

    func refreshContentSize() {
        let height = (coordinator?.contentHeight ?? 0) + ReaderTextFooter.height
        guard contentSize.height != height || contentSize.width != bounds.width else { return }
        contentSize = CGSize(width: bounds.width, height: height)
        positionCanvas()
        #if DEBUG
        ColumnProbe.viewport(
            bounds: bounds, offset: contentOffset.y,
            contentHeight: contentSize.height, canvas: canvas.frame
        )
        #endif
    }

    func redraw() {
        positionCanvas()
        canvas.setNeedsDisplay()
        canvas.invalidateAccessibility()
    }

    /// Moves content and offset together, so the reader stays on the same sentence.
    ///
    /// What a chapter arriving above the reader costs here: one addition. The renderer
    /// this replaces had to aim a `scrollTo` at a row, measure how far it landed out,
    /// and re-state itself up to twice — because a lazy container would not say how
    /// tall the rows it had just built were.
    func shift(by amount: CGFloat) {
        guard amount != 0 else { return }
        setContentOffset(CGPoint(x: 0, y: contentOffset.y + amount), animated: false)
        lastOffset = contentOffset.y
    }

    func setReadingOffset(_ y: CGFloat, animated: Bool) {
        let maximum = max(0, contentSize.height - bounds.height)
        setContentOffset(CGPoint(x: 0, y: min(max(y, 0), maximum)), animated: animated)
    }

    func apply(theme: ReaderSettings.Theme) {
        footer.apply(theme: theme)
        // Opaque, and painted the reader's own background: a full-screen transparent
        // layer redrawn on every scrolled frame is a full-screen blend on every scrolled
        // frame, for a surface with nothing behind it but the same colour.
        let background = UIColor(theme.background)
        guard canvas.backgroundColor != background else { return }
        canvas.backgroundColor = background
        canvas.setNeedsDisplay()
    }

    func showFooter(_ state: ReaderTextFooter.State) {
        footer.show(state)
    }

    /// A point in the content, as the reader sees it on the glass. A `UIScrollView`'s
    /// own coordinate space *is* the content — its bounds origin is the scroll offset —
    /// so a tap reported in it would name where the finger landed in the book rather
    /// than on the screen, and every tap zone would be measured against the wrong end.
    private func onScreen(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: point.y - contentOffset.y)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        coordinator?.handleTap(at: onScreen(gesture.location(in: self)))
    }

    @objc private func handlePress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        coordinator?.handleLongPress(at: onScreen(gesture.location(in: self)))
    }
}

extension ReaderTextScrollView: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Half a point of slack, so a settled screen's sub-pixel jitter does not read
        // as travel — the same guard the old viewport report used.
        if abs(contentOffset.y - lastOffset) > 0.5 {
            isMovingUp = contentOffset.y < lastOffset
            lastOffset = contentOffset.y
        }
        positionCanvas()
        canvas.setNeedsDisplay()
        canvas.invalidateAccessibility()
        coordinator?.scrolled()
    }

    // Whether a finger is on the glass, which decides when a chapter may be put in
    // above the reader — see `ReaderModel.showPreviousChapter` — and, on the way down,
    // the moment a press that has become a drag stops being a question. A `UIScrollView`
    // knows this outright; the renderer this replaces needed a simultaneous
    // `DragGesture` watching every touch to find it out.
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        coordinator?.handleTouch(down: true)
    }

    /// Still "touching" while the flick coasts: a deceleration carries an absolute
    /// destination computed before any insert, so content put in under one is undone
    /// exactly the way a running pan undoes it.
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate: Bool) {
        if !willDecelerate { coordinator?.handleTouch(down: false) }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        coordinator?.handleTouch(down: false)
    }
}

extension ReaderTextScrollView: UIGestureRecognizerDelegate {
    /// The long press runs alongside the scroll, and nothing else does.
    ///
    /// Narrow on purpose: this is not "let everything through", it is the one pairing
    /// where losing the touch to the winner would cost the reader the gesture they
    /// actually made — see where the press is set up.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        other === panGestureRecognizer
    }
}

/// Draws the visible slice of the column stack.
///
/// Holds no text of its own: it asks the coordinator to draw whatever falls inside the
/// window it currently covers.
final class ReaderTextCanvas: UIView {
    weak var coordinator: ReaderScrollCoordinator?
    /// Where this canvas sits in content coordinates.
    var columnOrigin: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .redraw
        // Dynamic colours resolve when they are drawn, so a light/dark switch has to
        // repaint. Same reason `ChapterPageView` registers for it.
        _ = registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ReaderTextCanvas, _) in
            view.setNeedsDisplay()
        }
        isAccessibilityElement = false
        accessibilityIdentifier = "reader.text"
    }

    required init?(coder: NSCoder) { nil }

    /// The paragraphs on screen, built when something asks and then held.
    ///
    /// Built lazily because nothing asks unless an accessibility client is attached, and
    /// allocating an element per visible paragraph per scrolled frame for the readers
    /// who have none would be the per-frame tax this renderer exists to remove. *Held*
    /// because UIKit expects the array to survive the call: a getter that hands back a
    /// freshly built set every time gives the accessibility snapshot elements that are
    /// released out from under it.
    private var elements: [UIAccessibilityElement]?

    override var accessibilityElements: [Any]? {
        get {
            if let elements { return elements }
            let built = coordinator?.accessibilityElements(for: self) ?? []
            elements = built
            return built
        }
        set { _ = newValue }
    }

    /// The window has moved or the text has changed, so the elements describe a screen
    /// nobody is looking at.
    func invalidateAccessibility() { elements = nil }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let coordinator else { return }
        #if DEBUG
        // The dirty rect UIKit asked for, against the bounds this draws all of. A
        // partial invalidation would leave the rest of the canvas holding whatever it
        // held when it was somewhere else — see `ColumnProbe`.
        if rect != bounds {
            NSLog(
                "[DEBUG-col] partial dirty rect=%.0f..%.0f of bounds h=%.0f",
                rect.minY, rect.maxY, bounds.height
            )
        }
        #endif
        coordinator.draw(
            CGRect(x: 0, y: columnOrigin, width: bounds.width, height: bounds.height),
            in: context
        )
    }
}

/// What sits under the last chapter: a spinner, or the end of the book.
///
/// Part of the content rather than an overlay, so reaching the end of the text is what
/// shows it — the same place it occupied when the column was a `LazyVStack`.
///
/// A failed chapter is *not* shown here, unlike before. It needs a retry and a way off
/// the screen — this reader hides the navigation bar, so a failure with no button is a
/// reader with no exit — and those belong in SwiftUI where they are already written and
/// already localized. `ReaderView` floats them over the text instead, where the reader
/// does not have to scroll to the foot of the content to find out anything went wrong.
final class ReaderTextFooter: UIView {
    enum State: Equatable {
        case none
        case loading
        case endOfBook
    }

    static let height: CGFloat = 96

    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.textColor = .secondaryLabel
        addSubview(label)
        addSubview(spinner)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = CGRect(x: 0, y: 28, width: bounds.width, height: bounds.height - 28)
        spinner.center = CGPoint(x: bounds.midX, y: 40)
    }

    func apply(theme: ReaderSettings.Theme) {
        label.textColor = UIColor(theme.foreground).withAlphaComponent(0.6)
    }

    func show(_ state: State) {
        switch state {
        case .none:
            label.text = nil
            spinner.stopAnimating()
        case .loading:
            label.text = nil
            spinner.startAnimating()
        case .endOfBook:
            label.text = String(localized: "reader.end")
            spinner.stopAnimating()
        }
    }
}
