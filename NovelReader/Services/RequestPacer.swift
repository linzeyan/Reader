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
    /// Seconds between consecutive paced requests to one host, sampled uniformly.
    var gap: ClosedRange<Double>

    /// When the next paced request to each host may start.
    ///
    /// Per host, because the politeness this buys is owed to a *server*. One clock for
    /// the whole app meant a subscription being read waited out a novel download's gap
    /// — two unrelated hosts, neither of which could tell the other was being asked for
    /// anything, taking turns at one or two seconds apiece. That is the cost paid by
    /// every batch that spans sites, and it bought nobody anything.
    ///
    /// Reserved up front rather than derived from "when did the last one happen": two
    /// callers on the same host (a download run and a read-ahead) can be waiting at
    /// once, and computing from the past would let both wake up together — the burst
    /// this exists to prevent.
    private var nextAllowed: [String: ContinuousClock.Instant] = [:]

    init(gap: ClosedRange<Double> = 0.9...2.6) {
        self.gap = gap
    }

    /// Returns once the caller may issue its request to `host`.
    ///
    /// - Parameter host: anything that names a server and is stable across the run —
    ///   a rule's host, a feed address's. Requests are spaced apart only against others
    ///   carrying the same string, so a caller that passed something per-request would
    ///   be asking for no pacing at all.
    func pace(host: String) async {
        let now = ContinuousClock.now
        let start = max(now, nextAllowed[host] ?? now)
        nextAllowed[host] = start + .seconds(Double.random(in: gap))
        guard start > now else { return }
        try? await Task.sleep(until: start, clock: .continuous)
    }

    /// Forgets every reservation, so the next paced request starts immediately.
    /// Used when a run ends: the following run should not inherit a gap earned
    /// by work the user has already cancelled.
    ///
    /// All hosts rather than the one the run was about, and safe because forgetting can
    /// only ever move a request *earlier*: a caller already asleep computed its instant
    /// before this was called, so nothing that is waiting can be woken into a burst.
    func reset() {
        nextAllowed.removeAll()
    }
}
