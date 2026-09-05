import Foundation
import WebKit

/// Loads pages with a real WebKit engine and extracts structured data from them.
///
/// Why a WKWebView instead of URLSession: the target sites sit behind Cloudflare.
/// Plain URLSession requests are answered with 403 + `cf-mitigated: challenge`
/// regardless of headers, because the non-interactive challenge requires an
/// actual JS engine. WebKit clears it transparently and keeps `cf_clearance` in
/// the shared cookie store, so every later request rides on it.
///
/// The same instance is used headless *and* surfaced: when a site escalates to
/// an interactive challenge we hand `webView` to the UI so the user can complete
/// it themselves. Nothing here attempts to solve or evade a challenge.
///
/// @MainActor because WKWebView is main-thread-only. Loads are serialised — one
/// web view can only display one page at a time, and hammering a challenged host
/// is exactly what we must not do.
/// Where the user agent actually lives.
///
/// Outside `WebFetcher` because that type is `@MainActor` and this string is read wherever
/// a request is built — including the picture fetches that deliberately run off it. A
/// main-actor static would turn every one of those into an `await` for a constant.
private enum FetchIdentity {
    static var userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
}

@MainActor
final class WebFetcher: NSObject {
    enum FetchError: LocalizedError {
        /// The host demanded an interactive challenge. The caller must stop
        /// batching and present `webView` so a human can complete it.
        case challengePresented(URL)
        /// The site turned a signed-out reader away. The associated URL is the
        /// site's own sign-in page, which the web view has already been taken to —
        /// the caller presents it the same way it presents a challenge.
        case signInRequired(URL)
        case navigationFailed(String)
        case timedOut
        case extractionFailed(String)
        /// The sandboxed web view an imported document is read in could not be
        /// built, because its block-everything content rules would not compile.
        ///
        /// Reading the document anyway is not an option: without those rules the
        /// file's own `<img>` and `<link>` tags reach the network and tell their
        /// author who opened the book and from which address. An import that
        /// cannot be isolated has to fail.
        case documentIsolationUnavailable

        var errorDescription: String? {
            switch self {
            case .challengePresented: return String(localized: "fetch.error.challenge")
            case .signInRequired: return String(localized: "fetch.error.signIn")
            case .navigationFailed(let m): return m
            case .timedOut: return String(localized: "fetch.error.timeout")
            case .extractionFailed(let m): return m
            case .documentIsolationUnavailable: return String(localized: "fetch.error.isolation")
            }
        }
    }

    /// Whether an error is one only the user can clear, by doing something in the
    /// browser themselves — a human check, or signing in.
    ///
    /// Screens ask this to decide whether to keep a failure inline or hand it up
    /// to the shell, which owns the one web view a sheet can show. Written once
    /// because the answer has to be the same everywhere: a screen that knows about
    /// challenges but not sign-ins swallows the sign-in silently, and the reader
    /// gets an error message about a missing title instead of a password field.
    /// `nonisolated` because it reads nothing but the error it is handed, and the
    /// screens that ask are not all on the main actor when they ask.
    nonisolated static func needsTheUser(_ error: any Error) -> Bool {
        switch error {
        case FetchError.challengePresented, FetchError.signInRequired: return true
        default: return false
        }
    }

    /// Hosted off-screen by the app shell, and re-parented into a sheet when a
    /// challenge needs the user. A web view with no window never finishes
    /// layout-dependent work, so it must be in the hierarchy either way.
    let webView: WKWebView

    private var navigationContinuation: CheckedContinuation<Void, Error>?
    /// Which web view the armed continuation belongs to. Navigation events from any
    /// other one are ignored: an imported document that tries to navigate after its
    /// text has been extracted must not resume — or fail — a fetch that started
    /// afterwards.
    private var navigatingView: WKWebView?
    /// Whether the navigation being waited on has actually taken over the web view.
    ///
    /// Load it and look, and for the first moments you are looking at the *previous*
    /// page — which on this web view is whatever the last fetch left behind, and is
    /// perfectly capable of being complete, full of text, and entirely the wrong
    /// document. Nothing that reads the page while a navigation is in flight may do
    /// so before this is true.
    private var navigationHasCommitted = false
    /// Serialises fetches: each waits for the previous one to finish.
    private var queueTail: Task<Void, Never> = Task {}
    /// The isolated web view imported files are loaded into. See `extract`.
    ///
    /// Not private so a test can check how it is configured. `WKUserContentController`
    /// has no getter for the rule lists attached to it, so "the document really was
    /// sandboxed" can only be asserted from the store and the scripting flag — plus
    /// the fact that `extract` throws when the rule list is missing.
    private(set) var importView: WKWebView?

