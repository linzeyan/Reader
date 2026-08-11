import SwiftUI
import UniformTypeIdentifiers

/// Requirement 3: bookmarks, grouped per source.
///
/// Grouping is by site rather than one flat list because the same novel is often
/// bookmarked on two sites (different translations, different update speeds) and
/// a flat list makes those look like duplicates.
struct LibraryView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var adding = false
    @State private var picking = false
    /// 0…1 while an import runs, nil otherwise — so it doubles as "busy".
    @State private var importProgress: Double?
    @State private var renaming: Book?
    @State private var draftName = ""

    var body: some View {
        NavigationStack {
            Group {
                if env.books.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("tab.library")
            .toolbar {
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

    /// Determinate, because an import is long enough that a spinner alone would
    /// look stuck: a full-length novel is hundreds of chapter files being written
    /// one at a time.
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

    /// Explicitly main-actor: the import runs off the main thread on purpose, so
    /// the state this sets around it would otherwise be written from wherever the
    /// task happened to land.
    @MainActor
    private func runImport(_ url: URL) async {
        importProgress = 0
        defer { importProgress = nil }
        do {
            try await env.importLocalBook(from: url) { importProgress = $0 }
        } catch {
            env.report(error)
        }
    }

    private var list: some View {
        List {
            ForEach(env.booksBySite, id: \.siteId) { group in
                Section(group.name) {
                    ForEach(group.books) { book in
                        NavigationLink(value: book) {
                            BookRow(book: book)
                        }
                        .accessibilityIdentifier("library.book")
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                env.removeBookmark(book)
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
            }
        }
        .listStyle(.insetGrouped)
        .navigationDestination(for: Book.self) { BookDetailView(book: $0) }
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
}

/// One bookmark. Shared with the search results screen so an already-bookmarked
/// hit looks identical to its library entry.
struct BookRow: View {
    let book: Book

    var body: some View {
        HStack(spacing: 12) {
            CoverImage(urlString: book.coverURL)
                .frame(width: 44, height: 60)
            VStack(alignment: .leading, spacing: 3) {
                Text(book.shownName).font(.body).lineLimit(2)
                if let author = book.author, !author.isEmpty {
                    Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let index = book.lastReadChapterIndex {
                    Text("library.progress \(index + 1)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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
