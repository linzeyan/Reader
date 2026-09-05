import XCTest
@testable import NovelReader

/// What this app looks like from the other end of the connection.
///
/// Both of these exist because these hosts sit behind a WAF that scores how plausible a
/// client is, and both were places the app was volunteering evidence against itself.
final class FetchIdentityTests: XCTestCase {
    // MARK: - User agent

    /// The version has to come from the engine, not from a constant. WebKit's TLS and
    /// HTTP/2 handshakes are version-specific, so a client calling itself an older Safari
    /// than the one it shakes hands as is an inconsistency a WAF can measure — which is
    /// exactly what the fixed `17_0` string this replaces was doing on an 18_7 engine.
    func testTheUserAgentCarriesTheEnginesOwnVersion() throws {
        let webKitDefault = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
        let agent = try XCTUnwrap(WebFetcher.safariUserAgent(matching: webKitDefault))
        XCTAssertTrue(agent.contains("iPhone OS 18_7"), agent)
        XCTAssertTrue(agent.contains("Version/18.0"), agent)
        XCTAssertFalse(agent.contains("17_0"), "no constant may outlive the engine it named")
    }

    /// The two tokens a `WKWebView` leaves out are what make a site serve its phone
    /// layout rather than an embedded-view one, and mobile Safari puts them in a
    /// particular order — `Version/` ahead of `Mobile/`, `Safari/` last.
    func testTheUserAgentIsShapedLikeMobileSafari() throws {
        let agent = try XCTUnwrap(WebFetcher.safariUserAgent(
            matching: "Mozilla/5.0 (iPhone; CPU iPhone OS 26_1 like Mac OS X) "
                + "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/23A340"
        ))
        let version = try XCTUnwrap(agent.range(of: "Version/26.0"))
        let mobile = try XCTUnwrap(agent.range(of: "Mobile/23A340"))
        XCTAssertLessThan(version.lowerBound, mobile.lowerBound)
        XCTAssertTrue(agent.hasSuffix("Safari/604.1"), agent)
    }

    /// An iPad announces itself differently, and the rules are written against the phone
    /// layout. Claiming the phone is safe — it is the same engine making the same
    /// handshake either way — but the version still has to be the real one.
    func testAnIPadIsStillDescribedAsAPhoneAtItsOwnVersion() throws {
        let agent = try XCTUnwrap(WebFetcher.safariUserAgent(
            matching: "Mozilla/5.0 (iPad; CPU OS 18_7 like Mac OS X) "
                + "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
        ))
        XCTAssertTrue(agent.contains("iPhone; CPU iPhone OS 18_7"), agent)
        XCTAssertTrue(agent.contains("Version/18.0"), agent)
    }

    /// A default this does not recognise is left alone rather than replaced by a guess.
    /// An unknown user agent is at least consistent with the engine sending it, which is
    /// the whole point of asking the engine in the first place.
    func testAnUnfamiliarDefaultIsLeftAlone() {
        XCTAssertNil(WebFetcher.safariUserAgent(matching: "SomeOtherEngine/1.0"))
        XCTAssertNil(
            WebFetcher.safariUserAgent(
                matching: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) "
                    + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 "
                    + "Safari/604.1"
            ),
            "an agent that is already Safari's must not be completed twice"
        )
    }

    // MARK: - Referrer

    /// Reading chapter after chapter is what this app mostly does, and a browser doing it
    /// sends the page it came from. Every load here is programmatic and the previous page
    /// has been replaced by `about:blank` by then, so without this each chapter is a cold,
    /// referrer-less hit on a deep URL — the shape a WAF reads as a crawler.
    func testTheNextChapterSaysWhereItCameFrom() {
        let previous = URL(string: "https://www.69shuba.com/txt/12345/1001")!
        let next = URL(string: "https://www.69shuba.com/txt/12345/1002")!
        let request = WebFetcher.request(for: next, comingFrom: previous)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Referer"), previous.absoluteString
        )
    }

    /// The one way this could do harm. A referrer carried across sites is not politeness —
    /// it is telling one site what the reader was doing on another.
    func testAReferrerNeverCrossesSites() {
        let request = WebFetcher.request(
            for: URL(string: "https://www.69shuba.com/txt/12345/1002")!,
            comingFrom: URL(string: "https://czbooks.net/n/abcdef")!
        )
        XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
    }

    func testTheFirstPageOfASessionHasNowhereToHaveComeFrom() {
        let url = URL(string: "https://www.69shuba.com/book/12345.htm")!
        XCTAssertNil(
            WebFetcher.request(for: url, comingFrom: nil).value(forHTTPHeaderField: "Referer")
        )
        XCTAssertNil(
            WebFetcher.request(for: url, comingFrom: url).value(forHTTPHeaderField: "Referer"),
            "a page is not its own referrer"
        )
    }
}
