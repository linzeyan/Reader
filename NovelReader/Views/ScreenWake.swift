import UIKit

/// The screen's idle timer, and the only place in the app that writes it.
///
/// `isIdleTimerDisabled` is one global flag with several opinions about it — the text
/// reader, the comic reader, and the appearance panel both of them can show over
/// themselves — and the failure it produces is the least visible one this app has: a phone
/// that never sleeps in somebody's pocket. Nothing on screen is wrong, no walk can see it,
/// and it arrives as "this app eats my battery" in a review months later.
///
/// One writer is what makes the trace able to say *why* the screen is being held, and what
/// stops the next caller forgetting to say it.
@MainActor
enum ScreenWake {
    /// Holds the screen awake for as long as either reason lasts.
    ///
    /// Both reasons rather than a boolean, because which one is holding it is the whole
    /// content of the trace line: `keepOn` is the reader's own answer and is meant to last
    /// the session, while `auto` is a page moving on its own and must end when it stops.
    /// A trace showing `why=auto` long after the pages stopped is a leak; the same file
    /// showing `why=keepOn` is a reader who asked for it.
    static func hold(keepOn: Bool, autoScrolling: Bool, trace: TraceLog) {
        switch (keepOn, autoScrolling) {
        case (true, true): apply("keepOn+auto", trace: trace)
        case (true, false): apply("keepOn", trace: trace)
        case (false, true): apply("auto", trace: trace)
        case (false, false): apply(nil, trace: trace)
        }
    }

    /// Lets the screen sleep again. The reader has been left, whatever it was holding it.
    static func release(trace: TraceLog) {
        apply(nil, trace: trace)
    }

    private static func apply(_ why: String?, trace: TraceLog) {
        // Only when it changes. Every caller is an `onChange` or an `onAppear`, and the
        // combination they arrive at is often the one already in force — a reader who turns
        // auto-scroll on and off through an evening would otherwise fill the trace with
        // lines saying the screen is still being held for the same reason as before. This
        // file is read by eye, and a line that changed nothing buries the one that did.
        guard why != held else { return }
        held = why
        UIApplication.shared.isIdleTimerDisabled = why != nil
        trace.note(why.map { "screen awake why=\($0)" } ?? "screen sleeps")
    }

    /// What is holding the screen awake, or nil when nothing is. Mirrors the system flag
    /// because the system will not say which of the two reasons it was set for.
    private static var held: String?
}
