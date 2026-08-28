import UIKit

/// The scroll view a comic's pages live in.
///
/// `ReaderTextScrollView`'s counterpart, and the same shape: a plain `UIScrollView`
/// whose content is as tall as the whole loaded window, with the coordinator doing all
/// the arithmetic and this doing all the UIKit.
///
/// Where it differs is what rides on top. The text reader draws its visible slice onto
/// one screen-tall canvas, because a `CALayer` cannot back a view tens of thousands of
/// points tall and glyphs are cheap to redraw every frame. Pages are not: decoding a
/// JPEG inside `draw(_:)` once per frame is the one thing a comic reader must never do.
/// So pages are real `UIImageView`s — the compositor draws them, which is what it is
/// for — recycled through a pool as the window moves, which keeps the number of live
/// views proportional to the screen rather than to the chapter.
final class ComicScrollView: UIScrollView {
    weak var coordinator: ComicScrollCoordinator?

    /// One page, as the coordinator describes it.
    struct VisiblePage {
        /// Stable across frames: chapter id plus page number. What the pool keys on, so
        /// a page that stays on screen keeps its view and its decoded bitmap.
        let key: String
        let frame: CGRect
        let image: UIImage?
        /// 1-based, for the placeholder that stands in until the image arrives.
        let number: Int
        let failed: Bool
    }

    /// Everything that scrolls, and the one view the zoom scales.
    ///
    /// A `UIScrollView` zooms by transforming a single subview, so the pages cannot be
    /// its own children any more. It carries no drawing of its own — it is a coordinate
    /// space, which is why it can be a chapter tall without costing anything.
    private let content = UIView()
    private let footer = ReaderTextFooter()
    private var live: [String: ComicPageView] = [:]
    private var pool: [ComicPageView] = []
    private var lastOffset: CGFloat = 0
    private var lastWidth: CGFloat = 0

    /// Whether the last movement carried the reader towards the front of the book.
    private(set) var isMovingUp = false

    /// Where the top of the window sits in the content — the reading position exactly.
    ///
    /// In *unzoomed* content points, which is the space the columns are laid out in and
    /// the only space the coordinator ever speaks. Dividing here is what keeps zoom out
    /// of every piece of arithmetic that follows.
    var readingOffset: CGFloat { contentOffset.y / zoomScale }
    /// How much of the content the screen holds — less of it the further in they zoom.
    var visibleHeight: CGFloat { bounds.height / zoomScale }
    /// Pages are drawn edge to edge. A comic page carries its own margins inside the
    /// artwork, and insetting it would put a second margin around the first.
    ///
    /// Unchanged by zoom: the layout is built once at the screen's width and magnified,
    /// rather than rebuilt at a wider measure — a rebuild would mean new columns, new
    /// stores and every page fetched again, once per pinch frame.
    var pageWidth: CGFloat { bounds.width }
    /// The glass, in points. What a tap zone is measured against — those are places on
    /// the screen, not places in the book.
    var screenSize: CGSize { bounds.size }

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Black, not the reader's theme. A comic page is a picture with its own paper
        // colour painted into it, so a "sepia" surround would frame every page in a
        // colour its artist did not choose — where a novel's background *is* its paper.
        backgroundColor = .black
        contentInsetAdjustmentBehavior = .never
        showsVerticalScrollIndicator = true
        delegate = self
        addSubview(content)
        content.addSubview(footer)

