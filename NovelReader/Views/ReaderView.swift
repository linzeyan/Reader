import SwiftUI

/// The reader. Two renderers over one position model.
///
/// Scrolling is one continuous column across chapter boundaries; paginated reading
/// (`PaginatedChapterView`) lays a chapter out with TextKit 2 and turns pages. The
/// choice is `ReaderSettings.mode`, and both write the same `ReadingPosition`, so a
/// reader can switch mid-chapter — or bookmark in one mode and jump to it in the
/// other — and land in the same place.
///
/// All controls sit at the bottom of the screen: the app is meant to be usable
/// with one hand, and the top third of a modern iPhone is out of thumb reach.
struct ReaderView: View {
    let book: Book
    /// Where to open. A position rather than a chapter number, so continuing a book
    /// and jumping to a saved position are the same operation.
    let position: ReadingPosition

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var model: ReaderModel?
    @State private var showControls = false
    @State private var showCatalog = false
    @State private var showSettings = false
    @State private var settings = ReaderSettings.shared
    /// The chapter a backwards page turn walked into, which has to open on its last
    /// page. Held as a chapter id rather than a flag so that a later jump to the same
    /// chapter from the catalog still opens at its start.
    @State private var openAtLastPage: String?
    /// Set when a forward page turn had nowhere left to go. The scrolling reader says
    /// the same thing at the foot of the last chapter; a page that simply refuses to
    /// turn, with nothing on screen, reads as a gesture the app missed.
    @State private var reachedEndOfBook = false

