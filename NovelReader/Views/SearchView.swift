import SwiftUI

/// Requirement 4: search one source, or every source at once.
///
/// The all-sites mode fills in site by site as results land, because the fetcher
/// can only drive one page at a time and the slowest source must not hold up the
/// first four. Sites that fail — a challenge, no search support — are shown as
/// such rather than silently omitted, so the result list is never quietly wrong.
struct SearchView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var query = ""
    @State private var scope: Scope = .all
    @State private var outcomes: [SiteSearchOutcome] = []
    @State private var pending: Set<String> = []
    @State private var task: Task<Void, Never>?
    @State private var hasSearched = false

    private enum Scope: Hashable {
        case all
        case site(String)
    }

    private var searchable: [SiteRule] { env.sites.searchableRules }

    var body: some View {
        NavigationStack {
            Group {
                if env.sites.rules.isEmpty {
                    ContentUnavailableView(
                        "library.empty.title",
                        systemImage: "magnifyingglass",
                        description: Text("library.empty.needSource")
                    )
                } else if searchable.isEmpty {
                    ContentUnavailableView(
                        "search.noSearchableSites",
                        systemImage: "magnifyingglass",
                        description: Text("search.noSearchableSites.hint")
                    )
                } else {
                    resultList
                }
            }
            .navigationTitle("tab.search")
            .navigationDestination(for: Book.self) { BookDetailView(book: $0) }
            .searchable(text: $query, prompt: Text("search.prompt"))
            .onSubmit(of: .search) { start() }
            .onDisappear { task?.cancel() }
        }
    }

    private var resultList: some View {
        List {
            Section {
                Picker("search.scope", selection: $scope) {
                    Text("search.scope.all").tag(Scope.all)
                    ForEach(searchable) { rule in
                        Text(rule.name).tag(Scope.site(rule.id))
                    }
                }
            }

            if !hasSearched {
                Section {
                    Text("search.hint").font(.footnote).foregroundStyle(.secondary)
                }
            }

            ForEach(outcomes) { outcome in
                Section {
                    if let failure = outcome.failure {
                        Label(message(for: failure), systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    } else if outcome.results.isEmpty {
                        Text("search.noResults").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ForEach(outcome.results) { result in
                            Button { add(result) } label: { ResultRow(result: result) }
                                .tint(.primary)
                        }
                    }
                } header: {
                    HStack {
                        Text(outcome.siteName)
                        if pending.contains(outcome.siteId) { ProgressView().controlSize(.mini) }
                    }
                }
            }

            ForEach(Array(pending).filter { id in !outcomes.contains { $0.siteId == id } }, id: \.self) { id in
                Section(env.sites.name(ofSite: id)) {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("search.searching").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func start() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        task?.cancel()
        outcomes = []
        hasSearched = true

        let rules: [SiteRule]
        switch scope {
        case .all: rules = searchable
        case .site(let id): rules = env.sites.rule(id: id).map { [$0] } ?? []
        }
        pending = Set(rules.map(\.id))

        task = Task {
            for await outcome in env.search.searchAll(trimmed, in: rules) {
                outcomes.append(outcome)
                pending.remove(outcome.siteId)
            }
            pending = []
        }
    }

    /// A hit is bookmarked straight from its search row: the row already carries
    /// title, author and cover, so opening the book page first would be a second
    /// round-trip for data we have.
    private func add(_ result: SearchResult) {
        guard let rule = env.sites.rule(id: result.siteId) else { return }
        Task {
            do {
                // Awaits the catalog too, so the book is readable the moment it
                // appears in the library rather than on its second open.
                try await env.addBook(
                    rule: rule,
                    siteBookId: result.siteBookId,
                    info: BookService.Info(
                        title: result.title, author: result.author, cover: result.coverURL,
                        category: nil, status: nil, intro: nil, latestChapter: nil
                    )
                )
                env.banner = String(localized: "search.added")
            } catch {
                env.report(error)
            }
        }
    }

    private func message(for error: any Error) -> String {
        if case ExtractorScript.BuildError.searchUnsupported = error {
            return String(localized: "search.unsupported")
        }
        return error.localizedDescription
    }
}

private struct ResultRow: View {
    let result: SearchResult

    var body: some View {
        HStack(spacing: 12) {
            CoverImage(urlString: result.coverURL)
                .frame(width: 40, height: 54)
            VStack(alignment: .leading, spacing: 3) {
                Text(result.title).lineLimit(2)
                if let author = result.author, !author.isEmpty {
                    Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "plus.circle").foregroundStyle(.tint)
        }
    }
}
