import CoreGraphics
import Foundation

/// Temporary instrumentation for one report: a page turned by tapping in the scrolling
/// reader sometimes lands and then, a moment later, slides forward on its own with nobody
/// touching the glass.
///
/// It does not reproduce offline — the demo library's chapters are either already on disk,
/// so nothing is ever waited for, or point at a host that does not resolve, so nothing ever
/// arrives — and the two mechanisms it could be look identical from the outside:
///
/// - the scroll was **clamped**, because there was not a window's worth of text below the
///   target yet, and the turn completed later when the next chapter made the content tall
///   enough; or
/// - the scroll **landed and then drifted**, because the lazy stack corrected the estimated
///   height of rows it had not built and slid the text under the reader.
///
/// One number tells them apart: where the paragraph the turn aimed at actually sits, from
/// the tap until a few seconds after it, with the chapter loads on the same clock. That is
/// all this records.
///
/// Goes out in a Debug build the reporter runs from Xcode, and **is deleted with the fix**.
/// No `#if DEBUG` for that reason: a conditional would only hide it from whoever comes to
/// remove it.
///
/// No locking of any kind. Every caller — the tap handler, the viewport preference, the
/// chapter append — is already on the main actor, so the ordering these lines are printed
/// in is the ordering they happened in.
enum ReaderTrace {
    /// A page turn was asked for, which is what starts a recording.
    ///
    /// Takes where the target sits *now*, before the scroll: a clamped turn is precisely
    /// one whose target never travels from that starting position to where `anchorY` asked
    /// for, so the first line has to say where it started or the rest cannot be read.
    static func turn(
        zone: String, targetID: String, anchorY: CGFloat, targetMinY: CGFloat?, viewport: CGFloat
    ) {
        opened = CFAbsoluteTimeGetCurrent()
        settledTarget = nil
        lastTarget = nil
        emit(
            "turn zone=\(zone) target=\(targetID) anchorY=\(y(anchorY)) "
                + "targetMinY=\(y(targetMinY)) viewport=\(y(viewport))"
        )
    }

    /// One layout pass's view of the window.
    ///
    /// Silent unless a turn is being recorded. This is called on every layout pass of every
    /// scroll — the ordinary business of reading a book — and printing all of it would bury
    /// the four seconds that are being asked about under an afternoon of them.
    static func frame(
        topChapter: Int, topParagraph: Int, topMinY: CGFloat,
        bottomChapter: Int, bottomParagraph: Int, bottomMaxY: CGFloat,
        targetMinY: CGFloat?, isLoading: Bool, loaded: ClosedRange<Int>?, pendingTarget: String?
    ) {
        guard isRecording else { return }
        emit(
            "\(tag(for: targetMinY)) top=\(topChapter)/\(topParagraph)@\(y(topMinY)) "
                + "bottom=\(bottomChapter)/\(bottomParagraph)@\(y(bottomMaxY)) "
                + "targetMinY=\(y(targetMinY)) touch=\(isTouching ? 1 : 0) "
                + "loading=\(isLoading ? 1 : 0) "
                + "loaded=\(loaded.map { "\($0.lowerBound)...\($0.upperBound)" } ?? "-") "
                + "pending=\(pendingTarget ?? "-")"
        )
    }

    /// Whether a finger is on the text.
    ///
    /// The one thing the first capture could not answer. A turn that lands and then slides
    /// looks, in these numbers, exactly like a turn that lands and is then dragged: both are
    /// smooth travel starting from where the turn stopped. Without this the log cannot say
    /// which, and the reporter should not have to remember.
    static func touch(down: Bool) {
        isTouching = down
    }

    /// `drift` rather than `frame` once the turn has settled and the target moves anyway.
    ///
    /// The report is about movement nobody asked for, and it arrives seconds after the
    /// interesting-looking part of the log has gone quiet. Naming it in the line means the
    /// reporter greps for one word instead of reading four hundred of them.
    private static func tag(for targetMinY: CGFloat?) -> String {
        guard let targetMinY else { return "frame" }
        guard let settled = settledTarget else {
            // Two readings within a point of each other is the turn having stopped. The
            // animation moves tens of points per frame, so it cannot be mistaken for this.
            if let previous = lastTarget, abs(previous - targetMinY) < 1 { settledTarget = targetMinY }
            lastTarget = targetMinY
            return "frame"
        }
        lastTarget = targetMinY
        // Two points of slack: the frames report at sub-pixel precision and a settled
        // reader still jitters by a rounding error.
        return abs(targetMinY - settled) > 2 ? "drift" : "frame"
    }

    /// A chapter load began or ended.
    ///
    /// Recorded whether or not a turn is being watched, unlike `frame`: the load that
    /// finishes in the middle of a turn is usually one the prefetch started before it, and
    /// a timeline that showed only the ending would leave the question of what the reader
    /// was waiting for unanswerable.
    static func chapter(_ event: String, index: Int) {
        emit("chapter \(event) index=\(index)")
    }

    /// When the turn being recorded was asked for. Everything is timed from there rather
    /// than from a wall clock because the question is entirely about the seconds *after* a
    /// tap, and absolute timestamps would make the reader of the log do the subtraction.
    private static var opened = CFAbsoluteTimeGetCurrent()
    private static var isTouching = false
    /// Where the target came to rest, once it has. Nil until the turn stops moving.
    private static var settledTarget: CGFloat?
    private static var lastTarget: CGFloat?

    /// How long a turn is worth watching. Long enough to outlast a chapter arriving over a
    /// slow connection, which is the case the report points at. Costs nothing while the
    /// text is still: the frames are reported when geometry changes, so a settled reader
    /// produces no lines at all — a turn on the demo library, where a chapter is a
    /// five-millisecond disk read, records twelve.
    private static let window: CFAbsoluteTime = 6

    private static var isRecording: Bool { CFAbsoluteTimeGetCurrent() - opened < window }

    private static func emit(_ body: String) {
        let ms = Int(((CFAbsoluteTimeGetCurrent() - opened) * 1000).rounded())
        // Padded so the timings line up down the left edge and the gaps can be seen at a
        // glance; `String(format:)` is avoided because its integer conversions are a
        // width trap on 64-bit.
        let stamp = String(repeating: " ", count: max(0, 5 - String(ms).count)) + String(ms)
        // `NSLog` rather than `print`: both land in the Xcode console the reporter will be
        // reading, but only this one also reaches the unified log, which is the only way
        // to confirm from here that the instrumentation fires at all.
        NSLog("RTRACE \(stamp)ms \(body)")
    }

    /// One decimal place: these are points on a screen, and the second one is noise.
    private static func y(_ value: CGFloat?) -> String {
        guard let value else { return "-" }
        return String(Double((value * 10).rounded()) / 10)
    }
}