    var body: some View {
        ZStack {
            settings.theme.background.ignoresSafeArea()
            if let model {
                content(model)
            } else {
                ProgressView()
            }
        }
        .navigationBarBackButtonHidden()
        // Never in paginated mode, even with the controls up: showing the navigation
        // bar changes the safe area, and a changed text area means re-measuring the
        // page breaks. The bottom control bar already carries everything the bar did.
        .toolbar(showControls && settings.mode == .scroll ? .visible : .hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .statusBarHidden(!showControls)
        .preferredColorScheme(settings.theme.colorScheme)
        .overlay(alignment: .bottom) { if showControls, let model { controlBar(model) } }
        .animation(.snappy(duration: 0.2), value: showControls)
        .sheet(isPresented: $showCatalog) { catalogSheet }
        .sheet(isPresented: $showSettings) {
            ReaderSettingsSheet(settings: settings)
                // Half height, and not resizable to full: every control in here
                // changes how the page behind it looks, and a sheet that covers
                // the page hides the only thing worth looking at while adjusting.
                .presentationDetents([.medium])
        }
        .task {
            guard model == nil else { return }
            let created = ReaderModel(book: book, env: env)
            model = created
            await created.start(at: position)
        }
        // Switching to the scrolling renderer builds a fresh scroll view, which starts
        // at the top of whatever is loaded. Re-aiming it happens on the next runloop
        // turn, once that scroll view exists to receive the target.
        .onChange(of: settings.mode) { _, mode in
            guard mode == .scroll else { return }
            Task { model?.retarget() }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            model?.stopReading()
        }
    }

    // MARK: - Text

    @ViewBuilder
    private func content(_ model: ReaderModel) -> some View {
        switch settings.mode {
        case .scroll: scrollingText(model)
        case .paginated: pagedText(model)
        }
    }

    private func scrollingText(_ model: ReaderModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.loaded) { item in
                        chapterBlock(item, model: model)
                    }
                    footer(model)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 80)
                .contentShape(.rect)
                .onTapGesture { showControls.toggle() }
                .accessibilityIdentifier("reader.text")
            }
            .scrollDismissesKeyboard(.immediately)
            .onChange(of: model.scrollTarget) { _, target in
                guard let target else { return }
                // No animation: a jump across chapters should land instantly,
                // not scroll through the text the user skipped.
                proxy.scrollTo(target, anchor: .top)
                model.scrollTarget = nil
            }
        }
    }

    /// The paginated renderer, and the plumbing that keeps it inside the existing
    /// chapter machinery: turning off either end is a `ReaderModel.jump`, which is the
    /// same call the catalog and the chapter buttons make, so read-ahead and progress
    /// need no second implementation.
    @ViewBuilder
    private func pagedText(_ model: ReaderModel) -> some View {
        if let current = model.currentLoadedChapter {
            PaginatedChapterView(
                title: current.chapter.title,
                paragraphs: current.paragraphs,
                chapterKey: current.chapter.id,
                settings: settings,
                landing: openAtLastPage == current.chapter.id
                    ? .lastPage : .anchor(model.currentAnchor),
                highlights: model.highlights(inChapter: current.chapter.siteChapterId),
                onAnchorChange: { anchor in
                    openAtLastPage = nil
                    // Any page that does turn answers the question the notice asked.
                    reachedEndOfBook = false
                    model.notePage(chapterIndex: current.chapter.index, anchor: anchor)
                },
                onTapCenter: { showControls.toggle() },
                onTurnPast: { edge in turnChapter(past: edge, model: model) },
                onHighlight: { selection in
                    model.addHighlight(
                        siteChapterId: current.chapter.siteChapterId, selection: selection
                    )
                },
                onRemoveHighlight: { model.removeHighlight($0) }
            )
            .overlay(alignment: .bottom) {
                if reachedEndOfBook {
                    Text("reader.end")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.bar, in: .capsule)
                        // Clear of the control bar's own resting place, so the two
                        // never stack on top of each other.
                        .padding(.bottom, 72)
                        .transition(.opacity)
                }
            }
            .animation(.default, value: reachedEndOfBook)
        } else if model.isLoading {
            ProgressView()
        } else if let error = model.error {
            VStack(spacing: 10) {
                Text(error).font(.footnote).foregroundStyle(.secondary)
                Button("reader.retry") {
                    Task {
                        await model.jump(
                            toChapterAt: model.currentChapterIndex, anchor: model.currentAnchor
                        )
                    }
                }
                    .buttonStyle(.bordered)
            }
        } else {
            Text("reader.end").font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// A page turn that ran off the end of a chapter continues into the next one, and
    /// off the start into the end of the previous one — the paginated equivalent of the
    /// scrolling reader's text simply carrying on.
    private func turnChapter(past edge: PageEdge, model: ReaderModel) {
        let target = model.currentChapterIndex + (edge == .end ? 1 : -1)
        guard model.chapters.indices.contains(target) else {
            // Only the end of the book is worth saying. Turning back from page one of
            // chapter one is a page that was never there, not a place to arrive at.
            reachedEndOfBook = edge == .end
            return
        }
        reachedEndOfBook = false
        openAtLastPage = edge == .start ? model.chapters[target].id : nil
        Task { await model.jump(toChapterAt: target) }
    }

    private func chapterBlock(_ item: ReaderModel.LoadedChapter, model: ReaderModel) -> some View {
        let highlights = model.highlights(inChapter: item.chapter.siteChapterId)
        return VStack(alignment: .leading, spacing: settings.paragraphSpacing) {
            Text(item.chapter.title)
                .font(.system(size: settings.fontSize + 4, weight: .semibold))
                .padding(.top, 28)
                .padding(.bottom, 6)
                .id(item.id)

            ForEach(Array(item.paragraphs.enumerated()), id: \.offset) { offset, paragraph in
                paragraphText(paragraph, highlights: highlights, paragraph: offset)
                    .font(settings.font)
                    .lineSpacing(settings.lineSpacing)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Every paragraph is a scroll destination, which is what makes a
                    // stored anchor something the reader can actually land on.
                    .id(TextAnchor.paragraphID(chapterId: item.chapter.id, paragraph: offset))
                    // Progress is recorded from whatever scrolls into view; there
                    // is no cheaper way to know the reading position in a lazy
                    // stack on iOS 17.
                    .onAppear { model.note(chapterIndex: item.chapter.index, paragraph: offset) }
            }
        }
        .foregroundStyle(settings.theme.foreground)
    }

    /// One paragraph, with any highlight over it tinted in.
    ///
    /// The scrolling renderer is left as it was — a plain `Text` per paragraph with the
    /// same modifiers — and only the *string* becomes attributed, and only when a
    /// highlight actually reaches this paragraph. Highlights are shown in both modes
    /// because a mark the reader made has to still be there when they switch; they are
    /// *made* only in paged mode, because nothing here knows where a character sits.
    private func paragraphText(
        _ text: String, highlights: [TextHighlight], paragraph: Int
    ) -> Text {
        guard !highlights.isEmpty else { return Text(text) }
        let length = (text as NSString).length
        let ranges = highlights.compactMap { $0.range(inParagraph: paragraph, length: length) }
        guard !ranges.isEmpty else { return Text(text) }
        var attributed = AttributedString(text)
        for range in ranges {
            guard let bounds = Range(range, in: attributed) else { continue }
            attributed[bounds].backgroundColor = settings.theme.highlight
        }
        return Text(attributed)
    }

    @ViewBuilder
    private func footer(_ model: ReaderModel) -> some View {
        Group {
            if model.isLoading {
                ProgressView().padding(.vertical, 28)
            } else if let error = model.error {
                VStack(spacing: 10) {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                    Button("reader.retry") { Task { await model.loadNext() } }
                        .buttonStyle(.bordered)
                }
                .padding(.vertical, 28)
            } else if model.hasMore {
                // Reaching this marker is what pulls in the next chapter, so the
                // text simply continues instead of ending at a "next" button.
                Color.clear
                    .frame(height: 1)
                    .onAppear { Task { await model.loadNext() } }
            } else {
                Text("reader.end")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Controls

    private func controlBar(_ model: ReaderModel) -> some View {
        HStack(spacing: 0) {
            control("chevron.left", label: "common.back") { dismiss() }
            control("list.bullet", label: "reader.catalog") { showCatalog = true }
            // Filled when the page on screen is already saved: a bookmark the reader
            // cannot see is one they will add twice.
            control(
                model.isCurrentPositionBookmarked ? "bookmark.fill" : "bookmark",
                label: model.isCurrentPositionBookmarked
                    ? "reader.bookmark.remove" : "reader.bookmark.add"
            ) {
                model.toggleBookmark()
            }
            .accessibilityIdentifier("reader.bookmark")
            control("arrow.up.to.line", label: "reader.previousChapter") {
                Task { await model.jump(toChapterAt: model.currentChapterIndex - 1) }
            }
            .disabled(model.currentChapterIndex <= 0)
            control("arrow.down.to.line", label: "reader.nextChapter") {
                Task { await model.jump(toChapterAt: model.currentChapterIndex + 1) }
            }
            .disabled(model.currentChapterIndex >= model.chapters.count - 1)
            control("textformat.size", label: "reader.settings") { showSettings = true }
        }
        .padding(.vertical, 10)
        .background(.bar)
        .clipShape(.rect(cornerRadius: 18))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func control(
        _ systemImage: String,
        label: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18))
                .frame(maxWidth: .infinity, minHeight: 34)
        }
        .accessibilityLabel(Text(label))
    }

    private var catalogSheet: some View {
        NavigationStack {
            List(model?.chapters ?? []) { chapter in
                Button {
                    showCatalog = false
                    Task { await model?.jump(toChapterAt: chapter.index) }
                } label: {
                    HStack {
                        // Against the position the book was opened with, deliberately —
                        // see `Chapter.isNew`, which explains why chapters read in this
                        // session keep their marker until the reader leaves.
                        ChapterRow(
                            chapter: chapter,
                            lastReadIndex: book.lastReadIndex(in: model?.chapters ?? [])
                        )
                        if chapter.index == model?.currentChapterIndex {
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tint)
                        }
                    }
                }
                .tint(.primary)
            }
            .navigationTitle("reader.catalog")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("common.done") { showCatalog = false }
                }
            }
        }
    }
}