    override init() {
        let config = WKWebViewConfiguration()
        // Persistent store: cf_clearance and the site's own cookies must survive
        // relaunch, otherwise every cold start re-triggers a challenge.
        //
        // Read here rather than as a default argument: a default argument is
        // evaluated outside the actor, and `.default()` is main-actor isolated.
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // Nothing this web view loads is ever *watched*. Both flags are about the one
        // way a page it is only reading can take the screen: with inline playback off
        // — the iPhone default — a `<video>` that starts playing is put up full screen
        // over whatever the reader was doing, and these sites carry video ads. That is
        // the black player with an X in the corner that appeared in the middle of a
        // comic. Inline keeps any such video inside a view nobody can see, and the
        // user-action requirement means it should not have started at all.
        // `blockMediaIfNeeded` is the belt to this pair of braces.
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        super.init()
        webView.navigationDelegate = self
        // Identify as mobile Safari so sites serve their phone layout, which is
        // lighter and has the selectors our rules are written against. Completed from
        // this engine's own default before the first fetch — see `adoptUserAgentIfNeeded`.
        webView.customUserAgent = Self.mobileSafariUserAgent
    }

    /// The identity every request this app makes goes out under: page loads here, and the
    /// `URLSession` fetches that shadow them (see `ImageFetcher`).
    ///
    /// A variable rather than a constant because the version in it has to be *this*
    /// engine's. WebKit's TLS and HTTP/2 handshakes are version-specific, and a client
    /// that shakes hands as one Safari while calling itself another two years older is
    /// exactly the inconsistency a WAF scores against — the fixed string this replaces
    /// claimed `17_0` on an engine whose own default said `18_7`, which is a free
    /// contribution to a bot score on every request. Set once per session, before any
    /// page is loaded; the value below is what stands in until then and on a device whose
    /// default is a shape `safariUserAgent(matching:)` does not recognise.
    ///
    /// `nonisolated` because the identity this app fetches under is not the web view's
    /// business: every request that shadows a page load sends it too, and the one that
    /// downloads an article's pictures runs off the main actor.
    nonisolated static var mobileSafariUserAgent: String { FetchIdentity.userAgent }

