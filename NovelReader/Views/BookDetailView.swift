import SwiftUI

/// Where a bookmark is turned into something readable: metadata, the chapter
/// index, and the download controls (requirements 4.2 / 4.3).
struct BookDetailView: View {
    let book: Book

    @Environment(AppEnvironment.self) private var env
    @State private var chapters: [Chapter] = []
    @State private var isRefreshing = false
    @State private var query = ""

    private var rule: SiteRule? { env.sites.rule(id: book.siteId) }

    /// The live row, so a rename or a progress update made elsewhere shows here.
    private var current: Book { env.books.first { $0.id == book.id } ?? book }

    private var filtered: [Chapter] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return chapters }
        return chapters.filter { $0.title.localizedStandardContains(trimmed) }
    }

    var body: some View {
        List {
            Section { header }
            if rule == nil {
                Section {
                    Label("book.missingRule", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } else {
                Section { actions }
                // Only while there is a run to show. A finished run clears its
                // progress, so this section cannot outlive the download.
                if env.downloader.progress?.bookId == book.id,
                   env.downloader.status == .running || env.downloader.status == .paused {
                    Section("book.downloading") { downloadStatus }
                }
            }
            Section {
                if chapters.isEmpty {
                    Text(isRefreshing ? "book.catalog.loading" : "book.catalog.empty")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filtered) { chapter in
                        NavigationLink(value: ReadingTarget(book: current, startIndex: chapter.index)) {
                            ChapterRow(chapter: chapter, book: current)
                        }
                    }
                }
            } header: {
                Text("book.catalog \(chapters.count)")
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer, prompt: Text("book.catalog.search"))
        .navigationTitle(current.shownName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: ReadingTarget.self) { target in
            ReaderView(book: target.book, startIndex: target.startIndex)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await refreshCatalog() }
                } label: {
                    Label("book.catalog.refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isRefreshing || rule == nil)
            }
        }
        .task { await loadChapters() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            CoverImage(urlString: current.coverURL)
                .frame(width: 72, height: 100)
            VStack(alignment: .leading, spacing: 6) {
                Text(current.shownName).font(.headline)
                if let author = current.author, !author.isEmpty {
                    Text(author).font(.subheadline).foregroundStyle(.secondary)
                }
                Text(env.sites.name(ofSite: current.siteId))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text("book.downloaded \(downloadedCount) \(chapters.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var actions: some View {
        NavigationLink(value: ReadingTarget(book: current, startIndex: current.lastReadChapterIndex ?? 0)) {
            Label(
                current.lastReadChapterIndex == nil ? "book.startReading" : "book.continueReading",
                systemImage: "book"
            )
        }
        .accessibilityIdentifier("book.read")
        .disabled(chapters.isEmpty)

        // One entry point rather than "download all" and "delete all" buttons:
        // both of those live on the management screen now, next to the
        // per-chapter selection that makes them make sense.
        NavigationLink {
            ChapterDownloadView(book: current)
        } label: {
            Label("downloads.title", systemImage: "arrow.down.circle")
        }
        .accessibilityIdentifier("book.downloads")
        .disabled(chapters.isEmpty)
    }

    @ViewBuilder
    private var downloadStatus: some View {
        if let progress = env.downloader.progress {
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: progress.fraction) {
                    Text("book.download.progress \(progress.completed) \(progress.total)")
                        .font(.footnote)
                }
                if let error = env.downloader.lastError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    if env.downloader.isBusy {
                        Button("book.download.pause") { env.downloader.pause() }
                    } else if env.downloader.canResume {
                        Button("book.download.resume") { env.requestResume() }
                    }
                    Spacer()
                    Button("common.cancel", role: .destructive) {
                        env.downloader.cancel()
                        Task { await loadChapters() }
                    }
                }
                .font(.footnote)
            }
        }
    }

    private var downloadedCount: Int { chapters.filter(\.isDownloaded).count }

    // MARK: - Loading

    /// The stored catalog is shown immediately; the site is only consulted when
    /// there is nothing to show, or when what there is has gone stale.
    ///
    /// A book with 1300 chapters must not re-hit the site on every open — but it
    /// also must not go a week without noticing new chapters. So: never fetched
    /// → fetch and wait (there is nothing else to display); older than a day →
    /// fetch quietly behind the list that is already on screen.
    private func loadChapters() async {
        chapters = (try? env.repo.chapters(bookId: book.id)) ?? []
        if chapters.isEmpty {
            await refreshCatalog()
        } else if current.isCatalogStale {
            await refreshCatalog(silently: true)
        }
    }

    /// - Parameter silently: the user did not ask for this one, so a failure
    ///   leaves the cached list alone without an error banner. A challenge still
    ///   goes through — that one needs a human and nothing else will say so.
    private func refreshCatalog(silently: Bool = false) async {
        guard let rule, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            chapters = try await env.bookService.refreshCatalog(rule: rule, book: current)
            // The write went to the database, not to the in-memory library, and
            // this is the moment new chapters appear — without this the shelf
            // keeps showing yesterday's count until something else reloads it.
            env.reloadLibrary()
        } catch {
            if case WebFetcher.FetchError.challengePresented = error {
                env.report(error)
            } else if !silently {
                env.report(error)
            }
        }
    }
}

/// Which book to open and where. Small and hashable so it can be a navigation
/// path value — the reader re-reads the chapter list itself rather than having a
/// 600-element array pushed through the stack.
struct ReadingTarget: Hashable {
    let book: Book
    let startIndex: Int
}

struct ChapterRow: View {
    let chapter: Chapter
    /// The owning book, which is what makes "new" answerable — the flag depends
    /// on the reading position, which lives on the book. Passed explicitly, with
    /// no default: three screens draw this row, and a default would let one of
    /// them silently stop showing the marker.
    let book: Book

    var body: some View {
        HStack {
            Text(chapter.title)
                .lineLimit(1)
                .foregroundStyle(chapter.isDownloaded ? .primary : .secondary)
            Spacer()
            // Deliberately the same weight as the downloaded arrow next to it:
            // this is a hint about one row, not a call to action.
            if chapter.isNew(in: book) {
                Text("chapter.new")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.red)
            }
            if chapter.isDownloaded {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
    }
}
