import SwiftUI
import UIKit

/// A comic chapter that has been given its place in the scrolling content.
///
/// `PlacedColumn`'s counterpart. Same job — `top` is in content coordinates, so an
/// insert above the reader is one addition — and one thing more: the column it carries
/// is still changing shape, because a page's height is not known until its image lands.
struct PlacedComicChapter {
    let chapterIndex: Int
    let chapterId: String
    let siteChapterId: String
    let column: ComicChapterColumn
    let store: ComicPageStore
    var top: CGFloat

    var height: CGFloat { column.height }
    var bottom: CGFloat { top + height }
}

/// Where the reader is, in the terms the model stores.
struct ComicPlace: Equatable {
    let chapterIndex: Int
    /// Which page the top of the window is on. Stored in `lastReadParagraph`, whose
    /// meaning is "which visual block" — a paragraph in a novel, a page here.
    let page: Int
    let fraction: Double
}

/// The comic reader's page surface: one column of pages per chapter, stacked in a
/// `UIScrollView`, drawn by recycled image views.
///
/// Mirrors `ReaderScrollingText` deliberately and shares no code with it. The two have
/// the same skeleton — place, restack, correct, report, ask for more — over units that
/// have nothing in common: one is a TextKit layout manager addressed by character
/// offset, the other an array of image sizes addressed by page. Sharing them would mean
/// an abstraction whose two users disagree about what a position *is*.
struct ComicScrollingPages: UIViewRepresentable {
    /// The loaded window, in reading order.
    let chapters: [ComicReaderModel.LoadedChapter]
    /// Where the reader must be put. Consumed once and cleared by the owner.
    let target: ComicReaderModel.ScrollTarget?
    let footer: ReaderTextFooter.State
    let fetcher: ImageFetcher

    let onPlaceChange: (ComicPlace) -> Void
    let onNeedsNext: () -> Void
    let onNeedsPrevious: () -> Void
    let onTouch: (Bool) -> Void
    /// - Returns: whether the tap should go on to turn a page.
    let onTap: (ReaderTapZone.Zone) -> Bool
    let onTargetReached: () -> Void

    func makeUIView(context: Context) -> ComicScrollView {
        let view = ComicScrollView()
        view.coordinator = context.coordinator
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: ComicScrollView, context: Context) {
        context.coordinator.update(with: self)
    }

    func makeCoordinator() -> ComicScrollCoordinator {
        ComicScrollCoordinator()
    }
}

/// Owns the placed chapters and everything that depends on where the scroll is.
@MainActor
final class ComicScrollCoordinator {
    weak var view: ComicScrollView?

    private(set) var placed: [PlacedComicChapter] = []
    private var config: ComicScrollingPages?
    /// The width every column was built for. A rotation makes all of them describe a
    /// measure nobody is reading at.
    private var builtForWidth: CGFloat = 0
    private var reported: ComicPlace?
    private var deliveredTarget: ComicReaderModel.ScrollTarget?
    /// Whether a finger is on the glass, which holds back the corrections that would
    /// move the content under it — see `apply(size:)`.
    private var isTouching = false
    /// Corrections that arrived while the reader was dragging, applied the moment they
    /// let go. Only the ones that would move them: a page growing *below* the reader
    /// changes nothing they can see and is applied straight away.
    private var heldCorrections: [(chapterId: String, page: Int, size: CGSize)] = []
    /// The page a restored position asked for, held until the reader takes over.
    /// See `scroll(toPage:inChapter:animated:)`.
    private var pendingLanding: (chapterIndex: Int, page: Int)?

    /// The seam between chapters. Wide enough to read as a break in a medium that has
    /// no other punctuation between one chapter's last panel and the next one's first.
    static let chapterGap: CGFloat = 32

    /// How much of the loaded chapter must remain below the window before the next one
    /// is asked for. One window, not the text reader's two: a comic page is most of a
    /// screen, so two windows of lead is most of a chapter — the reader would be
    /// fetching the next chapter from the moment they opened this one.
    private static let leadWindows: CGFloat = 1

    /// How far past the screen a page is kept decoded, in screens. One either side, so a
    /// turn lands on a page that is already there and the one behind survives a glance
    /// backwards.
    ///
    /// Measured against the glass rather than against `visibleHeight`, and that is the
    /// difference zoom makes. Magnifying to 2x halves how much of the book the screen
    /// holds, so a margin taken from `visibleHeight` would halve with it and release the
    /// bitmaps either side — which the double tap back out then has to decode again,
    /// with the reader watching a page they were already looking at turn into a grey
    /// rectangle and back. What is worth keeping decoded is a property of the reader's
    /// attention, and magnifying does not narrow that.
    private static let decodeMargin: CGFloat = 1

