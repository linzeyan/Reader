import SwiftUI

/// The reader: one continuous scroll across chapter boundaries.
///
/// v1 is deliberately scroll-based rather than paginated. Pagination needs
/// TextKit 2 layout to be correct across type sizes and is planned for v2; a
/// scroll view gets the reading experience right today, and the progress model
/// (chapter + paragraph) converts cleanly to page positions later.
///
/// All controls sit at the bottom of the screen: the app is meant to be usable
/// with one hand, and the top third of a modern iPhone is out of thumb reach.
struct ReaderView: View {
    let book: Book
    let startIndex: Int

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var model: ReaderModel?
    @State private var showControls = false
    @State private var showCatalog = false
    @State private var showSettings = false
    @State private var settings = ReaderSettings.shared

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
        .toolbar(showControls ? .visible : .hidden, for: .navigationBar)
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
            await created.start(at: startIndex)
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            model?.stopReading()
        }
    }

    // MARK: - Text

    private func content(_ model: ReaderModel) -> some View {
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

    private func chapterBlock(_ item: ReaderModel.LoadedChapter, model: ReaderModel) -> some View {
        VStack(alignment: .leading, spacing: settings.paragraphSpacing) {
            Text(item.chapter.title)
                .font(.system(size: settings.fontSize + 4, weight: .semibold))
                .padding(.top, 28)
                .padding(.bottom, 6)
                .id(item.id)

            ForEach(Array(item.paragraphs.enumerated()), id: \.offset) { offset, paragraph in
                Text(paragraph)
                    .font(settings.font)
                    .lineSpacing(settings.lineSpacing)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Progress is recorded from whatever scrolls into view; there
                    // is no cheaper way to know the reading position in a lazy
                    // stack on iOS 17.
                    .onAppear { model.note(chapterIndex: item.chapter.index, paragraph: offset) }
            }
        }
        .foregroundStyle(settings.theme.foreground)
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
            control("arrow.up.to.line", label: "reader.previousChapter") {
                Task { await model.jump(to: model.currentChapterIndex - 1) }
            }
            .disabled(model.currentChapterIndex <= 0)
            control("arrow.down.to.line", label: "reader.nextChapter") {
                Task { await model.jump(to: model.currentChapterIndex + 1) }
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
                    Task { await model?.jump(to: chapter.index) }
                } label: {
                    HStack {
                        ChapterRow(chapter: chapter, book: book)
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
    /// Set when the view should scroll somewhere; cleared by the view once done.
    var scrollTarget: String?

    var hasMore: Bool {
        guard let last = loaded.last else { return false }
        return last.chapter.index < chapters.count - 1
    }

    private let book: Book
    private let env: AppEnvironment
    private var currentOffset = 0
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

    func start(at index: Int) async {
        chapters = (try? env.repo.chapters(bookId: book.id)) ?? []
        guard !chapters.isEmpty else { return }
        await jump(to: min(max(index, 0), chapters.count - 1))
    }

    /// Replaces what is on screen with a single chapter. Everything before it is
    /// dropped rather than kept: an unbounded scroll history is the fastest way
    /// to make a long novel run the app out of memory.
    func jump(to index: Int) async {
        guard chapters.indices.contains(index) else { return }
        persistProgress()
        // Whatever was read ahead belonged to the old position.
        readAheadTask?.cancel()
        readAhead = nil
        loaded = []
        currentChapterIndex = index
        currentOffset = 0
        await append(chapters[index])
        scrollTarget = chapters[index].id
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

    func note(chapterIndex: Int, paragraph: Int) {
        currentChapterIndex = chapterIndex
        currentOffset = paragraph
    }

    /// Written on chapter change and on leaving the reader rather than on every
    /// paragraph: the position only matters when reading stops.
    func persistProgress() {
        guard !loaded.isEmpty else { return }
        guard persistedIndex != currentChapterIndex || currentOffset > 0 else { return }
        persistedIndex = currentChapterIndex
        env.recordProgress(book: book, chapterIndex: currentChapterIndex, offset: currentOffset)
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