        // Never below 1: the layout is already the full width of the screen, so zooming
        // out would only put black beside the page.
        minimumZoomScale = 1
        maximumZoomScale = Self.maximumZoom
        bouncesZoom = true

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        addGestureRecognizer(doubleTap)
        // The cost of double-tap zoom: showing the controls now waits to find out whether
        // a second tap is coming. Worth it — a page of scanned lettering at phone width
        // is the thing the reader reaches for zoom about, and they reach for it often.
        tap.require(toFail: doubleTap)
    }

    /// As far in as a page is worth magnifying.
    ///
    /// Three, which is roughly where a typical scan runs out of pixels: pages are decoded
    /// with a long-edge allowance of 3 (see `ComicPageStore.decode`), so up to this much
    /// magnification is showing detail that is really in the file rather than an
    /// interpolation of it.
    private static let maximumZoom: CGFloat = 3
    /// Where a double tap lands. Two, because the gesture's job is "make this readable"
    /// in one go, and the pinch is there for anyone who wants a different amount.
    private static let doubleTapZoom: CGFloat = 2

    /// Never loaded from a nib.
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        positionFooter()
        guard bounds.width != lastWidth else { return }
        lastWidth = bounds.width
        // The columns are about to be rebuilt for the new measure, and a magnification of
        // the old one means nothing against them.
        if zoomScale != 1 { setZoomScale(1, animated: false) }
        coordinator?.viewResized()
    }

    private func positionFooter() {
        footer.frame = CGRect(
            x: 0, y: coordinator?.contentHeight ?? 0,
            width: bounds.width, height: ReaderTextFooter.height
        )
    }

    func refreshContentSize() {
        let height = (coordinator?.contentHeight ?? 0) + ReaderTextFooter.height
        setContentHeight(height)
        positionFooter()
    }

    /// Resizes the content, in the size it has at zoom 1.
    ///
    /// Through `bounds` rather than `frame`, because a zoomed-in scroll view has put a
    /// transform on this view and a transformed view's frame means nothing. Bounds grow
    /// around the centre, so the top-left has to be pinned back by hand — otherwise every
    /// image that lands while the reader is zoomed in slides the page under them by half
    /// of whatever it corrected.
    private func setContentHeight(_ height: CGFloat) {
        let size = CGSize(width: bounds.width, height: height)
        let old = content.bounds.size
        if old != size {
            content.bounds = CGRect(origin: .zero, size: size)
            content.center = CGPoint(
                x: content.center.x + (size.width - old.width) / 2 * zoomScale,
                y: content.center.y + (size.height - old.height) / 2 * zoomScale
            )
        }
        let scaled = CGSize(width: size.width * zoomScale, height: size.height * zoomScale)
        if contentSize != scaled { contentSize = scaled }
    }

    /// Moves content and offset together, so the reader stays on the same page.
    ///
    /// The whole payoff of the column stack, and it matters more here than it does for
    /// text: a comic column is built on estimates and corrected as images arrive, so
    /// this runs tens of times per chapter rather than once per insert.
    func shift(by amount: CGFloat) {
        guard amount != 0 else { return }
        setContentOffset(
            CGPoint(x: contentOffset.x, y: contentOffset.y + amount * zoomScale), animated: false
        )
        lastOffset = contentOffset.y
    }

    func setReadingOffset(_ y: CGFloat, animated: Bool) {
        let maximum = max(0, contentSize.height - bounds.height)
        setContentOffset(
            CGPoint(x: contentOffset.x, y: min(max(y * zoomScale, 0), maximum)), animated: animated
        )
    }

    func showFooter(_ state: ReaderTextFooter.State) {
        footer.show(state)
    }

    // MARK: - Pages

    /// Puts exactly these pages on screen, reusing the views already there.
    ///
    /// Diffed by key rather than rebuilt: a scrolled frame usually changes one page at
    /// either end, and tearing every view down would drop the decoded bitmaps of pages
    /// that never left the screen.
    func show(_ pages: [VisiblePage]) {
        var kept: [String: ComicPageView] = [:]
        kept.reserveCapacity(pages.count)
        for page in pages {
            let view = live.removeValue(forKey: page.key) ?? dequeue()
            view.frame = page.frame
            view.show(image: page.image, number: page.number, failed: page.failed)
            kept[page.key] = view
        }
        for (_, view) in live { recycle(view) }
        live = kept
    }

    private func dequeue() -> ComicPageView {
        let view = pool.popLast() ?? ComicPageView()
        view.isHidden = false
        content.addSubview(view)
        // Under the footer, which shares the content view with the pages.
        content.sendSubviewToBack(view)
        return view
    }

    private func recycle(_ view: ComicPageView) {
        view.removeFromSuperview()
        view.show(image: nil, number: 0, failed: false)
        // Bounded: a window is a handful of pages, and a pool that grew with the chapter
        // would be holding views for pages nobody is near.
        guard pool.count < Self.poolLimit else { return }
        pool.append(view)
    }

    private static let poolLimit = 8

    // MARK: - Taps

    /// A point on the glass. A scroll view's own coordinate space *is* its content, so
    /// a raw touch location names where the finger landed in the chapter rather than on
    /// the screen — see `ReaderTextScrollView.onScreen`.
    private func onScreen(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - contentOffset.x, y: point.y - contentOffset.y)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        coordinator?.handleTap(at: onScreen(gesture.location(in: self)))
    }

    /// Magnifies around what they tapped, or gives up the magnification entirely.
    ///
    /// Zooming *to a rect* rather than setting a scale, so the panel under their finger
    /// is the panel they end up looking at — a scale alone magnifies around the middle of
    /// the screen, which is rarely what they pointed at.
    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard zoomScale == minimumZoomScale else {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let point = gesture.location(in: content)
        let size = CGSize(
            width: bounds.width / Self.doubleTapZoom, height: bounds.height / Self.doubleTapZoom
        )
        zoom(
            to: CGRect(
                x: point.x - size.width / 2, y: point.y - size.height / 2,
                width: size.width, height: size.height
            ),
            animated: true
        )
    }
}

