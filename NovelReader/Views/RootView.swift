import SwiftUI

/// The app shell: three tabs, the off-screen fetcher, and the things that have to
/// be able to appear over anything — the challenge sheet, the error banner, and
/// the import of a file another app has just handed us.
struct RootView: View {
    @State private var env = AppEnvironment.makeShared()
    @State private var hostToken = 0
    /// 0…1 while a file handed over by another app is being imported.
    @State private var importProgress: Double?
    @Environment(\.scenePhase) private var scenePhase

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
        // Owned here, like the challenge sheet: a download can be queued from the
        // book screen and the answer must survive that screen going away.
        .alert(
            "downloads.cellular.title",
            isPresented: Binding(
                get: { env.meteredPrompt != nil },
                set: { if !$0 { env.cancelMeteredDownload() } }
            )
        ) {
            Button("downloads.cellular.confirm") { env.confirmMeteredDownload() }
            Button("common.cancel", role: .cancel) { env.cancelMeteredDownload() }
        } message: {
            Text("downloads.cellular.message")
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                banner
                importBanner
            }
        }
        .animation(.snappy, value: env.banner)
        .animation(.snappy, value: importProgress == nil)
        // "Open with 書房" from Files, Mail or a browser (the document types are
        // declared in Info.plist). Handled by the shell rather than by the library
        // screen because it can arrive against any tab, including on a launch where
        // the library has never been on screen.
        .onOpenURL { url in Task { await open(url) } }
        // Only the two ends of the transition. `.inactive` also arrives for a
        // pulled-down notification centre, and stopping a download for that
        // would be stopping it while the user is still holding the phone.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: env.enterBackground()
            case .active: env.becomeActive()
            default: break
            }
        }
    }

    /// Determinate for the same reason the library's own import banner is: a
    /// full-length novel is hundreds of chapter files being written one at a time,
    /// and a spinner over that looks stuck.
    @ViewBuilder
    private var importBanner: some View {
        if let importProgress {
            ProgressView(value: importProgress) { Text("library.import.working") }
                .font(.footnote)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.bar, in: .rect(cornerRadius: 12))
                .padding(.horizontal)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// Imports a file another app handed us.
    ///
    /// Through `AppEnvironment.importLocalBook`, which is the same call the
    /// library's file picker makes: the URL arrives from outside the sandbox in
    /// exactly the same way, and the importer already takes the security-scoped
    /// access that needs.
    @MainActor
    private func open(_ url: URL) async {
        // `onOpenURL` sees every URL the app is ever asked to open, and this app
        // registers no scheme of its own — anything that is not a file is not ours.
        guard url.isFileURL else { return }
        importProgress = 0
        defer { importProgress = nil }
        do {
            _ = try await env.importLocalBook(from: url) { importProgress = $0 }
        } catch {
            env.report(error)
        }
        removeInboxCopy(of: url)
    }

    /// Deletes the copy iOS made in `Documents/Inbox` when another app sent us a
    /// file.
    ///
    /// Nothing else ever cleans that directory: the app does not expose its
    /// Documents folder, so a leftover copy is storage the user can neither see
    /// nor reclaim, one whole novel at a time. Done even when the import failed,
    /// because an unreachable file is no use to a retry either — the way to try
    /// again is to send it over from the source app.
    ///
    /// Strictly limited to our own inbox: a file the user opened in place belongs
    /// to them, and deleting it would be destroying the original.
    private func removeInboxCopy(of url: URL) {
        guard let documents = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return }
        let inbox = documents.appendingPathComponent("Inbox", isDirectory: true)
            .resolvingSymlinksInPath().path
        // Resolved on both sides: the container path is reached through a symlink
        // on some systems, and comparing one resolved path against an unresolved
        // one would answer "no" for a file that really is in the inbox.
        guard url.resolvingSymlinksInPath().path.hasPrefix(inbox + "/") else { return }
        try? FileManager.default.removeItem(at: url)
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