    /// Mobile Safari's user agent for the engine that produced `webKitDefault`.
    ///
    /// A `WKWebView` announces itself as an embedded view: its default names the OS
    /// version it actually is, and omits the `Version/…` and `Safari/…` tokens that say
    /// "browser". Some of these sites serve a thinner page to it, which is why they were
    /// ever added. This puts them back where mobile Safari puts them — `Version/` before
    /// `Mobile/`, `Safari/` last — around the version WebKit itself reported.
    ///
    /// Still the iPhone shape on an iPad, deliberately: the rules are written against the
    /// phone layout, and the handshake an iPad makes is the same engine's either way, so
    /// the claim stays consistent with what a WAF can measure.
    ///
    /// - Returns: nil when the default is not a shape this knows how to complete, in
    ///   which case WebKit's own is used unchanged — an unrecognised default is at least
    ///   an internally consistent one, which is the whole point of asking.
    nonisolated static func safariUserAgent(matching webKitDefault: String) -> String? {
        guard !webKitDefault.contains("Version/"),
              let osRange = webKitDefault.range(of: #"OS \d+(_\d+)*"#, options: .regularExpression)
        else { return nil }
        let release = webKitDefault[osRange].dropFirst(3)
        let major = release.prefix { $0.isNumber }
        guard !major.isEmpty else { return nil }
        let build = webKitDefault.range(of: #"Mobile/[0-9A-Za-z]+"#, options: .regularExpression)
            .map { String(webKitDefault[$0]) } ?? "Mobile/15E148"
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(release) like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(major).0 \(build) Safari/604.1"
    }

    /// Asks the engine what it calls itself, and completes that into Safari's own.
    ///
    /// Once per session, from inside `serialised`, so it is settled before the first page
    /// this fetcher ever loads — and so a probe that needs the web view cannot race one.
    /// A failed probe leaves the standing value: this is a refinement of an identity that
    /// already works, not something a fetch should fail over.
    private func adoptUserAgentIfNeeded() async {
        guard !hasAdoptedUserAgent else { return }
        hasAdoptedUserAgent = true
        let probed = try? await webView.evaluateJavaScript("navigator.userAgent") as? String
        guard let webKitDefault = probed ?? nil else { return }
        // WebKit's own is the fallback rather than the constant, because it is at least
        // consistent with the engine sending it.
        let agent = Self.safariUserAgent(matching: webKitDefault) ?? webKitDefault
        FetchIdentity.userAgent = agent
        webView.customUserAgent = agent
    }

    private var hasAdoptedUserAgent = false

    // MARK: - Fetching

    /// Loads `url`, then evaluates `script` (a JS expression returning a
    /// JSON-serialisable value) and decodes the result.
    ///
    /// - Throws: `.challengePresented` if the loaded page is a challenge — the
    ///   caller is expected to pause any batch work and ask the user to help.
    func fetch<T: Decodable>(
        _ url: URL,
        extracting script: String,
        as type: T.Type,
        signIn: SiteRule.SignIn? = nil,
        timeout: Duration = .seconds(30)
    ) async throws -> T {
        try await serialised {
            try await self.navigate(timeout: timeout, in: self.webView, settlingWhenReadable: true) {
                self.webView.load(self.request(for: url))
            }
            try await self.failIfChallenged()
            try await self.failIfTurnedAway(by: signIn, timeout: timeout)
            let value = try await self.evaluate(script, as: type, in: self.webView)
            await self.parkAfterExtraction()
            return value
        }
    }

    /// Loads `url`, runs `submitScript` inside it, waits for the navigation that
    /// script triggers, then extracts.
    ///
    /// This exists for POST search forms: submitting from within the page lets
    /// WebKit encode the query using the document's own charset, which is the
    /// only sane way to search the GBK/Big5 sites without reimplementing legacy
    /// encodings in the app.
    func fetch<T: Decodable>(
        _ url: URL,
        submitting submitScript: String,
        extracting script: String,
        as type: T.Type,
        signIn: SiteRule.SignIn? = nil,
        timeout: Duration = .seconds(30)
    ) async throws -> T {
        try await serialised {
            try await self.navigate(timeout: timeout, in: self.webView, settlingWhenReadable: true) {
                self.webView.load(self.request(for: url))
            }
            try await self.failIfChallenged()
            try await self.failIfTurnedAway(by: signIn, timeout: timeout)
            try await self.navigate(timeout: timeout, in: self.webView, settlingWhenReadable: true) {
                self.webView.evaluateJavaScript(submitScript, completionHandler: nil)
            }
            try await self.failIfChallenged()
            try await self.failIfTurnedAway(by: signIn, timeout: timeout)
            let value = try await self.evaluate(script, as: type, in: self.webView)
            await self.parkAfterExtraction()
            return value
        }
    }

    /// The request a page load goes out as.
    ///
    /// Carries a `Referer` when the last page fetched was on the same host, because that
    /// is what reading two chapters in a row looks like from the other end: a browser
    /// sends the page it came from. Every load here is programmatic, and the one before it
    /// was replaced by `about:blank` the moment its text was taken — so without this,
    /// every chapter of a novel is a cold, referrer-less hit on a deep URL, which is a
    /// shape a WAF has every reason to read as a crawler rather than a reader.
    ///
    /// Same host only, and never the page to itself. A referrer carried across sites is
    /// not politeness — it is telling one site what the reader was doing on another.
    /// `ImageFetcher` has sent one all along; the pages themselves did not.
    private func request(for url: URL) -> URLRequest {
        defer { cameFrom = url }
        return Self.request(for: url, comingFrom: cameFrom)
    }

    /// Not private so a test can pin the same-host rule. A referrer that leaks across
    /// sites is the one way this could do harm, and it is not reachable through the
    /// public surface without a network.
    nonisolated static func request(for url: URL, comingFrom previous: URL?) -> URLRequest {
        var request = URLRequest(url: url)
        if let previous, previous.host() == url.host(), previous != url {
            request.setValue(previous.absoluteString, forHTTPHeaderField: "Referer")
        }
        return request
    }

    /// The last page this fetcher was pointed at, for the referrer above. Deliberately
    /// not the web view's own `url`: by the time the next fetch starts that is
    /// `about:blank`, which is the whole problem.
    private var cameFrom: URL?

    /// Parks the fetcher's web view on a blank page once a fetch has what it came
    /// for.
    ///
    /// Left on the fetched page, the document lives on in the web content process —
    /// timers, animation loops, the ad scripts these sites carry — burning CPU for
    /// the whole session on a view that is deliberately kept in the window
    /// hierarchy and non-hidden (see `RootView`). The blank load ends that. Cookies
    /// live in the data store, so `cf_clearance` survives it. Awaited inside the
    /// serialised block rather than fired and forgotten: racing the next fetch's
    /// own load would cancel that navigation out from under its continuation. Never
    /// reached on the challenge path, where the sheet must show the page that
    /// challenged.
    private func parkAfterExtraction() async {
        try? await navigate(timeout: .seconds(5), in: webView) {
            self.webView.load(URLRequest(url: URL(string: "about:blank")!))
        }
    }

    /// Extracts from a document we already hold the bytes of, instead of from a
    /// URL. This is how an imported EPUB's chapters are read.
    ///
    /// The point is to run the *same* extractor over local XHTML as over a
    /// fetched page: `ExtractorScript.chapter` already normalises `<br>` / `<p>`
    /// / `<div>` into paragraph breaks and drops a repeated heading, and a
    /// second HTML reader written in Swift would be a worse copy that drifts
    /// away from this one.
    ///
    /// An imported file is content from outside the app, so it is loaded into a
    /// **separate** web view that has nothing worth stealing: a non-persistent data
    /// store, content scripting off for good, and every outgoing request blocked.
    /// It never touches `webView` — the one holding the user's cookies for every
    /// site they read, and the one the challenge sheet shows them full screen.
    ///
    /// Sharing that web view was a hole, not a shortcut. Switching content
    /// scripting off does not stop `<meta http-equiv="refresh">`, which the HTML
    /// parser implements: a book could point the fetcher's web view at any site it
    /// liked, and the flag was restored the moment this call returned, so the
    /// navigation landed with scripting back on. From there the document could keep
    /// interrupting real fetches — `fail(with:)` deliberately ignores the -999 that
    /// a superseded navigation reports — and a page claiming to be a Cloudflare
    /// challenge gets handed to the user in a sheet that shows no URL.
    ///
    /// Still queued through `serialised`, but for a different reason now: one
    /// navigation continuation is armed at a time, so two loads must not overlap
    /// even when they are on different web views.
    func extract<T: Decodable>(
        html: Data,
        extracting script: String,
        as type: T.Type,
        timeout: Duration = .seconds(15)
    ) async throws -> T {
        try await serialised {
            let view = try await self.importWebView()
            try await self.navigate(timeout: timeout, in: view) {
                // text/html, not application/xhtml+xml: WebKit's XML parser
                // abandons the whole document at the first well-formedness error
                // and real EPUBs contain them, while the HTML parser is
                // error-tolerant and builds the same DOM from valid input.
                view.load(
                    html,
                    mimeType: "text/html",
                    characterEncodingName: "UTF-8",
                    baseURL: Self.localBaseURL
                )
            }
            return try await self.evaluate(script, as: type, in: view)
        }
    }

    /// Gives back the web view an import was read in.
    ///
    /// Called when an import finishes, not when a document does: an EPUB is one
    /// `extract` per spine document, and the rule-list compile that building this view
    /// costs is worth paying once a book rather than once a chapter.
    ///
    /// Worth calling at all because a second `WKWebView` is a second web content
    /// process — tens of megabytes — and it was living for the rest of the session on
    /// the strength of one import, still holding the DOM of the last document it read.
    func releaseImportView() {
        importView = nil
    }

    /// Base URL for locally supplied markup. `about:blank` gives the document an
    /// opaque origin, and `decidePolicyFor` below refuses to let the import view
    /// navigate anywhere else.
    private static let localBaseURL = URL(string: "about:blank")!

    /// Built on first import rather than at init: most sessions never import a
    /// file, and the rule list below costs a compile.
    private func importWebView() async throws -> WKWebView {
        if let importView { return importView }
        let rules = try await Self.compileBlockAllRules()
        let config = WKWebViewConfiguration()
        // Nothing an imported book needs outlives its import, and this store must
        // not be the one carrying cf_clearance.
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.userContentController.add(rules)
        let view = WKWebView(frame: webView.frame, configuration: config)
        view.navigationDelegate = self
        importView = view
        return view
    }

    /// Blocks every request a loaded document makes.
    ///
    /// The opaque origin stops an imported file from *reading* anything; it does
    /// nothing about sending. A single `<img src="https://…">` needs no scripting
    /// and would tell whoever built the file the reader's IP address, the time, and
    /// that they opened this particular book — one beacon per chapter reports
    /// reading progress. Extraction needs no subresource, so none is allowed.
    ///
    /// A failure to compile throws rather than falling back to an unfiltered web
    /// view: quietly restoring network access is exactly the outcome this exists to
    /// prevent.
    private static func compileBlockAllRules() async throws -> WKContentRuleList {
        guard let store = WKContentRuleListStore.default() else {
            throw FetchError.documentIsolationUnavailable
        }
        return try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(
                forIdentifier: "import-block-all",
                encodedContentRuleList: #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#
            ) { list, error in
                if let list {
                    continuation.resume(returning: list)
                } else {
                    // WebKit's own error is dropped on purpose: what the user can act
                    // on is "this file could not be opened safely", and the reason a
                    // rule list failed to compile is not something they can fix.
                    continuation.resume(throwing: FetchError.documentIsolationUnavailable)
                }
            }
        }
    }

    /// Stops the fetcher's web view ever loading audio or video, once per session.
    ///
    /// The two configuration flags in `init` keep a playing video off the screen; this
    /// keeps there from being one. A page the app reads for a title, a catalog or a
    /// list of image addresses has no use for a media file, and the ad networks these
    /// sites carry serve plenty — each one a download the reader pays for out of their
    /// data plan to feed a player nobody is watching. Images are deliberately left
    /// alone: rules read `src` attributes off them, and a blocked image is a page the
    /// extractor sees differently from the one the site meant to serve.
    ///
    /// A failure to compile is swallowed, unlike `compileBlockAllRules`: there the
    /// rules *are* the isolation an import depends on, while here they are politeness.
    /// Refusing to fetch anything because an ad could not be blocked would trade a
    /// working app for a tidy one.
    private func blockMediaIfNeeded() async {
        guard !hasBlockedMedia, let store = WKContentRuleListStore.default() else { return }
        hasBlockedMedia = true
        let rules = #"""
        [{"trigger":{"url-filter":".*","resource-type":["media"]},"action":{"type":"block"}}]
        """#
        let list: WKContentRuleList? = await withCheckedContinuation { continuation in
            store.compileContentRuleList(
                forIdentifier: "fetch-block-media", encodedContentRuleList: rules
            ) { list, _ in
                continuation.resume(returning: list)
            }
        }
        guard let list else { return }
        webView.configuration.userContentController.add(list)
    }

    /// Tried once. A second attempt after a failure would recompile the same rules
    /// against the same store on every fetch for the rest of the session.
    private var hasBlockedMedia = false

    /// Hands the reader a challenge only once it is clear the check will not clear itself.
    ///
    /// A non-interactive check is a page like any other: it parses, it fires `load`, and
    /// the fetch waiter resumes on it — so the document in hand the moment a navigation
    /// finishes is perfectly capable of being Cloudflare's own interstitial, a couple of
    /// seconds away from running its JS and navigating on to the page we asked for.
    /// Reporting it here, which is what this used to do, put a sheet in front of the
    /// reader asking them to prove they are human for a check that was going to pass
    /// without them. `documentIsReadable` already refuses to settle early on a challenge
    /// for exactly this reason; the `didFinish` path had no such guard.
    ///
    /// So the page is watched instead of reported. Polled rather than waited on as a
    /// navigation, because clearing takes more than one hop and the last of them may
    /// already have landed by the time this looks — a wait for the *next* navigation
    /// would then spend its whole timeout on a page that was ours all along.
    private func failIfChallenged() async throws {
        guard var challenged = try await detectChallenge() else { return }
        let deadline = ContinuousClock.now + Self.challengeSelfClearGrace
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: Self.readabilityPollInterval)
            do {
                guard let stillChallenged = try await detectChallenge() else { return }
                challenged = stillChallenged
            } catch {
                // A probe that throws is a document being swapped out from under it,
                // which is what a check clearing itself looks like from here — so it is
                // "ask again", not an answer.
                continue
            }
        }
        throw FetchError.challengePresented(challenged)
    }

    /// How long a check gets to clear itself before the reader is asked.
    ///
    /// Long enough for the non-interactive check, which the recon notes measured a real
    /// engine passing in a few seconds, and short enough that the interactive one — which
    /// never clears, whatever it is given — does not leave a reader watching a spinner.
    /// Paid at most once per clearance window: a passed check leaves `cf_clearance`
    /// behind, and the requests riding on it see no challenge at all.
    private static let challengeSelfClearGrace: Duration = .seconds(8)

    /// Stops the fetch when the site bounced us to its "members only" page, and
    /// leaves the web view showing the sign-in form instead.
    ///
    /// Detected from the landed address rather than from the page's contents: the
    /// gate is a redirect out of a `<head>` script, so once the load settles the
    /// document we are holding is the site's own error page and carries no trace
    /// of what was asked for. `webView.url` is what is left.
    ///
    /// The address alone is not enough, though, because the redirect is often
    /// still in flight when the load reports finished. Measured on 8comic: of five
    /// gated books, one had already landed on the members page while four sat at
    /// their own address with the title blanked, the body empty, and the gate's
    /// script still in the markup — the parser had stopped, the navigation had not
    /// yet committed, and `webView.url` had nothing to say about it. Extracting
    /// from that husk yields "could not read a title", which sends the reader off
    /// to look for a fault in a rule that is working perfectly.
    ///
    /// So an emptied document is taken as "a navigation is on its way" and waited
    /// out. Bounded, and paid only by sites that declare a gate *and* handed back
    /// nothing — a page with any text in it never reaches the wait, which is every
    /// page anyone actually wanted. When nothing arrives the fetch simply carries
    /// on: a page that is empty because it is broken is not a page to ask anyone
    /// for a password over, and 8comic has those too.
    ///
    /// Navigating to the sign-in form rather than leaving it to the sheet is what
    /// makes this one interruption instead of two. The sheet shows *this* web view
    /// — the one with the site's cookies, which is the whole point, since a
    /// sign-in performed anywhere else would not be the one the next fetch rides
    /// on. The page it would otherwise be showing is a dead end with no form on it.
    ///
    /// A failed navigation to the form is swallowed: the fetch is over either way,
    /// and reporting "the sign-in page would not load" instead of "please sign in"
    /// tells the reader less about what to do next.
    private func failIfTurnedAway(by signIn: SiteRule.SignIn?, timeout: Duration) async throws {
        guard let signIn, let signInURL = signIn.signInURL else { return }
        if !signIn.turnsAway(webView.url) {
            guard try await documentWasEmptied() else { return }
            // An empty trigger: what is being waited for is the navigation the
            // page started for itself, which `didFinish` resumes.
            try? await navigate(timeout: Self.gateSettleTimeout, in: webView) {}
            guard signIn.turnsAway(webView.url) else { return }
        }
        try? await navigate(timeout: timeout, in: webView) {
            self.webView.load(self.request(for: signInURL))
        }
        throw FetchError.signInRequired(signInURL)
    }

    /// Long enough for a redirect already under way, short enough that a genuinely
    /// broken page does not hold the fetch queue up.
    private static let gateSettleTimeout: Duration = .seconds(3)

    /// Whether the loaded document has no text in it at all.
    ///
    /// The fingerprint of a gate caught mid-redirect: its script blanks the title
    /// and assigns `location.href` from `<head>`, so the parser never reaches the
    /// body. Deliberately not a test for the gate's own markup — that would be a
    /// rule reaching into the page as code rather than as data, and this says all
    /// that is needed to know it is worth waiting a moment longer.
    private func documentWasEmptied() async throws -> Bool {
        struct Probe: Decodable { let empty: Bool }
        let script = """
        (function () {
          var body = document.body;
          return { empty: !body || (body.textContent || '').trim().length === 0 };
        })()
        """
        return try await evaluate(script, as: Probe.self, in: webView).empty
    }

    /// Runs `body` after every previously queued fetch has settled.
    private func serialised<T>(_ body: @escaping () async throws -> T) async throws -> T {
        let previous = queueTail
        let task = Task { @MainActor in
            await previous.value
            await self.adoptUserAgentIfNeeded()
            await self.blockMediaIfNeeded()
            return try await body()
        }
        // Tail tracks completion only, so a failed fetch never blocks the queue.
        queueTail = Task { _ = try? await task.value }
        return try await task.value
    }

    /// Arms the navigation continuation, runs `trigger`, and waits for WebKit to
    /// report the resulting navigation. `trigger` must be what causes it — the
    /// continuation is armed first so a fast navigation cannot be missed.
    ///
    /// `settlingWhenReadable` adds a second way out: once the document has parsed
    /// and has text in it, stop waiting for the load to finish. Off by default and
    /// on only for the navigation a fetch is actually about, because two callers
    /// here are waiting for something else entirely — parking on `about:blank`,
    /// and watching for the redirect a sign-in gate started — and for those,
    /// "the page you already have is readable" is not the answer to the question.
    ///
    /// Not private so a test can drive it with a trigger that navigates nowhere:
    /// "this call always finishes" is the invariant the whole fetch queue rests
    /// on, and it is not reachable through the public surface without a network.
    func navigate(
        timeout: Duration,
        in view: WKWebView,
        settlingWhenReadable: Bool = false,
        trigger: @escaping () -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { continuation in
                    self.navigationContinuation = continuation
                    self.navigatingView = view
                    self.navigationHasCommitted = false
                    trigger()
                }
            }
            if settlingWhenReadable {
                group.addTask { @MainActor in try await self.settleWhenReadable(in: view) }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                // Resume the waiter explicitly. Cancelling it is not enough: a
                // checked continuation ignores cancellation, and a task group
                // awaits every child before it returns — so a navigation that
                // never arrives would hang this call, and with it the whole
                // serialised fetch queue, permanently. Reached only when a page
                // truly never navigates (a JS search box that opens an overlay
                // instead of loading a page is one real way to get here).
                await MainActor.run { self.timeOut() }
                throw FetchError.timedOut
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    private func timeOut() {
        navigationContinuation?.resume(throwing: FetchError.timedOut)
        navigationContinuation = nil
        navigatingView = nil
    }

    /// Resumes the waiter as though WebKit had reported the navigation finished.
    private func settleAsFinished() {
        navigationContinuation?.resume()
        navigationContinuation = nil
        navigatingView = nil
    }

    /// Stops waiting for a load that has already given us everything, and is not
    /// going to end.
    ///
    /// "Finished" means every subresource has settled, and on an ad-heavy page that
    /// can be much later than the document being complete — or never. Measured
    /// against the four comic sources: 8comic's chapter page is readable at 1.5s
    /// and finishes at 2.5s, mycomic's at 0.5s and 1.0s, while manhuagui's is fully
    /// readable at 1.5s — title, scripts and all — and was still loading thirty
    /// seconds later, every time. The fetch timeout was the only thing ending it,
    /// and it ended it with nothing.
    ///
    /// So the load event stays the normal signal, and this is the escape: readable
    /// and still loading, for long enough that finishing was clearly not imminent.
    /// The grace is what keeps this from changing anything that works today — every
    /// site measured finishes within about a second of becoming readable, so none
    /// of them ever reaches it.
    ///
    /// Readable deliberately requires text in the body, not just a parsed document.
    /// A page whose `<head>` script redirected has `readyState` complete and an
    /// empty body, and settling on that husk would hand the extractor a document
    /// that is on its way out — the exact failure `failIfTurnedAway` exists to
    /// catch, arrived at from the other direction.
    private func settleWhenReadable(in view: WKWebView) async throws {
        var readableSince: ContinuousClock.Instant?
        while true {
            try await Task.sleep(for: Self.readabilityPollInterval)
            // Until the navigation commits, the document being inspected is the one
            // the *last* fetch left behind.
            guard navigationHasCommitted, await documentIsReadable(in: view) else {
                readableSince = nil
                continue
            }
            guard let since = readableSince else {
                readableSince = .now
                continue
            }
            guard ContinuousClock.now - since >= Self.graceAfterReadable else { continue }
            settleAsFinished()
            return
        }
    }

    private static let readabilityPollInterval: Duration = .milliseconds(400)
    /// Comfortably longer than the gap between readable and finished on every site
    /// that has been measured, so only a page that is not going to finish waits it
    /// out.
    private static let graceAfterReadable: Duration = .seconds(5)

    /// A challenge page is text, and a parsed document, and emphatically not the
    /// page we asked for.
    ///
    /// It is also the one page whose whole purpose is served by waiting: the
    /// non-interactive check clears itself by running JS and navigating on, and
    /// the load event is what that arrives as. Settling early on it would trade a
    /// site that works after a short pause for one that asks the reader to prove
    /// they are human every time.
    private func documentIsReadable(in view: WKWebView) async -> Bool {
        struct Probe: Decodable { let readable: Bool }
        let script = """
        (function () {
          return {
            readable: document.readyState !== 'loading'
              && !!document.body
              && (document.body.textContent || '').trim().length > 0
              && !(\(Self.challengeMarkers))
          };
        })()
        """
        return (try? await evaluate(script, as: Probe.self, in: view))?.readable ?? false
    }

    private func evaluate<T: Decodable>(
        _ script: String, as type: T.Type, in view: WKWebView
    ) async throws -> T {
        let result: Any?
        do {
            result = try await view.evaluateJavaScript(script)
        } catch {
            throw FetchError.extractionFailed(error.localizedDescription)
        }
        guard let result, JSONSerialization.isValidJSONObject(result) else {
            throw FetchError.extractionFailed("extractor returned a non-JSON value")
        }
        let data = try JSONSerialization.data(withJSONObject: result)
        return try JSONDecoder().decode(type, from: data)
    }

    // MARK: - Challenge detection

    /// Returns the current URL when the loaded document is a Cloudflare
    /// interactive challenge rather than the page we asked for.
    ///
    /// Detection is deliberately shallow — we only need to know *that* we were
    /// challenged so we can hand control to the user.
    /// What a Cloudflare challenge looks like, as a JavaScript expression.
    ///
    /// One definition, because two callers need the same answer for opposite
    /// reasons — one to stop the fetch, one to keep waiting — and a copy that
    /// drifted would leave the second silently settling on the page the first is
    /// still looking for.
    private static let challengeMarkers = """
    !!window._cf_chl_opt \
    || !!document.querySelector('script[src*="challenges.cloudflare.com"]') \
    || !!document.querySelector('#challenge-form, #cf-challenge-running')
    """

    private func detectChallenge() async throws -> URL? {
        let probe = """
        (function () {
          return {
            challenged: \(Self.challengeMarkers),
            url: location.href
          };
        })()
        """
        struct Probe: Decodable { let challenged: Bool; let url: String }
        let probeResult = try await evaluate(probe, as: Probe.self, in: webView)
        guard probeResult.challenged else { return nil }
        return URL(string: probeResult.url)
    }
}

// MARK: - WKNavigationDelegate

extension WebFetcher: WKNavigationDelegate {
    /// The import web view is allowed exactly the one load `extract` gives it.
    ///
    /// `allowsContentJavaScript = false` is not a navigation policy: a `<meta
    /// http-equiv="refresh">` is the HTML parser's job and runs without scripting.
    /// Refusing anything but `about:blank` here is what actually keeps an imported
    /// book inside its own document.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard webView === importView else {
            // The fetcher's own web view has to be free to navigate: sites bounce
            // the first request, and clearing a challenge is a navigation.
            decisionHandler(.allow)
            return
        }
        let isLocal = navigationAction.request.url == Self.localBaseURL
        decisionHandler(isLocal ? .allow : .cancel)
    }

    /// The moment the new document takes over the web view. Before it, anything
    /// read from the page belongs to the page before.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === navigatingView else { return }
        navigationHasCommitted = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === navigatingView else { return }
        settleAsFinished()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === navigatingView else { return }
        fail(with: error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        guard webView === navigatingView else { return }
        fail(with: error)
    }

    /// A cancelled navigation is not a failure worth reporting.
    ///
    /// Several of these sites bounce the first request — a `<meta refresh>`, a
    /// `location.replace` in a head script, or a redirect to a mirror host. WebKit
    /// reports the superseded navigation as `NSURLErrorCancelled` (-999) *and*
    /// then starts the real one, so failing here would abort a load that is about
    /// to succeed. Staying silent lets the follow-up navigation resume the
    /// continuation, with the fetch timeout as the backstop if none arrives.
    private func fail(with error: any Error) {
        let nsError = error as NSError
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return }
        navigationContinuation?.resume(throwing: FetchError.navigationFailed(error.localizedDescription))
        navigationContinuation = nil
        navigatingView = nil
    }
}
