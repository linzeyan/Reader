#if DEBUG
import Foundation
import QuartzCore

/// One open question in the comic reader, instrumented until it is answered.
///
/// A hunt kit like `ColumnProbe`, and meant to be deleted the same way — see PITFALLS
/// 2026-08-28.
///
/// **`[DEBUG-zoom]` — double-tapping back out moves the page.** Everything that can move
/// a reader is logged with the same five numbers, so the step that moved them is the line
/// where `reading` changes: the zoom itself, a content resize, a `shift`, an offset set by
/// hand, or a correction that was held during the magnification and let go after it.
/// `reading` is the reading offset in unzoomed content points — the only number that
/// should be the same before and after a zoom, because zooming changes how much of a page
/// fills the screen and nothing about where the reader is in the book.
///
/// The `[DEBUG-page]` half is gone, and its going is part of the method: it answered its
/// question, and while it was still here it wrote several hundred lines per second into
/// the same console — enough that a device log pasted back for the zoom contained no zoom
/// in it at all. A probe that drowns the one it is next to is worse than no probe.
///
/// Unconditional in DEBUG rather than armed by a launch argument: whoever is reading this
/// has the device in one hand and the console in the other. Throttled where it is called
/// per frame.
///
/// ```
/// log stream --predicate 'eventMessage CONTAINS "[DEBUG-zoom]"'
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
        // Fine enough to see the path a zoom animation takes rather than only its ends: a
        // third of a second of animation at 0.1s was three samples, and the question is
        // where inside it the reader moves.
        guard now - lastZoomStep >= 0.03 else { return }
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

    /// Somebody setting the offset by hand, which is the one way of moving the reader that
    /// nothing else here would show. `asked` is what was requested and `landed` is what the
    /// scroll view took after clamping — a difference between them is the content being
    /// shorter than the position, which is its own kind of jump.
    static func movedTo(asked: CGFloat, landed: CGFloat, animated: Bool, zoom: CGFloat) {
        NSLog(
            "[DEBUG-zoom] set asked=%.1f landed=%.1f animated=%d zoom=%.3f",
            asked, landed, animated ? 1 : 0, zoom
        )
    }
}
#endif
