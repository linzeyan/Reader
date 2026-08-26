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
            case .navigationFailed(let m): return m
            case .timedOut: return String(localized: "fetch.error.timeout")
            case .extractionFailed(let m): return m
            case .documentIsolationUnavailable: return String(localized: "fetch.error.isolation")
            }
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
            try await self.navigate(timeout: timeout, in: self.webView) {
                self.webView.load(URLRequest(url: url))
            }
            try await self.failIfChallenged()
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
        timeout: Duration = .seconds(30)
    ) async throws -> T {
        try await serialised {
            try await self.navigate(timeout: timeout, in: self.webView) {
                self.webView.load(URLRequest(url: url))
            }
            try await self.failIfChallenged()
            try await self.navigate(timeout: timeout, in: self.webView) {
                self.webView.evaluateJavaScript(submitScript, completionHandler: nil)
            }
            try await self.failIfChallenged()
            let value = try await self.evaluate(script, as: type, in: self.webView)
            await self.parkAfterExtraction()
            return value
        }
    }

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
    func navigate(timeout: Duration, in view: WKWebView, trigger: @escaping () -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { continuation in
                    self.navigationContinuation = continuation
                    self.navigatingView = view
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
        navigatingView = nil
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === navigatingView else { return }
        navigationContinuation?.resume()
        navigationContinuation = nil
        navigatingView = nil
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