extension ComicScrollView: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }

    /// Magnifying changes how much of the book the screen holds, so the window of pages
    /// that are worth having decoded changes with it.
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        coordinator?.scrolled()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // A pinch moves the offset as a side effect of magnifying around a point, in
        // whichever direction the geometry works out to. Reading a direction of travel
        // out of that would have a zoom-in near the top of a chapter fetch the previous
        // one, which is the open that visibly runs backwards.
        if abs(contentOffset.y - lastOffset) > 0.5 {
            if !isZooming, !isZoomBouncing { isMovingUp = contentOffset.y < lastOffset }
            lastOffset = contentOffset.y
        }
        coordinator?.scrolled()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        coordinator?.handleTouch(down: true)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate: Bool) {
        if !willDecelerate { coordinator?.handleTouch(down: false) }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        coordinator?.handleTouch(down: false)
    }
}

/// One page: the image, or what stands in for it until it arrives.
///
/// The placeholder is a page number rather than a spinner, and that is the point of
/// having a view at all before the bytes land. A comic column is built on estimated
/// heights, so the reader can scroll the whole chapter immediately — and a screen of
/// identical grey rectangles gives them nothing to navigate by, while "12" says exactly
/// where they are.
final class ComicPageView: UIView {
    private let imageView = UIImageView()
    private let label = UILabel()

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit
        // The frame is already the image's own shape — the column derived its height
        // from the aspect ratio — so there is nothing to clip and no letterboxing.
        imageView.clipsToBounds = true
        addSubview(imageView)
        label.font = .preferredFont(forTextStyle: .largeTitle)
        label.textColor = UIColor.white.withAlphaComponent(0.25)
        label.textAlignment = .center
        addSubview(label)
        accessibilityIdentifier = "comic.page"
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        label.frame = bounds
    }

    func show(image: UIImage?, number: Int, failed: Bool) {
        imageView.image = image
        if image != nil {
            label.text = nil
            accessibilityLabel = String(localized: "comic.page \(number)")
            isAccessibilityElement = true
        } else {
            label.text = failed
                ? String(localized: "comic.page.failed \(number)")
                : (number > 0 ? "\(number)" : nil)
            accessibilityLabel = label.text
            isAccessibilityElement = number > 0
        }
    }
}
