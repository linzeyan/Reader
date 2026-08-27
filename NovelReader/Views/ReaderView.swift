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
    /// Where the finger last touched, in the window's space. A plain box rather than
    /// view state: it moves with every touch event and nothing on screen is drawn from
    /// it — the long press reads it once, at the moment it fires. It exists because
    /// `onLongPressGesture` cannot say where it landed, and the drag recogniser that
    /// already watches every touch can.
    private final class TouchLocation {
        var point = CGPoint.zero
    }
    @State private var lastTouch = TouchLocation()
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
        // at the top of whatever is loaded. Re-aiming it happens on the next runloop
        // turn, once that scroll view exists to receive the target.
        .onChange(of: settings.mode) { _, mode in
            // A question about a passage belongs to the renderer that asked it: the
            // paginated one is about to ask its own, over text it has laid out itself.
            markChoice = nil
            guard mode == .scroll else { return }
            Task { model?.retarget() }
        }
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
                            chapterRows(item, model: model)
                        }
                        footer(model)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 80)
                    .contentShape(.rect)
                    // Every tap in the column, resolved to a paragraph — or not — by
                    // the measured frames. One recogniser here instead of one per lazy
                    // row: the per-row pair was a fifth of the layout burst every
                    // chapter seam pays when its rows are first realized.
                    .onTapGesture(coordinateSpace: .named(Self.tapSpace)) { point in
                        handleTap(at: point, context: context)
                    }
                    // The long press moved up from the rows with the tap. It cannot
                    // say where it landed, so it reads the point the touch recogniser
                    // below keeps fresh — that drag begins on touch-down, before any
                    // press can complete. It still fails once the finger travels, which
                    // is what leaves a press that turns into a scroll a scroll.
                    .onLongPressGesture(minimumDuration: 0.4) {
                        guard let hit = hitParagraph(at: lastTouch.point) else { return }
                        mark(paragraph: hit.paragraph, in: hit.chapter)
                    }
                    .accessibilityIdentifier("reader.text")
                }
                .scrollDismissesKeyboard(.immediately)
                // Whether a finger is on the glass, which decides when a chapter may be
                // put in above the reader — see `ReaderModel.showPreviousChapter` — and
                // where that finger is, for the long press above. Simultaneous and
                // consuming nothing, so the scroll, the tap and the long press still
                // see every touch they did before.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.tapSpace))
                        .onChanged { value in
                            lastTouch.point = value.location
                            model.touch(down: true)
                        }
                        .onEnded { _ in model.touch(down: false) }
                )
                // Where the reading position comes from: the frames say what is on
                // screen, and the top of that is where the reader is. Geometry rather
                // than `onAppear`, because appearing is a fact about which rows the
                // lazy container built, not about what anyone can see.
                .onPreferenceChange(VisibleParagraphsKey.self) { frames in
                    visibleParagraphs = frames
                    // The same frames, for the model's chapter-height record —
                    // observation-ignored storage, so this per-frame call re-runs
                    // nothing.
                    model.noteFrames(frames)
                    guard let span = ReaderTapZone.visibleSpan(
                        of: frames, viewport: geometry.size.height
                    ) else {
                        return
                    }
                    // The model answers with the target while a jump is still in
                    // flight, and the scroll is commanded again. Re-issued per layout
                    // pass, not called once: the lazy stack positions unbuilt rows
                    // from estimates and corrects them as rows build, so a single
                    // `scrollTo` lands and then has the content slide out from under
                    // it.
                    if let pending = model.viewportChanged(top: span.top, bottom: span.bottom) {
                        proxy.scrollTo(pending, anchor: .top)
                    }
                }
                // A collapse or a re-inflation has changed the length of the text above
                // the reader, and states where they must stay. Aimed at a point inside
                // a row rather than at the row's top: `scrollTo` lines the anchor point
                // of the target up with the same point of the window, so for a row of
                // height `h` in a window of height `v`, an anchor of `a` puts the row's
                // top at `a * (v - h)` — the same arithmetic the tap zones use to move
                // inside an over-tall paragraph. One shot, no arrival gate: the content
                // it corrects for changed in the same transaction, so there is nothing
                // to keep chasing.
                .onChange(of: model.scrollCorrection) { _, correction in
                    guard let correction else { return }
                    let span = geometry.size.height - correction.height
                    if span > 0 {
                        let anchor = min(max(correction.minY / span, 0), 1)
                        proxy.scrollTo(correction.id, anchor: UnitPoint(x: 0, y: anchor))
                    }
                    model.clearScrollCorrection()
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
    /// The order is the point. The paragraph under the finger speaks first: a marked
    /// paragraph answers the tap that lands on it, the same way a marked passage answers
    /// one on the page — the reader put the mark there, and a mark that ignores being
    /// touched can only be undone from another screen. Then any question waiting on
    /// screen — a tap is how the reader says no to it, and it must not also turn a page.
    /// Then, only for readers who asked for it, the zones; for everyone else a tap means
    /// what it has always meant here.
    private func handleTap(at point: CGPoint, context: TapContext) {
        if let hit = hitParagraph(at: point) {
            // The lift of the finger that started the press arrives here as a tap, so
            // the paragraph being asked about must not dismiss its own question.
            if case .some(.mark(let asked, let askedParagraph, _)) = markChoice,
               asked == hit.chapter.chapter.siteChapterId,
               askedParagraph == hit.paragraph {
                return
            }
            // The first mark reaching this paragraph, in reading order. Paragraph
            // granularity is all this renderer has: a mark made on a page can cover a
            // single sentence of it, and a tap here cannot tell which sentence was
            // touched.
            if markChoice == nil, let model {
                let length = (hit.chapter.paragraphs[hit.paragraph] as NSString).length
                let highlights = model.highlights(
                    inChapter: hit.chapter.chapter.siteChapterId
                )
                if let mark = highlights.first(where: {
                    $0.range(inParagraph: hit.paragraph, length: length) != nil
                }) {
                    markChoice = .remove(mark)
                    return
                }
            }
        }
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
        // A previous-page tap at the very head of what is loaded has nothing above to
        // scroll into, and with the previous chapter now arriving only on upward
        // movement, no movement would ever happen: the tap would be a wall. The tap is
        // itself the intent the movement gate waits for, so it asks for the chapter
        // directly; the next tap has somewhere to go.
        if zone == .previous, let model,
           let span = ReaderTapZone.visibleSpan(
               of: visibleParagraphs, viewport: context.window.height
           ),
           span.top.paragraph == 0, span.top.minY >= 0 {
            Task { await model.loadPrevious(before: span.top.chapterIndex) }
        }
        let scroll = ReaderTapZone.pageScroll(
            zone, over: visibleParagraphs, viewport: context.window.height
        )
        guard let scroll else { return }
        // Animated, unlike a jump between chapters: this is the reader moving through
        // text they are reading, and a page that appears without moving gives them
        // nothing to tell it apart from a page that never turned.
        withAnimation(.easeOut(duration: 0.2)) {
            context.proxy.scrollTo(scroll.id, anchor: scroll.anchor)
        }
    }

    /// The paragraph under a point, from the measured frames — the same frames the
    /// page-turn zones scroll by. A tap is necessarily on screen, so its row is
    /// realized and reporting.
    private func hitParagraph(
        at point: CGPoint
    ) -> (chapter: ReaderModel.LoadedChapter, paragraph: Int)? {
        guard let model,
              let visible = visibleParagraphs.first(where: {
                  $0.minY <= point.y && point.y < $0.maxY
              }),
              let chapter = model.loaded.first(where: {
                  $0.chapter.index == visible.chapterIndex
              })
        else { return nil }
        return (chapter, visible.paragraph)
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
        _ item: ReaderModel.LoadedChapter, model: ReaderModel
    ) -> some View {
        if let height = item.collapsedHeight {
            // A chapter the reader is well past, kept as pure length: the same space
            // its rows occupied, in the same place, so the scroll offset still means
            // the same sentence — and none of those rows alive in the container. It
            // keeps the chapter's own id, so a jump to this chapter still has
            // somewhere to land.
            Color.clear.frame(height: height).id(item.id)
        } else {
            fullChapterRows(item, model: model)
        }
    }

    @ViewBuilder
    private func fullChapterRows(
        _ item: ReaderModel.LoadedChapter, model: ReaderModel
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

        // Over the indices rather than `Array(paragraphs.enumerated())`: the latter
        // materialises a fresh array of pairs, and every retained string in it, each
        // time this chapter's rows are evaluated.
        ForEach(item.paragraphs.indices, id: \.self) { offset in
            fullRow(item, offset: offset, highlights: highlights, marking: marking)
        }
    }

    /// One paragraph row. No gestures here, deliberately: the tap and the long press
    /// live on the column and resolve their paragraph through the measured frames,
    /// because two recognisers on every lazy row were paid again at each chapter seam,
    /// in the same frame as the rows' own layout.
    @ViewBuilder
    private func fullRow(
        _ item: ReaderModel.LoadedChapter, offset: Int,
        highlights: [TextHighlight], marking: Int?
    ) -> some View {
        paragraphText(
            item.paragraphs[offset], highlights: highlights, paragraph: offset,
            isBeingMarked: marking == offset
        )
            .font(settings.font)
            .lineSpacing(settings.lineSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                Button("reader.retry") { Task { await model.retry() } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("reader.retry")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private func footer(_ model: ReaderModel) -> some View {
        Group {
            if model.isLoading {
                ProgressView().padding(.vertical, 28)
            } else if let error = model.error {
                failure(error, model: model).padding(.vertical, 28)
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
                                lastReadIndex: lastReadIndex
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
        /// Set once the reader is well past this chapter: the height its block was
        /// measured at, drawn as one clear spacer *in the chapter's own place* while
        /// its rows are given back to the container.
        ///
        /// In place, rather than removed and added to a single spacer at the head of
        /// the column, because a chapter whose rows were never all measured cannot be
        /// priced — and in the head-spacer arrangement that one chapter dammed every
        /// chapter behind it: nothing could leave the window without changing the
        /// length of what sat above the reader. A chapter arriving by `loadPrevious`
        /// at a landing is exactly such a chapter, so on a device trace of an ordinary
        /// session the collapse never fired once and the window grew all evening.
        var collapsedHeight: CGFloat?
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

    /// Where the reader was, to the point, at the moment the text above them changed
    /// length — and therefore where the scroll has to be put back to.
    ///
    /// This exists because the collapse cannot be made height-neutral. A spacer stands
    /// in for a chapter at the height its rows measured, but the container does not
    /// hold a released chapter at that height: measured against a sweep of spacer
    /// heights on a 203-paragraph chapter, it had been giving it about four fifths of
    /// the sum of its own rows — so the "exact" spacer pushed the reader back about a
    /// page and a half, every time. That number is the container's, not ours, and
    /// nothing in the app can read it.
    ///
    /// So the height is left as the honest estimate it is, and the position is stated
    /// outright: a row currently on screen, and the exact offset it must sit at. Unlike
    /// `scrollTarget` this is a single shot with no arrival gate — it is a correction,
    /// not a journey — and unlike `retarget` it can name a point inside a paragraph
    /// rather than snapping to the paragraph's top, which is the flinch that made the
    /// first trim attempt worse than the problem.
    struct ScrollCorrection: Equatable {
        let id: String
        /// Where the row's top must end up, measured from the top of the window.
        let minY: CGFloat
        /// The row's own height, which the anchor arithmetic needs.
        let height: CGFloat
        /// Distinguishes two corrections that ask for the same place, so the view
        /// applies both rather than seeing no change.
        let serial: Int
    }
    private(set) var scrollCorrection: ScrollCorrection?

    /// Consumed by the view once the scroll has been put back.
    func clearScrollCorrection() { scrollCorrection = nil }

    /// The row a correction should be stated in terms of: the first one whose top is
    /// inside the window, so the anchor arithmetic stays within the scroll view's own
    /// range. Kept fresh by `noteFrames`, which sees every reported row.
    @ObservationIgnored private var correctionAnchor: (id: String, minY: CGFloat, height: CGFloat)?
    @ObservationIgnored private var correctionSerial = 0

    /// A correction that has been posted, with the place it was meant to reach: the
    /// anchor arithmetic is the scroll view's and not ours, and on a device it lands a
    /// few tens of points out. The frames that follow say by how much, and the
    /// correction is re-stated against its own miss.
    @ObservationIgnored private var heldPosition: (
        id: String, target: CGFloat, height: CGFloat, request: CGFloat, tries: Int, skip: Int
    )?

    /// Reports to ignore after a correction is posted. The first frames to arrive are
    /// the mutation's own reflow — rows at estimated offsets, a whole chapter out —
    /// and reading a miss off one of those turns a settling nudge into a shove.
    private static let holdSettleFrames = 3

    /// How far out a correction may land before it is worth re-stating. Under a couple
    /// of points is beneath noticing and not worth another transaction.
    private static let holdTolerance: CGFloat = 3

    /// Beyond this a miss is somebody else's movement, not the correction's own.
    private static let holdAbandon: CGFloat = 300

    /// States where the reader must stay, for a mutation about to change the length of
    /// the text above them.
    private func holdPosition() {
        guard let anchor = correctionAnchor else { return }
        heldPosition = (
            id: anchor.id, target: anchor.minY, height: anchor.height,
            request: anchor.minY, tries: 0, skip: Self.holdSettleFrames
        )
        postHeldPosition()
    }

    private func postHeldPosition() {
        guard let held = heldPosition else { return }
        correctionSerial += 1
        scrollCorrection = ScrollCorrection(
            id: held.id, minY: held.request, height: held.height, serial: correctionSerial
        )
    }

    /// Checks where the last correction actually put the reader, and asks again if it
    /// missed. Twice at most: this is a settling nudge of a few points, not a loop the
    /// screen should be allowed to argue with.
    private func checkHeldPosition(_ frames: [ReaderTapZone.VisibleParagraph]) {
        guard let held = heldPosition, scrollCorrection == nil else { return }
        guard held.skip == 0 else {
            heldPosition = (
                id: held.id, target: held.target, height: held.height,
                request: held.request, tries: held.tries, skip: held.skip - 1
            )
            return
        }
        guard let landed = frames.first(where: { $0.id == held.id }) else {
            // The row the correction was stated in terms of has left the screen —
            // whatever happened, this correction can no longer be checked against it.
            heldPosition = nil
            return
        }
        let error = held.target - landed.minY
        // A miss of half a screen or more is not the scroll view's arithmetic being
        // out — it is somebody else moving the text, and the last thing a correction
        // may do is argue with the reader.
        guard abs(error) < Self.holdAbandon else {
            heldPosition = nil
            return
        }
        guard abs(error) > Self.holdTolerance, held.tries < 2 else {
            heldPosition = nil
            return
        }
        heldPosition = (
            id: held.id, target: held.target, height: held.height,
            request: held.request + error, tries: held.tries + 1,
            skip: Self.holdSettleFrames
        )
        postHeldPosition()
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

    /// Where the top of the window was last report, for telling which way the reader
    /// is moving. Nothing more is derived from it — position comes from the report
    /// itself, this is only yesterday's copy to compare against.
    private var lastTop: ReaderTapZone.VisibleParagraph?
    /// The place the read share was last computed for, so the per-frame report only
    /// pays for it when the bottom of the window actually crosses a paragraph.
    private var lastShareBottom: (chapter: Int, paragraph: Int)?
    /// When the viewport last reported at all — the reader's "the screen is moving"
    /// signal. Frames arrive continuously through a turn's animation and its
    /// deceleration, and stop when the text is still; quiet is what the deferred
    /// append waits for.
    private var lastViewportReportAt: ContinuousClock.Instant = .now
    /// When the text above the reader last changed — a chapter inserted, or chapters
    /// dropped under memory pressure. For the next few frames the lazy stack corrects
    /// the estimated heights of the rows it gained or lost, and the corrections report
    /// transient tops a whole chapter away from where the reader is. To the direction
    /// test that is a reader flying toward the front of the book, and acting on it is
    /// how one polite insert cascades chapter by chapter to the cover. Until the reflow
    /// has had a moment to settle, upward movement is not the reader's.
    private var contentAboveChangedAt: ContinuousClock.Instant?
    /// Row heights recorded as rows pass through the measured frames, keyed
    /// chapter → paragraph. Heights, never positions: the two chapter heads a block
    /// height could be read from directly are never on screen in the same frame — a
    /// chapter is taller than the window — so the collapse sums what the frames said
    /// row by row, while the reader was actually reading them. Observation-ignored:
    /// written every scrolled frame, drawn from never.
    ///
    /// Kept across a collapse rather than discarded with the rows, so a chapter that
    /// is put back for a glance upward can collapse again the moment the reader turns
    /// round — without being read from end to end a second time.
    @ObservationIgnored private var recordedRowHeights: [Int: [Int: CGFloat]] = [:]
    /// One title block's height, recorded at the first chapter seam that shows the
    /// gap between two measured rows. Every title is styled identically, so one
    /// number serves every chapter.
    @ObservationIgnored private var recordedTitleHeight: CGFloat?
    /// The chapter before the first one loaded, fetched and waiting for a moment when
    /// putting it on screen will not fight the reader's finger — see `showPreviousChapter`.
    private var pendingPrevious: LoadedChapter?
    /// Set by `jump`, spent when that jump's landing settles: see `loadStoredPrevious`.
    /// A flag rather than a call at the end of `jump`, because the moment worth acting on
    /// is not when the chapter loads, it is when the scroll has stopped moving.
    private var wantsPreviousBehindLanding = false
    /// Whether a finger is on the glass right now. Set by the reader's drag recogniser.
    private var isTouching = false

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
        readAheadPhase = nil
        readAhead = nil
        // Fetched for a place the reader is leaving. Dropped here rather than left for
        // `showPreviousChapter` to reject, so a jump can never be followed by a chapter
        // arriving above the one it landed in.
        pendingPrevious = nil
        lastTop = nil
        lastShareBottom = nil
        loaded = []
        // The heights described a window that is being replaced. The title height
        // alone survives, because titles are styled the same everywhere in the book.
        recordedRowHeights = [:]
        await append(chapters[index])
        // Both halves of the aim written together, after the load. Set before it, the
        // index is overwritten in the meantime: the fetch suspends, the frames of the
        // *old* content keep arriving, and `viewportChanged` records where they say the
        // reader is — so the gate that decides this landing has arrived would be holding
        // the chapter the reader just left.
        currentChapterIndex = index
        let landing = landingAnchor(for: anchor)
        currentAnchor = landing
        scrollTarget = landing.scrollID(chapterId: chapters[index].id)
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

    func loadNext() async {
        guard !isLoading, let last = loaded.last else { return }
        let nextIndex = last.chapter.index + 1
        guard chapters.indices.contains(nextIndex) else { return }
        // Settling, unlike every other append: this is the one that fires while a
        // page turn's animation is in flight, because the prefetch lead is measured
        // off the frames that animation delivers. Device watchdog traces put the
        // append's own cost — one SwiftUI transaction growing the lazy stack by a
        // whole chapter — at 300–800ms of main-thread graph work, which landed
        // squarely on the turn the reader had just made, froze it mid-flight, and
        // was the reported "tap stalls for seconds, periodically": once per
        // chapter, at reading pace. Landed on a still screen instead, the same
        // work is invisible.
        await append(chapters[nextIndex], settling: true)
    }

    /// The least a chapter may be asked for ahead of the seam, in paragraphs.
    ///
    /// The lead that actually governs is two pages, measured off the screen — see
    /// `viewportChanged`. This is the floor for what measuring cannot describe: a
    /// paragraph long enough that one of them is the entire page.
    private static let minimumPrefetchLead = 6

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
    /// the `retarget` that follows is what puts it back. That correction is a `scrollTo`,
    /// and a `scrollTo` cannot hold against a pan that is still running: the scroll view
    /// recomputes its offset from where the finger started, so the correction survives a
    /// single frame and is then undone — with the arrival gate already closed behind it,
    /// so nothing re-aims. The reader is left at the *opening of the previous chapter*,
    /// and, since a drag pinned to the top keeps reporting upward movement, the next
    /// cooldown fetches the chapter before that one. That is the report this exists for:
    /// an upward drag after a chapter jump walking backwards through the book.
    ///
    /// So the fetch happens the moment the reader shows they are heading up — that part
    /// costs a request and is worth starting early — and only the visible half waits.
    /// It waits twice, for two different things: for the finger to lift, because the
    /// correction cannot hold against a running pan; and then for the viewport to go
    /// still, because the insert re-registers a chapter's worth of rows in one frame and
    /// that frame should not be one the reader is watching coast. The settle can time
    /// out with a finger back on the glass, so everything is re-checked after it — a
    /// deferred insert that has become wrong is dropped or retried at the next lift,
    /// never forced.
    func showPreviousChapter() {
        guard !isTouching, pendingPrevious != nil else { return }
        Task {
            await settleBeforeGrowingContent()
            guard !isTouching, let pending = pendingPrevious else {
                return
            }
            // The world can have moved on while the fetch or the settle waited — a jump
            // empties `loaded`, and a chapter fetched for a place the reader has left
            // belongs nowhere.
            guard let first = loaded.first, first.chapter.index == pending.chapter.index + 1
            else {
                pendingPrevious = nil
                return
            }
            pendingPrevious = nil
            loaded.insert(pending, at: 0)
            contentAboveChangedAt = .now
            // Aimed back at where the reader was, which is also what stops the newly
            // arrived paragraphs from being recorded as progress on their way past.
            retarget()
        }
    }

    /// Gives back the rows of every chapter the reader has scrolled well past, each
    /// replaced by a spacer of the height it was measured at. Returns whether any did.
    ///
    /// `loaded` used to only grow, and a lazy stack never releases a row it has built —
    /// so every read chapter stayed in the container as live nodes. A device trace
    /// showed what that costs: *every* transaction — the settled append and each page
    /// turn's realization alike — stalled ~25ms longer per accumulated chapter,
    /// reaching a third of a second by the fourteenth. That is both "the stalls grow
    /// the longer I read" and "the app slows down over a session"; the cap here is
    /// what those curves scale against.
    ///
    /// Each chapter is judged on its own, and left where it is. The first version
    /// removed collapsed chapters and pooled their heights into one spacer at the head
    /// of the column, which made the window a queue: a chapter that could not be priced
    /// stood at the front and dammed every chapter behind it, none of which could leave
    /// without changing the length of the text above the reader. That is not a corner
    /// case — a landing pulls the chapter before it in through `loadStoredPrevious`, the
    /// reader never scrolls back through it, and so its rows are never all measured. A
    /// device trace of an ordinary evening showed the consequence: not one collapse in
    /// twenty minutes, `loaded` at five chapters and climbing, every touch costing more
    /// than the last, until the unpriceable chapter fell far enough behind to be evicted
    /// outright — and that eviction's correction is the page that visibly slid backwards.
    /// Collapsed in place, the same chapter is simply skipped: it keeps its rows, which
    /// cost only what the few realized ones cost, and everything behind it collapses.
    ///
    /// One chapter is kept whole above the current one, so a flick back stays free.
    ///
    /// The height is the sum of row heights recorded while the reader read the
    /// chapter (`noteFrames`), plus the one title height priced at a seam — never a
    /// difference of positions: two chapter heads are taller than a screen apart, so
    /// they are never reported in the same frame.
    private func collapseReadChapters() -> Bool {
        var collapsed = false
        // Stated before the mutation, from frames that still describe the screen the
        // reader is looking at.
        let held = correctionAnchor
        for index in loaded.indices
        where loaded[index].collapsedHeight == nil
            && loaded[index].chapter.index < currentChapterIndex - 1 {
            guard let height = measuredBlockHeight(of: loaded[index]) else {
                continue
            }
            loaded[index].collapsedHeight = height
            collapsed = true
        }
        if collapsed, held != nil {
            correctionAnchor = held
            holdPosition()
        }
        return collapsed
    }

    /// Puts the rows back into the collapsed chapter directly above the reader.
    ///
    /// The way back, and the counterpart of the collapse: the rows return to a spacer
    /// their own measurements priced, so no text arrives above the reader that was not
    /// already accounted for — unlike `showPreviousChapter`, which brings in a chapter
    /// that was never there. It may run with a finger still on the glass, which is the
    /// point: a reader dragging upward must meet text, not a blank.
    ///
    /// One chapter per call, gated on the same reflow pause as the backtrack fetch, so a
    /// long flick upward re-inflates the book one chapter at a time rather than all of it.
    /// - Returns: whether a chapter was put back.
    private func reinflateChapterAbove(_ chapterIndex: Int) -> Bool {
        guard let position = loaded.firstIndex(where: { $0.chapter.index == chapterIndex }),
              position > 0, loaded[position - 1].collapsedHeight != nil
        else { return false }
        loaded[position - 1].collapsedHeight = nil
        // The same bargain in reverse: the rows coming back do not occupy what the
        // spacer did, so the reader is held where they are rather than left to be
        // moved by the difference.
        holdPosition()
        // The heights match, but the container still re-registers a chapter's worth of
        // rows, and rounding can wobble a frame. A wobble read as upward movement is
        // the cascade the reflow gate exists for.
        contentAboveChangedAt = .now
        return true
    }

    /// Feeds the frames the view measured this pass into the height record.
    ///
    /// Only heights that are still missing are written, so a settled screen costs a
    /// handful of dictionary probes per frame; the title height stops even looking
    /// once it is known.
    func noteFrames(_ frames: [ReaderTapZone.VisibleParagraph]) {
        for frame in frames
        where recordedRowHeights[frame.chapterIndex]?[frame.paragraph] == nil {
            recordedRowHeights[frame.chapterIndex, default: [:]][frame.paragraph] = frame.height
        }
        checkHeldPosition(frames)
        // The row a correction would be stated in terms of — the first whose top is on
        // screen. Only while nothing is already being corrected or aimed: those are
        // the frames that lie, and a correction taken from one would hold the reader
        // to a place they were never at.
        if scrollTarget == nil, scrollCorrection == nil, heldPosition == nil,
           let anchor = frames.filter({ $0.minY >= 0 }).min(by: { $0.minY < $1.minY }) {
            correctionAnchor = (id: anchor.id, minY: anchor.minY, height: anchor.height)
        }
        guard recordedTitleHeight == nil, frames.count > 1,
              // Not while a jump or an insert is still settling: those are the
              // frames that lie, with rows at estimated offsets a chapter away
              // from the truth (see `contentAboveChangedAt`) — and this number,
              // once recorded, prices every collapsed chapter for the session.
              scrollTarget == nil
        else { return }
        let ordered = frames.sorted { $0.minY < $1.minY }
        for (previous, current) in zip(ordered, ordered.dropFirst())
        where current.paragraph == 0 && current.chapterIndex == previous.chapterIndex + 1 {
            // Only a *physically* adjacent pair may price the title: sorted order
            // alone can put the head of a chapter next to some mid-chapter row
            // whose realized neighbours are missing, and the "gap" between them
            // would be every unrealized row in between. The last paragraph of the
            // previous chapter is adjacency by construction, and no title is
            // remotely near 200 points tall.
            guard let previousChapter = loaded.first(where: {
                $0.chapter.index == previous.chapterIndex
            }), previous.paragraph == previousChapter.paragraphs.count - 1 else { continue }
            let title = current.minY - previous.maxY
            if title > 0, title < 200 {
                recordedTitleHeight = title
            }
            return
        }
    }

    /// The length of one loaded chapter's block — title plus every paragraph row —
    /// from the heights recorded while the reader read it. Nil until every row of
    /// the chapter has been seen and some seam has priced a title.
    private func measuredBlockHeight(of item: LoadedChapter) -> CGFloat? {
        guard let title = recordedTitleHeight,
              let rows = recordedRowHeights[item.chapter.index],
              rows.count == item.paragraphs.count
        else { return nil }
        return title + rows.values.reduce(0, +)
    }

    /// Whether a finger is on the glass, from the reader's own drag recogniser.
    ///
    /// The one thing the geometry cannot say: a scroll that is being dragged and one
    /// that is coasting report identical frames, and only the first of them can undo a
    /// correction. Costs nothing when it does not change.
    func touch(down: Bool) {
        guard isTouching != down else { return }
        isTouching = down
        // A finger on the glass ends any correction still settling: a tap is a page
        // turn, and a correction that re-states itself over one is the page that turns
        // and comes straight back.
        if down { heldPosition = nil }
        if !down { showPreviousChapter() }
    }

    /// - Parameter settling: wait for the viewport to go quiet before mutating
    ///   `loaded`. Only the read-ahead path asks for this; a jump or a retry is the
    ///   reader waiting on an empty screen, and making them wait longer to be polite
    ///   to an animation that does not exist would be absurd.
    private func append(_ chapter: Chapter, settling: Bool = false) async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let text = try await paragraphs(for: chapter)
            if settling {
                await settleBeforeGrowingContent()
                // The world can move while this waits — and could already move
                // across the fetch's own suspension: a catalog jump replaces
                // `loaded`, and a chapter fetched for the old window belongs
                // nowhere. Valid only while it still extends the frontier it was
                // asked for.
                guard loaded.last?.chapter.index == chapter.index - 1 else { return }
                // Shrink before growing, so the container the slices diff against
                // is the capped one. The collapse changes no height and needs no
                // correction, but its transaction still costs a few frames on
                // device — the pause keeps it from merging with the first slice
                // into one long stutter, and the settle re-checks that the pause
                // itself was not spent scrolling.
                if collapseReadChapters() {
                    try? await Task.sleep(for: .milliseconds(250))
                    await settleBeforeGrowingContent()
                    guard loaded.last?.chapter.index == chapter.index - 1 else { return }
                }
                await appendInSlices(chapter, text: text)
                startReadingAhead()
                return
            }
            loaded.append(LoadedChapter(chapter: chapter, paragraphs: text))
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

    /// Paragraphs per slice. Small enough that one slice's transaction fits well
    /// inside a frame budget on device; large enough that a chapter completes in a
    /// handful of turns of the run loop.
    private static let appendSliceRows = 40

    /// Grows the tail chapter a slice at a time, each slice its own SwiftUI
    /// transaction landed on a quiet viewport.
    ///
    /// The whole-chapter append was one transaction costing 300–440ms of
    /// main-thread graph work on device — deferred to a still screen since 1.3.2,
    /// but still a frozen screen for whoever taps during it. The growth happens
    /// below the frontier the reader is at least a prefetch lead away from, so
    /// nothing on screen moves while it runs.
    ///
    /// Bails the moment the tail is no longer the chapter it was growing — a jump
    /// has replaced the world, and the partial chapter went with it.
    private func appendInSlices(_ chapter: Chapter, text: [String]) async {
        var count = min(Self.appendSliceRows, text.count)
        loaded.append(LoadedChapter(chapter: chapter, paragraphs: Array(text.prefix(count))))
        while count < text.count {
            // Well more than the one runloop turn that keeps slices from coalescing
            // into a single transaction: on device each slice costs a fixed few
            // frames of structure work regardless of its row count, and slices
            // spaced 50ms apart merged into one perceived stutter. A quarter second
            // apart they are separate blinks on a still screen — and the prefetch
            // lead is measured in pages, so the chapter still lands minutes early.
            try? await Task.sleep(for: .milliseconds(250))
            await settleBeforeGrowingContent()
            guard loaded.last?.chapter.id == chapter.id else { return }
            count = min(count + Self.appendSliceRows, text.count)
            loaded[loaded.count - 1] = LoadedChapter(
                chapter: chapter, paragraphs: Array(text.prefix(count))
            )
        }
    }

    /// Returns once the viewport has been quiet for a few frames' worth of time —
    /// the moment a whole chapter can be added to the lazy stack without anyone
    /// watching it happen.
    ///
    /// Quiet, not "animation finished": the model cannot see the scroll view's
    /// animations, but a moving screen delivers geometry reports every frame and a
    /// still one delivers none, so silence on that channel *is* stillness. Capped,
    /// because a reader parked exactly at the frontier is starving for this text
    /// and reports nothing — for them the wait must be a beat, not a bargain.
    private func settleBeforeGrowingContent() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if ContinuousClock.now > lastViewportReportAt.advanced(by: .milliseconds(400)) {
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
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
            await self.env.pacer.pace()
            guard !Task.isCancelled else { return }
            self.readAheadPhase = .fetching(chapterId: next.id)
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
        readAheadPhase = nil
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
        // Before the consistency guard: a lying reflow frame is still the screen
        // moving, which is exactly what the settle must not mutate under.
        lastViewportReportAt = .now
        // A report whose bottom sits before its top in reading order is not a place —
        // it is the lazy stack mid-reflow, with the rows of a freshly inserted chapter
        // overlapping the rows on screen at estimated offsets. On a device trace one
        // such frame passed the arrival test, the gate opened on it, and the next
        // report — the reflow settled a chapter up — was recorded as the reader's own
        // movement: reader and stored position both fell back a whole chapter.
        // Nothing here can be trusted, so nothing is recorded; a pending jump keeps
        // re-aiming, which is also what pulls the scroll back once the reflow settles.
        guard (top.chapterIndex, top.paragraph) <= (bottom.chapterIndex, bottom.paragraph)
        else { return scrollTarget }
        if let target = scrollTarget {
            guard hasArrived(top: top, bottom: bottom) else { return target }
            scrollTarget = nil
            // Deferred, not spent on this frame. The gate does not only open at rest:
            // a landing that stops one paragraph short of its aim leaves the gate
            // closed until the *next* page turn carries the top across it, and that
            // gate-open is mid-animation — the one moment the insert's correction
            // cannot hold. The pause outlives a turn's animation and its estimated-
            // height corrections; `showPreviousChapter` re-checks the world when it
            // fires, so a jump or a touch in the meantime still wins.
            if wantsPreviousBehindLanding {
                wantsPreviousBehindLanding = false
                Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    await loadStoredPrevious()
                }
            }
        }
        // Compared before writing because this fires on every scrolled frame, and an
        // `@Observable` write is a notification whether or not the value changed.
        if currentChapterIndex != top.chapterIndex { currentChapterIndex = top.chapterIndex }
        // A row boundary is the finest place the scroll can name, so the offset within
        // the paragraph is honestly zero rather than guessed at. See `TextAnchor`.
        let anchor = TextAnchor(paragraph: top.paragraph, characterOffset: 0)
        if currentAnchor != anchor { currentAnchor = anchor }
        // Under the same per-frame rule as the two writes above — and here the guard
        // covers the computation too: the share walks every paragraph's length
        // through an `NSString` bridge, which is real CPU to spend on frames where
        // the bottom has not even crossed into a new paragraph. Slice growth can
        // shift the denominator between crossings; the next crossing corrects it.
        if lastShareBottom?.chapter != bottom.chapterIndex
            || lastShareBottom?.paragraph != bottom.paragraph {
            lastShareBottom = (bottom.chapterIndex, bottom.paragraph)
            reportedFraction = readShare(through: bottom)
        }
        persistProgress(.reading)
        // Which way the reader is heading, judged against the previous report. Same
        // paragraph is compared by where it sits: the paragraph's top moving down the
        // window is the text moving down, which is the reader going up. The half-point
        // of slack keeps a settled screen's sub-pixel jitter from reading as travel.
        let movingUp: Bool
        if let lastTop {
            movingUp = (top.chapterIndex, top.paragraph) < (lastTop.chapterIndex, lastTop.paragraph)
                || ((top.chapterIndex, top.paragraph) == (lastTop.chapterIndex, lastTop.paragraph)
                    && top.minY > lastTop.minY + 0.5)
        } else {
            movingUp = false
        }
        lastTop = top
        if !isLoading {
            // Two pages of lead, with the page measured off this screen rather than
            // assumed. Six paragraphs — a third of a screen at the default size — was less
            // than one tapped page turn, so the turn that asked for the next chapter was
            // itself the turn that ran off the end of the loaded text: with nothing below
            // to scroll into it stopped short of where it was aimed, and then finished the
            // journey on its own once the chapter landed. That is the page that turns
            // twice. Measured because the reader's font size moves paragraphs-per-page by
            // a factor of three, and a lead fixed in paragraphs is late at the largest text
            // or greedy at the smallest.
            let page = top.chapterIndex == bottom.chapterIndex
                ? max(1, bottom.paragraph - top.paragraph)
                : Self.minimumPrefetchLead
            let lead = max(Self.minimumPrefetchLead, 2 * page)
            // The lead runs to the end of *everything* loaded, not of the chapter the
            // bottom is in. Measured against the last chapter alone, a short chapter
            // sitting between the reader and the frontier ate the whole lead: the next
            // load could not start until the reader had crossed into it, and for a
            // chapter shorter than the lead that crossing is the same tap that needs
            // the chapter after it — a turn into a wall, on a book that is entirely on
            // disk. Counted across the tail, its few paragraphs are just part of the
            // distance, and the load after it starts while the reader is still a page
            // or two away.
            // The existence check lives out here, not in the task: parked inside the
            // lead with nothing left to load — the end of the book, most evenings —
            // this branch used to allocate a task per scrolled frame just to find
            // that out. And never while a failure is showing: `append` clears the
            // error on entry, so re-spawning per frame kept a failing chapter in an
            // eternal spinner — the retry button at the foot of the text was never
            // on screen long enough to exist, and the reader was walled in with
            // every tap doing nothing. One failure, one visible retry.
            if error == nil, let last = loaded.last,
               chapters.indices.contains(last.chapter.index + 1),
               paragraphsBelow(bottom) < lead {
                Task { await loadNextIfLast(after: last.chapter.index) }
            }
            // Only for a reader actually heading up. Nearness alone is not intent: a
            // jump lands at the head of its chapter, which is inside any useful lead,
            // and inserting the previous chapter there shoves the text the reader just
            // asked for down a whole chapter and drags the view back to it — the open
            // that visibly runs backwards. Someone who wants what is above will move
            // toward it, and even one upward flick is pages of warning.
            //
            // Deaf while the reflow settles — see `contentAboveChangedAt`. A real
            // reader is a chapter away from the next trigger by then, so the pause
            // costs them nothing; without it the reflow's own frames are the trigger.
            let settled = contentAboveChangedAt.map {
                ContinuousClock.now > $0.advanced(by: .milliseconds(600))
            } ?? true
            // Nearing the top of the chapter they are in, on the way up: whatever lies
            // above has to be there before they reach it. A collapsed chapter is put
            // back where it stands — free, and no correction; only when there is no
            // collapsed chapter above does the window have to grow at the front, which
            // is the expensive half.
            if movingUp, settled, top.paragraph < lead,
               reinflateChapterAbove(top.chapterIndex) {
                return nil
            }
            if movingUp, settled, pendingPrevious == nil, let first = loaded.first,
               top.chapterIndex == first.chapter.index, top.paragraph < lead {
                Task { await loadPrevious(before: first.chapter.index) }
            }
        }
        return nil
    }

    /// Paragraphs loaded but still below the bottom of the window — the text the reader
    /// has left before they run out of content, however many chapter seams it crosses.
    private func paragraphsBelow(_ bottom: ReaderTapZone.VisibleParagraph) -> Int {
        loaded.reduce(0) { count, item in
            if item.chapter.index < bottom.chapterIndex { return count }
            if item.chapter.index == bottom.chapterIndex {
                return count + max(0, item.paragraphs.count - 1 - bottom.paragraph)
            }
            return count + item.paragraphs.count
        }
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

    /// Gives back every chapter but the one being read and its two neighbours.
    ///
    /// The scroll gains chapters in both directions and nothing takes them out again:
    /// `jump` empties the array, but a reader who simply keeps scrolling never calls
    /// it, so one session in the reader holds every chapter it crossed. Measured on a
    /// real book that is about seventy kilobytes a chapter, with the lazy stack's built
    /// rows flat at sixty-odd throughout — small enough that trimming as a matter of
    /// course would be paying a visible price for nothing. Dropping a chapter *above*
    /// the reader shortens the text above them, and the correction that follows can
    /// only land on a paragraph boundary rather than exactly where they were, so it
    /// shows. Under real pressure that flinch is a good trade and being killed is not.
    ///
    /// Both neighbours are kept because both are wanted: the one ahead is what the
    /// prefetch just paid for, and the one behind is where a reader turning back goes.
    func dropDistantChapters() {
        guard let current = loaded.firstIndex(where: {
            $0.chapter.index == currentChapterIndex
        }) else { return }
        let keep = max(0, current - 1)...min(loaded.count - 1, current + 1)
        guard keep.count < loaded.count else { return }
        let droppedAbove = keep.lowerBound > 0
        loaded = Array(loaded[keep])
        guard droppedAbove else { return }
        contentAboveChangedAt = .now
        retarget()
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
