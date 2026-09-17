import SwiftUI

/// The comic reader: one continuous column of pages, across chapter boundaries.
///
/// `ReaderView`'s counterpart, and deliberately a separate screen rather than a third
/// mode of it. That one is two renderers over a *text* position — a paragraph and a
/// character offset, with bookmarks, highlights, fonts and a share measured over
/// composed characters. None of those exist here, and the ones that do mean something
/// else: a page is a visual block, not a paragraph, and there is nothing finer inside
/// it to name.
///
/// What is shared is the position itself. A comic writes the same three columns a novel
/// does — `lastReadSiteChapterId`, `lastReadParagraph` widened to "which visual block",
/// `lastReadCharacterOffset` held at zero — so the shelf's progress, the reading
/// history and the iCloud merge all work on a comic without a line of new code. See
/// `Book.lastReadSiteChapterId`.
struct ComicReaderView: View {
    let book: Book
    let position: ReadingPosition

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: ComicReaderModel?
    @State private var showControls = false
    @State private var showCatalog = false
    @State private var showSettings = false
    /// Whether the pages are moving on their own right now.
    ///
    /// State for this session rather than a setting, unlike the speed they move at — the
    /// text reader's copy of this says why: a book that reopened already scrolling would
    /// be one that started moving before the reader had looked at it.
    @State private var autoScrolling = false
    /// Nothing in here is a type setting — a comic has no type — but how a book is left
    /// and how its pages are turned are the same acts on every shelf, so they are answered
    /// once, in one place, for all three.
    @State private var settings = ReaderSettings.shared

    private var pageTurn: ReaderSettings.PageTurn {
        settings.resolvedPageTurn(forBook: book.id, kind: book.kind)
    }

