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
@MainActor
final class WebFetcher: NSObject {
    enum FetchError: LocalizedError {
        /// The host demanded an interactive challenge. The caller must stop
        /// batching and present `webView` so a human can complete it.
        case challengePresented(URL)
        case navigationFailed(String)
        case timedOut
        case extractionFailed(String)

        var errorDescription: String? {
            switch self {
            case .challengePresented: return String(localized: "fetch.error.challenge")
            case .navigationFailed(let m): return m
            case .timedOut: return String(localized: "fetch.error.timeout")
            case .extractionFailed(let m): return m
            }
        }
    }

    /// Hosted off-screen by the app shell, and re-parented into a sheet when a
    /// challenge needs the user. A web view with no window never finishes
    /// layout-dependent work, so it must be in the hierarchy either way.
    let webView: WKWebView

    private var navigationContinuation: CheckedContinuation<Void, Error>?
    /// Serialises fetches: each waits for the previous one to finish.
    private var queueTail: Task<Void, Never> = Task {}

    override init() {
        let config = WKWebViewConfiguration()
        // Persistent store: cf_clearance and the site's own cookies must survive
        // relaunch, otherwise every cold start re-triggers a challenge.
        //
        // Read here rather than as a default argument: a default argument is
        // evaluated outside the actor, and `.default()` is main-actor isolated.
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        super.init()
        webView.navigationDelegate = self
        // Identify as mobile Safari so sites serve their phone layout, which is
        // lighter and has the selectors our rules are written against.
        webView.customUserAgent = Self.mobileSafariUserAgent
    }

    static let mobileSafariUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

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
        timeout: Duration = .seconds(30)
    ) async throws -> T {
        try await serialised {
            try await self.navigate(timeout: timeout) { self.webView.load(URLRequest(url: url)) }
            try await self.failIfChallenged()
            return try await self.evaluate(script, as: type)
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
        timeout: Duration = .seconds(30)
    ) async throws -> T {
        try await serialised {
            try await self.navigate(timeout: timeout) { self.webView.load(URLRequest(url: url)) }
            try await self.failIfChallenged()
            try await self.navigate(timeout: timeout) {
                self.webView.evaluateJavaScript(submitScript, completionHandler: nil)
            }
            try await self.failIfChallenged()
            return try await self.evaluate(script, as: type)
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
    /// Queued through `serialised` like every other load, for the reason the
    /// whole type is serialised: there is one web view, and importing a book must
    /// not navigate it out from under a download that is part-way through a page.
    func extract<T: Decodable>(
        html: Data,
        extracting script: String,
        as type: T.Type,
        timeout: Duration = .seconds(15)
    ) async throws -> T {
        try await serialised {
            let allowedScripts = self.contentJavaScriptEnabled
            // An imported file is content from outside the app, and this web view
            // holds the user's cookies for every site they read. The document's
            // origin is opaque (see `Self.localBaseURL`) so it cannot reach those
            // cookies, but there is no reason to let a book's markup execute at
            // all — nothing we extract from it needs scripting. `evaluateJavaScript`
            // is unaffected: it is not web content.
            //
            // Restored in a `defer` because leaving it off would break every later
            // site fetch: clearing a Cloudflare challenge needs a JS engine.
            self.contentJavaScriptEnabled = false
            defer { self.contentJavaScriptEnabled = allowedScripts }
            try await self.navigate(timeout: timeout) {
                // text/html, not application/xhtml+xml: WebKit's XML parser
                // abandons the whole document at the first well-formedness error
                // and real EPUBs contain them, while the HTML parser is
                // error-tolerant and builds the same DOM from valid input.
                self.webView.load(
                    html,
                    mimeType: "text/html",
                    characterEncodingName: "UTF-8",
                    baseURL: Self.localBaseURL
                )
            }
            return try await self.evaluate(script, as: type)
        }
    }

    /// Base URL for locally supplied markup. `about:blank` gives the document an
    /// opaque origin, so it shares nothing with the sites this web view has
    /// cookies for.
    private static let localBaseURL = URL(string: "about:blank")!

    /// WebKit declares `defaultWebpagePreferences` as an implicitly unwrapped
    /// optional, which a `let` binding turns into a real optional. Funnelling it
    /// through one accessor keeps that out of the code that cares about the flag.
    private var contentJavaScriptEnabled: Bool {
        get { webView.configuration.defaultWebpagePreferences.allowsContentJavaScript }
        set { webView.configuration.defaultWebpagePreferences.allowsContentJavaScript = newValue }
    }

    private func failIfChallenged() async throws {
        if let challengeURL = try await detectChallenge() {
            throw FetchError.challengePresented(challengeURL)
        }
    }

    /// Runs `body` after every previously queued fetch has settled.
    private func serialised<T>(_ body: @escaping () async throws -> T) async throws -> T {
        let previous = queueTail
        let task = Task { @MainActor in
            await previous.value
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
    /// Not private so a test can drive it with a trigger that navigates nowhere:
    /// "this call always finishes" is the invariant the whole fetch queue rests
    /// on, and it is not reachable through the public surface without a network.
    func navigate(timeout: Duration, trigger: @escaping () -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { continuation in
                    self.navigationContinuation = continuation
                    trigger()
                }
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
    }

    private func evaluate<T: Decodable>(_ script: String, as type: T.Type) async throws -> T {
        let result: Any?
        do {
            result = try await webView.evaluateJavaScript(script)
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
    private func detectChallenge() async throws -> URL? {
        let probe = """
        (function () {
          return {
            challenged: !!window._cf_chl_opt
              || !!document.querySelector('script[src*="challenges.cloudflare.com"]')
              || !!document.querySelector('#challenge-form, #cf-challenge-running'),
            url: location.href
          };
        })()
        """
        struct Probe: Decodable { let challenged: Bool; let url: String }
        let probeResult = try await evaluate(probe, as: Probe.self)
        guard probeResult.challenged else { return nil }
        return URL(string: probeResult.url)
    }
}

// MARK: - WKNavigationDelegate

extension WebFetcher: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationContinuation?.resume()
        navigationContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(with: error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
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
    }
}
