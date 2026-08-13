import SwiftUI
import UniformTypeIdentifiers

/// Requirement 3: bookmarks, grouped per source.
///
/// Grouping is by site *by default* rather than one flat list because the same
/// novel is often bookmarked on two sites (different translations, different
/// update speeds) and a flat list makes those look like duplicates. Someone who
/// reads from a single source has no such problem, so the grouping is a toggle.
///
/// The arrangement itself is not decided here — `LibraryShelf` sorts, groups and
/// filters, this view draws the result. That split is what makes the ordering
/// rules testable without a simulator.
struct LibraryView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var adding = false
    @State private var picking = false
    /// 0…1 while an import runs, nil otherwise — so it doubles as "busy".
    @State private var importProgress: Double?
    @State private var renaming: Book?
    @State private var draftName = ""
    /// The imported book a swipe is about to destroy. Only imported books get
    /// asked about, because only they have nowhere to come back from.
    @State private var confirmingLocalDelete: Book?

    var body: some View {
        NavigationStack {
            Group {
                let sections = env.shelf
                if env.books.isEmpty {
                    emptyState
                } else if sections.isEmpty {
                    // Reachable only through the filter, and it has to offer the
                    // way out: a shelf that looks empty with books on it is the one
                    // state a persisted filter can leave someone stranded in.
                    filteredEmptyState
                } else {
                    list(sections)
                }
            }
            .navigationTitle("tab.library")
            .toolbar {
                // Leading, away from the two buttons that add books: those are
                // actions and this is a view control, and putting it on the same
                // side would push them around every time an icon changed.
                //
                // Hidden on an empty shelf, where there is nothing to arrange and
                // the two ways to add a book are the only thing worth looking at.
                if !env.books.isEmpty {
                    ToolbarItem(placement: .topBarLeading) { arrangeMenu }
                }
                // Two buttons rather than one menu: the ways in are not
                // interchangeable — adding by URL needs an installed rule while
                // importing a file needs nothing at all — so a fresh install with
                // no sources yet has to be able to reach the second one, and
                // neither is worth burying behind an extra tap.
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        adding = true
                    } label: {
                        Label("library.add", systemImage: "plus")
                    }
                    .accessibilityIdentifier("library.add")
                    .disabled(env.sites.rules.isEmpty || importProgress != nil)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        picking = true
                    } label: {
                        Label("library.import", systemImage: "square.and.arrow.down")
                    }
                    .accessibilityIdentifier("library.import")
                    .disabled(importProgress != nil)
                }
            }
            .overlay(alignment: .top) { importBanner }
            .animation(.snappy, value: importProgress == nil)
            .sheet(isPresented: $adding) { AddBookSheet() }
            // Only the two types this app can actually read. Opening a book from
            // another app is a separate feature: it needs document types declared
            // in Info.plist, which is a shipping-configuration change.
            .fileImporter(isPresented: $picking, allowedContentTypes: [.plainText, .epub]) { result in
                switch result {
                case .success(let url): Task { await runImport(url) }
                case .failure(let failure): env.report(failure)
                }
            }
            .alert("library.rename", isPresented: renamingBinding) {
                TextField("library.rename.placeholder", text: $draftName)
                Button("common.cancel", role: .cancel) { renaming = nil }
                Button("common.save") {
                    if let book = renaming { env.rename(book, to: draftName) }
                    renaming = nil
                }
            } message: {
                Text("library.rename.hint")
            }
        }
    }

    private var renamingBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    /// Sort, grouping and filter in one menu.
    ///
    /// A menu rather than controls on the shelf itself: all three are set once and
    /// then left alone for weeks, and a permanent bar above the books would spend
    /// the top of every screen on decisions nobody revisits.
    private var arrangeMenu: some View {
        // `@Environment` hands over the object but no bindings, so the settings are
        // re-wrapped here — the standard way to bind to an `@Observable` that came
        // from the environment.
        @Bindable var settings = env.librarySettings
        return Menu {
            Picker("library.sort", selection: $settings.sort) {
                ForEach(LibrarySort.allCases) { sort in
                    Text(sort.nameKey).tag(sort)
                }
            }
            .pickerStyle(.inline)
            Toggle("library.groupBySource", isOn: $settings.groupBySource)
            Toggle("library.filter.newChapters", isOn: $settings.onlyWithNewChapters)
        } label: {
            // The filled icon is the only thing on screen that says the filter is
            // on, and the filter outlives the launch it was set in.
            Label(
                "library.arrange",
                systemImage: settings.onlyWithNewChapters
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
        }
        .accessibilityIdentifier("library.arrange")
    }

    /// Determinate, because an import is long enough that a spinner alone would
    /// look stuck: a full-length novel is hundreds of chapter files being written
    /// one at a time.
    @ViewBuilder
    private var importBanner: some View {
        if let importProgress {
            HStack(spacing: 14) {
                ProgressView(value: importProgress) { Text("library.import.working") }
                // A cancel button rather than a modal or nothing at all: importing
                // a large EPUB is a minute of the app doing one thing, and the user
                // who picked the wrong file should not have to wait it out.
                Button("common.cancel") { env.cancelImport() }
                    .accessibilityIdentifier("library.import.cancel")
            }
            .font(.footnote)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar, in: .rect(cornerRadius: 12))
            .padding(.horizontal)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// Explicitly main-actor: the import runs off the main thread on purpose, so
    /// the state this sets around it would otherwise be written from wherever the
    /// task happened to land.
    @MainActor
    private func runImport(_ url: URL) async {
        importProgress = 0
        defer { importProgress = nil }
        do {
            try await env.importLocalBook(from: url) { importProgress = $0 }
        } catch is CancellationError {
            // Not reported. The user asked for this and the banner going away is
            // the answer; a red error banner would read as "the import broke".
        } catch {
            env.report(error)
        }
    }

    private func list(_ sections: [LibrarySection]) -> some View {
        List {
            ForEach(sections) { section in
                // Two branches rather than a header that conditionally draws
                // nothing: an empty header still takes vertical space in an
                // inset-grouped list, which would leave the flat shelf with a gap
                // above its first book.
                if let name = section.name {
                    Section(name) { rows(section.books) }
                } else {
                    Section { rows(section.books) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationDestination(for: Book.self) { BookDetailView(book: $0) }
        .confirmationDialog(
            "local.delete.confirm",
            isPresented: Binding(
                get: { confirmingLocalDelete != nil },
                set: { if !$0 { confirmingLocalDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("common.delete", role: .destructive) {
                if let book = confirmingLocalDelete { env.removeBookmark(book) }
                confirmingLocalDelete = nil
            }
            Button("common.cancel", role: .cancel) { confirmingLocalDelete = nil }
        }
    }

    @ViewBuilder
    private func rows(_ books: [Book]) -> some View {
        ForEach(books) { book in
            NavigationLink(value: book) {
                BookRow(
                    book: book,
                    newChapterCount: env.newChapterCounts[book.id] ?? 0,
                    lastReadIndex: env.lastReadChapterIndexes[book.id]
                )
            }
            .accessibilityIdentifier("library.book")
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    // A bookmark can be recreated and its chapters downloaded
                    // again; an imported file cannot. The ask is only for the
                    // case that is unrecoverable.
                    if book.isLocal {
                        confirmingLocalDelete = book
                    } else {
                        env.removeBookmark(book)
                    }
                } label: {
                    Label("common.delete", systemImage: "trash")
                }
                Button {
                    draftName = book.displayName ?? ""
                    renaming = book
                } label: {
                    Label("library.rename", systemImage: "pencil")
                }
                .tint(.indigo)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                env.sites.rules.isEmpty ? "library.empty.title" : "library.empty.books",
                systemImage: "books.vertical"
            )
        } description: {
            Text(env.sites.rules.isEmpty ? "library.empty.needSource" : "library.empty.hint")
        } actions: {
            if env.sites.rules.isEmpty {
                Text("library.empty.gotoSettings").font(.footnote).foregroundStyle(.secondary)
            } else {
                Button("library.add") { adding = true }.buttonStyle(.borderedProminent)
            }
            // Offered even with no sources installed: a file on the device is a
            // book this app can read today, and it is the only such book a fresh
            // install has.
            Button("library.import") { picking = true }.buttonStyle(.bordered)
        }
    }

    /// Books exist, the filter is hiding all of them. The button is the point: it
    /// undoes the one setting that can produce this screen, so nobody has to work
    /// out that their shelf is filtered rather than lost.
    private var filteredEmptyState: some View {
        ContentUnavailableView {
            Label("library.filter.empty", systemImage: "bell.badge.slash")
        } actions: {
            Button("library.filter.clear") {
                env.librarySettings.onlyWithNewChapters = false
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

/// One bookmark. Shared with the search results screen so an already-bookmarked
/// hit looks identical to its library entry.
struct BookRow: View {
    let book: Book
    /// Chapters the site has added past the reader's position. Handed in rather
    /// than counted here: one grouped query fills the whole list (see
    /// `LibraryRepo.newChapterCounts`), where a per-row count would be one query
    /// per bookmark every time the shelf is drawn.
    let newChapterCount: Int
    /// How far the reader got, in reading order. Handed in for the same reason the count
    /// is: the book stores which chapter it left off in, and turning that into a number
    /// takes its catalog — one query for the whole shelf (see
    /// `LibraryRepo.lastReadChapterIndexes`), not one per row. Nil for a book nobody has
    /// opened, and for one whose chapter the site has dropped: there is no number left
    /// to show, and inventing one is what this whole identity change is against.
    let lastReadIndex: Int?

    var body: some View {
        HStack(spacing: 12) {
            CoverImage(urlString: book.coverURL)
                .frame(width: 44, height: 60)
            VStack(alignment: .leading, spacing: 3) {
                Text(book.shownName).font(.body).lineLimit(2)
                if let author = book.author, !author.isEmpty {
                    Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    if let lastReadIndex {
                        Text("library.progress \(lastReadIndex + 1)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if newChapterCount > 0 {
                        Text("library.newChapters \(newChapterCount)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Covers are hotlinked from the source site and frequently 403 or simply do not
/// exist, so the placeholder is the expected state, not the error state.
struct CoverImage: View {
    let urlString: String?

    var body: some View {
        AsyncImage(url: urlString.flatMap(URL.init(string:))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            default:
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .overlay { Image(systemName: "book.closed").foregroundStyle(.secondary) }
            }
        }
        .clipShape(.rect(cornerRadius: 4))
    }
}

// MARK: - Adding by URL

/// The generic "paste a link" path. It is the only way to add a book that does
/// not go through search, and it works for every installed rule because the
/// matching is done by host + id pattern, not by any hardcoded site.
struct AddBookSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("library.add.url", text: $text, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("add.url")
                } footer: {
                    Text("library.add.hint")
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }

                Section("library.add.sources") {
                    ForEach(env.sites.rules) { rule in
                        HStack {
                            Text(rule.name)
                            Spacer()
                            Text(rule.host).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("library.add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isWorking {
                        ProgressView()
                    } else {
                        Button("library.add.confirm") { Task { await add() } }
                            .accessibilityIdentifier("add.confirm")
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    private func add() async {
        error = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let rule = env.sites.rule(matching: url) else {
            error = String(localized: "library.add.error.noRule")
            return
        }
        guard let siteBookId = rule.bookId(from: url) else {
            error = String(localized: "library.add.error.noBookId")
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let info = try await env.bookService.info(rule: rule, siteBookId: siteBookId)
            try await env.addBook(rule: rule, siteBookId: siteBookId, info: info)
            dismiss()
        } catch {
            if case WebFetcher.FetchError.challengePresented = error {
                env.report(error)
                dismiss()
            } else {
                self.error = error.localizedDescription
            }
        }
    }
}