    var body: some View {
        ZStack {
            // Black behind everything, including the safe areas. A comic page is a
            // picture with its own paper colour in it, and a strip of the app's own
            // background beside one reads as part of the artwork.
            Color.black.ignoresSafeArea()
            if let model {
                content(model)
            } else {
                ProgressView().tint(.white)
            }
        }
        // What decides the edge swipe rather than what the chevron looks like — the text
        // reader's copy of this line says why. A comic has nothing to give up for it: the
        // pages are scrolled through vertically, so no gesture of this reader's own starts
        // at that edge.
        .navigationBarBackButtonHidden(!settings.swipeToGoBack)
        // Hidden for the same reason the text reader hides them: a bar that comes and
        // goes changes the safe area, and a changed safe area moves the page under the
        // reader while they are looking at it.
        .toolbar(.hidden, for: .navigationBar)
        .edgeSwipeGoesBack(settings.swipeToGoBack)
        .toolbar(.hidden, for: .tabBar)
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
        .overlay(alignment: .top) {
            if showControls, let model {
                ComicTitleCapsule(model: model, fallbackTitle: book.shownName)
            }
        }
        .overlay(alignment: .bottom) {
            if showControls, let model {
                ComicControlBar(
                    model: model,
                    onBack: settings.swipeToGoBack ? nil : { dismiss() },
                    autoScrolling: $autoScrolling,
                    showCatalog: $showCatalog,
                    showSettings: $showSettings
                )
            }
        }
        // Only alongside the controls, and only while the pages are moving: a reader who
        // has put the chrome away is looking at the artwork, and a slider left floating
        // over it would be the one thing on screen that is not the book.
        .overlay(alignment: .bottom) {
            if showControls, autoScrolling {
                ComicScrollBar(settings: settings)
            }
        }
        .animation(.snappy(duration: 0.2), value: showControls)
        .animation(.snappy(duration: 0.2), value: autoScrolling)
        .sheet(isPresented: $showCatalog) { catalogSheet }
        .sheet(isPresented: $showSettings) {
            // The text reader's panel, which reduces itself to the one question a comic
            // answers — see `ReadingOverrideSections`. Half height for that reader's
            // reason: every control in it changes the screen behind it.
            ReaderSettingsSheet(settings: settings, book: book)
                .presentationDetents([.medium])
        }
        .task {
            guard model == nil else { return }
            let created = ComicReaderModel(book: book, env: env)
            model = created
            await created.start(at: position)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.didReceiveMemoryWarningNotification
            )
        ) { _ in
            model?.dropDistantChapters()
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            model?.stopReading()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            model?.persistProgress()
            model?.touch(down: false)
        }
    }

    @ViewBuilder
    private func content(_ model: ComicReaderModel) -> some View {
        ZStack {
            ComicScrollingPages(
                chapters: model.loaded,
                target: model.scrollTarget,
                footer: model.footerState,
                fetcher: env.images,
                autoScroll: autoScrolling ? settings.comicScrollPace : nil,
                onPlaceChange: { model.record($0) },
                onNeedsNext: { Task { await model.loadNext() } },
                onNeedsPrevious: { Task { await model.loadPrevious() } },
                onTouch: { model.touch(down: $0) },
                onTap: { zone in
                    // A tap on the middle band is the controls, in both readers — and so
                    // is a tap anywhere, for a reader who moves by scrolling. The return
                    // value is what says whether the renderer should also turn.
                    guard pageTurn.turnsOnTap, zone != .controls else {
                        showControls.toggle()
                        return false
                    }
                    if showControls { showControls = false }
                    return true
                },
                onTargetReached: { model.clearScrollTarget() },
                onAutoScrollEnded: { autoScrolling = false }
            )
            .ignoresSafeArea()

            if let message = model.error {
                failure(message, model: model)
            }
        }
    }

    /// A failure that needs a decision, floated over the pages.
    ///
    /// Over rather than under, unlike the footer's spinner: this reader hides the
    /// navigation bar, so a failure the reader has to scroll to the bottom to find is a
    /// screen with no way out of it.
    private func failure(_ message: String, model: ComicReaderModel) -> some View {
        VStack(spacing: 14) {
            Text(message).font(.footnote).multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("common.back") { dismiss() }.buttonStyle(.bordered)
                Button("reader.retry") { Task { await model.retry() } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .background(.bar, in: .rect(cornerRadius: 16))
        .padding(.horizontal, 32)
    }

    /// The same order the book's own catalog screen is in — one book, one direction.
    private var catalogChapters: [Chapter] {
        let all = model?.chapters ?? []
        return env.librarySettings.isCatalogDescending(bookId: book.id, kind: book.kind)
            ? Array(all.reversed())
            : all
    }

    private var catalogSheet: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                let lastReadIndex = book.lastReadIndex(in: model?.chapters ?? [])
                List(catalogChapters) { chapter in
                    Button {
                        showCatalog = false
                        Task { await model?.jump(toChapterAt: chapter.index) }
                    } label: {
                        HStack {
                            ChapterRow(chapter: chapter, lastReadIndex: lastReadIndex, kind: book.kind)
                            if chapter.index == model?.currentChapterIndex {
                                Image(systemName: "chevron.right")
                                    .font(.caption).foregroundStyle(.tint)
                            }
                        }
                    }
                    .tint(.primary)
                }
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

/// Which chapter this is, and which page of it.
///
/// Its own view rather than a helper on `ComicReaderView`, and that is load-bearing for
/// the same reason `ReaderTitleCapsule` is: it reads state the scroll rewrites on every
/// frame, and reading that from the reader's own body would re-evaluate the whole
/// screen — the scroll view included — once per frame for as long as the controls are
/// up.
///
/// A page count where the text reader shows a percentage. "12 / 40" is what a comic
/// reader knows about where they are; a share of a chapter measured in points would
/// move under them as images arrive and replace estimates.
private struct ComicTitleCapsule: View {
    let model: ComicReaderModel
    let fallbackTitle: String

    var body: some View {
        HStack(spacing: 10) {
            Text(model.currentLoadedChapter?.chapter.title ?? fallbackTitle)
            if let pages = model.currentLoadedChapter?.imageURLs.count, pages > 0 {
                Text("comic.pageOf \(model.currentPage + 1) \(pages)")
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
        // One element, not two. "第 3 話" and "12 / 40" are one answer to one question —
        // where am I — and reading them as separate stops makes a caller swipe twice to
        // find out something the sighted reader takes in at a glance.
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("comic.chapterTitle")
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// The comic reader's bottom controls.
///
/// Six buttons where the text reader has up to eight. The ones that are missing are
/// missing on purpose: a bookmark is a text anchor, and there is nothing here to read out
/// loud. Zoom, which is what a comic wants in their place, is a pinch and a double tap
/// rather than a button — see `ComicScrollView`. Reading direction is not in this version.
private struct ComicControlBar: View {
    let model: ComicReaderModel
    /// Nil when the edge swipe leaves the book instead — see
    /// `ReaderSettings.swipeToGoBack`, and the text reader's bar, which does the same.
    let onBack: (() -> Void)?
    @Binding var autoScrolling: Bool
    @Binding var showCatalog: Bool
    @Binding var showSettings: Bool

    var body: some View {
        HStack(spacing: 0) {
            if let onBack {
                control("chevron.left", label: "common.back") { onBack() }
                    .accessibilityIdentifier("comic.back")
            }
            control("list.bullet", label: "reader.catalog") { showCatalog = true }
            control("arrow.up.to.line", label: "reader.previousChapter") {
                Task { await model.jump(toChapterAt: model.currentChapterIndex - 1) }
            }
            .disabled(model.currentChapterIndex <= 0)
            control("arrow.down.to.line", label: "reader.nextChapter") {
                Task { await model.jump(toChapterAt: model.currentChapterIndex + 1) }
            }
            .disabled(model.currentChapterIndex >= model.chapters.count - 1)
            .accessibilityIdentifier("comic.nextChapter")
            // The one control here that is a state rather than an action, so it says which
            // one it is in — the text reader's bar carries the same pair of glyphs for the
            // same reason: a play glyph over pages already moving would be a button
            // promising what it has just done.
            control(
                autoScrolling ? "pause.circle" : "play.circle",
                label: autoScrolling ? "reader.autoScroll.stop" : "reader.autoScroll.start"
            ) {
                autoScrolling.toggle()
            }
            .accessibilityIdentifier("comic.autoScroll")
            // A hand rather than the text reader's `textformat.size`: what this opens for a
            // comic is how the pages are turned, and nothing about type.
            control("hand.tap", label: "reader.settings.pageTurn") { showSettings = true }
                .accessibilityIdentifier("comic.settings")
        }
        .padding(.vertical, 10)
        .background(.bar)
        .clipShape(.rect(cornerRadius: 18))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func control(
        _ systemImage: String, label: LocalizedStringKey, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18))
                .frame(maxWidth: .infinity, minHeight: 34)
        }
        .accessibilityLabel(Text(label))
    }
}

/// How fast pages that are moving on their own move.
///
/// The text reader's strip, in the unit a comic is paced by — see `ComicPace`. A strip
/// over the pages rather than a row in the settings sheet, for that one's reason: the only
/// way to tell whether a speed is right is to watch the book go past while you change it,
/// and a speed set over a page that has stopped to show a sheet is set blind.
private struct ComicScrollBar: View {
    @Bindable var settings: ReaderSettings

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "tortoise")
            Slider(value: $settings.comicScrollPace.screensPerMinute, in: ComicPace.range)
                .accessibilityLabel(Text("reader.autoScroll.speed"))
                .accessibilityIdentifier("comic.autoScroll.speed")
            Image(systemName: "hare")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(.bar, in: .capsule)
        .padding(.horizontal, 12)
        // Clear of the control bar's own resting place, so the two never stack on top of
        // each other — the same clearance the text reader's strip keeps.
        .padding(.bottom, 72)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}
