#if DEBUG
import Foundation
import QuartzCore
import UIKit

/// Main-thread stall probe for the reader, read out of the unified log.
///
/// Rebuilt from the `[DEBUG-ap1]` kit the 2026-08-26 append work was diagnosed with
/// (see `docs/PITFALLS.md`). It is not committed as a permanent fixture and it is not
/// meant to be: it exists for one hunt at a time, and the entry it produces in
/// PITFALLS outlives it. Strip it once the question it was armed for is answered.
///
/// Three pieces, because a stall on its own says nothing about what caused it:
///
/// 1. **Heartbeat gap** — a timer on the main run loop that should fire every few
///    milliseconds. When it does not, the main thread was busy for exactly that long,
///    which is what "the tap did nothing" is made of. Only gaps over a threshold are
///    printed; a healthy screen is silent.
/// 2. **Mutation marks** — every structural change to `loaded` announces itself, so
///    the log has the events a gap could belong to.
/// 3. **`sinceMutation` attribution** — how long before a gap the last mutation was.
///    A gap milliseconds after an append belongs to that append; a gap tens of seconds
///    after one is somebody else's, and that distinction is the whole reason the 1.3.2
///    work found the tap-stall was *not* the append it was assumed to be.
///
/// Read it back with:
/// ```
/// xcrun simctl spawn "iPhone 17" log show --style compact \
///   --predicate 'eventMessage CONTAINS "[DEBUG-ap1]"' --start "$T"
/// ```
///
/// `NSLog` rather than `Logger`: the unified-log predicate above matches on
/// `eventMessage`, and it is what the previous hunts were read with.
enum ReaderProbe {
    /// Armed by `-reader.probe 1`, like every other test switch in this app. Off for
    /// anyone who did not ask, so an ordinary Debug build costs one boolean read.
    static let isArmed = UserDefaults.standard.bool(forKey: "reader.probe")

    /// Gaps below this are not worth a line. A 60fps frame is 16.7ms, so the default is
    /// "missed more than one frame" — the threshold the 2026-08-26 kit used, kept so the
    /// numbers in PITFALLS stay comparable.
    ///
    /// Lowerable with `-reader.probeGap <ms>`, because a threshold answers only the
    /// question it was set for. At 25ms a run of many small transactions is *silent*,
    /// and "no line was printed" reads as "nothing happened" when the truth can be a
    /// third of the main thread spent in work that never once crossed 25ms. The
    /// per-summary `stall=` total below is the honest version of that question; this
    /// knob is for seeing the distribution behind it.
    private static let gapThreshold: Double = {
        let asked = UserDefaults.standard.double(forKey: "reader.probeGap")
        return asked > 0 ? asked : 25
    }()

    /// How often the heartbeat should fire. Fine enough to place a 25ms gap, coarse
    /// enough that the probe is not itself the load.
    private static let beatInterval: TimeInterval = 0.004

    /// A periodic line even when nothing stalls, so a silent log can be told from a
    /// probe that was never armed — and so `bodyRate` has somewhere to be reported.
    private static let summaryInterval: Double = 5

    private static var timer: Timer?
    private static var lastBeat: Double = 0
    private static var lastSummaryAt: Double = 0
    private static var lastMutationAt: Double?
    private static var lastMutation = "none"
    /// Counted rather than printed per call: `body` runs at frame rate when something
    /// in it reads per-frame state, and a line each would be the load.
    private static var bodyCount = 0
    private static var bodiesAtLastSummary = 0
    /// Main-thread time lost to gaps over the threshold, and how many there were.
    ///
    /// The number the individual gap lines cannot give: a stall the reader feels is not
    /// always one long freeze. Many transactions each costing less than a printed line's
    /// worth add up to the same lost thread, and only a total says so.
    private static var stallTotal: Double = 0
    private static var stallCount = 0
    /// Structural mutations, for the "how much is this screen doing at all" question.
    private static var mutationCount = 0
    /// What the reader currently holds, for the "does the window stay capped" question
    /// the memory half of a long session turns on.
    private static var loadedChapters = 0

