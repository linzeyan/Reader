import SwiftUI

/// The app shell: three tabs, the off-screen fetcher, and the two things that
/// have to be able to appear over anything — the challenge sheet and the error
/// banner.
struct RootView: View {
    @State private var env = AppEnvironment.makeShared()
    @State private var hostToken = 0

    var body: some View {
        TabView {
            LibraryView()
                .tabItem { Label("tab.library", systemImage: "books.vertical") }
            SearchView()
                .tabItem { Label("tab.search", systemImage: "magnifyingglass") }
            SettingsView()
                .tabItem { Label("tab.settings", systemImage: "gearshape") }
        }
        .environment(env)
        // The fetcher's web view must live in the hierarchy even when idle:
        // WKWebView never finishes layout-dependent work while it has no window,
        // and that includes clearing a non-interactive challenge.
        .background {
            WebViewHost(webView: env.fetcher.webView, interactive: false, token: hostToken)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
        }
        .sheet(item: $env.challenge) { challenge in
            ChallengeSheet(webView: env.fetcher.webView, url: challenge.url) {
                env.challenge = nil
                env.downloader.pendingChallenge = nil
                // Reclaim the web view from the sheet.
                hostToken += 1
            }
        }
        .onChange(of: env.downloader.pendingChallenge) { _, new in
            if let new { env.challenge = ChallengeRequest(url: new) }
        }
        .overlay(alignment: .top) { banner }
        .animation(.snappy, value: env.banner)
    }

    @ViewBuilder
    private var banner: some View {
        if let message = env.banner {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.92), in: .rect(cornerRadius: 12))
                .padding(.horizontal)
                .onTapGesture { env.banner = nil }
                .task(id: message) {
                    try? await Task.sleep(for: .seconds(5))
                    if env.banner == message { env.banner = nil }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// `sheet(item:)` needs an `Identifiable`; a bare URL is not one, and keying the
/// sheet on the URL string would re-present it for the same host twice in a row.
struct ChallengeRequest: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}