    // MARK: - Updating

    func update(with config: ComicScrollingPages) {
        self.config = config
        view?.showFooter(config.footer)
        guard let view, view.pageWidth > 0 else { return }

        if builtForWidth != view.pageWidth {
            // Every column describes a width nobody is reading at. Keep the page the
            // reader is on — a point in the old stack means nothing in the new one.
            let keep = currentPlace()
            builtForWidth = view.pageWidth
            for chapter in placed { chapter.store.cancel() }
            placed = []
            deliveredTarget = nil
            addMissingChapters(config)
            if let keep {
                scroll(toPage: keep.page, inChapter: keep.chapterIndex, animated: false)
            }
        } else {
            addMissingChapters(config)
            dropChaptersNoLongerLoaded(config)
        }
        applyTargetIfNeeded(config)
        view.refreshContentSize()
        refreshVisible()
        reportPlace()
    }

    /// The window changed measure, so the next update has to rebuild — which the width
    /// comparison does on its own once it is given a chance to run.
    func viewResized() {
        guard let config else { return }
        update(with: config)
    }

    /// Puts every loaded chapter that has no column yet into the stack.
    ///
    /// Synchronous, unlike the text reader's, and that is the whole difference between
    /// the two media: laying a chapter of text out is seconds of work on a background
    /// queue, while a comic column is `pageCount` numbers and an estimate. There is
    /// nothing to wait for and nothing to hand between threads — the images arrive
    /// later, and arriving later is what `apply(size:)` is for.
    private func addMissingChapters(_ config: ComicScrollingPages) {
        guard let view else { return }
        var inserted = false
        for chapter in config.chapters
        where !placed.contains(where: { $0.chapterId == chapter.chapter.id }) {
            // Where the reader is, before the insert renumbers everything.
            let anchor = readingAnchor()
            let store = ComicPageStore(
                urls: chapter.imageURLs, chapterPage: chapter.chapterPage,
                fetcher: config.fetcher, missing: chapter.missingPages
            )
            let entry = PlacedComicChapter(
                chapterIndex: chapter.chapter.index,
                chapterId: chapter.chapter.id,
                siteChapterId: chapter.chapter.siteChapterId,
                column: ComicChapterColumn(
                    pageCount: chapter.imageURLs.count, width: view.pageWidth
                ),
                store: store,
                top: 0
            )
            let chapterId = chapter.chapter.id
            store.onSize = { [weak self] page, size in
                self?.apply(size: size, page: page, chapterId: chapterId)
            }
            store.onImage = { [weak self] _ in self?.refreshVisible() }
            store.onFetched = chapter.keepPage
            store.cached = chapter.cachedPage
            // Redrawn, not reported. The page draws its own retry button; a failure
            // banner over a chapter that is still readable would be the app stopping
            // the reader to tell them about something they can see.
            store.onFailure = { [weak self] _, _ in self?.refreshVisible() }
            store.onSlow = { [weak self] _ in self?.refreshVisible() }
            placed.insert(
                entry,
                at: placed.firstIndex { $0.chapterIndex > entry.chapterIndex } ?? placed.count
            )
            restack()
            view.refreshContentSize()
            // Everything the reader is looking at moved by exactly this much — zero when
            // the chapter landed below them, which is the common case.
            if let anchor, let now = absoluteTop(chapterId: anchor.chapterId, page: anchor.page) {
                view.shift(by: now - anchor.top)
            }
            inserted = true
        }
        guard inserted else { return }
        // A chapter arriving below can be the content a landing was short of. The last
        // page of a chapter cannot sit at the top of the window while it is the last
        // thing loaded — there is not a screen of anything under it — so a position
        // left at a chapter boundary is only restorable once the next chapter is back.
        retryLanding()
        refreshVisible()
    }

    private func dropChaptersNoLongerLoaded(_ config: ComicScrollingPages) {
        let live = Set(config.chapters.map(\.chapter.id))
        guard placed.contains(where: { !live.contains($0.chapterId) }) else { return }
        let keep = currentPlace()
        for chapter in placed where !live.contains(chapter.chapterId) { chapter.store.cancel() }
        placed.removeAll { !live.contains($0.chapterId) }
        restack()
        view?.refreshContentSize()
        if let keep { scroll(toPage: keep.page, inChapter: keep.chapterIndex, animated: false) }
    }

