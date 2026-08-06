import SwiftUI

/// Picking exactly which chapters to keep on the device.
///
/// The book screen only offers "all" and "none", which is the wrong granularity
/// for a 1300-chapter novel: people download the arc they are reading, and clear
/// the arcs they have finished. This screen is that middle ground — select a
/// range, download it, and later select the same rows and delete them.
///
/// Selection is by chapter id rather than by index so that a catalog refresh
/// arriving mid-selection cannot silently reassign the ticks to other chapters.
struct ChapterDownloadView: View {
    let book: Book

    @Environment(AppEnvironment.self) private var env
    @State private var chapters: [Chapter] = []
    @State private var selection: Set<String> = []
    @State private var query = ""
    @State private var confirmingDelete = false

    private var rule: SiteRule? { env.sites.rule(id: book.siteId) }

    private var filtered: [Chapter] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return chapters }
        return chapters.filter { $0.title.localizedStandardContains(trimmed) }
    }

    private var selectedChapters: [Chapter] { chapters.filter { selection.contains($0.id) } }
    private var downloadedCount: Int { chapters.filter(\.isDownloaded).count }
    /// Only chapters that are actually missing are worth queueing.
    private var selectedPending: [Chapter] { selectedChapters.filter { !$0.isDownloaded } }
    private var selectedDownloaded: [Chapter] { selectedChapters.filter(\.isDownloaded) }

    var body: some View {
        List(selection: $selection) {
            Section {
                LabeledContent("book.downloaded \(downloadedCount) \(chapters.count)") {
                    Text(sizeText)
                        .foregroundStyle(.secondary)
                }
                if let progress = env.downloader.progress, progress.bookId == book.id,
                   env.downloader.status == .running || env.downloader.status == .paused {
                    ProgressView(value: progress.fraction) {
                        Text("book.download.progress \(progress.completed) \(progress.total)")
                            .font(.footnote)
                    }
                }
            }

            Section {
                Button {
                    start(chapters)
                } label: {
                    Label("downloads.downloadAll", systemImage: "arrow.down.circle")
                }
                .accessibilityIdentifier("downloads.all")
                .disabled(rule == nil || downloadedCount == chapters.count || env.downloader.isBusy)

                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("downloads.deleteAll", systemImage: "trash")
                }
                .accessibilityIdentifier("downloads.deleteAll")
                .disabled(downloadedCount == 0)
            }

            Section {
                ForEach(filtered) { chapter in
                    ChapterRow(chapter: chapter)
                        .tag(chapter.id)
                }
            } header: {
                Text("book.catalog \(chapters.count)")
            }
        }
        .environment(\.editMode, .constant(.active))
        .searchable(text: $query, placement: .navigationBarDrawer, prompt: Text("book.catalog.search"))
        .navigationTitle("downloads.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(selection.count == chapters.count ? "downloads.selectNone" : "downloads.selectAll") {
                    // Toggles over *all* chapters, not the filtered ones: the
                    // button reads "select all", and quietly meaning "all the
                    // ones matching your search" is how people lose a selection.
                    selection = selection.count == chapters.count ? [] : Set(chapters.map(\.id))
                }
                .accessibilityIdentifier("downloads.selectAll")
            }
        }
        .safeAreaInset(edge: .bottom) { if !selection.isEmpty { selectionBar } }
        .confirmationDialog("downloads.deleteAll.confirm", isPresented: $confirmingDelete) {
            Button("downloads.deleteAll", role: .destructive) {
                try? env.downloads.delete(.book(book))
                reload()
            }
        }
        .task { reload() }
        .onChange(of: env.downloader.progress?.completed) { _, _ in reload() }
        .onChange(of: env.downloader.status) { _, _ in reload() }
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            // Clearing the ticks needs its own button: the toolbar one flips to
            // "deselect all" only once *everything* is selected, which is no help
            // after ticking three chapters by hand.
            Button {
                selection = []
            } label: {
                Label("downloads.clearSelection", systemImage: "xmark.circle")
            }
            .accessibilityIdentifier("downloads.clearSelection")

            Text("downloads.selected \(selection.count)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                start(selectedChapters)
                selection = []
            } label: {
                Label("downloads.download", systemImage: "arrow.down.circle")
            }
            .accessibilityIdentifier("downloads.downloadSelected")
            .disabled(rule == nil || selectedPending.isEmpty || env.downloader.isBusy)

            Button(role: .destructive) {
                for chapter in selectedDownloaded {
                    try? env.downloads.delete(.chapter(book: book, siteChapterId: chapter.siteChapterId))
                }
                selection = []
                reload()
            } label: {
                Label("downloads.delete", systemImage: "trash")
            }
            .accessibilityIdentifier("downloads.deleteSelected")
            .disabled(selectedDownloaded.isEmpty)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var sizeText: String {
        let bytes = env.downloads.size(of: .book(book))
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func start(_ wanted: [Chapter]) {
        guard let rule else { return }
        env.downloader.start(book: book, rule: rule, chapters: wanted)
    }

    private func reload() {
        chapters = (try? env.repo.chapters(bookId: book.id)) ?? []
        // A chapter deleted elsewhere must not stay ticked in a stale selection.
        let live = Set(chapters.map(\.id))
        selection = selection.intersection(live)
    }
}
