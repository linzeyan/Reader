import XCTest
@testable import NovelReader

/// The fetch queue is serialised through one web view, so a single call that
/// never returns stops every later fetch in the app — downloads, catalog
/// refreshes, search, all of it — until relaunch.
///
/// This is not hypothetical: deriving a rule for a site whose search box opens
/// an overlay instead of navigating hit exactly that, and the run had to be
/// killed. The timeout existed but could not fire, because a checked
/// continuation ignores cancellation while a task group waits for every child.
@MainActor
final class WebFetcherTimeoutTests: XCTestCase {
    func testNavigationThatNeverArrivesTimesOut() async throws {
        let fetcher = WebFetcher()
        do {
            // A trigger that does nothing at all: WebKit will never report a
            // navigation, so only the timeout can end this.
            try await fetcher.navigate(timeout: .milliseconds(200), in: fetcher.webView) {}
            XCTFail("a navigation that never happens must not succeed")
        } catch let error as WebFetcher.FetchError {
            guard case .timedOut = error else {
                return XCTFail("expected a timeout, got \(error)")
            }
        }
    }

    /// The part that actually matters: the fetcher is still usable afterwards.
    /// A timeout that leaves a continuation armed would make the *next* call
    /// resume against stale state.
    func testFetcherStillWorksAfterATimeout() async throws {
        let fetcher = WebFetcher()
        for attempt in 1...3 {
            do {
                try await fetcher.navigate(timeout: .milliseconds(150), in: fetcher.webView) {}
                XCTFail("attempt \(attempt) should have timed out")
            } catch {
                // Expected — what is being checked is that we get here at all.
            }
        }
    }
}
