#if DEBUG
import Foundation
import QuartzCore
import UIKit

/// Two open questions in the comic reader, instrumented until they are answered.
///
/// A hunt kit like `ColumnProbe`, and meant to be deleted the same way — see PITFALLS
/// 2026-08-28. Both questions have survived a round of reading the code and a round of
/// fixing what the reading suggested, which is the point at which the device has to say
/// what is actually happening rather than the code saying what should be.
///
/// **`[DEBUG-zoom]` — double-tapping back out moves the page.** Everything that can move
/// a reader is logged with the same five numbers, so the step that moved them is the line
/// where `reading` changes: the zoom itself, a content resize, a `shift`, or a correction
/// that was held during the magnification and let go after it. `reading` is the reading
/// offset in unzoomed content points — the only number that should be the same before and
/// after a zoom, because zooming changes how much of a page fills the screen and nothing
/// about where the reader is in the book.
///
/// **`[DEBUG-page]` — the retry button on a page that would not load is not there.**
/// Three places, because the button needs all three to be true: the store has to record
/// the failure, the coordinator has to pass `failed` into the window it draws, and the
/// page view has to turn that into a visible button somewhere on screen. Whichever of the
/// three is missing from the log is the one that is wrong.
///
/// Unconditional in DEBUG rather than armed by a launch argument: whoever is reading this
/// has the device in one hand and the console in the other. Throttled where it is called
/// per frame.
///
/// ```
/// log stream --predicate 'eventMessage CONTAINS "[DEBUG-zoom]" OR eventMessage CONTAINS "[DEBUG-page]"'
/// ```
enum ComicProbe {

    // MARK: - Zoom

    /// The scroll view's whole state, under a label saying what just happened to it.
    ///
    /// - Parameters:
    ///   - reading: `contentOffset.y / zoomScale`, the reading position.
    ///   - offset: the raw `contentOffset.y`, which is in magnified points.
    ///   - content: `contentSize.height`, also magnified.
    ///   - laid: the content view's own unzoomed height, which is what the columns add up
    ///     to. `content` should be this times `zoom`, and the moment it is not is the
    ///     moment the two disagree about where anything is.
    static func zoom(
        _ step: String, reading: CGFloat, offset: CGFloat, zoom: CGFloat,
        content: CGFloat, laid: CGFloat, bounds: CGFloat
    ) {
        NSLog(
            "[DEBUG-zoom] %@ reading=%.1f offset=%.1f zoom=%.3f content=%.1f laid=%.1f bounds=%.1f",
            step, reading, offset, zoom, content, laid, bounds
        )
    }

    /// The same, throttled, for the callers that run at frame rate.
    static func zoomStep(
        _ step: String, reading: CGFloat, offset: CGFloat, zoom: CGFloat,
        content: CGFloat, laid: CGFloat, bounds: CGFloat
    ) {
        let now = CACurrentMediaTime()
        guard now - lastZoomStep >= 0.1 else { return }
        lastZoomStep = now
        self.zoom(
            step, reading: reading, offset: offset, zoom: zoom,
            content: content, laid: laid, bounds: bounds
        )
    }

    private static var lastZoomStep: Double = 0

    /// A deliberate move of the content under the reader. `by` is in unzoomed points;
    /// what actually happened to `contentOffset.y` is `before`→`after`.
    static func shifted(by amount: CGFloat, before: CGFloat, after: CGFloat, zoom: CGFloat) {
        NSLog(
            "[DEBUG-zoom] shift by=%.1f offset %.1f->%.1f zoom=%.3f",
            amount, before, after, zoom
        )
    }

    /// The content growing or shrinking, which moves everything below the change.
    static func resized(from old: CGFloat, to new: CGFloat, zoom: CGFloat, offset: CGFloat) {
        NSLog(
            "[DEBUG-zoom] resize laid %.1f->%.1f zoom=%.3f offset=%.1f", old, new, zoom, offset
        )
    }

    /// A page's real height arriving. `held` means it was queued instead of applied,
    /// because the reader's finger was down or a magnification was in flight.
    static func correction(
        page: Int, from: CGFloat, to: CGFloat, above: Bool, held: Bool, reading: CGFloat
    ) {
        NSLog(
            "[DEBUG-zoom] correct page=%d h %.1f->%.1f above=%d held=%d reading=%.1f",
            page, from, to, above ? 1 : 0, held ? 1 : 0, reading
        )
    }

    /// One line per step of what a finished magnification lets go of, so the step that
    /// moves the reader is visible as the line after which `reading` changed.
    static func magnification(_ step: String, held: Int, reading: CGFloat) {
        NSLog("[DEBUG-zoom] mag.%@ held=%d reading=%.1f", step, held, reading)
    }

    // MARK: - The retry button

    /// The store recording that a page will not come. If this line is absent, nothing
    /// below it can be right — the page is still believed to be loading.
    static func pageFailed(_ page: Int, of pages: Int, error: any Error) {
        NSLog("[DEBUG-page] failed page=%d/%d %@", page, pages, String(describing: error))
    }

    static func pageRetried(_ page: Int, hadBytes: Bool, width: CGFloat?) {
        NSLog(
            "[DEBUG-page] retry page=%d bytes=%d width=%.1f",
            page, hadBytes ? 1 : 0, width ?? -1
        )
    }

    /// How a chapter opened, which decides what every line after it means. A chapter read
    /// off the device fails a page the instant it opens the marker; one read online waits
    /// for the network to give up first, and a black page with no button is that wait.
    /// `missing` is the gaps a download left behind.
    static func opened(chapter: Int, pages: Int, source: String, missing: [Int]) {
        NSLog(
            "[DEBUG-page] open ch=%d pages=%d source=%@ missing=%@",
            chapter, pages, source, list(missing)
        )
    }

    /// What the coordinator handed the scroll view. `failed` is the pages it marked,
    /// `known` is every page the store considers failed — a page in `known` but not in
    /// `visible` is one whose button exists nowhere on screen — and `pending` is every
    /// request still out. A visible page in none of the three is one nothing is doing
    /// anything about; a visible page in `pending` alone is the black rectangle the reader
    /// is waiting on, and how long it stays there is how long the button takes to appear.
    static func window(
        chapter: Int, visible: [Int], failed: [Int], known: [Int], pending: [Int]
    ) {
        guard !failed.isEmpty || !known.isEmpty || !pending.isEmpty else { return }
        let now = CACurrentMediaTime()
        guard now - lastWindow >= 0.25 else { return }
        lastWindow = now
        NSLog(
            "[DEBUG-page] window ch=%d visible=%@ failed=%@ known=%@ pending=%@",
            chapter, list(visible), list(failed), list(known), list(pending)
        )
    }

    private static var lastWindow: Double = 0

    /// The page view's own account. `button` is whether it made the button visible, and
    /// `frame` is where it put it — in the page's coordinates, which for a page taller
    /// than the screen may be nowhere the reader is looking.
    static func drew(number: Int, failed: Bool, hasImage: Bool, page: CGRect, button: CGRect) {
        guard failed else { return }
        NSLog(
            "[DEBUG-page] drew page=%d image=%d pageFrame=%.0fx%.0f button=(%.0f,%.0f %.0fx%.0f)",
            number, hasImage ? 1 : 0, page.width, page.height,
            button.minX, button.minY, button.width, button.height
        )
    }

    private static func list(_ pages: [Int]) -> String {
        pages.isEmpty ? "-" : pages.map(String.init).joined(separator: ",")
    }
}
#endif
