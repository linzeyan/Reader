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
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
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
    /// What the scrolling reader's bar is asking about, if anything. The paginated
    /// renderer holds the same two questions itself, because the selection they are
    /// about is a range in text only it has laid out.
    @State private var markChoice: ScrollMarkChoice?

    var body: some View {
        #if DEBUG
        // Counted, not printed: this runs at frame rate whenever something in here
        // reads per-frame state, and telling "body is re-running" from "the container
        // is busy" is the first fork in every reader stall. See `ReaderProbe`.
        let _ = ReaderProbe.body()
        #endif
        ZStack {
            settings.theme.background.ignoresSafeArea()
            if let model {
                content(model)
            } else {
                ProgressView()
            }
        }
        .navigationBarBackButtonHidden()
        // Never, in either mode. A navigation bar that comes and goes changes the safe
        // area, and a changed safe area moves every line of text down while the reader is
        // looking at it; in paginated mode it also re-measures the page breaks. What the
        // bar used to carry now floats over the text instead — see `titleCapsule`.
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        // Always hidden, for the same reason, rather than following the controls: on a
        // phone with no sensor housing the status bar's height *is* safe area, so
        // toggling it shifts the text by exactly that much.
        .statusBarHidden(true)
        .preferredColorScheme(settings.theme.colorScheme)
        .overlay(alignment: .top) {
            if showControls, let model {
                ReaderTitleCapsule(model: model, fallbackTitle: book.shownName)
            }
        }
        .overlay(alignment: .bottom) {
            if showControls, let model {
                ReaderControlBar(
                    model: model, onBack: { dismiss() },
                    showCatalog: $showCatalog, showSettings: $showSettings
                )
            }
        }
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
            #if DEBUG
            ReaderProbe.start()
            #endif
            guard model == nil else { return }
            let created = ReaderModel(book: book, env: env)
            model = created
            await created.start(at: position)
            #if DEBUG
            // Test-only: grow the loaded window to what hours of continuous reading
            // accumulate, without spending test time scrolling there. Read from the
            // defaults argument domain like the other test switches, and zero for
            // everyone else. The chapters arrive through the same `loadNext` path a
            // real session grows by, so the state is the real state, not a mock of
            // it. See `ReaderLongSessionTapTests`.
            let stressChapters = UserDefaults.standard.integer(forKey: "reader.stressPreload")
            while created.loaded.count < stressChapters, created.hasMore {
                let before = created.loaded.count
                await created.loadNext()
                // A chapter that will not load would hold this loop forever; the
                // walk is better served by whatever did load than by no reader.
                guard created.loaded.count > before else { break }
            }
            #endif
        }
        // Switching to the scrolling renderer builds a fresh scroll view, which starts
        // at the top of whatever is loaded. The target it is re-aimed with is applied
        // as soon as the chapter it names has a laid-out column, so it can be stated
        // here rather than a runloop turn later.
        .onChange(of: settings.mode) { _, mode in retargetOnModeChange(mode) }
        // The only thing this screen holds that is worth giving back, and the only
        // place that knows which chapters the reader still needs. Scoped to the reader
        // being on screen, which is exactly when there are chapters to give back.
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.didReceiveMemoryWarningNotification
            )
        ) { _ in
            model?.dropDistantChapters()
        }
        // Applied on the way in *and* on the toggle: set only in `onAppear`, turning
        // the setting off mid-session changed nothing until the reader was left and
        // re-entered — invisible exactly when someone worried about battery flips it.
        .onChange(of: settings.keepScreenOn) { _, keepOn in
            UIApplication.shared.isIdleTimerDisabled = keepOn
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            model?.stopReading()
            #if DEBUG
            ReaderProbe.stop()
            #endif
        }
        // The position has to be on disk before the process can be taken away, and a
        // suspended app is killed without being told. `.inactive` rather than
        // `.background` alone: it is the phase that arrives while the app is still
        // running, and writing a row is cheap enough to do for a pulled-down
        // notification centre that turns out to be nothing.
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            model?.persistProgress()
            // A drag the app was taken away from mid-gesture never ends, and a finger
            // the reader believes is still down would hold back every later chapter it
            // is asked for. Leaving is as good as lifting.
            model?.touch(down: false)
        }
    }

    /// Switching to the scrolling renderer aims it at where the paginated one left the
    /// reader. Both write the same `ReadingPosition`, so this is a restatement rather
    /// than a conversion.
    private func retargetOnModeChange(_ mode: ReaderSettings.Mode) {
        // A question about a passage belongs to the renderer that asked it: the
        // paginated one is about to ask its own, over text it has laid out itself.
        markChoice = nil
        guard mode == .scroll else { return }
        model?.retarget()
    }

    // MARK: - Text

    @ViewBuilder
    private func content(_ model: ReaderModel) -> some View {
        switch settings.mode {
        case .scroll: scrollingText(model)
        case .paginated: pagedText(model)
        }
    }

    @ViewBuilder
    private func scrollingText(_ model: ReaderModel) -> some View {
        if model.loaded.isEmpty {
            // Nothing to draw, and the one moment a failure has to own the whole
            // screen: this reader hides the navigation bar, so the only way off it is
            // the control bar — which is summoned by a tap *on the text*, and there is
            // none. A site demanding verification lands the reader here every time.
            if model.isLoading {
                ProgressView()
            } else if let error = model.error {
                failure(error, model: model)
            } else {
                Text("reader.end").font(.footnote).foregroundStyle(.secondary)
            }
        } else {
            ReaderScrollingText(
                chapters: model.loaded,
                settings: settings,
                highlights: model.highlightsByChapter,
                marked: markChoice.flatMap(\.beingMarked),
                target: model.scrollTarget,
                footer: model.isLoading ? .loading : (model.hasMore ? .none : .endOfBook),
                onPlaceChange: { model.notePlace($0) },
                // Guarded here rather than inside the model: these are asked on every
                // scrolled frame the reader spends inside the prefetch lead, and
                // parked at the end of the book that would be a task per frame to find
                // out there is nothing to do.
                onNeedsNext: {
                    guard model.canLoadNext, let last = model.loaded.last else { return }
                    Task { await model.loadNextIfLast(after: last.chapter.index) }
                },
                onNeedsPrevious: {
                    guard model.canLoadPrevious, let first = model.loaded.first else { return }
                    Task { await model.loadPrevious(before: first.chapter.index) }
                },
                onTouch: { down in
                    model.touch(down: down)
                    // A press that turned into a drag was a scroll, not a question. The
                    // press fires on time whatever the finger does next, so this is the
                    // only thing that can tell the two apart: a drag has begun.
                    if down, markChoice != nil { markChoice = nil }
                },
                onTap: { handleTap($0, model: model) },
                onMark: { chapterIndex, paragraph in
                    guard let chapter = model.loaded.first(where: {
                        $0.chapter.index == chapterIndex
                    }) else { return }
                    mark(paragraph: paragraph, in: chapter)
                },
                onTargetReached: { model.clearScrollTarget() }
            )
            .overlay(alignment: .bottom) { markBar(model) }
            .overlay(alignment: .bottom) { loadFailure(model) }
            .animation(.snappy(duration: 0.18), value: markChoice)
        }
    }

    /// A chapter that would not load, floated over the text the reader still has.
    ///
    /// Over rather than under, unlike the notice this replaces. It carries the only way
    /// off this screen — see `failure(_:model:)` — and a way out the reader has to
    /// scroll to the foot of the loaded text to find is one they will not find.
    @ViewBuilder
    private func loadFailure(_ model: ReaderModel) -> some View {
        if let error = model.error {
            failure(error, model: model)
                .padding(.vertical, 12)
                .background(.bar, in: .rect(cornerRadius: 18))
                .padding(.horizontal, 12)
                // Clear of the control bar's own resting place, so the two never stack
                // on top of each other.
                .padding(.bottom, 72)
                .transition(.opacity)
        }
    }

    /// Every tap in the scrolling reader ends up here.
    ///
    /// The order is the point. The paragraph under the finger speaks first: a marked
    /// paragraph answers the tap that lands on it, the same way a marked passage answers
    /// one on the page — the reader put the mark there, and a mark that ignores being
    /// touched can only be undone from another screen. Then any question waiting on
    /// screen — a tap is how the reader says no to it, and it must not also turn a page.
    /// Then, only for readers who asked for it, the zones; for everyone else a tap means
    /// what it has always meant here.
    ///
    /// - Returns: whether the tap should go on to turn a page.
    private func handleTap(_ tap: ReaderTap, model: ReaderModel) -> Bool {
        if let paragraph = tap.paragraph, let index = tap.chapterIndex,
           let chapter = model.loaded.first(where: { $0.chapter.index == index }) {
            // The lift of the finger that started the press arrives here as a tap, so
            // the paragraph being asked about must not dismiss its own question.
            if case .some(.mark(let asked, let askedParagraph, _)) = markChoice,
               asked == chapter.chapter.siteChapterId, askedParagraph == paragraph {
                return false
            }
            // The mark under the finger, hit against the bands it is drawn in — see
            // `ReaderScrollCoordinator.highlight(at:in:)`, which is also the rule the
            // paginated renderer answers by.
            if markChoice == nil, let stored = tap.highlight {
                markChoice = .remove(stored)
                return false
            }
        }
        if markChoice != nil {
            markChoice = nil
            return false
        }
        guard settings.tapToTurnPage, tap.zone != .controls else {
            showControls.toggle()
            return false
        }
        return true
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
                onAnchorChange: { anchor, fraction in
                    openAtLastPage = nil
                    // Any page that does turn answers the question the notice asked.
                    reachedEndOfBook = false
                    model.notePage(
                        chapterIndex: current.chapter.index, anchor: anchor, fraction: fraction
                    )
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
            failure(error, model: model)
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

    // MARK: - Marks while scrolling

    /// What the scrolling reader's bar is asking about.
    ///
    /// One value with two cases rather than two optionals: the bar can only ever ask one
    /// question, and a pair of states that must never both be set is a state machine
    /// spelled wrong.
    private enum ScrollMarkChoice: Equatable {
        /// A long press picked out a whole paragraph, which is waiting to become a mark.
        case mark(siteChapterId: String, paragraph: Int, selection: TextSelection)
        /// A tap landed on a stored mark, which is waiting to be removed.
        case remove(TextHighlight)

        var siteChapterId: String {
            switch self {
            case .mark(let siteChapterId, _, _): return siteChapterId
            case .remove(let highlight): return highlight.siteChapterId
            }
        }

        /// The paragraph to draw picked out, when the open question is about marking one.
        var beingMarked: ReaderMark? {
            guard case .mark(let siteChapterId, let paragraph, _) = self else { return nil }
            return ReaderMark(siteChapterId: siteChapterId, paragraph: paragraph)
        }
    }

    /// A long press picks out the paragraph under the finger.
    private func mark(paragraph: Int, in chapter: ReaderModel.LoadedChapter) {
        guard let selection = TextSelection.wholeParagraph(at: paragraph, in: chapter.paragraphs)
        else { return }
        markChoice = .mark(
            siteChapterId: chapter.chapter.siteChapterId, paragraph: paragraph, selection: selection
        )
    }

    /// The bar that asks about the paragraph, drawn only while the chapter it belongs to
    /// is still on screen: a jump from the catalog replaces what is loaded, and a bar
    /// left over from the chapter before would offer to mark text nobody can see.
    @ViewBuilder
    private func markBar(_ model: ReaderModel) -> some View {
        if let choice = markChoice,
           model.loaded.contains(where: { $0.chapter.siteChapterId == choice.siteChapterId }) {
            switch choice {
            case .mark(let siteChapterId, _, let selection):
                MarkActionBar(title: "reader.highlight.add", icon: "highlighter") {
                    model.addHighlight(siteChapterId: siteChapterId, selection: selection)
                    markChoice = nil
                } cancel: {
                    markChoice = nil
                }
            case .remove(let highlight):
                MarkActionBar(title: "reader.highlight.remove", icon: "trash") {
                    model.removeHighlight(highlight)
                    markChoice = nil
                } cancel: {
                    markChoice = nil
                }
            }
        }
    }

    /// What either renderer shows when a chapter will not load: what went wrong, another
    /// go at it, and a way out.
    ///
    /// The way out is the part that was missing. This screen hides the navigation bar and
    /// the back button with it, so the only way off it is the floating control bar — and
    /// the control bar is summoned by a tap *on the text*, which a chapter that failed to
    /// load does not have. A site demanding verification lands the reader here every time,
    /// including straight after they have passed it, and until this button existed the
    /// only way off the screen was to kill the app.
    private func failure(_ message: String, model: ReaderModel) -> some View {
        VStack(spacing: 12) {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("common.back") { dismiss() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("reader.failure.back")
                // The one failure with a real answer on it. An article the publisher
                // summarised to nothing will never load however many times it is
                // retried, and the page it points at is where the piece actually is.
                if let original = model.currentArticleURL {
                    Button("reader.openOriginal") { openURL(original) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("reader.failure.openOriginal")
                }
                Button("reader.retry") { Task { await model.retry() } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("reader.retry")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }

    // MARK: - Controls

    /// The same order the book's own catalog screen is in — one book, one direction.
    /// A reader who put a serial newest-first is not asking for that only when they
    /// arrive from the shelf.
    private var catalogChapters: [Chapter] {
        let all = model?.chapters ?? []
        return env.librarySettings.isCatalogDescending(bookId: book.id)
            ? Array(all.reversed())
            : all
    }

    private var catalogSheet: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                // Hoisted out of the row builder, like the other two screens that draw
                // `ChapterRow` — touching it per row makes drawing a thirteen-hundred-
                // chapter list quadratic (see `BookDetailView`).
                let lastReadIndex = book.lastReadIndex(in: model?.chapters ?? [])
                List(catalogChapters) { chapter in
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
                                lastReadIndex: lastReadIndex,
                                kind: book.kind
                            )
                            if chapter.index == model?.currentChapterIndex {
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tint)
                            }
                        }
                    }
                    .tint(.primary)
                }
                // Opens where the reader is, not at chapter one. A catalog of thirteen
                // hundred chapters that always starts at the top is a scroll the reader
                // has to make every single time to find out where they already are.
                // Centred rather than at the top, so the chapters either side of it —
                // the ones worth going back to — come with it.
                //
                // In `task` because it runs after the first render: `scrollTo` needs rows
                // to aim at, and there are none while the list is still being built.
                .task {
                    guard let model, model.chapters.indices.contains(model.currentChapterIndex)
                    else { return }
                    proxy.scrollTo(model.chapters[model.currentChapterIndex].id, anchor: .center)
                }
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

// MARK: - Control chrome

/// The floating counterpart to the control bar: which chapter this is, and how far
/// through it the reader has got.
///
/// It is an overlay, not the navigation bar it replaces, because a bar that appears
/// pushes the text down; floating over the page costs the reader a strip of text
/// only while the controls are up.
///
/// Its own view, not a helper on `ReaderView`, and that is load-bearing: it reads
/// `currentFraction` and `currentLoadedChapter`, which the viewport rewrites on
/// every scrolled frame. Read from `ReaderView.body`, those writes re-evaluated the
/// whole reader — the full ForEach over every loaded chapter — once per frame for
/// as long as the chrome was up, which on device is exactly "with the toolbar open,
/// every tapped turn stutters". Here the same writes re-evaluate a capsule.
///
/// The share is the one the model would store, so what the reader sees here and what
/// the shelf says later cannot disagree.
private struct ReaderTitleCapsule: View {
    let model: ReaderModel
    let fallbackTitle: String

    var body: some View {
        HStack(spacing: 10) {
            // No line limit. A capsule this wide holds about twenty CJK characters at
            // footnote size, and these titles run past that routinely — a capsule
            // reading "第363章 爆發之二，逆天刷子，啓動！魔帝之…" names no chapter the
            // reader can place, which is the one thing it is for. Wrapping costs a
            // strip of text only while the controls are up, and only for the titles
            // that need it.
            Text(model.currentLoadedChapter?.chapter.title ?? fallbackTitle)
            if let fraction = model.currentFraction {
                Text(verbatim: TextAnchor.shareText(fraction))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.bar, in: .capsule)
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .accessibilityIdentifier("reader.chapterTitle")
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// The reader's bottom controls. Its own view for the same reason as
/// `ReaderTitleCapsule`: the bookmark fill and the chapter buttons read state the
/// viewport rewrites every frame, and those reads must not belong to the whole
/// reader's body.
private struct ReaderControlBar: View {
    let model: ReaderModel
    let onBack: () -> Void
    @Binding var showCatalog: Bool
    @Binding var showSettings: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 0) {
            control("chevron.left", label: "common.back") { onBack() }
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
            // Named for the walks that have to make a chapter jump. The label is
            // localized, so it is not a handle a test can hold.
            .accessibilityIdentifier("reader.nextChapter")
            // Only where there is an original to open — see `currentArticleURL`. A
            // seventh control on every novel would be a browser button on text that is
            // already fully here.
            if let original = model.currentArticleURL {
                control("safari", label: "reader.openOriginal") { openURL(original) }
                    .accessibilityIdentifier("reader.openOriginal")
            }
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
}

// MARK: - Mark action bar

/// The bar that asks about one passage: what to do with it, and a way out.
///
/// The only control the highlight feature has, in either renderer, and it exists only
/// once there is something to act on: marking a passage has to say *which* passage, so
/// the gesture comes first and a permanent button in the control bar could report
/// nothing but "pick something first".
struct MarkActionBar: View {
    let title: LocalizedStringKey
    let icon: String
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: confirm) {
                Label(title, systemImage: icon).font(.footnote.weight(.medium))
            }
            .accessibilityIdentifier("reader.highlight.action")
            Divider().frame(height: 18)
            Button("common.cancel", action: cancel)
                .font(.footnote)
                .tint(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar, in: .capsule)
        // Clear of the reader's own control bar, which may well be up when a passage is
        // marked: two bars stacked on each other at the bottom of the screen is the one
        // way to make a confirm button unhittable. Lands where the end-of-book notice
        // lands, and for the same reason.
        .padding(.bottom, 60)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
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

    /// Where the scrolling renderer has to put the reader. Consumed once and cleared by
    /// the renderer: a jump, a mode switch, or opening the book.
    ///
    /// A chapter and an anchor rather than a view id. The id it replaces existed for
    /// `ScrollViewProxy`, which can only be pointed at a view and cannot say where the
    /// view landed — which is why a jump used to need an arrival gate that kept
    /// re-aiming while a lazy container settled, and why every insert above the reader
    /// had to be paid for with a correction that measured its own miss. A laid-out
    /// column turns this pair into an exact height.
    struct ScrollTarget: Equatable {
        let chapterIndex: Int
        let anchor: TextAnchor
    }
    private(set) var scrollTarget: ScrollTarget?

    /// Consumed by the renderer once the reader has been put there.
    ///
    /// Also where the way back behind a landing is spent. A jump leaves one chapter
    /// loaded, so the first backward drag after one has nothing above it to move into;
    /// spending that gesture here costs the reader nothing, and `showPreviousChapter`
    /// still holds the insert until their hand is off the glass.
    ///
    /// Here rather than on the first place reported after the target cleared, which is
    /// what it used to wait for: that was standing in for "the scroll has stopped
    /// moving", back when a landing converged over several frames of a lazy container
    /// re-aiming. The renderer sets an exact offset and says so — this call *is* the
    /// landing — and the old proxy no longer fires at all, because the landing's place
    /// is reported synchronously by the offset change, while the target is still set.
    func clearScrollTarget() {
        scrollTarget = nil
        guard wantsPreviousBehindLanding else { return }
        wantsPreviousBehindLanding = false
        Task { await loadStoredPrevious() }
    }

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

    /// The page the article on screen came from, for a subscription.
    ///
    /// A feed carries whatever text the publisher chose to put in the document, and a
    /// great many publish a first paragraph and a link — so for this one medium the
    /// original is not a curiosity, it is the rest of what the reader came for. It is
    /// also the only answer available for an article with no text at all, which is why
    /// the failure screen offers it too.
    ///
    /// Only for a subscription. A novel's chapter page is the very thing this reader has
    /// already drawn, in a browser that does not remember where they were.
    ///
    /// Nil when the feed published no link of its own, which `FeedService` stores as an
    /// empty address rather than inventing one.
    var currentArticleURL: URL? {
        guard book.kind == .feed, chapters.indices.contains(currentChapterIndex),
              let url = URL(string: chapters[currentChapterIndex].url),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    var isCurrentPositionBookmarked: Bool {
        guard let currentPosition else { return false }
        return bookmarkedIDs.contains(
            ReadingBookmark.makeId(bookId: book.id, position: currentPosition)
        )
    }

    private let book: Book
    private let env: AppEnvironment
    /// The share the renderer on screen last reported: a page's, or a scrolled window's.
    /// Nil only before either has said anything, which is the one moment `currentFraction`
    /// has to fall back to measuring the anchor.
    private var reportedFraction: Double?
    private var writeRule = ProgressWriteRule()
    /// The one chapter read ahead, held in memory only. Never more than one:
    /// this is here to hide a page load, not to become a second download queue.
    private var readAhead: (chapterId: String, paragraphs: [String])?
    private var readAheadTask: Task<Void, Never>?
    /// What the in-flight read-ahead is doing, so a reader who catches up with it can
    /// act on the difference: a fetch already on the wire is worth waiting for, while
    /// a politeness pause that has not asked for anything yet is worth abandoning.
    /// Without this, catching up meant issuing the same request *again*, queued behind
    /// the read-ahead's copy in the fetcher — a slow chapter made twice as slow.
    ///
    /// Left stale when the task ends on its own: by then awaiting the task is free and
    /// the result — or its absence — answers correctly. Only the paths that abandon
    /// the task clear it.
    private var readAheadPhase: ReadAheadPhase?

    private enum ReadAheadPhase {
        case pacing(chapterId: String)
        case fetching(chapterId: String)
    }

    /// Bumped by every jump. A chapter fetched for a window the reader has left belongs
    /// nowhere, and `loaded` on its own cannot say so: a jump empties it, which looks
    /// exactly like the empty window that jump's own load is about to fill.
    @ObservationIgnored private var generation = 0
    /// The chapter before the first one loaded, fetched and waiting for a moment when
    /// putting it on screen will not fight the reader's finger — see `showPreviousChapter`.
    private var pendingPrevious: LoadedChapter?
    /// Set by `jump`, spent when the renderer says that jump has landed — see
    /// `clearScrollTarget` and `loadStoredPrevious`. A flag rather than a call at the end
    /// of `jump`, because the moment worth acting on is not when the chapter loads, it is
    /// when the reader is standing where they asked to be.
    private var wantsPreviousBehindLanding = false
    /// Whether a finger is on the glass right now. Set by the reader's drag recogniser.
    private var isTouching = false

    init(book: Book, env: AppEnvironment) {
        self.book = book
        self.env = env
    }

    /// Announces a structural change to the loaded window to the stall probe, so a
    /// heartbeat gap has an event to be attributed to. A no-op in Release, where
    /// `ReaderProbe` does not exist.
    ///
    /// The message is an autoclosure so an unarmed run does not even build the string.
    private func probe(_ what: @autoclosure () -> String) {
        #if DEBUG
        guard ReaderProbe.isArmed else { return }
        ReaderProbe.mutated(what(), loaded: loaded.count)
        #endif
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
        readAheadPhase = nil
        readAhead = nil
        // Fetched for a place the reader is leaving. Dropped here rather than left for
        // `showPreviousChapter` to reject, so a jump can never be followed by a chapter
        // arriving above the one it landed in.
        pendingPrevious = nil
        generation += 1
        let mine = generation
        loaded = []
        probe("jump idx=\(index)")
        // Aimed before the load rather than after it. The renderer holds a target until
        // the chapter it names has a laid-out column and then applies it exactly, so
        // stating it early costs nothing — and the reports that arrive in the meantime
        // are the *old* content's, which is what made the aim unsafe to state early
        // when a lazy container had to be re-aimed until it settled.
        currentChapterIndex = index
        currentAnchor = anchor
        scrollTarget = ScrollTarget(chapterIndex: index, anchor: anchor)
        await append(chapters[index])
        guard mine == generation else { return }
        // A stored anchor can name a paragraph the re-fetched chapter no longer has.
        let landing = landingAnchor(for: anchor)
        guard landing != anchor else {
            wantsPreviousBehindLanding = index > 0
            return
        }
        currentAnchor = landing
        scrollTarget = ScrollTarget(chapterIndex: index, anchor: landing)
        // The way back, once this landing has settled. Nothing to give back at the front
        // of the book.
        wantsPreviousBehindLanding = index > 0
    }

    /// A stored anchor can outlive the text it named: a chapter re-fetched from the
    /// site can come back with fewer paragraphs than when the position was recorded.
    /// Clamping keeps the jump inside the chapter — the end of the right chapter is
    /// closer to the truth than not moving at all, and an anchor no paragraph can
    /// satisfy would aim the scroll at a row that never exists.
    private func landingAnchor(for anchor: TextAnchor) -> TextAnchor {
        let count = loaded.first?.paragraphs.count ?? 0
        guard count > 0 else { return .start }
        guard anchor.paragraph >= count else { return anchor }
        return TextAnchor(paragraph: count - 1, characterOffset: 0)
    }

    /// Another go at whatever failed.
    ///
    /// Which call that is depends on how far the reader got. With text on screen the
    /// failure was the chapter *after* it, and `loadNext` is the retry. With nothing
    /// loaded the chapter the reader opened is the one that failed — and `loadNext`
    /// cannot ask for it, because it works from the last loaded chapter and there is
    /// none. That is what made the retry button do nothing on the one screen where it
    /// was the only control: a site demanding verification fails the *first* chapter,
    /// so the reader was left tapping a button that could not act.
    func retry() async {
        guard loaded.isEmpty else { return await loadNext() }
        await jump(toChapterAt: currentChapterIndex, anchor: currentAnchor)
    }

    /// Whether asking for the chapter after the loaded window is worth a task right now.
    ///
    /// Asked before one is spawned rather than checked inside it: the renderer asks on
    /// every scrolled frame the reader spends inside the prefetch lead, and parked at
    /// the end of the book that would be a task per frame to find out there is nothing
    /// to do. Never while a failure is showing either — `append` clears the error on
    /// entry, so re-spawning per frame kept a failing chapter in an eternal spinner:
    /// the retry button was never on screen long enough to exist, and the reader was
    /// walled in with every tap doing nothing.
    var canLoadNext: Bool {
        guard error == nil, !isLoading, let last = loaded.last else { return false }
        return chapters.indices.contains(last.chapter.index + 1)
    }

    var canLoadPrevious: Bool {
        guard !isLoading, pendingPrevious == nil, let first = loaded.first else { return false }
        return first.chapter.index > 0
    }

    func loadNext() async {
        guard !isLoading, let last = loaded.last else { return }
        let nextIndex = last.chapter.index + 1
        guard chapters.indices.contains(nextIndex) else { return }
        // No longer deferred to a still screen, and nothing waits for one. The append
        // this used to be froze the main thread for 300–800ms — one SwiftUI transaction
        // growing a lazy stack by a whole chapter — which is why it was sliced up and
        // landed on a quiet viewport. Here it appends one element to an array; the
        // chapter's layout happens on `ReaderScrollCoordinator`'s own queue, off the
        // main thread, and arrives as a `contentSize` change nobody is watching.
        await append(chapters[nextIndex])
    }

    /// Pulls the next chapter in while the reader is still a few paragraphs short of it.
    ///
    /// The marker at the very foot of the text is too late to be smooth: reaching it is
    /// the moment the scroll runs out of content, and the file read and layout pass that
    /// follow happen while the reader is looking at the seam. Asked for a page or two
    /// early, the same work lands before they get there.
    ///
    /// - Parameter index: the chapter the caller saw as the last one loaded. Re-checked
    ///   here because these calls queue up — the viewport reports every frame — and a
    ///   queued call running after another one's append would load past the frontier
    ///   the reader is actually near.
    func loadNextIfLast(after index: Int) async {
        guard loaded.last?.chapter.index == index else { return }
        await loadNext()
    }

    /// The chapter before the first one loaded, put in front of it.
    ///
    /// `jump` drops everything it replaces, which keeps a long novel from filling memory
    /// with chapters nobody is reading — but it also turned the top of the screen into a
    /// wall: someone who opened chapter 40 from the catalog could scroll forward for ever
    /// and not back one line. This gives back the way they came.
    ///
    /// Failures are silent, unlike a forward load. This is speculative work the reader
    /// never asked for — the same bargain read-ahead makes in the other direction — and
    /// replacing the page they are reading with an error would be answering a question
    /// nobody asked.
    ///
    /// Fetching it is all this does. Putting it on screen waits for `showPreviousChapter`,
    /// because an insert while a finger is on the glass cannot be corrected — see there.
    ///
    /// - Parameter index: the chapter the caller believed was first. Re-checked here
    ///   because these calls queue up — the viewport reports every frame — and a call
    ///   that ran after another one's insert would put a *second* chapter above the
    ///   reader, and a third after that, walking backwards through the book one queued
    ///   task at a time.
    func loadPrevious(before index: Int) async {
        guard !isLoading, pendingPrevious == nil,
              let first = loaded.first, first.chapter.index == index
        else {
            return
        }
        let target = index - 1
        guard chapters.indices.contains(target) else { return }
        isLoading = true
        defer { isLoading = false }
        guard let text = try? await paragraphs(for: chapters[target]) else { return }
        pendingPrevious = LoadedChapter(chapter: chapters[target], paragraphs: text)
        showPreviousChapter()
    }

    /// The chapter behind a landing, put in place while the reader is still looking at
    /// where they arrived.
    ///
    /// A jump leaves one chapter loaded, so the first backward drag after one has nothing
    /// above it to move into: it rubber-bands, the chapter it asks for arrives only once
    /// the finger lifts (`showPreviousChapter`), and the reader's way back is a whole
    /// gesture late. Every time. Spending that gesture here instead costs them nothing —
    /// at a landing there is no scroll in flight to fight and, almost always, no finger on
    /// the glass; and if there is one, the same gate holds this back until it lifts.
    ///
    /// Off disk only, and silently nothing otherwise. An insert above the reader is paid
    /// for with a correction that can land no finer than a paragraph boundary, and paying
    /// that — plus a request to the site — on *every* jump, for a reader who may well
    /// never look back, is a worse bargain than the wall. A downloaded book pays for a
    /// file read. That is also why this does not go through `loadPrevious`: falling back
    /// to the network is exactly what it must not do.
    ///
    /// Asked of the loaded window rather than of a chapter number: what belongs above the
    /// reader is whatever comes before the first chapter *loaded*, and that is the one
    /// fact here that cannot be stale.
    private func loadStoredPrevious() async {
        guard pendingPrevious == nil, let first = loaded.first else { return }
        let target = first.chapter.index - 1
        guard chapters.indices.contains(target), chapters[target].isDownloaded,
              let text = await storedParagraphs(for: chapters[target]), !text.isEmpty
        else { return }
        pendingPrevious = LoadedChapter(chapter: chapters[target], paragraphs: text)
        showPreviousChapter()
    }

    /// Puts a fetched previous chapter above the reader, once nothing is touching the
    /// screen.
    ///
    /// The insert moves everything the reader is looking at down by a whole chapter, and
    /// a correction used to be what put it back. That correction was a `scrollTo`, and a
    /// `scrollTo` cannot hold against a pan that is still running: the scroll view
    /// recomputes its offset from where the finger started, so the correction survives a
    /// single frame and is then undone — with the arrival gate already closed behind it,
    /// so nothing re-aims. The reader is left at the *opening of the previous chapter*,
    /// and, since a drag pinned to the top keeps reporting upward movement, the next
    /// cooldown fetches the chapter before that one. That is the report this exists for:
    /// an upward drag after a chapter jump walking backwards through the book.
    ///
    /// So the fetch happens the moment the reader shows they are heading up — that part
    /// costs a request and is worth starting early — and only the visible half waits,
    /// for the finger to lift. The insert itself is exact now: the renderer moves the
    /// content and the scroll offset together, so nothing has to be corrected
    /// afterwards. What a running gesture would still undo is the *offset* — a pan and
    /// a deceleration both carry an absolute destination computed before the insert —
    /// which is why this waits for the reader's gesture to finish playing out rather
    /// than for a quiet screen.
    func showPreviousChapter() {
        guard !isTouching, let pending = pendingPrevious else { return }
        // The world can have moved on while the fetch waited — a jump empties `loaded`,
        // and a chapter fetched for a place the reader has left belongs nowhere.
        guard let first = loaded.first, first.chapter.index == pending.chapter.index + 1
        else {
            pendingPrevious = nil
            return
        }
        pendingPrevious = nil
        loaded.insert(pending, at: 0)
        probe("insertAbove idx=\(pending.chapter.index) rows=\(pending.paragraphs.count)")
    }

    /// Whether the reader's own gesture is still playing out — a finger on the glass, or
    /// the coast after it lifts.
    ///
    /// The one thing a content insert has to wait for. Both a pan and a deceleration
    /// carry an absolute destination that was computed before the insert, so a scroll
    /// offset moved under either of them is moved straight back.
    func touch(down: Bool) {
        guard isTouching != down else { return }
        isTouching = down
        if !down { showPreviousChapter() }
    }

    private func append(_ chapter: Chapter) async {
        let mine = generation
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let text = try await paragraphs(for: chapter)
            // The world can move across the fetch's own suspension: a catalog jump
            // replaces `loaded`, and a chapter fetched for the old window belongs
            // nowhere. Valid only while it still extends the frontier it was asked
            // for — or while the window is the empty one this load was sent to fill,
            // which is what the generation check tells apart from a window some later
            // jump emptied.
            guard mine == generation,
                  loaded.isEmpty || loaded.last?.chapter.index == chapter.index - 1
            else { return }
            loaded.append(LoadedChapter(chapter: chapter, paragraphs: text))
            probe("append idx=\(chapter.index) rows=\(text.count)")
            startReadingAhead()
        } catch {
            guard mine == generation else { return }
            // A challenge or a sign-in gate has to reach the shell so the sheet can
            // be presented; everything else stays inline so the user keeps their
            // scroll position.
            if WebFetcher.needsTheUser(error) {
                env.report(error)
            }
            self.error = error.localizedDescription
        }
    }

    /// Local text wins: a downloaded chapter must be readable with no network at
    /// all, which is the entire point of downloading it.
    ///
    /// Then whatever reading online left behind. That is a weaker claim than a
    /// download — `ChapterCache` may have thrown the chapter away to stay under its
    /// ceiling, and it is asked for the chapter rather than told about it — but when
    /// it does have one, scrolling back up a chapter costs a disk read instead of a
    /// trip to the site. Which is also the polite thing: the page has not changed
    /// since the reader passed it two minutes ago.
    private func paragraphs(for chapter: Chapter) async throws -> [String] {
        if chapter.isDownloaded, let stored = await storedParagraphs(for: chapter), !stored.isEmpty {
            return stored
        }
        if let cached = await env.cache.paragraphs(of: book, siteChapterId: chapter.siteChapterId) {
            return cached
        }
        switch readAheadPhase {
        case .fetching(let id) where id == chapter.id:
            // The read-ahead is already asking for exactly this page. Waiting joins
            // that request; fetching here instead would queue a second copy behind it
            // in the fetcher and pay for the page twice — on the slow sites, the
            // difference between a pause at the seam and a page that will not turn.
            await readAheadTask?.value
        case .pacing(let id) where id == chapter.id:
            // Still waiting its polite turn. The reader arriving is what makes the
            // request no longer speculative, and politeness delays are only for
            // speculation — abandon the pause and ask directly.
            readAheadTask?.cancel()
            readAheadPhase = nil
        default:
            break
        }
        if let readAhead, readAhead.chapterId == chapter.id {
            self.readAhead = nil
            return readAhead.paragraphs
        }
        // An article's text arrives with the refresh that found it, so reaching here
        // means there never was any: a feed that published a headline and a link and no
        // body, or one whose markup would not read. Saying so is the honest answer, and
        // it is a different one from the reader having deleted something.
        if book.kind == .feed { throw FeedService.FeedError.emptyArticle }
        guard let rule = env.sites.rule(id: book.siteId) else {
            // An imported book has no site to fall back to. Reaching here means
            // its text is gone from disk — deleted from the storage screen — and
            // re-importing the file is the only way back, so say that instead of
            // reporting a bad URL for a book that never had one.
            if book.isLocal { throw LocalBookError.contentDeleted }
            throw BookService.ServiceError.badURL
        }
        let fetched = try await env.bookService.chapterParagraphs(rule: rule, chapter: chapter)
        env.cache.store(paragraphs: fetched, of: book, siteChapterId: chapter.siteChapterId)
        return fetched
    }

    /// Reads a downloaded chapter off the main actor.
    ///
    /// The read itself is small, but it lands in the middle of the scroll that asked for
    /// it — the reader is at the seam between two chapters when this runs — and a
    /// filesystem hit on the main thread there is a stutter they can see. Only the file
    /// store crosses over, which is a path and a `FileManager`; the database is not
    /// touched, because "is it downloaded" was answered by the row already in hand.
    private func storedParagraphs(for chapter: Chapter) async -> [String]? {
        let files = env.files
        let siteId = book.siteId
        let siteBookId = book.siteBookId
        let siteChapterId = chapter.siteChapterId
        return await Task.detached(priority: .userInitiated) {
            try? files.readParagraphs(
                siteId: siteId, siteBookId: siteBookId, siteChapterId: siteChapterId
            )
        }.value
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
        // The phase is written here and inside the task, never by the task being
        // replaced: a superseded task finds itself cancelled when it wakes and
        // returns without touching anything, so it cannot smear its state over the
        // read-ahead that replaced it.
        readAheadPhase = .pacing(chapterId: next.id)
        readAheadTask = Task { [weak self] in
            guard let self else { return }
            // A chapter already in the cache is read back instead of asked for. Not for
            // the speed — `paragraphs(for:)` would find it there in any case — but
            // because the alternative is a request nobody needs for text this device
            // already has, which is exactly the traffic the pacer exists to avoid.
            if let cached = await self.env.cache.paragraphs(
                of: self.book, siteChapterId: next.siteChapterId
            ) {
                guard !Task.isCancelled else { return }
                self.readAheadPhase = nil
                self.readAhead = (chapterId: next.id, paragraphs: cached)
                return
            }
            await self.env.pacer.pace()
            guard !Task.isCancelled else { return }
            self.readAheadPhase = .fetching(chapterId: next.id)
            guard let paragraphs = try? await self.env.bookService.chapterParagraphs(
                rule: rule, chapter: next
            ) else { return }
            guard !Task.isCancelled else { return }
            self.env.cache.store(
                paragraphs: paragraphs, of: self.book, siteChapterId: next.siteChapterId
            )
            self.readAhead = (chapterId: next.id, paragraphs: paragraphs)
        }
    }

    /// Leaving the reader: stop reading ahead. Continuing to fetch pages for a
    /// screen nobody is looking at is the definition of impolite traffic.
    func stopReading() {
        readAheadTask?.cancel()
        readAheadTask = nil
        readAheadPhase = nil
        persistProgress()
    }

    // MARK: Progress

    /// Records where the scrolling renderer says the reader is.
    ///
    /// The counterpart of `notePage`, and as authoritative. The renderer states a place
    /// off a scroll offset it set itself, against columns it laid out itself, so there
    /// is no viewport to second-guess: the arrival gate, the reflow-deafness window and
    /// the consistency check that used to guard this all existed because a lazy
    /// container reported rows at estimated offsets while it settled, and a single
    /// lying frame could move both the reader and the stored position a chapter.
    ///
    /// The `characterOffset` is real here, unlike in the renderer this replaces. A
    /// laid-out column knows which character the top line of the window starts on, and
    /// that is what makes a mode switch land on the same *line* rather than at the top
    /// of the paragraph the line happens to be in — which, in books whose paragraphs
    /// run taller than a screen, is pages away.
    func notePlace(_ place: ReaderPlace) {
        // Compared before writing because this arrives on scrolled frames, and an
        // `@Observable` write is a notification whether or not the value changed.
        if currentChapterIndex != place.chapterIndex { currentChapterIndex = place.chapterIndex }
        if currentAnchor != place.anchor { currentAnchor = place.anchor }
        if reportedFraction != place.fraction { reportedFraction = place.fraction }
        persistProgress(.reading)
    }

    /// Records the page the paginated reader settled on.
    ///
    /// Separate from `viewportChanged` because a page is authoritative: the renderer
    /// says where it landed, once, with no viewport to second-guess it. This is also
    /// the one path that can record a real `characterOffset` — a page knows which
    /// character it opens on.
    /// - Parameter fraction: the share the page itself displays, taken rather than
    ///   recomputed from the anchor. A page measures to its own *end* — that is what
    ///   makes the last page read 100% — while the anchor names where the page begins.
    ///   Recomputing here would store a number a couple of percent behind the one the
    ///   reader was just looking at, and the shelf would show the difference.
    func notePage(chapterIndex: Int, anchor: TextAnchor, fraction: Double) {
        currentChapterIndex = chapterIndex
        currentAnchor = anchor
        reportedFraction = fraction
        persistProgress(.reading)
    }

    /// Gives back every chapter but the one being read and its two neighbours.
    ///
    /// The scroll gains chapters in both directions and nothing takes them out again:
    /// `jump` empties the array, but a reader who simply keeps scrolling never calls
    /// it, so one session in the reader holds every chapter it crossed. Measured on a
    /// real book that is about seventy kilobytes a chapter — small enough that trimming
    /// as a matter of course would be paying a price for nothing. Under real pressure
    /// giving them back is a good trade and being killed is not.
    ///
    /// Both neighbours are kept because both are wanted: the one ahead is what the
    /// prefetch just paid for, and the one behind is where a reader turning back goes.
    func dropDistantChapters() {
        guard let current = loaded.firstIndex(where: {
            $0.chapter.index == currentChapterIndex
        }) else { return }
        let keep = max(0, current - 1)...min(loaded.count - 1, current + 1)
        guard keep.count < loaded.count else { return }
        loaded = Array(loaded[keep])
        probe("drop keeping=\(keep.count)")
        // Nothing to re-aim: the renderer keeps the reader's own chapter where it is
        // and restacks around it, so shortening the text above them is exact.
    }

    /// Re-aims the scrolling reader at the current position without re-fetching.
    ///
    /// Used when the renderer changes under a chapter that is already in memory: a
    /// chapter read online is held nowhere else, so going through `jump` would spend a
    /// network round trip to show text the app is already holding.
    func retarget() {
        guard currentLoadedChapter != nil else { return }
        scrollTarget = ScrollTarget(chapterIndex: currentChapterIndex, anchor: currentAnchor)
    }

    /// How far through the chapter the reader is, as the renderer on screen measures it.
    ///
    /// Nil only when no chapter is loaded, which is the same moment `currentPosition` has
    /// no chapter to name.
    ///
    /// Both renderers report their own share — a page measures to its end, a scrolled
    /// window to the bottom of the screen — and this prefers what they said. The fallback
    /// measures the anchor, which is the top of the screen and therefore an
    /// under-statement; it is reached only in the moment between a chapter loading and
    /// the first frame being reported.
    var currentFraction: Double? {
        if let reportedFraction { return reportedFraction }
        guard let current = currentLoadedChapter else { return nil }
        return TextAnchor.claimedShare(currentAnchor.fraction(in: current.paragraphs))
    }

    /// Writes the position down, as often as `ProgressWriteRule` allows.
    ///
    /// Every way of *leaving* a position goes through here with `.leaving`: changing
    /// chapter, closing the book, and the app going to the background. That last one is
    /// why reading itself also offers positions: a process suspended in the background
    /// can be killed without ever coming back, and until this existed everything since
    /// the chapter was opened went with it.
    func persistProgress(_ occasion: ProgressWriteRule.Occasion = .leaving) {
        guard !loaded.isEmpty, let position = currentPosition else { return }
        guard writeRule.shouldWrite(position, occasion: occasion) else {
            // Refused means the row already holds this position — a throttled
            // `.reading` write got there first, and those deliberately tell nobody.
            // Leaving still has to publish, or the shelf keeps showing wherever the
            // previous session ended until something unrelated reloads it — which is
            // what "reading during a download loses my progress" turned out to be.
            if occasion == .leaving { env.publishProgress(bookId: book.id) }
            return
        }
        env.recordProgress(
            book: book,
            position: position,
            fraction: currentFraction,
            publish: occasion == .leaving
        )
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