    /// Starts the heartbeat. Idempotent — the reader can be entered more than once.
    static func start() {
        guard isArmed, timer == nil else { return }
        let now = CACurrentMediaTime()
        lastBeat = now
        lastSummaryAt = now
        let beat = Timer(timeInterval: beatInterval, repeats: true) { _ in tick() }
        // `.common`, not the default mode: a timer in the default mode simply does not
        // fire while a scroll view is tracking a finger, and every one of those silences
        // would be logged as a main-thread stall. The probe would then report its
        // loudest numbers exactly when the reader is dragging, which is nonsense.
        RunLoop.main.add(beat, forMode: .common)
        timer = beat
        // The launch arguments verbatim, so a run can be told from an arm of itself:
        // a switch that silently failed to arrive makes the second arm a copy of the
        // first, and two identical timelines look exactly like "it made no difference".
        let arms = ProcessInfo.processInfo.arguments
            .filter { $0.hasPrefix("-reader.") }
            .joined(separator: " ")
        NSLog("[DEBUG-ap1] armed threshold=%.0fms args{%@}", gapThreshold, arms)
    }

    static func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// One structural change to the loaded window.
    ///
    /// - Parameters:
    ///   - what: the event, short enough to read a thousand of them.
    ///   - loaded: how many chapters `loaded` holds after it. There is no longer a
    ///     second count of "how many of those still hold rows": a chapter is a laid-out
    ///     column now, and the container that would not release rows is gone.
    static func mutated(_ what: String, loaded: Int) {
        guard isArmed else { return }
        let now = CACurrentMediaTime()
        lastMutationAt = now
        lastMutation = what
        loadedChapters = loaded
        mutationCount += 1
        NSLog("[DEBUG-ap1] mutation %@ loaded=%d rss=%dMB", what, loaded, residentMB())
    }

    /// Called from `ReaderView.body`. Cheap on purpose: an increment.
    static func body() {
        guard isArmed else { return }
        bodyCount += 1
    }

    private static func tick() {
        let now = CACurrentMediaTime()
        let gap = (now - lastBeat) * 1000
        lastBeat = now

        if gap >= gapThreshold {
            stallTotal += gap
            stallCount += 1
            // The attribution: a gap right after a mutation is that mutation's, and one
            // long after it is unowned — which is the finding worth having, because an
            // unowned stall means the cost is in row realization rather than in
            // anything this app explicitly did.
            let since = lastMutationAt.map { String(format: "%.0f", (now - $0) * 1000) } ?? "never"
            NSLog(
                "[DEBUG-ap1] gap=%.0fms sinceMutation=%@ after=%@ loaded=%d",
                gap, since, lastMutation, loadedChapters
            )
        }

        let window = now - lastSummaryAt
        guard window >= summaryInterval else { return }
        let bodies = bodyCount - bodiesAtLastSummary
        let rate = Double(bodies) / window
        // Share of the window the main thread spent past the threshold. This is the
        // figure that says whether a screen is usable: individual gaps can all sit
        // under a printed line's threshold while the thread is gone a third of the time.
        let lost = stallTotal / (window * 1000) * 100
        NSLog(
            "[DEBUG-ap1] summary bodyRate=%.1f/s stall=%.0fms/%ds n=%d lost=%.0f%% "
                + "mutations=%d loaded=%d rss=%dMB",
            rate, stallTotal, Int(window), stallCount, lost,
            mutationCount, loadedChapters, residentMB()
        )
        lastSummaryAt = now
        bodiesAtLastSummary = bodyCount
        stallTotal = 0
        stallCount = 0
        mutationCount = 0
    }

    /// Resident size in megabytes — "is the window actually capped" has a memory half,
    /// and a session that grows all evening shows here before it shows anywhere else.
    private static func residentMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Int(info.resident_size / (1024 * 1024))
    }
}
#endif
