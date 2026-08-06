import Foundation

/// Spaces out the requests the app makes on its own initiative.
///
/// Downloading a book and reading ahead are both the app deciding to fetch
/// pages nobody asked for right now. These hosts sit behind a WAF, and a burst
/// of requests — or worse, a burst at a metronome-perfect interval — is exactly
/// the shape that gets an IP blocked. So the gap is randomised: a constant
/// 1200ms is itself a fingerprint, while a human clicking through chapters
/// never produces one.
///
/// Interactive work does not come through here. Making someone wait two seconds
/// after they tapped something would be trading their time for politeness they
/// did not ask for; the point is only to keep *unattended* traffic unremarkable.
@MainActor
final class RequestPacer {
    /// Seconds between consecutive paced requests, sampled uniformly.
    var gap: ClosedRange<Double>

    /// When the next paced request may start. Reserved up front rather than
    /// derived from "when did the last one happen": two callers (a download run
    /// and a read-ahead) can be waiting at once, and computing from the past
    /// would let both wake up together — the burst this exists to prevent.
    private var nextAllowed: ContinuousClock.Instant = .now

    init(gap: ClosedRange<Double> = 0.9...2.6) {
        self.gap = gap
    }

    /// Returns once the caller may issue its request.
    func pace() async {
        let now = ContinuousClock.now
        let start = max(now, nextAllowed)
        nextAllowed = start + .seconds(Double.random(in: gap))
        guard start > now else { return }
        try? await Task.sleep(until: start, clock: .continuous)
    }

    /// Forgets the reservation, so the next paced request starts immediately.
    /// Used when a run ends: the following run should not inherit a gap earned
    /// by work the user has already cancelled.
    func reset() {
        nextAllowed = .now
    }
}