// MARK: - Model

/// Holds the chapters currently rendered and pulls in the next one on demand.
@MainActor
@Observable
final class ReaderModel {
    struct LoadedChapter: Identifiable {
        let chapter: Chapter
        let paragraphs: [String]
        var id: String { chapter.id }
    }

    private(set) var chapters: [Chapter] = []
    private(set) var loaded: [LoadedChapter] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var currentChapterIndex = 0
    private(set) var currentAnchor = TextAnchor.start
    /// Ids of this book's saved positions, so the bookmark button can show whether
    /// the page on screen is one of them. Held as a set rather than re-queried on
    /// every scroll: `note` fires per paragraph.
    private(set) var bookmarkedIDs: Set<String> = []
    /// This book's highlights, grouped the way both renderers ask for them: one
    /// chapter at a time, keyed by the chapter's own id. Grouped once on open rather
    /// than queried per chapter because the scrolling reader can have several chapters
    /// on screen and re-draws every paragraph of them as it scrolls.
    private(set) var highlightsByChapter: [String: [TextHighlight]] = [:]
    /// Set when the view should scroll somewhere; cleared by the view once done.
    var scrollTarget: String?

    var hasMore: Bool {
        guard let last = loaded.last else { return false }
        return last.chapter.index < chapters.count - 1
    }

