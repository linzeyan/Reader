import XCTest
@testable import NovelReader

/// A site that only serves signed-in readers is a wall the app cannot climb, and
/// these tests pin the three decisions that follow from that.
///
/// Recognising the wall, because on the site this exists for the gate is a
/// redirect fired from `<head>` — by the time the page settles there is nothing
/// left of the book that was asked for, and the landed address is the only
/// evidence. Refusing a wall that points somewhere else, because a rule file is
/// something users pass around and this one field decides where a full-screen
/// browser opens with a keyboard in front of it. And treating both walls alike
/// afterwards, because a screen that knows about human checks but not sign-ins
/// swallows the sign-in and shows the reader a missing-title error instead.
final class SignInGateTests: XCTestCase {

    /// A comic source shaped like 8comic: the gate bounces to a members page, and
    /// signing in happens on the site's own form.
    private static func ruleJSON(signIn: String?) -> String {
        """
        {
          "id": "gated",
          "name": "Gated",
          "host": "www.gated.test",
          "kind": "comic",
          "urls": {
            "book": "https://www.gated.test/html/{bookId}.html",
            "catalog": "https://www.gated.test/html/{bookId}.html",
            "chapter": "https://www.gated.test/online/new-{bookId}.html?ch={chapterId}"
          },
          "idPatterns": { "bookId": "/html/(\\\\d+)", "chapterId": "[?&]ch=(\\\\d+)" },
          "search": null,
          "book": { "title": { "meta": "name" } },
          "catalog": { "container": "#chapters", "linkSelector": "a", "order": "ascending" },
          "images": { "strategies": [{ "type": "dom", "selector": "img", "attributes": ["src"] }] }
          \(signIn.map { ",\n  \"signIn\": \($0)" } ?? "")
        }
        """
    }

    private static let ownHost = """
    { "landsOn": "/member/404.html", "url": "https://www.gated.test/member/login" }
    """

    private func decode(_ json: String) throws -> SiteRule {
        try JSONDecoder().decode(SiteRule.self, from: Data(json.utf8))
    }

    // MARK: - Recognising the wall

    /// Most sites never ask anyone to sign in, and every rule file written before
    /// this field existed says nothing about it. Absent has to mean "no gate", not
    /// a decoding error.
    func testARuleThatSaysNothingAboutSigningInHasNoGate() throws {
        XCTAssertNil(try decode(Self.ruleJSON(signIn: nil)).signIn)
    }

    func testTheGateIsRecognisedFromTheAddressTheSiteLandsOn() throws {
        let signIn = try XCTUnwrap(try decode(Self.ruleJSON(signIn: Self.ownHost)).signIn)

        XCTAssertTrue(signIn.turnsAway(URL(string: "https://www.gated.test/member/404.html")))
        // The site appends its own query on the way out on some paths; the match is
        // a substring precisely so that does not have to be predicted.
        XCTAssertTrue(signIn.turnsAway(URL(string: "https://www.gated.test/member/404.html?r=103")))
        // The page that was actually asked for is not a gate.
        XCTAssertFalse(signIn.turnsAway(URL(string: "https://www.gated.test/html/5946.html")))
        // A page that merely *links* to the members area is not one either — the
        // test is where the browser ended up, not what the address resembles.
        XCTAssertFalse(signIn.turnsAway(URL(string: "https://www.gated.test/member/login")))
    }

    /// A fetch that landed nowhere failed for some other reason. Calling that a
    /// sign-in gate would send the reader to type a password at a site that never
    /// asked for one, which is a far worse answer than the network error it is.
    func testAFetchThatLandedNowhereIsNotAGate() throws {
        let signIn = try XCTUnwrap(try decode(Self.ruleJSON(signIn: Self.ownHost)).signIn)
        XCTAssertFalse(signIn.turnsAway(nil))
    }

    // MARK: - Refusing a wall that points elsewhere

    /// The reason this check exists at all: rule files circulate between users, and
    /// this field is the one place a rule names a page the app will show full
    /// screen, with no address bar and a password field on it. A rule for a site
    /// you trust must not be able to open someone else's login form.
    @MainActor
    func testASignInAddressOnAnotherSiteIsRefused() throws {
        let elsewhere = """
        { "landsOn": "/member/404.html", "url": "https://www.lookalike.test/member/login" }
        """
        XCTAssertThrowsError(
            try makeStore().importRule(data: Data(Self.ruleJSON(signIn: elsewhere).utf8))
        ) { error in
            guard case SiteStore.ImportError.malformed(let detail) = error else {
                return XCTFail("expected a malformed-rule refusal, got \(error)")
            }
            XCTAssertTrue(
                detail.contains("www.gated.test"),
                "the refusal has to name the host the rule is for, or it is not actionable: \(detail)"
            )
        }
    }

    /// And the whole point of the check is that the legitimate case still installs.
    @MainActor
    func testASignInOnTheSitesOwnHostImports() throws {
        let rule = try makeStore().importRule(data: Data(Self.ruleJSON(signIn: Self.ownHost).utf8))
        XCTAssertEqual(rule.signIn?.landsOn, "/member/404.html")
        XCTAssertEqual(rule.signIn?.signInURL?.absoluteString, "https://www.gated.test/member/login")
    }

    /// An address that is not an address is refused for the same reason: there
    /// would be nowhere to send the reader, so the gate could only ever be a dead
    /// end reached at the worst possible moment.
    @MainActor
    func testAnUnparseableSignInAddressIsRefused() throws {
        let broken = """
        { "landsOn": "/member/404.html", "url": "not a url at all" }
        """
        XCTAssertThrowsError(
            try makeStore().importRule(data: Data(Self.ruleJSON(signIn: broken).utf8))
        )
    }

    // MARK: - Treating both walls alike

    /// Every screen that fetches asks this one question to decide whether to keep a
    /// failure inline or hand it up to the shell, which owns the only web view a
    /// sheet can show. Both walls have to answer yes and ordinary failures no —
    /// a chapter that timed out must not throw a browser at the reader.
    @MainActor
    func testOnlyTheWallsTheUserCanClearReachTheShell() {
        let url = URL(string: "https://www.gated.test/member/login")!
        XCTAssertTrue(WebFetcher.needsTheUser(WebFetcher.FetchError.challengePresented(url)))
        XCTAssertTrue(WebFetcher.needsTheUser(WebFetcher.FetchError.signInRequired(url)))

        XCTAssertFalse(WebFetcher.needsTheUser(WebFetcher.FetchError.timedOut))
        XCTAssertFalse(WebFetcher.needsTheUser(WebFetcher.FetchError.navigationFailed("offline")))
        XCTAssertFalse(WebFetcher.needsTheUser(BookService.ServiceError.noTitle))
    }

    @MainActor
    private func makeStore() -> SiteStore {
        SiteStore(
            directory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("NovelReaderTests-\(UUID().uuidString)")
        )
    }
}
