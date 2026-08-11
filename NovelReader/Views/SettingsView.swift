import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var cloud = env.cloud
        @Bindable var downloadSettings = env.downloadSettings

        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        SiteListView()
                    } label: {
                        LabeledContent("settings.sources") {
                            Text("\(env.sites.rules.count)")
                        }
                    }
                    .accessibilityIdentifier("settings.sources")
                } footer: {
                    Text("settings.sources.footer")
                }

                Section {
                    Toggle("settings.icloud", isOn: $cloud.isEnabled)
                } footer: {
                    Text("settings.icloud.footer")
                }

                Section {
                    Picker("settings.downloadNetwork", selection: $downloadSettings.network) {
                        Text("settings.downloadNetwork.wifiOnly")
                            .tag(DownloadSettings.NetworkPolicy.wifiOnly)
                        Text("settings.downloadNetwork.wifiAndCellular")
                            .tag(DownloadSettings.NetworkPolicy.wifiAndCellular)
                    }
                    .accessibilityIdentifier("settings.downloadNetwork")
                } footer: {
                    Text("settings.downloadNetwork.footer")
                }

                BackgroundDownloadsSection()

                Section {
                    NavigationLink("settings.storage") { StorageView() }
                        .accessibilityIdentifier("settings.storage")
                }

                Section("reader.settings") {
                    NavigationLink("settings.appearance") { AppearanceSettingsView() }
                        .accessibilityIdentifier("settings.appearance")
                }

                Section {
                    LabeledContent("settings.version", value: Self.version)
                }
            }
            .navigationTitle("tab.settings")
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }
}

// MARK: - Background downloads

/// The only window onto a feature that by definition runs where nobody can see
/// it. Without this the honest answer to "did it download anything overnight?" is
/// "look at the chapter list and guess", which cannot distinguish a background
/// window that never got granted from one that ran and fetched nothing because
/// iOS had suspended the web content process.
private struct BackgroundDownloadsSection: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Section {
            if let run = env.backgroundDownloads.lastRun {
                LabeledContent("settings.background.when") {
                    Text(run.startedAt, format: .relative(presentation: .named))
                }
                LabeledContent("settings.background.result") {
                    Text(Self.label(for: run.outcome))
                }
                LabeledContent("settings.background.chapters", value: "\(run.chapters)")
                LabeledContent("settings.background.connection") {
                    Text(Self.label(for: run.connection))
                }
            } else {
                Text("settings.background.never").foregroundStyle(.secondary)
            }
            if let error = env.backgroundDownloads.lastScheduleError {
                LabeledContent("settings.background.scheduleError") { Text(error) }
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("settings.background")
        } footer: {
            Text("settings.background.footer")
        }
    }

    private static func label(for outcome: BackgroundDownloadRun.Outcome) -> LocalizedStringKey {
        switch outcome {
        case .completed: return "settings.background.outcome.completed"
        case .expired: return "settings.background.outcome.expired"
        case .stalled: return "settings.background.outcome.stalled"
        case .blockedByPolicy: return "settings.background.outcome.blockedByPolicy"
        case .nothingToDo: return "settings.background.outcome.nothingToDo"
        case .queueLost: return "settings.background.outcome.queueLost"
        }
    }

    private static func label(for connection: NetworkMonitor.Connection) -> LocalizedStringKey {
        switch connection {
        case .wifi: return "settings.background.connection.wifi"
        case .cellular: return "settings.background.connection.cellular"
        case .offline: return "settings.background.connection.offline"
        case .unknown: return "settings.background.connection.unknown"
        }
    }
}

// MARK: - Sources

