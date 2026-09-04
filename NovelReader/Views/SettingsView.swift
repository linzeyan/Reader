import SwiftUI
import UniformTypeIdentifiers

/// The settings tab: five topics, each a heading a reader would recognise, and the
/// detail of each one tap away.
///
/// It used to be nine unlabelled sections in the order they were built, with the storage
/// screen sitting between the background-download report and the launch pickers. Nothing
/// there was wrong on its own; together they were a wall to be read top to bottom every
/// time, because there was no heading to skip by.
///
/// So the rule here is one question per section — where books come from, what reading
/// looks like, how chapters arrive, what they take up, whether it syncs — and anything
/// that is more than a line or two of controls lives on its own screen behind a link.
/// Everything below is still exactly the same controls; only where they sit has changed.
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

                Section("settings.section.reading") {
                    NavigationLink("settings.appearance") { AppearanceSettingsView() }
                        .accessibilityIdentifier("settings.appearance")
                    // The two launch pickers and the reading-history controls, together
                    // on one screen: they are four answers to "what do I see when I open
                    // this app", and they were three sections apart.
                    NavigationLink("settings.start") { StartSettingsView() }
                        .accessibilityIdentifier("settings.start")
                }

                Section {
                    Picker("settings.downloadNetwork", selection: $downloadSettings.network) {
                        Text("settings.downloadNetwork.wifiOnly")
                            .tag(DownloadSettings.NetworkPolicy.wifiOnly)
                        Text("settings.downloadNetwork.wifiAndCellular")
                            .tag(DownloadSettings.NetworkPolicy.wifiAndCellular)
                    }
                    .accessibilityIdentifier("settings.downloadNetwork")
                    // A report rather than a setting, and four rows of one: on the main
                    // screen it read as something to configure.
                    NavigationLink("settings.background") { BackgroundDownloadsView() }
                        .accessibilityIdentifier("settings.background")
                } header: {
                    Text("settings.section.downloads")
                } footer: {
                    Text("settings.downloadNetwork.footer")
                }

                // Two links, not one inside the other: what the reader asked to keep and
                // what reading left behind are different promises, and burying the second
                // inside the first says it is a detail of the first.
                Section("settings.section.storage") {
                    NavigationLink("storage.downloads") { StorageView() }
                        .accessibilityIdentifier("settings.storage")
                    NavigationLink("settings.cache") { CacheView() }
                        .accessibilityIdentifier("settings.cache")
                    // Here rather than beside the feed shelf: it is the one setting in
                    // the app that deletes things the reader did not ask it to, and this
                    // is the section people come to when they are looking for space.
                    NavigationLink("retention.title") { FeedRetentionView() }
                        .accessibilityIdentifier("settings.retention")
                }

                Section {
                    Toggle("settings.icloud", isOn: $cloud.isEnabled)
                    // Beside the sync toggle, because they answer the same question from
                    // opposite ends: sync is what keeps two devices the same, a backup is
                    // what survives having neither of them. A reader looking for one has
                    // looked for the other first.
                    NavigationLink("settings.backup") { BackupView() }
                        .accessibilityIdentifier("settings.backup")
                } header: {
                    Text("settings.section.sync")
                } footer: {
                    Text("settings.icloud.footer")
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

// MARK: - Launch

/// Everything about what the app opens on: which screen, which shelf, and how long the
/// list on that screen is.
///
/// One screen because they are one question. They were three sections on the main
/// settings list with a storage link between two of them, so answering "why does it open
/// here?" meant reading the whole page.
private struct StartSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var settings = env.librarySettings

        List {
            Section {
                Picker("settings.home", selection: $settings.home) {
                    ForEach(HomeScreen.allCases) { screen in
                        Text(screen.nameKey).tag(screen)
                    }
                }
                .accessibilityIdentifier("settings.home")
                Picker("settings.defaultMode", selection: $settings.defaultMediaMode) {
                    ForEach(MediaMode.allCases) { mode in
                        Label(mode.nameKey, systemImage: mode.icon).tag(mode)
                    }
                }
                .accessibilityIdentifier("settings.defaultMode")
            } footer: {
                Text("settings.start.footer")
            }

            RecentReadingSection()
        }
        .navigationTitle("settings.start")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Reading history

/// The two controls the app's first screen has: how long it is, and a way to empty it.
///
/// Here rather than in a menu on the screen itself, unlike the shelf's arrangement
/// controls. Those are three choices a reader flips between; these are set once, and
/// one of them is a delete — putting a destructive button in the toolbar of the screen
/// it destroys is how it gets pressed by someone reaching for the first row.
private struct RecentReadingSection: View {
    @Environment(AppEnvironment.self) private var env
    @State private var confirmingClear = false

    var body: some View {
        @Bindable var settings = env.librarySettings

        Section {
            Stepper(
                value: $settings.recentReadingCount,
                in: LibrarySettings.recentReadingRange
            ) {
                LabeledContent("settings.recent.count") {
                    Text("\(settings.recentReadingCount)")
                }
            }
            .accessibilityIdentifier("settings.recent.count")

            Button("settings.recent.clear", role: .destructive) { confirmingClear = true }
                .accessibilityIdentifier("settings.recent.clear")
                // Nothing to forget is not an error, and a button that does nothing is
                // worse than one that is plainly unavailable.
                .disabled(env.recentReads.isEmpty)
        } header: {
            Text("settings.recent")
        } footer: {
            Text("settings.recent.footer")
        }
        // Asked about, unlike most of this app's deletes, because what is destroyed is
        // not visible from here: the list is on another tab, and "clear" gives no hint
        // that reading *positions* survive it. The dialog is where that gets said.
        .confirmationDialog(
            "settings.recent.clear.confirm",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("settings.recent.clear", role: .destructive) { env.clearReadingHistory() }
            Button("common.cancel", role: .cancel) {}
        }
    }
}

// MARK: - Background downloads

/// The report on its own screen, because it is a report: four rows of what happened last
/// night, which on the main settings list read as four things to set.
private struct BackgroundDownloadsView: View {
    var body: some View {
        List {
            BackgroundDownloadsSection()
        }
        .navigationTitle("settings.background")
        .navigationBarTitleDisplayMode(.inline)
    }
}

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
        case .deferredToLaunch: return "settings.background.outcome.deferredToLaunch"
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
            // Split by medium, and headed even when only one medium is installed:
            // which shelf a source feeds is the thing a reader wants to check here,
            // and a rule file does not say it anywhere the list would otherwise show.
            // Empty sections are dropped rather than drawn as a header over nothing.
            ForEach(MediaMode.allCases) { mode in
                let installed = env.sites.rules(of: mode)
                if !installed.isEmpty {
                    Section {
                        ForEach(installed) { row($0) }
                    } header: {
                        Label(mode.nameKey, systemImage: mode.icon)
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

    private func row(_ rule: SiteRule) -> some View {
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
///
/// Downloads only. What reading online leaves behind is a different kind of thing —
/// nobody asked for it, it has a ceiling, and it goes away by itself — and mixing the two
/// totals would make the one number a reader checks mean nothing. `CacheView` is the
/// other half, one tap away.
struct StorageView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var siteSizes: [String: Int64] = [:]
    @State private var bookSizes: [String: Int64] = [:]
    @State private var total: Int64 = 0
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
            } footer: {
                Text("storage.downloads.footer")
            }

            ForEach(downloadedGroups, id: \.siteId) { group in
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
                } header: {
                    HStack {
                        Text(group.name)
                        Spacer()
                        Text(Self.format(siteSizes[group.siteId] ?? 0))
                    }
                }
            }
        }
        .navigationTitle("storage.downloads")
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

    /// Only the books that have something downloaded, the same rule `CacheView` reads by.
    ///
    /// A shelf is mostly books nobody has taken offline, and listing them all put the one
    /// number this screen exists for — where the space went — in a column of zeroes. The
    /// site's own delete button needs no `disabled` state once this filter runs: a group is
    /// here because one of its books has bytes, so the site has bytes.
    private var downloadedGroups: [LibrarySource] {
        env.booksBySite.compactMap { group in
            let books = group.books.filter { (bookSizes[$0.id] ?? 0) > 0 }
            guard !books.isEmpty else { return nil }
            return LibrarySource(siteId: group.siteId, name: group.name, books: books)
        }
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

// MARK: - Cache

/// What the app kept without being asked, and the two ways to take it back.
///
/// Two caches, listed apart because they are not the same promise. The chapter cache is
/// the text and pages of things the reader has actually read, it is measured per book,
/// and it holds a ceiling they set. The web caches are WebKit's and `URLCache`'s, they
/// cannot be measured properly (see `WebCache.imageCacheBytes`), and there is nothing to
/// aim at inside them — the only honest control is one button that empties the lot, and
/// it has to say what the lot is.
struct CacheView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var bookSizes: [String: Int64] = [:]
    @State private var webBytes: Int64 = 0
    @State private var free: Int64 = 0
    @State private var clearing = false

    var body: some View {
        @Bindable var cache = env.cache
        List {
            Section {
                LabeledContent("cache.used", value: Self.format(env.cache.used ?? 0))
                // A slider rather than a list of sizes. The list had to stop somewhere,
                // and where it stopped — "2.15 GB", because a gibibyte drawn in decimal
                // is not a number anyone chose — read as the app being broken. A slider
                // has an end without pretending the end is a menu item, and the row above
                // it says what the end is.
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("cache.limit", value: Self.format(cache.limit))
                    Slider(
                        value: Binding(
                            get: { Double(cache.limit) },
                            set: { cache.limit = ChapterCache.rounded($0) }
                        ),
                        in: Double(ChapterCache.minimumLimit)...Double(ceiling),
                        step: Double(ChapterCache.limitStep)
                    )
                    .accessibilityIdentifier("cache.limit")
                }
                LabeledContent("cache.free", value: Self.format(free))
                Button("cache.clear", role: .destructive) {
                    env.cache.clearEverything()
                    measure()
                }
                .disabled((env.cache.used ?? 0) == 0)
                .accessibilityIdentifier("cache.clear")
            } header: {
                Text("cache.chapters")
            } footer: {
                Text("cache.chapters.footer")
            }

            ForEach(cachedGroups, id: \.siteId) { group in
                Section(group.name) {
                    ForEach(group.books) { book in
                        LabeledContent(
                            book.shownName, value: Self.format(bookSizes[book.id] ?? 0)
                        )
                        .swipeActions {
                            // No confirmation, unlike a download: everything here can be
                            // read again, and most of it will be thrown away by the
                            // ceiling anyway.
                            Button(role: .destructive) {
                                env.cache.clear(book)
                                measure()
                            } label: {
                                Label("common.delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            Section {
                LabeledContent("cache.web", value: Self.format(webBytes))
                Button("storage.clearCache") {
                    clearing = true
                    Task {
                        await WebCache.clear()
                        clearing = false
                        measure()
                    }
                }
                .disabled(clearing)
                .accessibilityIdentifier("storage.clearCache")
            } header: {
                Text("cache.web.section")
            } footer: {
                Text("cache.web.footer")
            }
        }
        .navigationTitle("settings.cache")
        .navigationBarTitleDisplayMode(.inline)
        .task { measure() }
    }

    /// Only the books that have something cached. The whole library would be a list of
    /// zeroes with the answer buried in it.
    private var cachedGroups: [LibrarySource] {
        env.booksBySite.compactMap { group in
            let books = group.books.filter { (bookSizes[$0.id] ?? 0) > 0 }
            guard !books.isEmpty else { return nil }
            return LibrarySource(siteId: group.siteId, name: group.name, books: books)
        }
    }

    /// The top of the slider. `free` is read once when the screen appears rather than per
    /// redraw: how much room the disk has is a syscall, and `body` runs on every one of
    /// these numbers landing.
    ///
    /// Never below what is already set, or dragging the slider would be the act of
    /// lowering a limit the reader chose on a fuller day.
    private var ceiling: Double {
        Double(max(ChapterCache.ceiling(free: free), env.cache.limit))
    }

    private func measure() {
        webBytes = WebCache.imageCacheBytes
        free = ChapterCache.freeBytes()
        Task {
            await env.cache.measure()
            // The total first, because that is the number the screen is opened for; the
            // per-book list fills in behind it a moment later.
            bookSizes = await env.cache.sizes(of: env.books)
        }
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