    /// The chapter the reader is in, which the paginated renderer draws one page of.
    /// Looked up by index rather than taken as `loaded.first`, because switching over
    /// from the scrolling reader can leave several chapters loaded.
    var currentLoadedChapter: LoadedChapter? {
        loaded.first { $0.chapter.index == currentChapterIndex }
    }

    /// What would be stored for where the reader is now.
    ///
    /// This is the boundary the two ways of naming a chapter meet at: inside a session
    /// the reader moves by reading order, because that is what "next chapter" means and
    /// the catalog cannot change under an open reader; anything that is *written down*
    /// names the chapter by its site id, which outlives the catalog being renumbered.
    ///
    /// Nil until a chapter is on screen — a position names a chapter, and before the
    /// catalog is loaded there is none to name.
    var currentPosition: ReadingPosition? {
        guard chapters.indices.contains(currentChapterIndex) else { return nil }
        return ReadingPosition(
            siteChapterId: chapters[currentChapterIndex].siteChapterId, anchor: currentAnchor
        )
    }

    var isCurrentPositionBookmarked: Bool {
        guard let currentPosition else { return false }
        return bookmarkedIDs.contains(
            ReadingBookmark.makeId(bookId: book.id, position: currentPosition)
        )
    }

    private let book: Book
    private let env: AppEnvironment
    /// The anchor a jump asked for, held until the paragraph it names is actually on
    /// screen. See `note`.
    private var restoring: TextAnchor?
    private var persistedIndex: Int?
    /// The one chapter read ahead, held in memory only. Never more than one:
    /// this is here to hide a page load, not to become a second download queue.
    private var readAhead: (chapterId: String, paragraphs: [String])?
    private var readAheadTask: Task<Void, Never>?

    init(book: Book, env: AppEnvironment) {
        self.book = book
        self.env = env
    }

    // MARK: Loading

    func start(at position: ReadingPosition) async {
        chapters = (try? env.repo.chapters(bookId: book.id)) ?? []
        bookmarkedIDs = Set((try? env.repo.readingBookmarks(bookId: book.id))?.map(\.id) ?? [])
        highlightsByChapter = Dictionary(
            grouping: (try? env.repo.highlights(bookId: book.id)) ?? [], by: \.siteChapterId
        )
        guard !chapters.isEmpty else { return }
        // The one place a stored chapter id is resolved against reading order, so that
        // everything after it can work in the order the reader's controls mean.
        //
        // A position naming a chapter the site has dropped opens the book at its start:
        // the reader asked for this book, and its first chapter is the only place left
        // that still exists. A *mark* is not treated this way — the marks list refuses
        // to offer one as a destination at all, because landing near a passage is not
        // the same kind of answer as landing near a reading position.
        let index = chapters.firstIndex { $0.siteChapterId == position.siteChapterId } ?? 0
        await jump(toChapterAt: index, anchor: position.anchor)
    }

    /// Replaces what is on screen with a single chapter, landing on `anchor`.
    /// Everything before it is dropped rather than kept: an unbounded scroll history
    /// is the fastest way to make a long novel run the app out of memory.
    ///
    /// Addressed by reading order rather than by chapter id: every caller is *moving*
    /// through the book — the next chapter, the previous one, a row of the catalog — and
    /// the loaded array is the order they mean.
    func jump(toChapterAt index: Int, anchor: TextAnchor = .start) async {
        guard chapters.indices.contains(index) else { return }
        persistProgress()
        // Whatever was read ahead belonged to the old position.
        readAheadTask?.cancel()
        readAhead = nil
        loaded = []
        currentChapterIndex = index
        currentAnchor = anchor
        await append(chapters[index])
        let landing = landingAnchor(for: anchor)
        currentAnchor = landing
        // Only worth guarding when there is text above the landing paragraph for the
        // scroll to travel through.
        restoring = landing.paragraph > 0 ? landing : nil
        scrollTarget = landing.scrollID(chapterId: chapters[index].id)
    }

