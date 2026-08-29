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
        /// Whether the page will not be coming, which is what it says under its button.
        let failed: Bool
        /// Whether it carries a retry button at all. A page that failed does; so does one
        /// that has simply kept the reader waiting, which has not failed and says its own
        /// number instead — see `ComicPageStore.offersRetry(page:)`.
        let offersRetry: Bool
        /// What the button drawn in the page's place does.
        let onRetry: () -> Void
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

    /// Whether a magnification is in flight — the pinch, and the animated zoom a double
    /// tap starts.
    ///
    /// Its own flag rather than `UIScrollView.isZooming`, which answers for the gesture
    /// and not for the animation that follows a programmatic zoom. That animation is
    /// exactly the window that matters: `zoomScale` is already the value it is heading
    /// for while `contentOffset` and `contentSize` are still travelling, so anything
    /// that computes a position from the two together computes it from halfway.
    private(set) var isMagnifying = false

    /// Where the reader was before a double tap magnified them, so the double tap back out
    /// puts them there again.
    ///
    /// A double tap in and straight back out has to be a no-op on position. The reader
    /// magnified a panel to read it and tapped again to carry on, and any displacement is
    /// them having to find their place on a page they never asked to leave. Zooming in is
    /// around the *finger*, which is what makes it useful — the panel they pointed at
    /// travels to the middle of the screen — and without this, coming out leaves it there.
    /// Measured on device: in at 29858, out at 30182, a third of a screen from where they
    /// started, and the same displacement on every pair.
    ///
    /// Dropped the moment they move themselves. Someone who pans across a magnified page
    /// has gone somewhere on purpose, and hauling them back would be this same complaint in
    /// reverse; that case falls through to keeping the middle of the screen still, which is
    /// true whatever they did in between.
    private var offsetBeforeZoom: CGFloat?

    /// Whether the magnification now starting is the double tap's own animation rather than
    /// the reader's fingers.
    ///
    /// `scrollViewWillBeginZooming` reports both, and they mean opposite things for
    /// `offsetBeforeZoom`: a pinch discards it, while the double tap wrote it two lines
    /// before starting the zoom that reports here. Without the distinction the position is
    /// wiped by the very animation it was written for.
    private var isDoubleTapZooming = false

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
        // Both recognizers sit on the scroll view and neither cancels touches, so a tap
        // on a page's retry button would otherwise reach the button *and* the tap zone
        // it happens to be sitting in — and a comic page is taller than the screen, so
        // that zone is wherever the page put the button. Asked here rather than
        // hit-tested inside the handler: `touch.view` is the view UIKit itself decided
        // this touch belongs to, and re-deriving it from a point is how the first
        // attempt at this got a different answer than UIKit did.
        tap.delegate = self
        addGestureRecognizer(tap)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        doubleTap.delegate = self
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
            #if DEBUG
            ComicProbe.resized(
                from: old.height, to: size.height, zoom: zoomScale, offset: contentOffset.y
            )
            #endif
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
        #if DEBUG
        let before = contentOffset.y
        #endif
        setContentOffset(
            CGPoint(x: contentOffset.x, y: contentOffset.y + amount * zoomScale), animated: false
        )
        #if DEBUG
        ComicProbe.shifted(
            by: amount, before: before, after: contentOffset.y, zoom: zoomScale
        )
        #endif
        lastOffset = contentOffset.y
    }

    func setReadingOffset(_ y: CGFloat, animated: Bool) {
        let maximum = max(0, contentSize.height - bounds.height)
        let landed = min(max(y * zoomScale, 0), maximum)
        #if DEBUG
        ComicProbe.movedTo(
            asked: y * zoomScale, landed: landed, animated: animated, zoom: zoomScale
        )
        #endif
        setContentOffset(CGPoint(x: contentOffset.x, y: landed), animated: animated)
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
            view.show(
                image: page.image, number: page.number, failed: page.failed,
                offersRetry: page.offersRetry, onRetry: page.onRetry
            )
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
        view.show(image: nil, number: 0, failed: false, offersRetry: false)
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
    /// Zooming *to a rect* rather than setting a scale, in both directions and for the
    /// same reason: the reader has a place they are looking at, and a scale on its own
    /// has no opinion about where that is.
    ///
    /// Going in, the rect is around their finger, so the panel they pointed at is the
    /// panel they get. Coming out, it is where they were before going in — and failing
    /// that, the window centred where the window already is.
    ///
    /// Both halves of that were measured, and each was a jump on its own. Keeping the same
    /// *top edge* is the first: at 2x a 896pt screen holds 448 points of book, so a reader
    /// at 2634 is looking at about 2858, and coming out on the top edge makes the middle
    /// 3082 — everything under their eyes slides up a quarter screen. Keeping the middle
    /// instead fixes that but leaves the second: the tapped panel travelled to the centre
    /// on the way in and stays there on the way out, so the pair moves the reader by
    /// however far their finger was from the middle. On device that was 324 points, every
    /// time. A double tap in and back out is a request to look closer and then carry on,
    /// so it has to leave the page exactly where it found it.
    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        // Set here rather than left to `scrollViewWillBeginZooming`, which is about the
        // gesture: the whole cost of a double tap is paid by the animation after it.
        isMagnifying = true
        isDoubleTapZooming = true
        coordinator?.magnificationBegan()
        let target: CGRect
        if zoomScale == minimumZoomScale {
            #if DEBUG
            probe("tap.in")
            #endif
            offsetBeforeZoom = readingOffset
            let point = gesture.location(in: content)
            let size = CGSize(
                width: bounds.width / Self.doubleTapZoom,
                height: bounds.height / Self.doubleTapZoom
            )
            target = CGRect(
                x: point.x - size.width / 2, y: point.y - size.height / 2,
                width: size.width, height: size.height
            )
        } else {
            #if DEBUG
            probe("tap.out")
            #endif
            let middle = readingOffset + visibleHeight / 2
            target = CGRect(
                x: 0, y: offsetBeforeZoom ?? (middle - bounds.height / 2),
                width: bounds.width, height: bounds.height
            )
            offsetBeforeZoom = nil
        }
        // Driven by hand rather than through `zoom(to:animated: true)`, for one thing that
        // call cannot give: a completion that means the reader has stopped seeing movement.
        //
        // `scrollViewDidEndZooming` reports the *model* settling, and measured on device
        // that is the whole animation early — the whole `tap.out` … `zoom.ended` sequence
        // lands in one frame. Everything a magnification holds back was being released into
        // a zoom the reader was still watching, and a height correction resizes the content
        // view the zoom is animating, which abandons the animation rather than adjusting
        // it. That is why the jump came and went: it needed an image to land inside the
        // third of a second, and most double taps had none.
        UIView.animate(
            withDuration: Self.doubleTapDuration, delay: 0, options: .curveEaseInOut
        ) {
            self.zoom(to: target, animated: false)
        } completion: { [weak self] _ in
            guard let self else { return }
            self.endMagnifying()
            #if DEBUG
            self.probe("zoom.released")
            #endif
        }
    }

    /// How long a double tap's zoom runs. `UIScrollView`'s own is about this, and matching
    /// it matters less than owning it — what the corrections wait for is this number.
    private static let doubleTapDuration: TimeInterval = 0.3

    #if DEBUG
    /// Every number the reader's position is computed from, in one place, so the step
    /// that moved them is the line where `reading` changed. See `ComicProbe`.
    func probe(_ step: String, throttled: Bool = false) {
        let report = throttled ? ComicProbe.zoomStep : ComicProbe.zoom
        report(
            step, readingOffset, contentOffset.y, zoomScale,
            contentSize.height, content.bounds.height, bounds.height
        )
    }
    #endif
}

