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
    /// Where the paragraphs on screen currently sit. The same frames answer two
    /// questions: which paragraph the window's top edge is in — the reading position —
    /// and where a tap in the page-turn zones should scroll to.
    @State private var visibleParagraphs: [ReaderTapZone.VisibleParagraph] = []
    /// The paragraph the last tapped page turn aimed at, kept only so `ReaderTrace` can
    /// follow it. Temporary — see `ReaderTrace`.
    @State private var tracedTarget: String?
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
        .overlay(alignment: .top) { if showControls, let model { titleCapsule(model) } }
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
            // A question about a passage belongs to the renderer that asked it: the
            // paginated one is about to ask its own, over text it has laid out itself.
            markChoice = nil
            guard mode == .scroll else { return }
            Task { model?.retarget() }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            model?.stopReading()
        }
        // The position has to be on disk before the process can be taken away, and a
        // suspended app is killed without being told. `.inactive` rather than
        // `.background` alone: it is the phase that arrives while the app is still
        // running, and writing a row is cheap enough to do for a pulled-down
        // notification centre that turns out to be nothing.
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            model?.persistProgress()
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
        // The window, measured once, is what turns a tap into a zone and a zone into a
        // page. Read from a container that does not scroll: a coordinate space on the
        // scroll view itself travels with the text, and a tap would report where it
        // landed in the *book* rather than on the screen.
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                let context = TapContext(window: geometry.size, proxy: proxy)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.loaded) { item in
                            chapterRows(item, model: model, context: context)
                        }
                        footer(model)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 80)
                    .contentShape(.rect)
                    // A tap that reached no paragraph — the gaps, the margins, the space
                    // under the last line of a chapter.
                    .onTapGesture(coordinateSpace: .named(Self.tapSpace)) { point in
                        handleTap(at: point, context: context)
                    }
                    .accessibilityIdentifier("reader.text")
                }
                .scrollDismissesKeyboard(.immediately)
                // Temporary, for `ReaderTrace`: simultaneous and consuming nothing, so the
                // scroll and both tap gestures still see every touch they did before.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in ReaderTrace.touch(down: true) }
                        .onEnded { _ in ReaderTrace.touch(down: false) }
                )
                // Where the reading position comes from: the frames say what is on
                // screen, and the top of that is where the reader is. Geometry rather
                // than `onAppear`, because appearing is a fact about which rows the
                // lazy container built, not about what anyone can see.
                .onPreferenceChange(VisibleParagraphsKey.self) { frames in
                    visibleParagraphs = frames
                    guard let span = ReaderTapZone.visibleSpan(
                        of: frames, viewport: geometry.size.height
                    ) else { return }
                    // The model answers with the target while a jump is still in
                    // flight, and the scroll is commanded again. Re-issued per layout
                    // pass, not called once: the lazy stack positions unbuilt rows
                    // from estimates and corrects them as rows build, so a single
                    // `scrollTo` lands and then has the content slide out from under
                    // it.
                    ReaderTrace.frame(
                        topChapter: span.top.chapterIndex,
                        topParagraph: span.top.paragraph,
                        topMinY: span.top.minY,
                        bottomChapter: span.bottom.chapterIndex,
                        bottomParagraph: span.bottom.paragraph,
                        bottomMaxY: span.bottom.maxY,
                        targetMinY: frames.first { $0.id == tracedTarget }?.minY,
                        isLoading: model.isLoading,
                        loaded: model.loadedChapterRange,
                        pendingTarget: model.scrollTarget
                    )
                    if let pending = model.viewportChanged(top: span.top, bottom: span.bottom) {
                        proxy.scrollTo(pending, anchor: .top)
                    }
                }
                .onChange(of: model.scrollTarget) { _, target in
                    guard let target else { return }
                    // No animation: a jump across chapters should land instantly, not
                    // scroll through the text the user skipped. Every posted target is
                    // accompanied by a content change, so the preference fires and the
                    // model keeps re-aiming until the landing is confirmed.
                    proxy.scrollTo(target, anchor: .top)
                }
                // A target posted while this scroll view did not exist — a jump made in
                // paginated mode leaves one behind, and `onChange` only reports changes
                // it was attached to see.
                .onAppear {
                    guard let target = model.scrollTarget else { return }
                    proxy.scrollTo(target, anchor: .top)
                }
                .overlay(alignment: .bottom) { markBar(model) }
                .animation(.snappy(duration: 0.18), value: markChoice)
            }
        }
        .coordinateSpace(.named(Self.tapSpace))
    }

    /// What a tap needs beyond where it landed: how big the window is, and the scroll
    /// view to move. Handed down rather than held in state, because both belong to the
    /// scroll view being drawn right now.
    private struct TapContext {
        let window: CGSize
        let proxy: ScrollViewProxy
    }

    /// The name the tap zones are measured in.
    private static let tapSpace = "reader.window"

    /// Every tap in the scrolling reader ends up here.
    ///
    /// The order is the point. A question waiting on screen is answered first — a tap is
    /// how the reader says no to it, and it must not also turn a page. Then, only for
    /// readers who asked for it, the zones; for everyone else a tap means what it has
    /// always meant here.
    private func handleTap(at point: CGPoint, context: TapContext) {
        if markChoice != nil {
            markChoice = nil
            return
        }
        guard settings.tapToTurnPage else {
            showControls.toggle()
            return
        }
        let zone = ReaderTapZone.zone(at: point, in: context.window)
        guard zone != .controls else {
            showControls.toggle()
            return
        }
        guard let scroll = ReaderTapZone.pageScroll(
            zone, over: visibleParagraphs, viewport: context.window.height
        ) else { return }
        tracedTarget = scroll.id
        ReaderTrace.turn(
            zone: zone == .next ? "next" : "previous",
            targetID: scroll.id,
            anchorY: scroll.anchor.y,
            targetMinY: visibleParagraphs.first { $0.id == scroll.id }?.minY,
            viewport: context.window.height
        )
        // Animated, unlike a jump between chapters: this is the reader moving through
        // text they are reading, and a page that appears without moving gives them
        // nothing to tell it apart from a page that never turned.
        withAnimation(.easeOut(duration: 0.2)) {
            context.proxy.scrollTo(scroll.id, anchor: scroll.anchor)
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

    /// One chapter's rows, emitted as *direct* children of the lazy stack.
    ///
    /// No `VStack` around them, and that is the whole point: a plain stack builds all
    /// of its children the moment the lazy container reaches it, which lays out an
    /// entire chapter in one frame — the hitch at every seam — and fires every
    /// paragraph's `onAppear` at once, which is what used to scatter the recorded
    /// position all over the chapter. Left as siblings, each paragraph is its own lazy
    /// row and is built only when the scroll approaches it.
    @ViewBuilder
    private func chapterRows(
        _ item: ReaderModel.LoadedChapter, model: ReaderModel, context: TapContext
    ) -> some View {
        let highlights = model.highlights(inChapter: item.chapter.siteChapterId)
        let marking = markChoice?.paragraphBeingMarked(inChapter: item.chapter.siteChapterId)
        Text(item.chapter.title)
            .font(.system(size: settings.fontSize + 4, weight: .semibold))
            .padding(.top, 28)
            // What the removed stack's spacing used to add below the title, kept so the
            // seam looks the same as it did.
            .padding(.bottom, 6 + settings.paragraphSpacing)
            .foregroundStyle(settings.theme.foreground)
            .id(item.id)

        ForEach(Array(item.paragraphs.enumerated()), id: \.offset) { offset, paragraph in
            paragraphText(
                paragraph, highlights: highlights, paragraph: offset, isBeingMarked: marking == offset
            )
                .font(settings.font)
                .lineSpacing(settings.lineSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
                // The whole row rather than the glyphs alone, so a press lands on the
                // paragraph the reader aimed at even beside a short last line.
                .contentShape(.rect)
                .foregroundStyle(settings.theme.foreground)
                // The spacing the removed stack used to put between paragraphs. Inside
                // the measured row rather than between rows, so the reported frames
                // tile the column without gaps and the top of the window is always
                // inside *some* paragraph.
                .padding(.bottom, settings.paragraphSpacing)
                // Every paragraph is a scroll destination, which is what makes a
                // stored anchor something the reader can actually land on.
                .id(TextAnchor.paragraphID(chapterId: item.chapter.id, paragraph: offset))
                // The unit this renderer can act on, named so the gesture test can
                // press one — a coordinate inside the column would be a guess about
                // where a paragraph happens to have been laid out.
                .accessibilityIdentifier("reader.paragraph")
                // Always measured, not only for tap-to-turn: the frames are the reading
                // position now, and every reader has one of those.
                .background { paragraphFrame(item, offset) }
                .onTapGesture(coordinateSpace: .named(Self.tapSpace)) { point in
                    tap(
                        paragraph: offset, in: item, highlights: highlights,
                        at: point, context: context
                    )
                }
                // A SwiftUI long press rather than the UIKit recogniser the page
                // needs: there the press has to say *where* it landed, here the
                // paragraph it landed on is the whole answer. It also fails once the
                // finger travels past `maximumDistance`, which is what leaves a press
                // that turns into a scroll a scroll and nothing else.
                .onLongPressGesture(minimumDuration: 0.4) { mark(paragraph: offset, in: item) }
        }
    }

    /// Reports where one paragraph currently sits in the window, for the tap that has to
    /// turn a page. In the window's own coordinate space, so the numbers mean "on screen"
    /// rather than "in the book".
    private func paragraphFrame(_ item: ReaderModel.LoadedChapter, _ offset: Int) -> some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named(Self.tapSpace))
            Color.clear.preference(
                key: VisibleParagraphsKey.self,
                value: [
                    ReaderTapZone.VisibleParagraph(
                        chapterIndex: item.chapter.index,
                        paragraph: offset,
                        id: TextAnchor.paragraphID(chapterId: item.chapter.id, paragraph: offset),
                        minY: frame.minY,
                        maxY: frame.maxY
                    )
                ]
            )
        }
    }

    /// One paragraph, with any highlight over it tinted in.
    ///
    /// The scrolling renderer is left as it was — a plain `Text` per paragraph with the
    /// same modifiers — and only the *string* becomes attributed, and only when a
    /// highlight reaches this paragraph or the reader is being asked about it. Both modes
    /// show highlights and both make them; what differs is how finely they can aim. Here
    /// a mark is a whole paragraph, because nothing in a lazy stack of `Text` knows where
    /// a character sits — see `TextSelection.wholeParagraph(at:in:)`.
    private func paragraphText(
        _ text: String, highlights: [TextHighlight], paragraph: Int, isBeingMarked: Bool
    ) -> Text {
        guard isBeingMarked || !highlights.isEmpty else { return Text(text) }
        let length = (text as NSString).length
        let ranges = highlights.compactMap { $0.range(inParagraph: paragraph, length: length) }
        guard isBeingMarked || !ranges.isEmpty else { return Text(text) }
        var attributed = AttributedString(text)
        // Neutral while the question is open, yellow once the reader answers it: the two
        // colours the page uses, in the same order, so committing a mark looks like the
        // same event in both renderers.
        if isBeingMarked { attributed.backgroundColor = settings.theme.selection }
        for range in ranges {
            guard let bounds = Range(range, in: attributed) else { continue }
            attributed[bounds].backgroundColor = settings.theme.highlight
        }
        return Text(attributed)
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

        /// The paragraph to draw as picked out, when the open question is about marking
        /// one in this chapter.
        func paragraphBeingMarked(inChapter siteChapterId: String) -> Int? {
            guard case .mark(let chapter, let paragraph, _) = self, chapter == siteChapterId else {
                return nil
            }
            return paragraph
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

    /// A tap on a paragraph: offer to remove the mark on it, or do what a tap has always
    /// done here and show the controls.
    ///
    /// A marked paragraph answers the tap that lands on it, the same way a marked passage
    /// answers one on the page: the reader put the mark there, and a mark that ignores
    /// being touched can only be undone from another screen.
    private func tap(
        paragraph: Int,
        in chapter: ReaderModel.LoadedChapter,
        highlights: [TextHighlight],
        at point: CGPoint,
        context: TapContext
    ) {
        // The lift of the finger that started the press arrives here as a tap, so the
        // paragraph being asked about must not dismiss its own question.
        if case .some(.mark(let asked, let askedParagraph, _)) = markChoice,
           asked == chapter.chapter.siteChapterId, askedParagraph == paragraph {
            return
        }
        let length = (chapter.paragraphs[paragraph] as NSString).length
        // The first mark reaching this paragraph, in reading order. Paragraph granularity
        // is all this renderer has: a mark made on a page can cover a single sentence of
        // it, and a tap here cannot tell which sentence was touched.
        //
        // Checked before the zones for the same reason the page checks its own marks
        // first: the reader put the mark there, and a mark that cannot answer a tap can
        // only be undone from another screen.
        if markChoice == nil, let hit = highlights.first(where: {
            $0.range(inParagraph: paragraph, length: length) != nil
        }) {
            markChoice = .remove(hit)
            return
        }
        handleTap(at: point, context: context)
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

    /// The floating counterpart to the control bar: which chapter this is, and how far
    /// through it the reader has got.
    ///
    /// It is an overlay, not the navigation bar it replaces, because a bar that appears
    /// pushes the text down — the thing this whole change is about. Floating over the
    /// page costs the reader a strip of text for as long as the controls are up, and
    /// gives it straight back; the bar cost them the position of every line.
    ///
    /// The share is the one the model would store, so what the reader sees here and what
    /// the shelf says later cannot disagree.
    private func titleCapsule(_ model: ReaderModel) -> some View {
        HStack(spacing: 10) {
            Text(model.currentLoadedChapter?.chapter.title ?? book.shownName)
                .lineLimit(1)
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
                                lastReadIndex: book.lastReadIndex(in: model?.chapters ?? [])
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
    /// The share the renderer on screen last reported: a page's, or a scrolled window's.
    /// Nil only before either has said anything, which is the one moment `currentFraction`
    /// has to fall back to measuring the anchor.
    private var reportedFraction: Double?
    private var writeRule = ProgressWriteRule()
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
        scrollTarget = landing.scrollID(chapterId: chapters[index].id)
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

    func loadNext() async {
        guard !isLoading, let last = loaded.last else { return }
        let nextIndex = last.chapter.index + 1
        guard chapters.indices.contains(nextIndex) else { return }
        await append(chapters[nextIndex])
    }

    /// How many paragraphs of the visible span from the edge of what is loaded counts
    /// as "nearly there". Far enough that the next chapter's text arrives before the
    /// reader reaches the seam, close enough that a reader who stops mid-chapter has
    /// not pulled a chapter they will never look at.
    private static let prefetchLead = 6

    /// Pulls the next chapter in while the reader is still a few paragraphs short of it.
    ///
    /// The marker at the very foot of the text is too late to be smooth: reaching it is
    /// the moment the scroll runs out of content, and the file read and layout pass that
    /// follow happen while the reader is looking at the seam. Asked for a few paragraphs
    /// early, the same work lands before they get there.
    ///
    /// - Parameter index: the chapter the paragraph belongs to. A reader who scrolled
    ///   back up into an earlier one is not near any seam, so nothing is fetched.
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
    /// - Parameter index: the chapter the caller believed was first. Re-checked here
    ///   because these calls queue up — the viewport reports every frame — and a call
    ///   that ran after another one's insert would put a *second* chapter above the
    ///   reader, and a third after that, walking backwards through the book one queued
    ///   task at a time.
    func loadPrevious(before index: Int) async {
        guard !isLoading, let first = loaded.first, first.chapter.index == index else { return }
        let target = index - 1
        guard chapters.indices.contains(target) else { return }
        isLoading = true
        defer { isLoading = false }
        guard let text = try? await paragraphs(for: chapters[target]) else { return }
        loaded.insert(LoadedChapter(chapter: chapters[target], paragraphs: text), at: 0)
        // Inserting above the reader moves everything they are looking at down by a whole
        // chapter, so the view is immediately aimed back at where they were. Their own
        // position is the target, which is also what stops the newly arrived paragraphs
        // from being recorded as progress on their way past.
        retarget()
    }

    /// The reading-order span of what is on screen, for `ReaderTrace`. Temporary.
    var loadedChapterRange: ClosedRange<Int>? {
        guard let first = loaded.first, let last = loaded.last else { return nil }
        return first.chapter.index...last.chapter.index
    }

    private func append(_ chapter: Chapter) async {
        isLoading = true
        error = nil
        ReaderTrace.chapter("append-begin", index: chapter.index)
        defer {
            isLoading = false
            ReaderTrace.chapter("append-end", index: chapter.index)
        }
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
        if chapter.isDownloaded, let stored = await storedParagraphs(for: chapter), !stored.isEmpty {
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

    /// The scrolling reader's position, taken from what is actually on screen.
    ///
    /// The top of the visible span is where the text on screen begins — the same claim
    /// `TextAnchor.fraction(in:)` turns into a share. Geometry rather than `onAppear`,
    /// because appearing is a fact about which rows the lazy container built, not about
    /// what the reader can see, and the two disagree exactly when it matters: during
    /// fast scrolls, and in the flood of rows a landing jump instantiates.
    ///
    /// While a jump is still in flight nothing is recorded — the frames describe where
    /// the scroll *used* to be, and the transient "top of the chapter" frames of a
    /// landing are exactly what once made edge-prefetch walk the book backwards one
    /// inserted chapter at a time. The caller gets the still-pending target back and
    /// keeps re-aiming the scroll at it.
    ///
    /// Edge-prefetch is decided here too — "the reader is near a seam" is a fact about
    /// the visible span, and deciding it anywhere else would need a second definition
    /// of visible.
    ///
    /// - Returns: the target a pending jump still has to reach, or nil once the
    ///   viewport is the reader's own again.
    func viewportChanged(
        top: ReaderTapZone.VisibleParagraph, bottom: ReaderTapZone.VisibleParagraph
    ) -> String? {
        if let target = scrollTarget {
            guard hasArrived(top: top, bottom: bottom) else { return target }
            scrollTarget = nil
        }
        // Compared before writing because this fires on every scrolled frame, and an
        // `@Observable` write is a notification whether or not the value changed.
        if currentChapterIndex != top.chapterIndex { currentChapterIndex = top.chapterIndex }
        // A row boundary is the finest place the scroll can name, so the offset within
        // the paragraph is honestly zero rather than guessed at. See `TextAnchor`.
        let anchor = TextAnchor(paragraph: top.paragraph, characterOffset: 0)
        if currentAnchor != anchor { currentAnchor = anchor }
        reportedFraction = readShare(through: bottom)
        persistProgress(.reading)
        if !isLoading {
            if let last = loaded.last, bottom.chapterIndex == last.chapter.index,
               bottom.paragraph + Self.prefetchLead >= last.paragraphs.count {
                Task { await loadNextIfLast(after: last.chapter.index) }
            }
            if let first = loaded.first, top.chapterIndex == first.chapter.index,
               top.paragraph < Self.prefetchLead {
                Task { await loadPrevious(before: first.chapter.index) }
            }
        }
        return nil
    }

    /// How far through the chapter the scrolling reader has read, measured to the bottom
    /// of the window.
    ///
    /// The anchor and the share answer different questions about the same screen: the
    /// anchor is where to come back to, so it is the top; the share is what has been
    /// read, so it runs to the end of the last paragraph the reader can see. Deriving it
    /// from the anchor instead — which is what this used to do, by leaving
    /// `reportedFraction` nil — measured to where the screen *begins*, so the final
    /// screen of a chapter reported a screenful short of its end and no scrolled chapter
    /// could ever reach 100%. That is a couple of percent on the shelf, and it is the
    /// whole difference between a finished book and an almost-finished one to the
    /// reading history, which reads a full 100% as "there is nothing left of this".
    ///
    /// This is the same claim `PaginatedChapterView.fraction(atPage:)` makes for a page,
    /// stated through the same rounding, so a chapter finished in one renderer is
    /// finished in the other.
    ///
    /// A bottom in a later chapter means the whole of this one is behind the reader.
    /// It can never be in an earlier one: `ReaderTapZone.visibleSpan` takes the two ends
    /// of one window in reading order.
    private func readShare(through bottom: ReaderTapZone.VisibleParagraph) -> Double? {
        guard let current = currentLoadedChapter else { return nil }
        guard bottom.chapterIndex == current.chapter.index else { return 1 }
        return TextAnchor.claimedShare(
            TextAnchor.endOfParagraph(bottom.paragraph, in: current.paragraphs)
                .fraction(in: current.paragraphs)
        )
    }

    /// Whether a jump's scroll has reached what it aimed at.
    ///
    /// "At or past the aimed row", in reading order — not "the aimed row is on screen
    /// somewhere". A chapter's opening screen can show its first fifteen paragraphs,
    /// so a mid-chapter target is often *visible* from the top of the chapter while
    /// the scroll has not moved at all; declaring arrival there once opened the gate
    /// onto the head-of-chapter frames and let edge-prefetch insert the previous
    /// chapter under a reader who never asked for it.
    ///
    /// The aim is `currentChapterIndex`/`currentAnchor`, which `jump` set and nothing
    /// else touches while the gate is closed.
    ///
    /// The second clause is the end of the book's tail: a target too close to the end
    /// of what is loaded can never be scrolled to the top of the window, so "the
    /// content is pinned against its own end and the aimed row is on screen" has to
    /// count as having arrived, or the gate would never open.
    private func hasArrived(
        top: ReaderTapZone.VisibleParagraph, bottom: ReaderTapZone.VisibleParagraph
    ) -> Bool {
        if top.chapterIndex > currentChapterIndex { return true }
        if top.chapterIndex == currentChapterIndex, top.paragraph >= currentAnchor.paragraph {
            return true
        }
        guard let last = loaded.last else { return false }
        let pinned = bottom.chapterIndex == last.chapter.index
            && bottom.paragraph >= last.paragraphs.count - 1
        let aimOnScreen = bottom.chapterIndex > currentChapterIndex
            || (bottom.chapterIndex == currentChapterIndex
                && bottom.paragraph >= currentAnchor.paragraph)
        return pinned && aimOnScreen
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

    /// Re-aims the scrolling reader at the current position without re-fetching.
    ///
    /// Used when the renderer changes under a chapter that is already in memory: a
    /// chapter read online is held nowhere else, so going through `jump` would spend a
    /// network round trip to show text the app is already holding.
    func retarget() {
        guard let current = currentLoadedChapter else { return }
        scrollTarget = currentAnchor.scrollID(chapterId: current.chapter.id)
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
        guard writeRule.shouldWrite(position, occasion: occasion) else { return }
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
