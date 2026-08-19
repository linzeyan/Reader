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
    /// Where a long-pressed range extends from: the chapter most recently ticked on
    /// its own. An anchor rather than filling between any two taps, because scattered
    /// picking — three arcs' worth of single ticks — is this screen's other job, and
    /// taps that quietly select everything in between would take it away. A long
    /// press is the reader saying "through to here"; a tap keeps meaning one row.
    @State private var rangeAnchorId: String?

    private var rule: SiteRule? { env.sites.rule(id: book.siteId) }

    private var filtered: [Chapter] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return chapters }
        return chapters.filter { $0.title.localizedStandardContains(trimmed) }
    }

    private var selectedChapters: [Chapter] { chapters.filter { selection.contains($0.id) } }
    /// Lazily, for the reason given on `BookDetailView.downloadedCount`.
    private var downloadedCount: Int { chapters.lazy.filter(\.isDownloaded).count }
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
                // Resolved once for the list, not once per row. `lastReadIndex(in:)`
                // scans the catalog, so reading it inside the loop is quadratic — a
                // thirteen-hundred-chapter book spent the best part of a million string
                // comparisons on every pass, and the download screen re-evaluates on
                // every chapter that lands.
                let lastReadIndex = book.lastReadIndex(in: chapters)
                ForEach(filtered) { chapter in
                    ChapterRow(chapter: chapter, lastReadIndex: lastReadIndex)
                        .tag(chapter.id)
                        // Simultaneous, not `onLongPressGesture`: an exclusive
                        // recognizer on the row makes the list's own edit-mode tap
                        // wait on it, and ticking one chapter stops working — the
                        // screen's basic gesture lost to its convenience one.
                        .simultaneousGesture(
                            LongPressGesture().onEnded { _ in extendSelection(to: chapter) }
                        )
                }
            } header: {
                Text("book.catalog \(chapters.count)")
            } footer: {
                // Said on the screen because a gesture with no affordance is a
                // feature that only its author uses.
                Text("downloads.rangeHint")
            }
        }
        .onChange(of: selection) { old, new in
            // A single fresh tick moves the anchor; a range fill or "select all"
            // adds many at once and deliberately does not — the anchor is about
            // the reader's last single choice. An anchor that got unticked is
            // gone: extending from a row that is no longer selected would select
            // a stretch starting somewhere unmarked.
            let added = new.subtracting(old)
            if added.count == 1 { rangeAnchorId = added.first }
            if let anchor = rangeAnchorId, !new.contains(anchor) { rangeAnchorId = nil }
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
                .accessibilityIdentifier("downloads.selectedCount")
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

    /// Ticks everything from the anchor through `chapter`, both ends included.
    ///
    /// Over the *filtered* rows, not the whole catalog: with a search narrowing the
    /// list, the rows between two results are not on screen, and selecting what
    /// cannot be seen is how people delete chapters they never chose. Without a
    /// live anchor the press falls back to ticking the one row, which also plants
    /// the anchor — so press, then press, works the same as tap, then press.
    private func extendSelection(to chapter: Chapter) {
        let rows = filtered
        guard let anchor = rangeAnchorId,
              let from = rows.firstIndex(where: { $0.id == anchor }),
              let to = rows.firstIndex(where: { $0.id == chapter.id })
        else {
            selection.insert(chapter.id)
            rangeAnchorId = chapter.id
            return
        }
        selection.formUnion(rows[min(from, to)...max(from, to)].map(\.id))
        rangeAnchorId = chapter.id
    }

    /// Through the environment rather than straight to the queue: on a metered
    /// connection under the Wi-Fi-only policy this asks before spending data.
    private func start(_ wanted: [Chapter]) {
        guard let rule else { return }
        env.requestDownload(book: book, rule: rule, chapters: wanted)
    }

    private func reload() {
        chapters = (try? env.repo.chapters(bookId: book.id)) ?? []
        // A chapter deleted elsewhere must not stay ticked in a stale selection.
        let live = Set(chapters.map(\.id))
        selection = selection.intersection(live)
    }
}