/// Requirement: the user owns the source list. Nothing is preinstalled in a
/// release build, so this screen is where an app with no sources becomes useful.
struct SiteListView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var importing = false
    @State private var pasting = false
    @State private var fetching = false
    @State private var deriving = false
    @State private var pasted = ""
    @State private var error: String?

    var body: some View {
        List {
            if let error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            if env.sites.rules.isEmpty {
                Section {
                    Text("settings.sources.empty").foregroundStyle(.secondary)
                }
            }
            ForEach(env.sites.rules) { rule in
                NavigationLink {
                    SiteDetailView(siteId: rule.id)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(rule.name)
                        Text(rule.host).font(.caption).foregroundStyle(.secondary)
                        if rule.search == nil {
                            Text("settings.sources.noSearch")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .accessibilityIdentifier("sources.row")
                .swipeActions {
                    Button(role: .destructive) {
                        remove(rule)
                    } label: {
                        Label("common.delete", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("settings.sources")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // First, because it is the only entry that does not require
                    // someone to have written a rule file already.
                    Button("settings.sources.derive", systemImage: "wand.and.stars") {
                        deriving = true
                    }
                    .accessibilityIdentifier("sources.derive")
                    Divider()
                    Button("settings.sources.importFile", systemImage: "doc") { importing = true }
                    Button("settings.sources.importURL", systemImage: "link") { fetching = true }
                        .accessibilityIdentifier("sources.importURL")
                    Button("settings.sources.importPaste", systemImage: "doc.on.clipboard") {
                        pasted = ""
                        pasting = true
                    }
                } label: {
                    Label("settings.sources.add", systemImage: "plus")
                }
            }
        }
        // Pushed rather than presented: deriving a rule can hit a Cloudflare
        // challenge, and the challenge sheet is owned by the root view — a sheet
        // here would be in the way of the one the user has to interact with.
        .navigationDestination(isPresented: $deriving) { DeriveRuleView() }
        .sheet(isPresented: $fetching) { RemoteRuleImportView() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                apply { try env.sites.importRule(from: url) }
            case .failure(let failure):
                error = failure.localizedDescription
            }
        }
        .sheet(isPresented: $pasting) {
            NavigationStack {
                TextEditor(text: $pasted)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 8)
                    .navigationTitle("settings.sources.importPaste")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("common.cancel") { pasting = false }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("common.save") {
                                apply { try env.sites.importRule(data: Data(pasted.utf8)) }
                                pasting = false
                            }
                            .disabled(pasted.isEmpty)
                        }
                    }
            }
        }
    }

    private func apply(_ work: () throws -> SiteRule) {
        do {
            _ = try work()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Removing a rule leaves its bookmarks alone. They keep appearing in the
    /// library under the raw site id, so reinstalling the rule restores them —
    /// deleting a rule must not silently destroy a reading history.
    private func remove(_ rule: SiteRule) {
        do {
            try env.sites.remove(id: rule.id)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Storage

/// Requirement 4.3: the four delete scopes, with the numbers that justify them.
struct StorageView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var siteSizes: [String: Int64] = [:]
    @State private var bookSizes: [String: Int64] = [:]
    @State private var total: Int64 = 0
    @State private var cacheBytes: Int64 = 0
    @State private var confirmingEverything = false
    /// Set when the delete about to happen cannot be undone by downloading again —
    /// an imported book, or the whole imported shelf.
    @State private var confirmingLocalScope: DownloadStore.Scope?

    var body: some View {
        List {
            Section {
                LabeledContent("storage.total", value: Self.format(total))
                Button("storage.deleteAll", role: .destructive) { confirmingEverything = true }
                    .disabled(total == 0)
            }

            Section {
                LabeledContent("storage.cache", value: Self.format(cacheBytes))
                Button("storage.clearCache") {
                    Task {
                        await WebCache.clear()
                        cacheBytes = WebCache.imageCacheBytes
                    }
                }
                .accessibilityIdentifier("storage.clearCache")
            } footer: {
                Text("storage.cache.footer")
            }

            ForEach(env.booksBySite, id: \.siteId) { group in
                Section {
                    ForEach(group.books) { book in
                        LabeledContent(book.shownName, value: Self.format(bookSizes[book.id] ?? 0))
                            .swipeActions {
                                Button(role: .destructive) {
                                    // For a site book this reclaims space and the
                                    // chapters can be fetched again. For an
                                    // imported one it is the only copy.
                                    delete(.book(book), reversible: !book.isLocal)
                                } label: {
                                    Label("common.delete", systemImage: "trash")
                                }
                            }
                    }
                    Button("storage.deleteSite", role: .destructive) {
                        delete(
                            .site(siteId: group.siteId),
                            reversible: group.siteId != Book.localSiteId
                        )
                    }
                    .disabled((siteSizes[group.siteId] ?? 0) == 0)
                } header: {
                    HStack {
                        Text(group.name)
                        Spacer()
                        Text(Self.format(siteSizes[group.siteId] ?? 0))
                    }
                }
            }
        }
        .navigationTitle("settings.storage")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "storage.deleteAll.confirm",
            isPresented: $confirmingEverything,
            titleVisibility: .visible
        ) {
            Button("storage.deleteAll", role: .destructive) {
                try? env.downloads.delete(.everything)
                measure()
            }
            Button("common.cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "local.delete.confirm",
            isPresented: Binding(
                get: { confirmingLocalScope != nil },
                set: { if !$0 { confirmingLocalScope = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("common.delete", role: .destructive) {
                if let scope = confirmingLocalScope { apply(scope) }
                confirmingLocalScope = nil
            }
            Button("common.cancel", role: .cancel) { confirmingLocalScope = nil }
        }
        .task { measure() }
    }

    /// Deletes at once when the bytes can be fetched again, and asks first when
    /// they cannot. Reclaiming space is routine; destroying the only copy of a
    /// file the user imported is not, and a swipe is too cheap a gesture for it.
    private func delete(_ scope: DownloadStore.Scope, reversible: Bool) {
        if reversible {
            apply(scope)
        } else {
            confirmingLocalScope = scope
        }
    }

    private func apply(_ scope: DownloadStore.Scope) {
        try? env.downloads.delete(scope)
        measure()
    }

    /// Sizes come from walking the files rather than from a stored total: the
    /// number has to stay honest after a crash mid-delete, and a few hundred
    /// stat() calls on a screen the user visits occasionally is nothing.
    private func measure() {
        total = env.downloads.size(of: .everything)
        cacheBytes = WebCache.imageCacheBytes
        var sites: [String: Int64] = [:]
        var books: [String: Int64] = [:]
        for group in env.booksBySite {
            sites[group.siteId] = env.downloads.size(of: .site(siteId: group.siteId))
            for book in group.books {
                books[book.id] = env.downloads.size(of: .book(book))
            }
        }
        siteSizes = sites
        bookSizes = books
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