    private func restack() {
        var y: CGFloat = 0
        for index in placed.indices {
            placed[index].top = y
            y += placed[index].height + Self.chapterGap
        }
    }

    var contentHeight: CGFloat { placed.last?.bottom ?? 0 }

    // MARK: - Corrections

    /// Replaces a page's estimated height with its real one, keeping the reader where
    /// they are.
    ///
    /// This runs tens of times per chapter, where the text reader's equivalent runs once
    /// per chapter insert — and it is the same single addition, which is why the column
    /// stack was worth mirroring rather than reaching for a lazy container again.
    ///
    /// Held back while a finger is on the glass, and only then: adjusting the content
    /// offset mid-drag fights the pan gesture, which computes its own destination from
    /// where the touch started. A page growing at or below the reader moves nothing they
    /// can see, needs no offset change, and is applied immediately whatever their hand
    /// is doing.
    private func apply(size: CGSize, page: Int, chapterId: String) {
        guard let view, let index = placed.firstIndex(where: { $0.chapterId == chapterId })
        else { return }
        let chapter = placed[index]
        let isAbove = chapter.top + chapter.column.top(ofPage: page)
            + chapter.column.height(ofPage: page) <= view.readingOffset
        // A drag holds back only the corrections that would move the reader, because
        // adjusting the offset mid-drag fights the pan gesture — a page growing at or
        // below them moves nothing they can see.
        //
        // A magnification holds back *everything*, which is not the same rule and was the
        // double tap's jump. Measured on device: coming out of 2x, a page at the reader's
        // own position corrected 621→594, the content shrank by 27 points, and the offset
        // went from 222 to 0 — the top of the chapter. A scroll view mid-zoom is animating
        // its offset against a content size it was given when the animation started, and
        // changing that size under it does not adjust the animation, it abandons it.
        // Which page was corrected makes no difference to that: what disturbs the zoom is
        // the resize, and every correction is a resize.
        let holding = view.isMagnifying || (isAbove && isTouching)
        if holding {
            heldCorrections.append((chapterId, page, size))
            return
        }
        let anchor = isAbove ? readingAnchor() : nil
        guard chapter.column.setSize(size, ofPage: page) != 0 else { return }
        restack()
        view.refreshContentSize()
        if let anchor, let now = absoluteTop(chapterId: anchor.chapterId, page: anchor.page) {
            view.shift(by: now - anchor.top)
        }
        // The correction may be the content this landing was waiting for.
        retryLanding()
        refreshVisible()
    }

    private func applyHeldCorrections() {
        guard !heldCorrections.isEmpty else { return }
        let held = heldCorrections
        heldCorrections = []
        for correction in held {
            apply(size: correction.size, page: correction.page, chapterId: correction.chapterId)
        }
    }

    /// The page the top of the window is on, and where that page sits in the content.
    /// Taken before a change so it can be found again after one.
    private func readingAnchor() -> (chapterId: String, page: Int, top: CGFloat)? {
        guard let view, let chapter = chapter(atY: view.readingOffset) else { return nil }
        let page = chapter.column.page(atY: view.readingOffset - chapter.top)
        return (chapter.chapterId, page, chapter.top + chapter.column.top(ofPage: page))
    }

    private func absoluteTop(chapterId: String, page: Int) -> CGFloat? {
        guard let chapter = placed.first(where: { $0.chapterId == chapterId }) else { return nil }
        return chapter.top + chapter.column.top(ofPage: page)
    }

    // MARK: - Where the reader is

    func chapter(atY y: CGFloat) -> PlacedComicChapter? {
        placed.last { $0.top <= y } ?? placed.first
    }

    func currentPlace() -> ComicPlace? {
        guard let view, let chapter = chapter(atY: view.readingOffset) else { return nil }
        let inColumn = view.readingOffset - chapter.top
        return ComicPlace(
            chapterIndex: chapter.chapterIndex,
            page: chapter.column.page(atY: inColumn),
            fraction: chapter.column.fractionRead(through: inColumn + view.visibleHeight)
        )
    }

    func scrolled() {
        reportPlace()
        refreshVisible()
        askForMoreIfNeeded()
    }

