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
    /// 0…1 while an export runs, nil otherwise — so it doubles as "busy", the
    /// same way the library's import banner works.
    @State private var exportProgress: Double?
    /// The export in flight, held so the banner's cancel button has something to
    /// pull. At most one: the menu that starts an export is replaced by its own
    /// progress indicator while one is running.
    @State private var exportTask: Task<Void, Never>?
    /// The export waiting for the user to accept that the file will be
    /// incomplete. Non-nil only while that question is on screen.
    @State private var partialChoice: ExportChoice?
    /// A finished export, waiting for the user to choose where it goes.
    @State private var pendingExport: BookExporter.Export?
    /// The same, for a comic — a different type because it can be several files.
    @State private var pendingComicExport: ComicExporter.Export?

    /// What was asked for. The two novel formats and the comic archive share one
    /// path because everything around them is the same — the partial warning, the
    /// banner, the cancel button — and only the writer at the far end differs.
    private enum ExportChoice: Equatable {
        case text
        case epub
        case comic

        var novelFormat: BookExporter.Format? {
            switch self {
            case .text: return .text
            case .epub: return .epub
            case .comic: return nil
            }
        }
    }

    private var rule: SiteRule? { env.sites.rule(id: book.siteId) }

    /// The live row, so a rename or a progress update made elsewhere shows here.
    private var current: Book { env.books.first { $0.id == book.id } ?? book }

    /// The search box and the order control, applied. Evaluated once per body and handed
    /// to the section that draws it: filtering thirteen hundred titles is not something to
    /// do twice because two parts of one list want the answer.
    private var catalog: BookCatalog {
        BookCatalog(
            chapters: chapters,
            query: query,
            descending: env.librarySettings.isCatalogDescending(bookId: book.id),
            lastReadSiteChapterId: current.lastReadSiteChapterId
        )
    }

    /// Resolved once for the whole list rather than per row, and computed rather than
    /// stored: reading somewhere else in the app moves it, and a copy taken when the
    /// catalog loaded would keep marking a chapter the reader has already passed.
    private var lastReadIndex: Int? { current.lastReadIndex(in: chapters) }

    /// Where the read button goes: the stored position, or the first chapter for a book
    /// nobody has opened. Nil only while there is no catalog to name a chapter with,
    /// which is the same state `disabled` reports on the row itself.
    private var readingTarget: ReadingTarget? {
        let position = current.readingPosition
            ?? chapters.first.map { .chapterStart($0.siteChapterId) }
        return position.map { ReadingTarget(book: current, position: $0) }
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
            catalogSection(catalog)
        }
        .searchable(text: $query, placement: .navigationBarDrawer, prompt: Text("book.catalog.search"))
        .navigationTitle(current.shownName)
        .navigationBarTitleDisplayMode(.inline)
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
            ToolbarItem(placement: .topBarTrailing) {
                // A menu for a novel because there are two text formats to choose
                // between; a button for a comic because there is one archive and a
                // menu of one item is a tap nobody needs.
                if current.kind == .novel {
                    exportMenu
                } else {
                    comicExportButton
                }
            }
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
            presenting: partialChoice
        ) { choice in
            Button("book.export.partial.confirm") { startExport(choice) }
            Button("common.cancel", role: .cancel) {}
        }
        .fileExporter(
            isPresented: exportBinding,
            document: pendingExport.map { BookExportDocument($0.url) },
            contentType: pendingExport?.format.contentType ?? .plainText,
            defaultFilename: pendingExport?.filename
        ) { result in
            if case .failure(let error) = result { env.report(error) }
            // The book was written to a temporary file so it never had to sit in
            // memory; the save sheet has taken its own copy by now, so the
            // temporary one is only wasted space from here on.
            if let url = pendingExport?.url { try? FileManager.default.removeItem(at: url) }
            pendingExport = nil
        }
        // Its own sheet because a comic can come out as several files, and the
        // multi-document exporter asks for a folder to put them in rather than a
        // filename. Each document carries its own name (see `ExportedFileWrapper`),
        // which is what keeps the parts from landing on top of one another.
        .fileExporter(
            isPresented: comicExportBinding,
            documents: (pendingComicExport?.urls ?? []).map(BookExportDocument.init),
            contentType: .zip
        ) { result in
            if case .failure(let error) = result { env.report(error) }
            for url in pendingComicExport?.urls ?? [] {
                try? FileManager.default.removeItem(at: url)
            }
            pendingComicExport = nil
        }
        .overlay(alignment: .top) { exportBanner }
        .animation(.snappy, value: exportProgress == nil)
        .task { await loadChapters() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            BookCover(book: current)
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
        NavigationLink(value: readingTarget) {
            Label(
                current.readingPosition == nil ? "book.startReading" : "book.continueReading",
                systemImage: "book"
            )
        }
        .accessibilityIdentifier("book.read")
        .disabled(chapters.isEmpty)

        // Always present, and with no count on it. A row that appears only once the
        // feature has been used is a feature nobody finds, and a count cached here
        // would go stale the moment a mark is added in the reader pushed on top
        // of this screen — the list itself is the one place that cannot be wrong.
        //
        // One row for both kinds of mark: see `ReadingMarksView` for why they share a
        // screen rather than growing a row each.
        // Novels only: a bookmark and a highlight are both anchored to text, and a
        // comic has none to anchor to. Hidden rather than disabled because this one is
        // not coming back — it is not a feature a comic is waiting for.
        if current.kind == .novel {
            NavigationLink {
                ReadingMarksView(book: current)
            } label: {
                Label("marks.title", systemImage: "bookmark")
            }
            .accessibilityIdentifier("book.marks")
        }

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

    /// The chapter list: where the reader left off, pinned above it, then the catalog
    /// in whichever direction this book is being read.
    @ViewBuilder
    private func catalogSection(_ catalog: BookCatalog) -> some View {
        Section {
            if let lastRead = catalog.lastRead { lastReadRow(lastRead) }
            if chapters.isEmpty {
                Text(isRefreshing ? "book.catalog.loading" : "book.catalog.empty")
                    .foregroundStyle(.secondary)
            } else {
                // Read into a local before the loop: `lastReadIndex` is computed, and
                // computing it scans the catalog, so touching it per row makes drawing
                // a thirteen-hundred-chapter list quadratic.
                let lastRead = lastReadIndex
                ForEach(catalog.chapters) { chapter in
                    NavigationLink(
                        value: ReadingTarget(
                            book: current, position: .chapterStart(chapter.siteChapterId)
                        )
                    ) {
                        ChapterRow(chapter: chapter, lastReadIndex: lastRead)
                    }
                }
            }
        } header: {
            HStack {
                // The count is of the book, not of what the search left: it is how long
                // the novel is, and a header that changed with every keystroke would be
                // reporting the query back rather than the book.
                Text("book.catalog \(chapters.count)")
                Spacer()
                // Absent while there is no catalog: there is nothing to put in an
                // order yet.
                if !chapters.isEmpty { orderToggle }
            }
        }
    }

    /// Where the reader left off, in full: which chapter, and how far into it.
    ///
    /// The actions section above already offers to continue, but it does not say *where*
    /// — and a button whose destination you have to press it to learn is one people press
    /// warily. This goes to exactly the same place, by the same stored anchor, and says so
    /// first. Pinned above the list because the alternative is finding one row among
    /// thirteen hundred, which is the position marker's whole problem.
    private func lastReadRow(_ chapter: Chapter) -> some View {
        NavigationLink(value: readingTarget) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("book.lastRead")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(chapter.title).lineLimit(1)
                }
                Spacer()
                // Only where the position was recorded finely enough to have one — see
                // `Book.lastReadFraction`.
                if let fraction = current.lastReadFraction {
                    Text(verbatim: TextAnchor.shareText(fraction))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier("book.lastRead")
    }

    /// Which end of the book the catalog starts at, remembered for this book alone —
    /// see `LibrarySettings.catalogDescending` for why that is per book.
    ///
    /// A one-tap toggle in the section header rather than the old navigation-bar menu:
    /// the order is a fact about the rows under the header, and the menu's reason to
    /// exist — a lone arrow leaves the reader to work out which way the list goes — is
    /// kept by naming the current order on the label itself.
    private var orderToggle: some View {
        Button {
            orderBinding.wrappedValue.toggle()
        } label: {
            Label(
                orderBinding.wrappedValue
                    ? "book.catalog.order.descending" : "book.catalog.order.ascending",
                systemImage: orderBinding.wrappedValue ? "arrow.up" : "arrow.down"
            )
            .font(.caption2)
        }
        .accessibilityIdentifier("book.catalog.order")
    }

    /// The settings object comes from the environment without bindings, and this one is
    /// keyed by book, so the binding is built by hand rather than with `@Bindable`.
    private var orderBinding: Binding<Bool> {
        Binding(
            get: { env.librarySettings.isCatalogDescending(bookId: book.id) },
            set: { env.librarySettings.setCatalogDescending($0, bookId: book.id) }
        )
    }

    /// In the toolbar rather than among the actions below, for two reasons: it is
    /// an action on the whole book, and the actions section is the one thing this
    /// screen hides when a book's rule has gone missing — which is exactly the
    /// moment rescuing the text that is still on the device matters most.
    @ViewBuilder
    private var exportMenu: some View {
        if exportProgress != nil {
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

    /// A comic's export: one button, because there is one thing it can produce.
    /// Disabled for the same reason the menu is — see `exportMenu`.
    private var comicExportButton: some View {
        Group {
            if exportProgress != nil {
                ProgressView()
            } else {
                Button {
                    beginExport(.comic)
                } label: {
                    Label("book.export", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("book.export")
                .disabled(downloadedCount == 0)
            }
        }
    }

    private var partialBinding: Binding<Bool> {
        Binding(get: { partialChoice != nil }, set: { if !$0 { partialChoice = nil } })
    }

    private var exportBinding: Binding<Bool> {
        Binding(get: { pendingExport != nil }, set: { if !$0 { pendingExport = nil } })
    }

    private var comicExportBinding: Binding<Bool> {
        Binding(get: { pendingComicExport != nil }, set: { if !$0 { pendingComicExport = nil } })
    }

    /// The same banner an import gets, for the same reason: writing out a
    /// thirteen-hundred-chapter novel is a minute of the app doing one thing, so
    /// it has to say how far along it is and it has to offer a way out.
    @ViewBuilder
    private var exportBanner: some View {
        if let exportProgress {
            HStack(spacing: 14) {
                ProgressView(value: exportProgress) { Text("book.export.working") }
                Button("common.cancel") { exportTask?.cancel() }
                    .accessibilityIdentifier("book.export.cancel")
            }
            .font(.footnote)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar, in: .rect(cornerRadius: 12))
            .padding(.horizontal)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
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

    /// Counted lazily: the eager `filter` allocated a second array of every downloaded
    /// chapter — a hundred and fifty kilobytes on a long book — to arrive at an integer,
    /// and this is read several times per pass.
    private var downloadedCount: Int { chapters.lazy.filter(\.isDownloaded).count }

    // MARK: - Exporting

    /// A whole book goes straight to work; a partial one asks first.
    private func beginExport(_ choice: ExportChoice) {
        if downloadedCount < chapters.count {
            partialChoice = choice
        } else {
            startExport(choice)
        }
    }

    /// Wrapped in a task rather than awaited straight from the button so the
    /// banner's cancel button has a handle to pull — the same shape
    /// `AppEnvironment.importLocalBook` uses for the import.
    private func startExport(_ choice: ExportChoice) {
        exportTask = Task { await runExport(choice) }
    }

    /// `BookExporter` is not main-actor bound, so the reads and the deflate pass
    /// leave this actor on their own; only the state around them is set here —
    /// explicitly, because the progress callback comes back to this actor from
    /// wherever the export happens to be running.
    @MainActor
    private func runExport(_ choice: ExportChoice) async {
        partialChoice = nil
        exportProgress = 0
        defer {
            exportProgress = nil
            exportTask = nil
        }
        do {
            if let format = choice.novelFormat {
                pendingExport = try await BookExporter(
                    downloads: env.downloads, covers: env.coverFiles
                )
                .export(book: current, chapters: chapters, format: format) { exportProgress = $0 }
            } else {
                pendingComicExport = try await ComicExporter(
                    files: env.files, covers: env.coverFiles
                )
                .export(book: current, chapters: chapters) { exportProgress = $0 }
            }
        } catch is CancellationError {
            // Stopping was the user's own decision, and the banner going away is
            // the answer. An error banner would read as the export having broken.
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
            if WebFetcher.needsTheUser(error) || !silently { env.report(error) }
        }
    }
}

/// The file an export produced, in the shape `fileExporter` wants.
///
/// `fileExporter` rather than a `ShareLink`: a share link needs its file to exist
/// when the button is *drawn*, which would mean writing out a whole novel every
/// time this screen appears, on the chance that someone taps it. The save sheet it
/// presents can still hand the file to another app, and it is what "export" means
/// here — a file the user files away, not a message they send.
///
/// Carries a URL rather than the bytes. A novel is megabytes, the save sheet can
/// stay open for a while, and there is nothing for those bytes to do in the
/// meantime.
///
/// Write-only. The app already reads these files, through `LocalBookImporter`, and
/// a second way in would be a second thing to keep correct.
struct BookExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .epub, .zip] }

    private let url: URL

    init(_ url: URL) { self.url = url }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try ExportedFileWrapper(copying: url)
    }
}

/// A file wrapper that puts the export where it is asked to by copying the file.
///
/// `FileWrapper`'s own `write` reads the whole file into memory to write it out
/// again, which is exactly what streaming the export to disk was meant to avoid.
/// A filesystem copy is a clone on APFS and a streamed copy anywhere else.
///
/// Backed by the URL rather than by data, so that a caller which ignores this
/// override still writes the right bytes — just the slow way.
private final class ExportedFileWrapper: FileWrapper {
    private let source: URL

    init(copying source: URL) throws {
        self.source = source
        try super.init(url: source, options: [])
    }

    required init?(coder: NSCoder) {
        // Never archived: this wrapper exists only between building the file and
        // the save sheet writing it out.
        return nil
    }

    override func write(
        to url: URL, options: FileWrapper.WritingOptions = [], originalContentsURL: URL?
    ) throws {
        // `copyItem` refuses to overwrite, and the save sheet has already created
        // the destination by the time it asks for the contents.
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: source, to: url)
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
    /// How far the reader got, in reading order, which is what makes "new" answerable —
    /// the flag is a comparison against their position. Resolved by the caller from the
    /// book and its catalog (`Book.lastReadIndex(in:)`), because the position names a
    /// chapter and only the catalog can say what number that is. Passed explicitly, with
    /// no default: three screens draw this row, and a default would let one of them
    /// silently stop showing the marker.
    let lastReadIndex: Int?

    var body: some View {
        HStack {
            Text(chapter.title)
                .lineLimit(1)
                .foregroundStyle(chapter.isDownloaded ? .primary : .secondary)
            Spacer()
            // Deliberately the same weight as the downloaded arrow next to it:
            // this is a hint about one row, not a call to action.
            if chapter.isNew(lastReadIndex: lastReadIndex) {
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
