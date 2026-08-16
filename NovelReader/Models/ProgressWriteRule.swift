import Foundation

/// When a reading position is worth writing down.
///
/// Reading moves the position several times a minute and the database is where it has to
/// end up, so the two extremes are both wrong: a write per paragraph is a write per flick
/// of a thumb, and writing only when the reader closes the book loses everything the
/// moment iOS reclaims the process — which is exactly what "it only remembered the
/// chapter I opened" was.
///
/// So there are two occasions. Leaving one — a chapter change, the app going to the
/// background, the reader closing the book — always writes, because it may be the last
/// moment anything is asked. Simply reading writes at most once every few seconds, and
/// only when the position has actually moved.
///
/// A separate, pure type because it is the only part of this that can be tested without a
/// simulator: `ReaderModel` is bound to `AppEnvironment`, which owns a web view, a
/// database and a download queue.
struct ProgressWriteRule {
    enum Occasion {
        /// The reader is still reading and the position moved under them.
        case reading
        /// A moment this position may be the last one seen.
        case leaving
    }

    /// Long enough that a steady reader writes a handful of times an hour, short enough
    /// that a process killed in the background loses a few paragraphs rather than a
    /// chapter. It is only ever an upper bound on what is lost: every way of *leaving*
    /// writes immediately.
    static let interval: TimeInterval = 5

    private var written: (position: ReadingPosition, at: Date)?

    /// - Returns: whether to write, recording that the write happened when it says yes.
    ///
    /// A position identical to the last one written is refused on both occasions, not
    /// merely throttled. The write stamps `Book.updatedAt`, which is what iCloud settles
    /// merges by, so re-writing an unchanged position would let this device win a race
    /// against another one that has genuinely read further.
    mutating func shouldWrite(
        _ position: ReadingPosition, occasion: Occasion, now: Date = Date()
    ) -> Bool {
        if let written {
            guard written.position != position else { return false }
            if occasion == .reading, now.timeIntervalSince(written.at) < Self.interval {
                return false
            }
        }
        written = (position, now)
        return true
    }
}
