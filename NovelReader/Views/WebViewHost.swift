import SwiftUI
import WebKit

/// Hosts the fetcher's single web view, either invisibly (the normal case) or
/// interactively inside the challenge sheet.
///
/// There is only ever one WKWebView in the app — it carries the Cloudflare
/// clearance cookie — so it has to move between hosts rather than be duplicated.
/// The container-plus-reparent dance is what makes that safe: whichever host
/// updates last adopts the view, and the other is left with an empty container.
struct WebViewHost: UIViewRepresentable {
    let webView: WKWebView
    var interactive: Bool
    /// Bumped by the owner to force `updateUIView` when nothing else changed —
    /// needed to pull the web view back after the challenge sheet closes.
    var token: Int

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if webView.superview !== container {
            webView.removeFromSuperview()
            webView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(webView)
            NSLayoutConstraint.activate([
                webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                webView.topAnchor.constraint(equalTo: container.topAnchor),
                webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        webView.isUserInteractionEnabled = interactive
        // Zero opacity rather than `isHidden`: a hidden view is skipped during
        // layout, which stalls the very JS challenges we depend on clearing.
        container.alpha = interactive ? 1 : 0
        // But an alpha-zero web view still publishes its whole DOM to
        // accessibility. Left alone, VoiceOver would walk hundreds of invisible
        // links from whatever page the fetcher happens to be holding. Only the
        // challenge sheet — where the user is meant to interact — stays visible.
        //
        // Set on the web view itself, not just the container: WKWebView's
        // accessibility tree is vended by the out-of-process web content, and
        // hiding an ancestor does not reach it.
        // `accessibilityElementsHidden` alone is not enough — WebKit's remote
        // element ignores it — so the child list is emptied outright.
        webView.accessibilityElements = interactive ? nil : []
        webView.accessibilityElementsHidden = !interactive
        container.accessibilityElementsHidden = !interactive
    }
}

/// Surfaces the web view so the user can get past something the app cannot:
/// a human check, or a site that only serves signed-in readers.
///
/// Nothing here solves or evades either one — the app simply stops batching and
/// gets out of the way. Whatever cookie results then lives in the shared data
/// store, so the queue can be resumed.
struct ChallengeSheet: View {
    let webView: WKWebView
    let url: URL
    var reason: ChallengeRequest.Reason = .verification
    let onDone: () -> Void

    /// Followed live rather than read once from `url`. This sheet is the one place
    /// the app hands a full-screen browser to the user with no address bar, and a
    /// challenge page is free to redirect — a label naming the site the app meant
    /// to visit, while the field being typed into belongs to somewhere else, would
    /// be worse than showing nothing.
    @State private var current: URL?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text(site)
                    .font(.footnote.monospaced())
                    .lineLimit(1)
                    // The host is the part that matters, so a long path is what
                    // gets eaten — and truncating the middle keeps a lookalike
                    // domain from hiding behind an ellipsis.
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal)
                Text(explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                WebViewHost(webView: webView, interactive: true, token: 0)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("common.cancel") { onDone() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("challenge.done") { onDone() }.fontWeight(.semibold)
                }
            }
        }
        .interactiveDismissDisabled()
        .onReceive(webView.publisher(for: \.url)) { current = $0 }
    }

    private var title: LocalizedStringKey {
        reason == .signIn ? "challenge.signIn.title" : "challenge.title"
    }

    private var explanation: LocalizedStringKey {
        reason == .signIn ? "challenge.signIn.explain" : "challenge.explain"
    }

    /// A bare host for ordinary https, where the scheme is noise. Anything else —
    /// plain http, a data or file URL — is shown whole, because that is precisely
    /// the case where the user needs to see what they are really looking at.
    private var site: String {
        let shown = current ?? url
        guard shown.scheme == "https", let host = shown.host() else { return shown.absoluteString }
        return host
    }
}
