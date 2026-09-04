import SwiftUI
import UIKit
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
    @State private var exportingSubscriptions = false
    /// 0…1 while an import runs, nil otherwise — so it doubles as "busy".
    @State private var importProgress: Double?
    /// What the import is working on right now, for the one import whose steps have
    /// names: a subscription list, where each step is a whole feed being fetched.
    @State private var importNote: String?
    /// What a finished subscription import came to, held until the reader dismisses it.
    ///
    /// The only import that reports a result, because it is the only one whose result is
    /// not on the screen behind it: a novel arrives as one row the reader can see, while
    /// forty subscriptions land among the ones already there — and a list re-imported
    /// from a backup can legitimately add nothing at all, which is indistinguishable from
    /// having failed unless it is said.
    @State private var importOutcome: String?
    @State private var renaming: Book?
    @State private var draftName = ""
    /// The imported book a swipe is about to destroy. Only imported books get
    /// asked about, because only they have nowhere to come back from.
    @State private var confirmingLocalDelete: Book?
    /// Held so the reading history's handoff can lay down a whole route — shelf,
    /// book screen, reader — in one assignment. See `consumeHandoff`.
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                let sections = env.shelf
                if env.shelfBooks.isEmpty {
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
            // At the stack's root rather than on the shelf list, for the same reason
            // the history used to declare them at its root: the handoff lays both
            // path values down in one transaction, before any pushed screen — and
            // its own destinations — exists. Both types are declared here and
            // nowhere deeper: a stack uses only the declaration closest to its root,
            // so a second one on the book screen would be dead weight — which is
            // exactly what it was, announced at every launch by the runtime.
            .navigationDestination(for: Book.self) { BookDetailView(book: $0) }
            // The one place a book turns into a reader, which is why the history's
            // handoff works across media without knowing anything about either: it lays
            // down a route and this decides what the end of it is.
            .navigationDestination(for: ReadingTarget.self) { target in
                switch target.book.kind {
                // An article is text, and the reader that draws text is this one. That a
                // subscription needed no reader of its own is the whole return on filing
                // a feed as a book and an article as a chapter.
                case .novel, .feed: ReaderView(book: target.book, position: target.position)
                case .comic: ComicReaderView(book: target.book, position: target.position)
                }
            }
            .onAppear { consumeHandoff() }
            .onChange(of: env.readingHandoff) { _, _ in consumeHandoff() }
            .toolbar {
                // Leading, away from the two buttons that add books: those are
                // actions and this is a view control, and putting it on the same
                // side would push them around every time an icon changed.
                //
                // Hidden on an empty shelf, where there is nothing to arrange and
                // the two ways to add a book are the only thing worth looking at.
                if !env.shelfBooks.isEmpty {
                    ToolbarItem(placement: .topBarLeading) { arrangeMenu }
                }
                // Never hidden, unlike the menu above it: switching modes is how
                // someone gets *off* an empty comic shelf and back to the novels they
                // have, so it is the one control that has to be there when there is
                // nothing else on the screen.
                //
                // Beside the large title rather than tucked against it. Nothing places
                // a control on the title's own line without giving the large title up,
                // and the shelf keeping the same heading as the other three tabs was
                // worth more than the last few points of proximity.
                ToolbarItem(placement: .topBarLeading) { MediaModePicker() }
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
                    // Rules gate the two media that are read through one. A feed address
                    // is complete on its own, so gating the feed shelf on an empty rule
                    // list would leave a fresh install unable to subscribe to anything.
                    .disabled(
                        (env.mediaMode.needsRules && env.sites.rules.isEmpty)
                            || importProgress != nil
                    )
                }
                // On every shelf, taking a different kind of file on each. What a
                // file can be imported *as* is decided by its type — text is a
                // novel, an archive of pictures is a comic, a list of addresses is
                // subscriptions — so the shelf the reader is looking at is what says
                // which one to offer. Offering the wrong one would take a file,
                // succeed, and put the result on the shelf they are not looking at,
                // which is indistinguishable from having failed.
                ToolbarItem(placement: .topBarTrailing) {
                    // A menu on the feed shelf, because a subscription list goes both
                    // ways: OPML is how forty feeds arrive from another reader, and a
                    // reader who cannot get them out again is one who has to think twice
                    // about putting them in. One control either way — the toolbar already
                    // carries four.
                    if env.mediaMode == .feed { subscriptionsMenu } else { importButton }
                }
            }
            .overlay(alignment: .top) { importBanner }
            .animation(.snappy, value: importProgress == nil)
            .sheet(isPresented: $adding) { AddBookSheet() }
            // Only the types this app can actually read, and only the ones that
            // belong to the shelf in front of the reader. Opening a book from
            // another app is a separate feature: it needs document types declared
            // in Info.plist, which is a shipping-configuration change — and for
            // `.zip` in particular it would put this app in the "open with" menu of
            // every archive on the device, comic or not.
            .fileImporter(isPresented: $picking, allowedContentTypes: importableTypes) { result in
                switch result {
                case .success(let url): Task { await runImport(url) }
                case .failure(let failure): env.report(failure)
                }
            }
            // Built when the sheet opens rather than held: the list is the shelf, and one
            // taken a minute ago could be missing the feed just subscribed to.
            .fileExporter(
                isPresented: $exportingSubscriptions,
                document: SubscriptionsDocument(env.subscriptionsDocument()),
                contentType: .xml,
                defaultFilename: subscriptionsFilename
            ) { result in
                if case .failure(let error) = result { env.report(error) }
            }
            .alert(
                "library.opml.imported.title",
                isPresented: Binding(
                    get: { importOutcome != nil },
                    set: { if !$0 { importOutcome = nil } }
                )
            ) {
                Button("common.done") { importOutcome = nil }
            } message: {
                Text(importOutcome ?? "")
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

    private var importButton: some View {
        Button {
            picking = true
        } label: {
            Label("library.import", systemImage: "square.and.arrow.down")
        }
        .accessibilityIdentifier("library.import")
        .disabled(importProgress != nil)
    }

    /// The two halves of OPML. Export is disabled rather than hidden on an empty shelf:
    /// it is not a feature that arrives with the first subscription, it is one there is
    /// briefly nothing to do with.
    private var subscriptionsMenu: some View {
        Menu {
            Button("library.opml.import", systemImage: "square.and.arrow.down") {
                picking = true
            }
            .accessibilityIdentifier("library.opml.import")
            Button("library.opml.export", systemImage: "square.and.arrow.up") {
                exportingSubscriptions = true
            }
            .accessibilityIdentifier("library.opml.export")
            .disabled(env.shelfBooks.isEmpty)
        } label: {
            Label("library.opml", systemImage: "square.and.arrow.up.on.square")
        }
        .accessibilityIdentifier("library.opml")
        .disabled(importProgress != nil)
    }

    /// Dated, because what this file is for is keeping. Someone who exports twice ends up
    /// with two of them, and the file system's own answer to a repeated name — a "2" on
    /// the end — says which was saved second but not what either one holds. The date is
    /// written largest part first so that a folder of them sorts into the order they were
    /// made in.
    private var subscriptionsFilename: String {
        let day = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        return "subscriptions-\(day).opml"
    }

    private var renamingBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    /// Opens the book the reading history handed over: the book's screen beneath the
    /// reader, so the way back is the same as from any other route into a book.
    ///
    /// The path is *replaced*, not appended to — whatever the shelf was showing, the
    /// handoff means "take me to this sentence", and pushing on top of an old stack
    /// would put an unrelated book on the way back. One assignment, so the stack
    /// plays the route as a single push.
    private func consumeHandoff() {
        guard let target = env.readingHandoff else { return }
        env.readingHandoff = nil
        var route = NavigationPath()
        route.append(target.book)
        route.append(target)
        path = route
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
            Toggle(
                env.mediaMode == .feed ? "library.filter.unread" : "library.filter.newChapters",
                isOn: $settings.onlyWithNewChapters
            )
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
                VStack(alignment: .leading, spacing: 2) {
                    ProgressView(value: importProgress) { Text("library.import.working") }
                    if let importNote {
                        Text(importNote)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .accessibilityIdentifier("library.import.note")
                    }
                }
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
    private var importableTypes: [UTType] {
        switch env.mediaMode {
        case .novel: return [.plainText, .epub]
        case .comic: return [.zip]
        // A subscription list travels as OPML, which no system declares a type for — the
        // picker would grey out every `.opml` on the device if this asked only for `.xml`,
        // and half the exports in the world are named `.xml` if it asked only for the
        // dynamic type. Both, so that either file can be chosen.
        case .feed: return [UTType(filenameExtension: "opml") ?? .xml, .xml]
        }
    }

    private func runImport(_ url: URL) async {
        importProgress = 0
        defer {
            importProgress = nil
            importNote = nil
        }
        do {
            switch env.mediaMode {
            case .novel: try await env.importLocalBook(from: url) { importProgress = $0 }
            case .comic: try await env.importComicArchive(from: url) { importProgress = $0 }
            // The one import that is not a book: a list of addresses, each of which is
            // then subscribed to for real. Determinate for the same reason a novel's is —
            // forty feeds is forty requests, and a spinner would look stuck — and named,
            // because every one of those requests is a subscription the reader chose.
            case .feed:
                // How many the file listed, taken from the progress it reports rather than
                // read out of the file a second time: the count the reader watched climb is
                // the one the result has to agree with.
                var listed = 0
                let added = try await env.importSubscriptions(from: url) { step in
                    listed = step.count
                    importProgress = step.fraction
                    importNote = step.subscription.map {
                        String(
                            localized: "library.import.subscription \($0) \(step.index + 1) \(step.count)"
                        )
                    }
                }
                importOutcome = String(localized: "library.opml.imported \(listed) \(added)")
            }
        } catch is CancellationError {
            // Not reported. The user asked for this and the banner going away is
            // the answer; a red error banner would read as "the import broke".
        } catch {
            env.report(error)
        }
    }

    /// The shelf, with the pull gesture on the one mode that has something to pull.
    ///
    /// Feeds only, and branched rather than made a no-op action: a pull that spins and
    /// changes nothing is worse than no gesture at all. The novel and comic shelves refresh
    /// a catalog at a time, from the book's own screen — forty catalogs behind one gesture
    /// is a minute of the shared web view being unavailable to the reader who made it.
    @ViewBuilder
    private func list(_ sections: [LibrarySection]) -> some View {
        if env.mediaMode == .feed {
            shelf(sections).refreshable { await env.refreshFeeds(force: true) }
        } else {
            shelf(sections)
        }
    }

    private func shelf(_ sections: [LibrarySection]) -> some View {
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
            // The menu is attached only where it would have something in it. A
            // `contextMenu` whose body evaluates to nothing still opens on a long
            // press — as an empty grey card — and that is the answer an imported
            // book, or one whose source has been removed, would give.
            if let source = env.sites.sourceURL(of: book) {
                row(book).contextMenu { copyLinkButton(source) }
            } else {
                row(book)
            }
        }
    }

    private func row(_ book: Book) -> some View {
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

    /// Hands back the address the book came from, for pasting into a browser or
    /// sending to someone.
    ///
    /// A long press rather than a third swipe action: the two already there are
    /// the ones that change the shelf, and a row on a narrow phone has no room
    /// for a button nobody presses in a hurry. Copied as a plain string, because
    /// the places it is going — an address bar, a message — read text.
    ///
    /// No confirmation is shown. The only banner this app has is the red error
    /// one, and copying is the system-wide gesture whose result the user can see
    /// by pasting.
    private func copyLinkButton(_ url: URL) -> some View {
        Button {
            UIPasteboard.general.string = url.absoluteString
        } label: {
            Label("library.copyLink", systemImage: "link")
        }
        .accessibilityIdentifier("library.copyLink")
    }

    private var emptyState: some View {
        let copy = emptyCopy
        return ContentUnavailableView {
            Label(copy.heading, systemImage: env.mediaMode.icon)
        } description: {
            Text(copy.body)
        } actions: {
            if copy.needsSource {
                Text("library.empty.gotoSettings").font(.footnote).foregroundStyle(.secondary)
            } else {
                Button("library.add") { adding = true }.buttonStyle(.borderedProminent)
            }
            // Offered even with no sources installed: a file on the device is a
            // book this app can read today, and it is the only such book a fresh
            // install has. Novels only, for the reason the toolbar button gives.
            if env.mediaMode == .novel {
                Button("library.import") { picking = true }.buttonStyle(.bordered)
            }
        }
    }

    /// What an empty shelf says, and whether the way out of it is installing a source.
    ///
    /// Both questions are per mode. "No sources yet" has to mean no *comic* sources
    /// when the comic shelf is on screen, since a novel rule is no help to someone
    /// pasting a comic address — and comics get their own wording for the other case
    /// too, because "書櫃是空的" in front of a library full of novels reads as though
    /// they had all gone missing, when what is empty is the half being looked at.
    private var emptyCopy: (heading: LocalizedStringKey, body: LocalizedStringKey, needsSource: Bool) {
        let mode = env.mediaMode
        // A feed shelf is never waiting on a source: an address is the whole of what it
        // takes to subscribe, so its empty state offers the button rather than sending
        // the reader to settings for a rule it will never use.
        if mode.needsRules, env.sites.rules(of: mode).isEmpty {
            return (mode.noSourcesTitleKey, mode.noSourcesHintKey, true)
        }
        switch mode {
        case .novel: return ("library.empty.books", "library.empty.hint", false)
        case .comic: return ("library.empty.comic.books", "library.empty.comic.hint", false)
        case .feed: return ("library.empty.feed.title", "library.empty.feed.hint", false)
        }
    }

    /// Books exist, the filter is hiding all of them. The button is the point: it
    /// undoes the one setting that can produce this screen, so nobody has to work
    /// out that their shelf is filtered rather than lost.
    private var filteredEmptyState: some View {
        ContentUnavailableView {
            Label(
                env.mediaMode == .feed ? "library.filter.unread.empty" : "library.filter.empty",
                systemImage: "bell.badge.slash"
            )
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
            BookCover(book: book)
                .frame(width: 44, height: 60)
            VStack(alignment: .leading, spacing: 3) {
                Text(book.shownName).font(.body).lineLimit(2)
                if let author = book.author, !author.isEmpty {
                    Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    if let lastReadIndex {
                        progress(lastReadIndex)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if newChapterCount > 0 {
                        // "New" wears off after a day for a novel and never does for a
                        // subscription — see `Chapter.isNew` — so the badge that counts
                        // them is not saying the same thing on the two shelves.
                        Text(
                            book.kind == .feed
                                ? "library.unread \(newChapterCount)"
                                : "library.newChapters \(newChapterCount)"
                        )
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// Where the reader is, as finely as the book can say.
    ///
    /// A chapter alone is coarse in a novel whose chapters take twenty minutes, so the
    /// share comes with it — but only where there is one. A position recorded before the
    /// column existed, or restored from another device and not read here since, knows
    /// its chapter and nothing finer, and "第 12 章 · 0%" would be a claim about how far
    /// in they are that nothing measured.
    ///
    /// A subscription counts the same way and is worded differently, here and everywhere
    /// else this app names a position: what a feed holds is articles, and "第 12 章" for
    /// the twelfth post on someone's blog is the app describing a novel it is not reading.
    private func progress(_ lastReadIndex: Int) -> Text {
        guard let fraction = book.lastReadFraction else {
            return book.kind == .feed
                ? Text("library.progress.article \(lastReadIndex + 1)")
                : Text("library.progress \(lastReadIndex + 1)")
        }
        let share = TextAnchor.shareText(fraction)
        return book.kind == .feed
            ? Text("library.progress.article.share \(lastReadIndex + 1) \(share)")
            : Text("library.progress.share \(lastReadIndex + 1) \(share)")
    }
}

/// A book's cover, drawn from the copy on this device.
///
/// The file rather than the site's address, because a cover is an image request and
/// these hosts refuse an image request that does not say which page it belongs to —
/// `AsyncImage` cannot send that header, and `CoverService` exists to. The bytes are
/// kept, so this is also what stops the shelf's appearance depending on whether
/// `URLCache` has evicted anything since.
///
/// Resolved per view rather than through one cache of decoded images: the answer is a
/// file URL, and SwiftUI only draws the rows that are on screen, so what is held in
/// memory is a screenful of thumbnails rather than the whole library's.
struct BookCover: View {
    let book: Book

    @Environment(AppEnvironment.self) private var env
    @State private var file: URL?
    /// Which book `file` was resolved for. A row recycled onto a different book must
    /// not draw the previous one's cover while the new one is being looked up.
    @State private var resolvedFor: String?

    var body: some View {
        CoverImage(url: resolvedFor == book.id ? file : nil)
            .task(id: book.id) {
                file = await env.covers.cover(for: book)
                resolvedFor = book.id
            }
    }
}

/// The subscription list as a file the save sheet can write.
///
/// Held in memory, unlike a book export, which streams through a temporary file: an OPML
/// of forty feeds is a few kilobytes and a novel is forty megabytes.
struct SubscriptionsDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.xml] }

    private let text: String

    init(_ text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        // Never read back. Importing a list is `OPML.subscriptions(in:)`, which takes the
        // file the picker handed over rather than a document type declared for writing.
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// Covers are hotlinked from the source site and frequently 403 or simply do not
/// exist, so the placeholder is the expected state, not the error state.
struct CoverImage: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { phase in
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