extension ComicScrollView: UIGestureRecognizerDelegate {
    /// Keeps the reader's taps and the pages' own controls apart.
    ///
    /// Refusing the double tap as well is deliberate: a reader who taps a retry button
    /// twice — because the first tap did not appear to do anything — means "try again",
    /// not "magnify". It also means the button answers on the first touch instead of
    /// waiting to find out whether a second one is coming.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch
    ) -> Bool {
        !(touch.view is UIControl)
    }
}

extension ComicScrollView: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        isMagnifying = true
        coordinator?.magnificationBegan()
        // A pinch is not half of a toggle: whatever the reader does with their fingers from
        // here is where they meant to be. The double tap's own animation reports its
        // beginning here too, and that one *is* half of a toggle — see `isDoubleTapZooming`.
        guard !isDoubleTapZooming else { return }
        offsetBeforeZoom = nil
    }

    /// The end of the pinch *and* the end of a programmatic zoom's animation, which is
    /// the one this is really here for. Everything held back while the content was
    /// travelling is let go here, in the order it would have happened in.
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        #if DEBUG
        probe("zoom.ended")
        #endif
        // A double tap says when it is over from its own completion. This fires as the
        // model settles, which for that one is before the reader has seen anything move.
        guard !isDoubleTapZooming else { return }
        endMagnifying()
        #if DEBUG
        probe("zoom.released")
        #endif
    }

    /// Magnifying changes how much of the book the screen holds, so the window of pages
    /// that are worth having decoded changes with it.
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        #if DEBUG
        probe("zoom.step", throttled: true)
        #endif
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
        // The safety net. A magnification that somehow never reported its end would
        // otherwise leave the reader in a book that never loads its next chapter, and
        // a finger dragging the page is a magnification that is over whatever WebKit
        // said about it.
        endMagnifying()
        // Where they are is theirs now, so the double tap back out has nothing to restore
        // and falls through to keeping the middle of the screen still.
        offsetBeforeZoom = nil
        coordinator?.handleTouch(down: true)
    }

    private func endMagnifying() {
        guard isMagnifying else { return }
        isMagnifying = false
        isDoubleTapZooming = false
        coordinator?.magnificationEnded()
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
///
/// A page that failed gets a button in its place instead of a message, and that is the
/// difference between one dead image and an interrupted read: the chapter carries on
/// scrolling either way, and the one page that did not arrive is a thing the reader can
/// tap when they get to it — or scroll straight past.
final class ComicPageView: UIView {
    private let imageView = UIImageView()
    private let label = UILabel()
    private let retryButton = UIButton(type: .system)
    private var onRetry: (() -> Void)?
    /// Which of the two layouts is up: the button and a line under it, or the page number
    /// filling the frame.
    private var isOfferingRetry = false

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit
        // The frame is already the image's own shape — the column derived its height
        // from the aspect ratio — so there is nothing to clip and no letterboxing.
        imageView.clipsToBounds = true
        addSubview(imageView)
        label.textColor = UIColor.white.withAlphaComponent(0.25)
        label.textAlignment = .center
        addSubview(label)
        retryButton.setImage(
            UIImage(
                systemName: "arrow.clockwise",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 30, weight: .regular)
            ),
            for: .normal
        )
        retryButton.tintColor = UIColor.white.withAlphaComponent(0.6)
        // A ring, so it reads as something to press rather than as an icon printed on
        // the page. A comic page's own artwork is what everything else here is.
        retryButton.layer.borderColor = UIColor.white.withAlphaComponent(0.3).cgColor
        retryButton.layer.borderWidth = 1
        retryButton.layer.cornerRadius = Self.retrySide / 2
        retryButton.isHidden = true
        retryButton.accessibilityIdentifier = "comic.page.retry"
        retryButton.accessibilityLabel = String(localized: "comic.page.retry")
        retryButton.addTarget(self, action: #selector(tappedRetry), for: .touchUpInside)
        addSubview(retryButton)
        accessibilityIdentifier = "comic.page"
    }

    required init?(coder: NSCoder) { nil }

    private static let retrySide: CGFloat = 64

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        guard isOfferingRetry else {
            label.frame = bounds
            return
        }
        // Centred on the page, with the reason under it. A page is usually taller than
        // the screen, so this is the middle of the *page* and not of the window — which
        // is where the reader ends up when they scroll to look at what is wrong.
        let side = Self.retrySide
        retryButton.frame = CGRect(
            x: (bounds.width - side) / 2, y: (bounds.height - side) / 2,
            width: side, height: side
        )
        label.frame = CGRect(
            x: 0, y: retryButton.frame.maxY + 12, width: bounds.width, height: 24
        )
    }

    @objc private func tappedRetry() {
        onRetry?()
    }

    func show(
        image: UIImage?, number: Int, failed: Bool, offersRetry: Bool,
        onRetry: (() -> Void)? = nil
    ) {
        imageView.image = image
        // Re-assigned on every pass because these views are pooled: the closure knows
        // which page it is for, and a recycled view is a different page.
        self.onRetry = onRetry
        let showsRetry = image == nil && offersRetry
        if isOfferingRetry != showsRetry {
            isOfferingRetry = showsRetry
            setNeedsLayout()
        }
        retryButton.isHidden = !showsRetry
        label.font = .preferredFont(forTextStyle: showsRetry ? .footnote : .largeTitle)
        if image != nil {
            label.text = nil
            accessibilityLabel = String(localized: "comic.page \(number)")
            isAccessibilityElement = true
        } else {
            label.text = failed
                ? String(localized: "comic.page.failed \(number)")
                : (number > 0 ? "\(number)" : nil)
            accessibilityLabel = label.text
            // Never the container when the button is showing: two elements at the same
            // place, one of which does nothing, is what VoiceOver reads as a dead end.
            isAccessibilityElement = number > 0 && !showsRetry
        }
    }
}
