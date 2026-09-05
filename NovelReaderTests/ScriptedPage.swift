import WebKit
@testable import NovelReader

/// A page whose own scripts run.
///
/// The web view `WebFetcher.extract(html:)` uses deliberately has scripting off —
/// it reads files from strangers — so it cannot exercise a `global` strategy,
/// whose entire job is to read what a site's scripts built. This is that one
/// missing capability and nothing else: local markup, no network, no cookies.
///
/// Shared by the comic image extractor's tests and the search extractor's,
/// because both ask the same question of an extractor: given exactly this markup,
/// what does it come back with?
@MainActor
final class ScriptedPage: NSObject, WKNavigationDelegate {
    /// Stands in for the page under test, so a relative URL in the markup resolves
    /// the way it would on the site.
    static let baseURL = URL(string: "https://comic.test/online/new-103.html?ch=1")!

    private let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    private var loaded: CheckedContinuation<Void, Never>?
    private let base: URL

    init(baseURL: URL = ScriptedPage.baseURL) {
        base = baseURL
    }

    func load(_ html: String) async {
        webView.navigationDelegate = self
        await withCheckedContinuation { continuation in
            loaded = continuation
            webView.loadHTMLString(html, baseURL: base)
        }
    }

    func evaluate<T: Decodable>(_ script: String, as type: T.Type) async throws -> T {
        let result = try await webView.evaluateJavaScript(script)
        let data = try JSONSerialization.data(withJSONObject: result as Any)
        return try JSONDecoder().decode(type, from: data)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume()
        loaded = nil
    }
}