    /// A stored anchor can outlive the text it named: a chapter re-fetched from the
    /// site can come back with fewer paragraphs than when the position was recorded.
    /// Clamping keeps the jump inside the chapter — the end of the right chapter is
    /// closer to the truth than not moving at all, and an anchor that no paragraph
    /// can satisfy would leave `note` waiting for a paragraph that never appears.
    private func landingAnchor(for anchor: TextAnchor) -> TextAnchor {
        let count = loaded.first?.paragraphs.count ?? 0
        guard count > 0 else { return .start }
        guard anchor.paragraph >= count else { return anchor }
        return TextAnchor(paragraph: count - 1, characterOffset: 0)
    }

    func loadNext() async {
        guard !isLoading, let last = loaded.last else { return }
        let nextIndex = last.chapter.index + 1
        guard chapters.indices.contains(nextIndex) else { return }
        await append(chapters[nextIndex])
    }

    private func append(_ chapter: Chapter) async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            loaded.append(LoadedChapter(chapter: chapter, paragraphs: try await paragraphs(for: chapter)))
            startReadingAhead()
        } catch {
            // A challenge has to reach the shell so the sheet can be presented;
            // everything else stays inline so the user keeps their scroll position.
            if case WebFetcher.FetchError.challengePresented = error {
                env.report(error)
            }
            self.error = error.localizedDescription
        }
    }

    /// Local text wins: a downloaded chapter must be readable with no network at
    /// all, which is the entire point of downloading it. Chapters read online are
    /// held in memory only — writing them to disk would inflate the storage
    /// screen with files the user never asked to keep.
    private func paragraphs(for chapter: Chapter) async throws -> [String] {
        if chapter.isDownloaded,
           let stored = try? env.downloads.readParagraphs(book: book, siteChapterId: chapter.siteChapterId),
           !stored.isEmpty {
            return stored
        }
        if let readAhead, readAhead.chapterId == chapter.id {
            self.readAhead = nil
            return readAhead.paragraphs
        }
        guard let rule = env.sites.rule(id: book.siteId) else {
            // An imported book has no site to fall back to. Reaching here means
            // its text is gone from disk — deleted from the storage screen — and
            // re-importing the file is the only way back, so say that instead of
            // reporting a bad URL for a book that never had one.
            if book.isLocal { throw LocalBookError.contentDeleted }
            throw BookService.ServiceError.badURL
        }
        return try await env.bookService.chapterParagraphs(rule: rule, chapter: chapter)
    }

    /// Fetches the chapter after the last one on screen, at a random remove,
    /// so that scrolling into it shows text instead of a spinner.
    ///
    /// Only for chapters that are *not* downloaded — a downloaded one is already
    /// instant. It goes through the shared pacer for the same reason downloads
    /// do: read-ahead is the app fetching a page nobody asked for yet, and it
    /// should not add up with a download run into a burst.
    ///
    /// Failures are swallowed on purpose. This is speculative work; if it does
    /// not land, scrolling down simply fetches the chapter the normal way and
    /// reports any error there, where the user can see it in context.
    private func startReadingAhead() {
        guard let last = loaded.last else { return }
        let nextIndex = last.chapter.index + 1
        guard chapters.indices.contains(nextIndex) else { return }
        let next = chapters[nextIndex]
        guard !next.isDownloaded, readAhead?.chapterId != next.id,
              let rule = env.sites.rule(id: book.siteId)
        else { return }

        readAheadTask?.cancel()
        readAheadTask = Task { [weak self] in
            guard let self else { return }
            await self.env.pacer.pace()
            guard !Task.isCancelled else { return }
            guard let paragraphs = try? await self.env.bookService.chapterParagraphs(
                rule: rule, chapter: next
            ) else { return }
            guard !Task.isCancelled else { return }
            self.readAhead = (chapterId: next.id, paragraphs: paragraphs)
        }
    }

    /// Leaving the reader: stop reading ahead. Continuing to fetch pages for a
    /// screen nobody is looking at is the definition of impolite traffic.
    func stopReading() {
        readAheadTask?.cancel()
        readAheadTask = nil
        persistProgress()
    }

    // MARK: Progress

    /// Records that a paragraph came into view.
    ///
    /// Notes are ignored until a jump has landed. Restoring a position renders every
    /// paragraph the scroll passes on the way down, and the last of those to appear
    /// would otherwise overwrite the position just restored with one near the top of
    /// the chapter — turning "continue reading" into "read this chapter again".
    func note(chapterIndex: Int, paragraph: Int) {
        if let restoring {
            guard chapterIndex == currentChapterIndex, paragraph >= restoring.paragraph else { return }
            self.restoring = nil
        }
        currentChapterIndex = chapterIndex
        // A scroll view can only say which paragraph appeared, so the offset within
        // it is honestly zero rather than guessed at. See `TextAnchor`.
        currentAnchor = TextAnchor(paragraph: paragraph, characterOffset: 0)
    }

    /// Records the page the paginated reader settled on.
    ///
    /// Separate from `note` because a page is authoritative: the renderer says where it
    /// landed, once, so there is no cascade of appearing paragraphs to filter and the
    /// `restoring` guard would only get in the way. This is also the one path that can
    /// record a real `characterOffset` — a page knows which character it opens on.
    func notePage(chapterIndex: Int, anchor: TextAnchor) {
        restoring = nil
        currentChapterIndex = chapterIndex
        currentAnchor = anchor
    }

    /// Re-aims the scrolling reader at the current position without re-fetching.
    ///
    /// Used when the renderer changes under a chapter that is already in memory: a
    /// chapter read online is held nowhere else, so going through `jump` would spend a
    /// network round trip to show text the app is already holding.
    func retarget() {
        guard let current = currentLoadedChapter else { return }
        restoring = currentAnchor.paragraph > 0 ? currentAnchor : nil
        scrollTarget = currentAnchor.scrollID(chapterId: current.chapter.id)
    }

    /// Written on chapter change and on leaving the reader rather than on every
    /// paragraph: the position only matters when reading stops.
    func persistProgress() {
        guard !loaded.isEmpty, let position = currentPosition else { return }
        // Compared against the start of the chapter rather than against paragraph 0:
        // the paginated reader can move within the first paragraph, and that is still
        // a position worth keeping.
        guard persistedIndex != currentChapterIndex || currentAnchor != .start else { return }
        persistedIndex = currentChapterIndex
        env.recordProgress(book: book, position: position)
    }

    // MARK: Saved positions

    /// One button both saves and unsaves, because the filled icon is the only thing
    /// on screen that says this page is already saved — so the tap that produced it
    /// has to be the tap that undoes it.
    ///
    /// No confirmation, matching the library's rule: the app asks before a delete
    /// that destroys text it cannot fetch again (`LibraryView`), and the sentence a
    /// bookmark points at stays exactly where it was.
    func toggleBookmark() {
        guard let position = currentPosition else { return }
        let id = ReadingBookmark.makeId(bookId: book.id, position: position)
        if bookmarkedIDs.contains(id) {
            try? env.repo.removeReadingBookmark(id: id)
            bookmarkedIDs.remove(id)
        } else {
            _ = try? env.repo.addReadingBookmark(
                bookId: book.id, position: position, excerpt: currentExcerpt()
            )
            bookmarkedIDs.insert(id)
        }
    }

    /// Captured at save time rather than looked up when the list is drawn: the text
    /// of a chapter read online is held in memory only, so by the time the list
    /// appears there may be nothing left to quote.
    private func currentExcerpt() -> String? {
        guard let chapter = currentLoadedChapter else { return nil }
        return currentAnchor.excerpt(in: chapter.paragraphs)
    }

    // MARK: Highlights

    func highlights(inChapter siteChapterId: String) -> [TextHighlight] {
        highlightsByChapter[siteChapterId] ?? []
    }

    /// No confirmation and no undo prompt, matching the bookmark button: the mark is
    /// visible the instant it is made, and the way to undo it is to tap it.
    func addHighlight(siteChapterId: String, selection: TextSelection) {
        guard let stored = try? env.repo.addHighlight(
            bookId: book.id, siteChapterId: siteChapterId, selection: selection
        ) else { return }
        var marks = highlightsByChapter[siteChapterId] ?? []
        // The repository is idempotent on the span, so re-marking a passage returns the
        // row that is already on screen; appending it again would paint it twice.
        guard !marks.contains(where: { $0.id == stored.id }) else { return }
        marks.append(stored)
        highlightsByChapter[siteChapterId] = marks
    }

    func removeHighlight(_ highlight: TextHighlight) {
        try? env.repo.removeHighlight(id: highlight.id)
        highlightsByChapter[highlight.siteChapterId]?.removeAll { $0.id == highlight.id }
    }
}

// MARK: - Appearance sheet

struct ReaderSettingsSheet: View {
    @Bindable var settings: ReaderSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                ReadingAppearanceSections(settings: settings)
            }
            .navigationTitle("reader.settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("common.done") { dismiss() }
                }
            }
        }
    }
}