    /// Where the reader is, published to the model.
    ///
    /// Not while magnifying, and that is not an optimisation. Zooming does not move
    /// anyone in the book — it changes how much of one page fills the screen — but it
    /// does change `fractionRead`, so reporting through a zoom writes "you have read
    /// less of this chapter" to the reading position. Worse, it writes it on every
    /// frame of the animation, and every write brings SwiftUI back through
    /// `updateUIView` while the scroll view is still travelling.
    private func reportPlace() {
        guard let config, view?.isMagnifying != true,
              let place = currentPlace(), place != reported
        else { return }
        reported = place
        config.onPlaceChange(place)
    }

    /// The reader has started magnifying, so a restored position is no longer the answer
    /// to where they are.
    ///
    /// The same rule as `turnPage` and `handleTouch(down:)` — anything they did with their
    /// own hands makes the position theirs — and it has to be said separately because a
    /// double tap never drags, so the scroll view never reports a touch for it. That gap
    /// was the double tap's jump, and it was much larger than the arithmetic ever was.
    /// Measured on device: a chapter opened at page 4 and then double-tapped, never
    /// scrolled, had `pendingLanding` still set — so every image that arrived corrected a
    /// height, every correction re-asserted the landing, and the reader was dragged from
    /// 2634 back to 2394.5 in the middle of coming out of the zoom, over and over.
    func magnificationBegan() {
        pendingLanding = nil
    }

    /// Everything a magnification held back, once it is over.
    func magnificationEnded() {
        applyHeldCorrections()
        reportPlace()
        askForMoreIfNeeded()
        refreshVisible()
    }

    private func askForMoreIfNeeded() {
        guard let config, let view, !placed.isEmpty, !view.isMagnifying else { return }
        let lead = view.visibleHeight * Self.leadWindows
        if contentHeight - (view.readingOffset + view.visibleHeight) < lead {
            config.onNeedsNext()
        }
        // Only when actually heading up — a landing sits at the top of its chapter, and
        // pulling the previous one in there is the open that visibly runs backwards.
        if view.isMovingUp, view.readingOffset < lead {
            config.onNeedsPrevious()
        }
    }

    // MARK: - Drawing

    /// Tells every chapter which of its pages to hold, and the scroll view which to show.
    ///
    /// One pass over the placed chapters per scrolled frame that changed anything. The
    /// two ranges are deliberately different: the scroll view is given the pages that
    /// touch the screen, while a store is asked to keep a screen more either side, so a
    /// page turn lands on a bitmap that already exists.
    private func refreshVisible() {
        guard let view else { return }
        let top = view.readingOffset
        let bottom = top + view.visibleHeight
        let margin = view.screenSize.height * Self.decodeMargin
        // A magnification reaches its destination in the model before the reader has seen
        // it move, so `visibleHeight` says 448 points while 896 are still on the glass —
        // and the pages outside the new window would be taken off the screen they are
        // still on, blacking out the top and bottom for the length of the animation. A
        // screen either side covers the whole of what the zoom travels through; the views
        // are recycled the moment it settles, which is what `magnificationEnded` redraws
        // for. It matches `margin` on purpose: a page drawn past the decoded window is a
        // grey rectangle, which is the blackout again by another route. Widen one and the
        // other has to follow.
        let drawn = view.isMagnifying ? view.screenSize.height : 0
        var pages: [ComicScrollView.VisiblePage] = []
        for chapter in placed {
            let wanted = chapter.column.pages(
                in: (top - margin - chapter.top)..<(bottom + margin - chapter.top)
            )
            chapter.store.setWindow(wanted, width: view.pageWidth)
            guard chapter.bottom > top - drawn, chapter.top < bottom + drawn else { continue }
            for page in chapter.column.pages(
                in: (top - drawn - chapter.top)..<(bottom + drawn - chapter.top)
            ) {
                let frame = chapter.column.frame(ofPage: page)
                let store = chapter.store
                pages.append(ComicScrollView.VisiblePage(
                    key: "\(chapter.chapterId)#\(page)",
                    frame: frame.offsetBy(dx: 0, dy: chapter.top),
                    image: store.image(page: page),
                    number: page + 1,
                    failed: store.hasFailed(page: page),
                    offersRetry: store.offersRetry(page: page),
                    onRetry: { [weak self] in
                        store.retry(page: page)
                        self?.refreshVisible()
                    }
                ))
            }
        }
        view.show(pages)
    }

