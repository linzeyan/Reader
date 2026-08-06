import XCTest
@testable import NovelReader

/// The pacer is what keeps unattended fetching from looking like a scraper, so
/// "it returned immediately" and "both waiters woke together" are the two
/// failures worth pinning. Gaps here are tiny; only their existence is checked.
@MainActor
final class RequestPacerTests: XCTestCase {
    func testTheFirstRequestIsNotDelayed() async {
        let pacer = RequestPacer(gap: 0.5...0.5)
        let start = ContinuousClock.now
        await pacer.pace()
        XCTAssertLessThan(
            ContinuousClock.now - start, .milliseconds(200),
            "Nothing has been fetched yet, so there is nothing to be polite about"
        )
    }

    func testConsecutiveRequestsAreSpacedApart() async {
        let pacer = RequestPacer(gap: 0.2...0.2)
        await pacer.pace()
        let start = ContinuousClock.now
        await pacer.pace()
        XCTAssertGreaterThan(ContinuousClock.now - start, .milliseconds(100))
    }

    /// Two callers wait at once whenever a download run and the reader's
    /// read-ahead overlap. If both computed their wait from "when did the last
    /// request happen", both would wake at the same instant — a burst of two,
    /// produced by the code meant to prevent bursts.
    func testTwoWaitersDoNotWakeTogether() async {
        let pacer = RequestPacer(gap: 0.2...0.2)
        await pacer.pace()

        async let first: ContinuousClock.Instant = { await pacer.pace(); return .now }()
        async let second: ContinuousClock.Instant = { await pacer.pace(); return .now }()
        let instants = await [first, second].sorted { $0 < $1 }

        XCTAssertGreaterThan(
            instants[1] - instants[0], .milliseconds(100),
            "The second waiter must be queued behind the first, not beside it"
        )
    }

    /// A cancelled run must not make the next one inherit its reserved slot.
    func testResetClearsTheReservation() async {
        let pacer = RequestPacer(gap: 5...5)
        await pacer.pace()
        pacer.reset()
        let start = ContinuousClock.now
        await pacer.pace()
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(200))
    }
}
