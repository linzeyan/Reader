import SwiftUI
import UniformTypeIdentifiers

/// Where a bookmark is turned into something readable: metadata, the chapter
/// index, and the download controls (requirements 4.2 / 4.3).
struct BookDetailView: View {
    let book: Book

    @Environment(AppEnvironment.self) private var env
    @State private var chapters: [Chapter] = []
    @State private var isRefreshing = false
    @State private var query = ""
    @State private var isExporting = false
    /// The format waiting for the user to accept that the file will be
    /// incomplete. Non-nil only while that question is on screen.
    @State private var partialFormat: BookExporter.Format?
    /// A finished export, waiting for the user to choose where it goes.
    @State private var pendingExport: BookExporter.Export?

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
            // An imported book has no rule and needs none: its text is already on
            // the device. Warning about a missing rule would be telling the user
            // to install something to fix a book that works.
            if rule == nil && !current.isLocal {
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
                        NavigationLink(value: ReadingTarget(book: current, position: .chapterStart(chapter.index))) {
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
            ReaderView(book: target.book, position: target.position)
        }
        .toolbar {
            // Hidden, not disabled, for an imported book: there is nowhere to
            // refresh a catalog from, and a permanently greyed-out button reads
            // as something being broken.
            if !current.isLocal {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await refreshCatalog() }
                    } label: {
                        Label("book.catalog.refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(isRefreshing || rule == nil)
                }
            }
            ToolbarItem(placement: .topBarTrailing) { exportMenu }
        }
        // Asked *before* the file is written, not reported after: someone
        // exporting a book to read elsewhere needs the chance to download the
        // rest first, and by the time a file is in the share sheet the decision
        // has already been made for them.
        .confirmationDialog(
            Text("book.export.partial \(downloadedCount) \(chapters.count)"),
            isPresented: partialBinding,
            titleVisibility: .visible,
            // `presenting:` rather than reading the state inside the action:
            // dismissing the dialog clears it, and which format was tapped must
            // not depend on whether that happens first.
            presenting: partialFormat
        ) { format in
            Button("book.export.partial.confirm") { Task { await runExport(format) } }
            Button("common.cancel", role: .cancel) {}
        }
        .fileExporter(
            isPresented: exportBinding,
            document: pendingExport.map(BookExportDocument.init),
            contentType: pendingExport?.format.contentType ?? .plainText,
            defaultFilename: pendingExport?.filename
        ) { result in
            if case .failure(let error) = result { env.report(error) }
            pendingExport = nil
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
        // Continuing lands on the stored anchor, not merely in the right chapter:
        // that is the whole point of recording a paragraph.
        NavigationLink(
            value: ReadingTarget(book: current, position: current.readingPosition ?? .chapterStart(0))
        ) {
            Label(
                current.readingPosition == nil ? "book.startReading" : "book.continueReading",
                systemImage: "book"
            )
        }
        .accessibilityIdentifier("book.read")
        .disabled(chapters.isEmpty)

        // Always present, and with no count on it. A row that appears only once the
        // feature has been used is a feature nobody finds, and a count cached here
        // would go stale the moment a bookmark is added in the reader pushed on top
        // of this screen — the list itself is the one place that cannot be wrong.
        NavigationLink {
            BookmarkListView(book: current)
        } label: {
            Label("bookmarks.title", systemImage: "bookmark")
        }
        .accessibilityIdentifier("book.bookmarks")

        // One entry point rather than "download all" and "delete all" buttons:
        // both of those live on the management screen now, next to the
        // per-chapter selection that makes them make sense.
        //
        // Absent for an imported book: every one of its chapters is already on the
        // device, so the screen would offer nothing but a way to delete the book's
        // only copy of its own text.
        if !current.isLocal {
            NavigationLink {
                ChapterDownloadView(book: current)
            } label: {
                Label("downloads.title", systemImage: "arrow.down.circle")
            }
            .accessibilityIdentifier("book.downloads")
            .disabled(chapters.isEmpty)
        }
    }

    /// In the toolbar rather than among the actions below, for two reasons: it is
    /// an action on the whole book, and the actions section is the one thing this
    /// screen hides when a book's rule has gone missing — which is exactly the
    /// moment rescuing the text that is still on the device matters most.
    @ViewBuilder
    private var exportMenu: some View {
        if isExporting {
            ProgressView()
        } else {
            Menu {
                Button {
                    beginExport(.text)
                } label: {
                    Label("book.export.text", systemImage: "doc.plaintext")
                }
                Button {
                    beginExport(.epub)
                } label: {
                    Label("book.export.epub", systemImage: "book.closed")
                }
            } label: {
                Label("book.export", systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("book.export")
            // Disabled rather than hidden: the header directly above already says
            // how many chapters are on the device, so a greyed-out export reads as
            // "nothing to write yet" rather than as a broken button.
            .disabled(downloadedCount == 0)
        }
    }

    private var partialBinding: Binding<Bool> {
        Binding(get: { partialFormat != nil }, set: { if !$0 { partialFormat = nil } })
    }

    private var exportBinding: Binding<Bool> {
        Binding(get: { pendingExport != nil }, set: { if !$0 { pendingExport = nil } })
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

    // MARK: - Exporting

    /// A whole book goes straight to work; a partial one asks first.
    private func beginExport(_ format: BookExporter.Format) {
        if downloadedCount < chapters.count {
            partialFormat = format
        } else {
            Task { await runExport(format) }
        }
    }

    /// `BookExporter` is not main-actor bound, so the reads and the deflate pass
    /// leave this actor on their own; only the state around them is set here.
    private func runExport(_ format: BookExporter.Format) async {
        partialFormat = nil
        isExporting = true
        defer { isExporting = false }
        do {
            pendingExport = try await BookExporter(downloads: env.downloads)
                .export(book: current, chapters: chapters, format: format)
        } catch {
            env.report(error)
        }
    }

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

/// The bytes an export produced, in the shape `fileExporter` wants.
///
/// `fileExporter` rather than a `ShareLink`: a share link needs its file to exist
/// when the button is *drawn*, which would mean writing out a whole novel every
/// time this screen appears, on the chance that someone taps it. The save sheet it
/// presents can still hand the file to another app, and it is what "export" means
/// here — a file the user files away, not a message they send.
///
/// Write-only. The app already reads these files, through `LocalBookImporter`, and
/// a second way in would be a second thing to keep correct.
struct BookExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .epub] }

    private let data: Data

    init(_ export: BookExporter.Export) { data = export.data }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Which book to open and where. Small and hashable so it can be a navigation
/// path value — the reader re-reads the chapter list itself rather than having a
/// 600-element array pushed through the stack.
struct ReadingTarget: Hashable {
    let book: Book
    let position: ReadingPosition
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