    // MARK: - Moving the reader

    private func applyTargetIfNeeded(_ config: ComicScrollingPages) {
        guard let target = config.target else {
            deliveredTarget = nil
            return
        }
        guard target != deliveredTarget,
              placed.contains(where: { $0.chapterIndex == target.chapterIndex })
        else { return }
        deliveredTarget = target
        scroll(toPage: target.page, inChapter: target.chapterIndex, animated: false)
        // Off this pass: clearing the target writes to the model, and this can run inside
        // `updateUIView` — which is SwiftUI in the middle of reading it.
        Task { @MainActor in config.onTargetReached() }
        reportPlace()
    }

    /// Puts a page at the top of the window, and keeps it there until the reader moves.
    ///
    /// Setting the offset once is not enough, and this is the whole reason: a chapter
    /// that has just been opened is nearly all estimates, and every image that lands
    /// replaces one. A page that comes back *shorter* than its estimate — the common
    /// case, since a printed page runs about 1.4 times its width against an estimate of
    /// 1.5 — shrinks the content below the reader, and a `UIScrollView` whose content
    /// becomes shorter than its offset pulls the offset back without telling anyone.
    /// Near the end of a chapter there is not much below to lose, so the pull is a
    /// whole page: that is what reopening the app one page above where it was left
    /// actually was.
    ///
    /// So the landing is held and re-asserted after every correction, rather than aimed
    /// at once and hoped for. It is dropped the moment the reader touches the glass or
    /// taps to turn — from there where they are is their decision, not a position being
    /// restored — and addressed by chapter and page rather than by offset, so a chapter
    /// arriving above it does not make it mean somewhere else.
    func scroll(toPage page: Int, inChapter index: Int, animated: Bool) {
        guard let view, let chapter = placed.first(where: { $0.chapterIndex == index })
        else { return }
        view.setReadingOffset(chapter.top + chapter.column.top(ofPage: page), animated: animated)
        // Not for an animated move: that is a reader-initiated jump, already theirs.
        pendingLanding = animated ? nil : (index, page)
        refreshVisible()
    }

    private func retryLanding() {
        guard let landing = pendingLanding else { return }
        scroll(toPage: landing.page, inChapter: landing.chapterIndex, animated: false)
    }

    /// Turns a page in the direction a tap asked for.
    ///
    /// A window at a time with a sliver of overlap, rather than the text reader's
    /// "aim at a paragraph": a comic page is usually taller than the screen, so there is
    /// no unit smaller than the window to line anything up with. The overlap is what
    /// stops a panel being split across two taps with no part of it fully seen.
    func turnPage(_ zone: ReaderTapZone.Zone) {
        guard let view, let config else { return }
        // The reader has moved themselves, so a restored landing is no longer the
        // answer to where they are — re-asserting it after the next correction would
        // pull them back off the page they just turned to. Deliberately here and not in
        // `handleTap`: a tap on the middle band only shows the controls, and someone
        // checking which page they are on has not asked to be moved.
        pendingLanding = nil
        if zone == .previous, view.readingOffset <= 0 { config.onNeedsPrevious() }
        let step = view.visibleHeight - min(view.visibleHeight * 0.12, 64)
        switch zone {
        case .next: view.setReadingOffset(view.readingOffset + step, animated: true)
        case .previous: view.setReadingOffset(view.readingOffset - step, animated: true)
        case .controls: break
        }
    }

    // MARK: - Touching

    func handleTap(at point: CGPoint) {
        guard let config, let view else { return }
        // Against the glass, not the window into the book: a tap zone is a third of the
        // screen the finger landed on, and magnifying the page does not move it.
        let zone = ReaderTapZone.zone(at: point, in: view.screenSize)
        guard config.onTap(zone) else { return }
        turnPage(zone)
    }

    func handleTouch(down: Bool) {
        isTouching = down
        // Where they are is theirs to decide now, and a restored position still trying to
        // land would be taking the book back off them.
        if down { pendingLanding = nil }
        config?.onTouch(down)
        if !down { applyHeldCorrections() }
    }

    /// Drops every decoded bitmap the reader is not looking at. What a memory warning
    /// asks for: the bytes and the measured heights stay, so nothing moves and nothing
    /// has to be fetched again.
    func releaseOffscreenImages() {
        for chapter in placed { chapter.store.releaseImages() }
        refreshVisible()
    }
}
