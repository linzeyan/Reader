import SwiftUI
import UIKit

/// A chapter that has been laid out and given its place in the scrolling content.
///
/// The unit the scrolling reader stacks. `top` is in content coordinates — the whole
/// loaded window, not one chapter — and it is what makes an insert above the reader
/// free: everything below shifts by a known number of points, and the scroll offset
/// shifts with it. The renderer this replaces could only ask a lazy container to aim at
/// a row and then measure how far it missed by (`ScrollCorrection`), because the
/// container would not say how tall anything was.
struct PlacedColumn {
    let chapterIndex: Int
    let chapterId: String
    let siteChapterId: String
    let column: ChapterColumn
    /// Where this chapter starts in content coordinates.
    var top: CGFloat

    var height: CGFloat { column.height }
    var bottom: CGFloat { top + height }
}

/// Where the reader is, in the terms the model stores.
struct ReaderPlace: Equatable {
    let chapterIndex: Int
    let anchor: TextAnchor
    /// Share of the chapter read, measured to the *bottom* of the window and over the
    /// same composed text `PaginatedChapterView.fraction(atPage:)` measures over — see
    /// `ReaderScrollCoordinator.fractionRead(through:)`.
    let fraction: Double
}

/// The paragraph the reader is being asked about, drawn picked out.
struct ReaderMark: Equatable {
    let siteChapterId: String
    let paragraph: Int
}

/// What a tap landed on.
///
/// Reported rather than acted on, because the decisions belong to the reader view: a
/// tap answers an open question about a passage before it turns a page, and that
/// question is state only that view holds. What this carries is what only the renderer
/// knows — which zone the finger was in, which paragraph it was over, and whether it
/// landed on the ink of a stored mark.
struct ReaderTap {
    let zone: ReaderTapZone.Zone
    let chapterIndex: Int?
    let paragraph: Int?
    let highlight: TextHighlight?
    /// The address under the finger, for an article with links in its sentences.
    let link: URL?
}

/// The scrolling reader's text surface: one continuous TextKit 2 column per chapter,
/// stacked in a `UIScrollView` and drawn by a canvas the size of the screen.
///
/// Replaces a `ScrollView` + `LazyVStack` + one SwiftUI `Text` per paragraph. That
/// arrangement cost 58ms of main-thread layout per tapped turn — rows being laid out as
/// they entered the viewport, unowned by any mutation, fixed rather than growing (see
/// PITFALLS, 2026-08-27) — and it also forced a long tail of machinery whose only job
/// was coping with a container that would not answer questions: height-preserving
/// collapse, scroll corrections with settle-and-retry, per-row `GeometryReader`
/// preference plumbing, slice-by-slice appends and a reflow deafness window. None of
/// that is here, because a laid-out column knows its own height and a `contentOffset`
/// is an exact number.
///
/// It also makes the two renderers one book. Line spacing, paragraph spacing and the
/// share-read denominator used to be implemented twice — `.lineSpacing()` plus
/// `.padding(.bottom,)` against `NSParagraphStyle`, paragraph character counts against
/// the composed string's length — and identical settings through different machinery do
/// not have to come out the same. Both now draw from `ChapterText`.
struct ReaderScrollingText: UIViewRepresentable {
    /// The loaded window, in reading order.
    let chapters: [ReaderModel.LoadedChapter]
    let settings: ReaderSettings
    /// The colours, already resolved. Handed down rather than read off `settings`,
    /// because the system's own light-or-dark answer is a trait of the view tree and
    /// this view's owner is the one holding it.
    let palette: ReaderPalette
    /// This book's highlights, by site chapter id — looked up per chapter as it is drawn.
    let highlights: [String: [TextHighlight]]
    /// The paragraph being asked about right now, drawn in the selection colour.
    let marked: ReaderMark?
    /// Where the reader must be put. Consumed once and cleared by the owner: a jump, a
    /// mode switch, or opening the book.
    let target: ReaderModel.ScrollTarget?
    /// What sits under the last chapter.
    let footer: ReaderTextFooter.State

    let onPlaceChange: (ReaderPlace) -> Void
    let onNeedsNext: () -> Void
    let onNeedsPrevious: () -> Void
    /// Whether a finger is on the glass, which is what holds back an insert above the
    /// reader — see `ReaderModel.showPreviousChapter` — and, going down, the one signal
    /// that tells a deliberate press apart from a thumb that rested before it dragged.
    let onTouch: (Bool) -> Void
    /// - Returns: whether the tap should go on to turn a page.
    let onTap: (ReaderTap) -> Bool
    let onMark: (Int, Int) -> Void
    /// Fired once the reader has been put where `target` asked, so the owner can stop
    /// asking. Unlike the arrival gate this replaces, there is nothing to detect: the
    /// scroll offset was set to an exact number, so it has arrived by construction.
    let onTargetReached: () -> Void

    func makeUIView(context: Context) -> ReaderTextScrollView {
        let view = ReaderTextScrollView()
        view.coordinator = context.coordinator
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: ReaderTextScrollView, context: Context) {
        context.coordinator.update(with: self)
    }

    func makeCoordinator() -> ReaderScrollCoordinator {
        ReaderScrollCoordinator()
    }
}

/// Owns the laid-out columns and everything that depends on where the scroll is.
///
/// A class rather than state on the `View` because layout happens off the main thread
/// and lands later: the value the SwiftUI graph handed us has long since been replaced
/// by the time a column is ready.
@MainActor
final class ReaderScrollCoordinator {
    weak var view: ReaderTextScrollView?

    private(set) var placed: [PlacedColumn] = []
    private var config: ReaderScrollingText?
    /// The layout key the current columns were built under. Anything in it changing
    /// means every column describes text nobody is reading — a rotation, a font, a size.
    private var builtFor: LayoutKey?
    /// Chapters whose layout is in flight, so a second `updateUIView` in the same beat
    /// does not lay the same chapter out twice.
    private var laying: Set<String> = []
    /// The place last reported, so a scrolled frame that has not crossed a paragraph
    /// costs nothing.
    private var reported: ReaderPlace?
    private var deliveredTarget: ReaderModel.ScrollTarget?

    /// Everything that changes where lines break.
    private struct LayoutKey: Equatable {
        let width: CGFloat
        let fontName: String?
        let fontSize: Double
        let lineSpacing: Double
        let paragraphSpacing: Double
        /// The text colour, which is baked into every laid-out glyph. Only the ink: the
        /// page behind it is painted by a view under this one, so changing a gradient for
        /// a photograph must not throw away chapters that are already laid out.
        let ink: String
    }

    /// The gap between one chapter's last line and the next chapter's heading. The
    /// heading carries its own space above it inside the column, so this is only the
    /// seam.
    static let chapterGap: CGFloat = 28

    /// Laid out off the main thread, one chapter at a time, in order. Serial rather than
    /// concurrent on purpose: `NSTextLayoutManager` is not thread-safe, and one queue is
    /// the cheapest way to guarantee a column is only ever touched by one thread at a
    /// time before it is handed over.
    private let layoutQueue = DispatchQueue(
        label: "reader.column.layout", qos: .userInitiated
    )

    func update(with config: ReaderScrollingText) {
        self.config = config
        view?.showFooter(config.footer)
        let key = LayoutKey(
            width: view?.textWidth ?? 0,
            fontName: config.settings.fontName,
            fontSize: config.settings.fontSize,
            lineSpacing: config.settings.lineSpacing,
            paragraphSpacing: config.settings.paragraphSpacing,
            ink: config.palette.textKey
        )
        guard key.width > 0 else { return }
        view?.apply(palette: config.palette)

        if builtFor != key {
            // Everything on screen describes a measure nobody is reading at. Keep the
            // reader's place as an anchor — a point in the old layout means nothing in
            // the new one — and rebuild.
            let keep = currentPlace()
            builtFor = key
            placed = []
            laying = []
            deliveredTarget = nil
            layOutMissing(
                for: config,
                restoring: keep.map { ReaderModel.ScrollTarget(
                    chapterIndex: $0.chapterIndex, anchor: $0.anchor
                ) }
            )
            return
        }
        layOutMissing(for: config, restoring: nil)
        dropChaptersNoLongerLoaded(config)
        applyTargetIfNeeded(config)
        view?.refreshContentSize()
        view?.redraw()
    }

    /// The window changed measure. Everything laid out describes a width nobody is
    /// reading at, so the next `update` has to rebuild — which the key comparison does
    /// on its own, once it is given a chance to run.
    func viewResized() {
        guard let config else { return }
        update(with: config)
    }

    // MARK: - Building columns

    /// Lays out any loaded chapter that has no column yet, oldest first.
    private func layOutMissing(
        for config: ReaderScrollingText, restoring target: ReaderModel.ScrollTarget?
    ) {
        guard let key = builtFor else { return }
        for chapter in config.chapters
        where !placed.contains(where: { $0.chapterId == chapter.chapter.id })
            && !laying.contains(chapter.chapter.id) {
            laying.insert(chapter.chapter.id)
            let identity = chapter.chapter.id
            let index = chapter.chapter.index
            let siteId = chapter.chapter.siteChapterId
            let title = chapter.chapter.title
            let subtitle = chapter.subtitle
            let blocks = chapter.blocks
            let typography = ReaderTypography(
                settings: config.settings, color: config.palette.foreground.uiColor
            )
            // A screenful, which is as tall as a picture may usefully be here: taller and
            // the reader scrolls past it without ever seeing it whole. Falls back to the
            // measure when the view has not been sized yet, which is a portrait-ish
            // rectangle rather than a number that would let an image grow without limit.
            let layout = chapter.imageDirectory.map {
                ArticleLayout(
                    width: key.width,
                    maxImageHeight: max(view?.visibleHeight ?? 0, key.width),
                    directory: $0
                )
            }
            layoutQueue.async { [weak self] in
                let column = ChapterColumn(
                    text: ChapterText(
                        title: title, subtitle: subtitle, blocks: blocks,
                        typography: typography, layout: layout,
                        // Ragged, unlike a page: this column has no visible right edge
                        // to justify against.
                        alignment: .natural
                    ),
                    width: key.width
                )
                column.layOut()
                Task { @MainActor [weak self] in
                    self?.place(
                        column, id: identity, index: index, siteChapterId: siteId,
                        builtUnder: key, restoring: target
                    )
                }
            }
        }
    }

    /// Puts a freshly laid-out chapter into the stack, keeping the reader where they are.
    ///
    /// This is the method the old renderer needed `ScrollCorrection`, `holdPosition`,
    /// `checkHeldPosition` and a three-frame settle for. Here an insert above the reader
    /// is: recompute the tops, see how far the reader's own chapter moved, and move the
    /// scroll offset by the same amount. Exact, no frames to wait for and nothing to
    /// re-aim.
    private func place(
        _ column: ChapterColumn, id: String, index: Int, siteChapterId: String,
        builtUnder key: LayoutKey, restoring target: ReaderModel.ScrollTarget?
    ) {
        laying.remove(id)
        // Laid out for a measure that has since changed, or for a chapter the reader has
        // jumped away from.
        guard key == builtFor, let config, config.chapters.contains(where: {
            $0.chapter.id == id
        }), !placed.contains(where: { $0.chapterId == id }) else { return }

        // The chapter the reader is in, and where it sat before the insert. Held by id
        // rather than by position, because the insert renumbers the array.
        let anchor = view.flatMap { chapter(atY: $0.readingOffset) }
        let anchorTop = anchor?.top

        #if DEBUG
        ColumnProbe.placed(index, report: column.layoutReport)
        #endif
        let entry = PlacedColumn(
            chapterIndex: index, chapterId: id, siteChapterId: siteChapterId,
            column: column, top: 0
        )
        placed.insert(entry, at: placed.firstIndex { $0.chapterIndex > index } ?? placed.count)
        restack()
        view?.refreshContentSize()

        if let anchor, let anchorTop,
           let moved = placed.first(where: { $0.chapterId == anchor.chapterId }) {
            // Everything the reader is looking at moved by exactly this much. Zero when
            // the chapter landed below them, which is the common case.
            view?.shift(by: moved.top - anchorTop)
        }
        if let target, placed.contains(where: { $0.chapterIndex == target.chapterIndex }) {
            scroll(to: target.anchor, inChapter: target.chapterIndex, animated: false)
        }
        // A jump states its aim before the chapter it names can possibly be laid out,
        // so this is where most landings actually happen.
        applyTargetIfNeeded(config)
        view?.redraw()
        reportPlace()
    }

    /// Recomputes every chapter's top.
    private func restack() {
        var y: CGFloat = 0
        for index in placed.indices {
            placed[index].top = y
            y += placed[index].height + Self.chapterGap
        }
    }

    private func dropChaptersNoLongerLoaded(_ config: ReaderScrollingText) {
        let live = Set(config.chapters.map(\.chapter.id))
        guard placed.contains(where: { !live.contains($0.chapterId) }) else { return }
        let keep = currentPlace()
        placed.removeAll { !live.contains($0.chapterId) }
        restack()
        view?.refreshContentSize()
        if let keep { scroll(to: keep.anchor, inChapter: keep.chapterIndex, animated: false) }
    }

    var contentHeight: CGFloat { placed.last?.bottom ?? 0 }

    // MARK: - Where the reader is

    /// The chapter a content height falls in.
    func chapter(atY y: CGFloat) -> PlacedColumn? {
        placed.last { $0.top <= y } ?? placed.first
    }

    /// What the model should store for the current scroll offset.
    func currentPlace() -> ReaderPlace? {
        guard let view, !placed.isEmpty, let chapter = chapter(atY: view.readingOffset)
        else { return nil }
        return ReaderPlace(
            chapterIndex: chapter.chapterIndex,
            anchor: chapter.column.anchor(atY: view.readingOffset - chapter.top),
            fraction: fractionRead(through: view.readingOffset + view.visibleHeight, in: chapter)
        )
    }

    /// How far through the chapter the bottom of the window has reached.
    ///
    /// Over the composed chapter's own length, which is what makes this and
    /// `PaginatedChapterView.fraction(atPage:)` the same number. They used to be two
    /// denominators: a page measured over the composed string — heading, separators and
    /// all — while the scrolling reader measured over the paragraph array alone, so the
    /// two modes disagreed about the same sentence by the length of a title plus one
    /// character per paragraph. That is the reported "switching modes moves the
    /// percentage".
    ///
    /// `offset(atY:)` names the line straddling the foot of the window, so what is
    /// counted is the text the reader could actually finish — which is exactly what a
    /// page's `NSMaxRange` counts, since every line on a page is whole.
    private func fractionRead(through bottom: CGFloat, in chapter: PlacedColumn) -> Double {
        guard bottom < chapter.bottom else { return 1 }
        let total = chapter.column.text.attributed.length
        guard total > 0 else { return 0 }
        let offset = chapter.column.offset(atY: bottom - chapter.top)
        return TextAnchor.claimedShare(Double(offset) / Double(total))
    }

    /// Called by the scroll view whenever the content moves.
    func scrolled() {
        reportPlace()
        askForMoreIfNeeded()
    }

    private func reportPlace() {
        guard let config, let place = currentPlace(), place != reported else { return }
        reported = place
        config.onPlaceChange(place)
    }

    /// How much loaded text has to remain in each direction before more is asked for.
    /// Two windows: one page of lead was the turn that ran off the end of the loaded
    /// text and then finished its journey once the chapter landed — the page that turns
    /// twice.
    private static let leadWindows: CGFloat = 2

    private func askForMoreIfNeeded() {
        guard let config, let view, !placed.isEmpty else { return }
        let lead = view.visibleHeight * Self.leadWindows
        if contentHeight - (view.readingOffset + view.visibleHeight) < lead {
            config.onNeedsNext()
        }
        // Only when actually heading up: a landing sits at the head of its chapter,
        // which is inside any useful lead, and pulling the previous chapter in there
        // is the open that visibly runs backwards. Unlike the old renderer this cannot
        // shove the reader — the insert is exact — but it would still spend a request
        // nobody asked for.
        if view.isMovingUp, view.readingOffset < lead {
            config.onNeedsPrevious()
        }
    }

    // MARK: - Moving the reader

    private func applyTargetIfNeeded(_ config: ReaderScrollingText) {
        guard let target = config.target else {
            // The owner has stopped asking, so the next ask is a fresh one even when it
            // names the same place — a reader who jumps to a chapter, reads on and
            // jumps back is asking twice for one destination.
            deliveredTarget = nil
            return
        }
        guard target != deliveredTarget,
              placed.contains(where: { $0.chapterIndex == target.chapterIndex })
        else { return }
        deliveredTarget = target
        scroll(to: target.anchor, inChapter: target.chapterIndex, animated: false)
        // Off this pass: clearing the target writes to the model, and this can run
        // inside `updateUIView` — which is SwiftUI in the middle of reading it.
        Task { @MainActor in config.onTargetReached() }
        reportPlace()
    }

    func scroll(to anchor: TextAnchor, inChapter index: Int, animated: Bool) {
        guard let view, let chapter = placed.first(where: { $0.chapterIndex == index })
        else { return }
        view.setReadingOffset(chapter.top + chapter.column.y(for: anchor), animated: animated)
    }

    /// The paragraphs with any part on screen, in the shape `ReaderTapZone` reads.
    ///
    /// Same value, same rules, computed instead of collected: this used to be a
    /// `GeometryReader` behind every realized row feeding a preference tree on every
    /// frame. `ReaderTapZone` is unchanged — its page-turn arithmetic is a rule about
    /// where a finger landed, and it was never the thing that was slow.
    func visibleParagraphs() -> [ReaderTapZone.VisibleParagraph] {
        guard let view else { return [] }
        let top = view.readingOffset
        let bottom = top + view.visibleHeight
        var result: [ReaderTapZone.VisibleParagraph] = []
        for chapter in placed where chapter.bottom > top && chapter.top < bottom {
            for frame in chapter.column.paragraphs(in: (top - chapter.top)..<(bottom - chapter.top)) {
                result.append(ReaderTapZone.VisibleParagraph(
                    chapterIndex: chapter.chapterIndex,
                    paragraph: frame.paragraph,
                    id: TextAnchor.paragraphID(
                        chapterId: chapter.chapterId, paragraph: frame.paragraph
                    ),
                    minY: chapter.top + frame.minY - top,
                    maxY: chapter.top + frame.maxY - top
                ))
            }
        }
        return result
    }

    /// Turns a page in the direction a tap asked for, by the rule `ReaderTapZone` states.
    func turnPage(_ zone: ReaderTapZone.Zone) {
        guard let view, let config else { return }
        // A previous-page tap with nothing above to move into would be a wall: the gate
        // that fetches the chapter above waits for upward movement, and here nothing
        // moves. The tap is itself that intent, so it asks directly; the next tap has
        // somewhere to go.
        if zone == .previous, view.readingOffset <= 0 { config.onNeedsPrevious() }
        guard let destination = pageTurnDestination(zone) else { return }
        // Animated, unlike a jump between chapters: this is the reader moving through
        // text they are reading, and a page that appears without moving gives them
        // nothing to tell it apart from a page that never turned.
        view.setReadingOffset(destination, animated: true)
    }

    /// Where a page turn in this direction would land, in content coordinates.
    ///
    /// `ReaderTapZone` names a paragraph and the point of the window to line it up
    /// with, which was a `scrollTo` in the old renderer and is arithmetic here: for a
    /// paragraph of height `h` in a window of height `v`, an anchor of `a` puts its top
    /// `a * (v - h)` below the top of the screen. Separate from the move so the number
    /// can be asserted without a runloop to animate through.
    func pageTurnDestination(_ zone: ReaderTapZone.Zone) -> CGFloat? {
        guard let view, let scroll = ReaderTapZone.pageScroll(
            zone, over: visibleParagraphs(), viewport: view.visibleHeight
        ), let (chapter, frame) = paragraph(withID: scroll.id) else { return nil }
        let height = frame.maxY - frame.minY
        return chapter.top + frame.minY - scroll.anchor.y * (view.visibleHeight - height)
    }

    private func paragraph(
        withID id: String
    ) -> (chapter: PlacedColumn, frame: ChapterColumn.ParagraphFrame)? {
        for chapter in placed {
            guard let frame = chapter.column.paragraphFrames.first(where: {
                TextAnchor.paragraphID(
                    chapterId: chapter.chapterId, paragraph: $0.paragraph
                ) == id
            }) else { continue }
            return (chapter, frame)
        }
        return nil
    }

    // MARK: - Touching text

    /// What a point on the glass is over.
    func hit(_ point: CGPoint) -> (chapter: PlacedColumn, paragraph: Int)? {
        guard let view else { return nil }
        let inContent = point.y + view.readingOffset
        guard let chapter = chapter(atY: inContent) else { return nil }
        let inColumn = inContent - chapter.top
        guard let frame = chapter.column.paragraphFrames.first(where: {
            $0.minY <= inColumn && inColumn < $0.maxY
        }) else { return nil }
        return (chapter, frame.paragraph)
    }

    func handleTap(at point: CGPoint) {
        guard let config, let view else { return }
        let hit = hit(point)
        let tap = ReaderTap(
            zone: ReaderTapZone.zone(
                at: point, in: CGSize(width: view.bounds.width, height: view.visibleHeight)
            ),
            chapterIndex: hit?.chapter.chapterIndex,
            paragraph: hit?.paragraph,
            highlight: hit.flatMap { highlight(at: point, in: $0.chapter) },
            link: hit.flatMap { link(at: point, in: $0.chapter, paragraph: $0.paragraph) }
        )
        guard config.onTap(tap) else { return }
        turnPage(tap.zone)
    }

    func handleLongPress(at point: CGPoint) {
        guard let config, let hit = hit(point) else { return }
        config.onMark(hit.chapter.chapterIndex, hit.paragraph)
    }

    func handleTouch(down: Bool) {
        config?.onTouch(down)
    }

    /// The stored highlight under a point, hit against the bands it is *drawn* in — the
    /// reader's own question, and the same rule the paginated renderer answers by.
    private func highlight(at point: CGPoint, in chapter: PlacedColumn) -> TextHighlight? {
        guard let config, let view else { return nil }
        let marks = config.highlights[chapter.siteChapterId] ?? []
        guard !marks.isEmpty else { return nil }
        let inColumn = CGPoint(
            x: point.x - ReaderTextScrollView.textMargin,
            y: point.y + view.readingOffset - chapter.top
        )
        let slack = (config.settings.lineSpacing + config.settings.paragraphSpacing) / 2
        return marks.first { mark in
            chapter.column.text.ranges(of: mark).contains { range in
                chapter.column.rects(for: range).contains {
                    $0.insetBy(dx: 0, dy: -slack).contains(inColumn)
                }
            }
        }
    }

    /// The link under a point, hit against the ink the same way a stored mark is.
    ///
    /// Narrowed to the tapped paragraph first: an article's links are a list over the
    /// whole chapter, and asking where each of them was drawn would be a layout question
    /// per link per tap. The paragraph under the finger is already known, and a link
    /// cannot cross one.
    private func link(at point: CGPoint, in chapter: PlacedColumn, paragraph: Int) -> URL? {
        guard let view, !chapter.column.text.links.isEmpty,
              chapter.column.text.paragraphRanges.indices.contains(paragraph)
        else { return nil }
        let inColumn = CGPoint(
            x: point.x - ReaderTextScrollView.textMargin,
            y: point.y + view.readingOffset - chapter.top
        )
        let span = chapter.column.text.paragraphRanges[paragraph]
        for link in chapter.column.text.links
        where NSIntersectionRange(link.range, span).length > 0 {
            // A couple of words in the middle of a sentence is a smaller target than
            // anything else here that can be tapped, so the ink is given a little room —
            // but only a little, or the whole line becomes a link.
            let hit = chapter.column.rects(for: link.range).contains {
                $0.insetBy(dx: -4, dy: -4).contains(inColumn)
            }
            if hit { return link.url }
        }
        return nil
    }

    // MARK: - Drawing

    /// Draws the visible slice of every chapter it touches, plus their marks.
    func draw(_ visible: CGRect, in context: CGContext) {
        for chapter in placed where chapter.bottom > visible.minY && chapter.top < visible.maxY {
            let inColumn = CGRect(
                x: 0, y: visible.minY - chapter.top,
                width: visible.width, height: visible.height
            )
            context.saveGState()
            context.translateBy(x: 0, y: chapter.top - visible.minY)
            // Behind the glyphs, in that order: a band over the text would wash out the
            // words it is there to point at.
            for (rect, colour) in bands(of: chapter, in: inColumn) {
                colour.setFill()
                UIBezierPath(roundedRect: rect.insetBy(dx: 0, dy: 0.5), cornerRadius: 3).fill()
            }
            chapter.column.draw(inColumn, in: context)
            context.restoreGState()
        }
    }

    /// The marked bands of one chapter that reach into the window.
    ///
    /// Filtered by paragraph extent before any layout is asked for: turning a mark into
    /// rects costs an `ensureLayout` and a segment enumeration, and this runs on every
    /// drawn frame. Almost every chapter has no marks at all, so the loop below usually
    /// does nothing.
    private func bands(of chapter: PlacedColumn, in visible: CGRect) -> [(CGRect, UIColor)] {
        guard let config else { return [] }
        var result: [(CGRect, UIColor)] = []
        let frames = chapter.column.paragraphFrames
        // Clamped rather than trusted, for the same reason `ChapterText.offset(for:)`
        // clamps: a mark can outlive the text it named when a chapter comes back from
        // the site shorter than it was.
        func reaches(_ from: Int, through to: Int) -> Bool {
            guard !frames.isEmpty else { return false }
            let first = frames[min(max(from, 0), frames.count - 1)]
            let last = frames[min(max(to, 0), frames.count - 1)]
            return last.maxY > visible.minY && first.minY < visible.maxY
        }
        for mark in config.highlights[chapter.siteChapterId] ?? []
        where reaches(mark.startParagraph, through: mark.endParagraph) {
            for range in chapter.column.text.ranges(of: mark) {
                for rect in chapter.column.rects(for: range) where rect.intersects(visible) {
                    result.append((rect, UIColor(config.palette.highlight)))
                }
            }
        }
        if let marked = config.marked, marked.siteChapterId == chapter.siteChapterId,
           chapter.column.text.paragraphRanges.indices.contains(marked.paragraph),
           reaches(marked.paragraph, through: marked.paragraph) {
            let range = chapter.column.text.paragraphRanges[marked.paragraph]
            for rect in chapter.column.rects(for: range) where rect.intersects(visible) {
                result.append((rect, UIColor(config.palette.selection)))
            }
        }
        return result
    }

    // MARK: - Accessibility

    /// One element per chapter heading and paragraph on screen, in reading order.
    ///
    /// Hand-built because a drawn column has no view tree for VoiceOver to walk — the
    /// scrolling reader is the default mode, and it had one `Text` per paragraph and one
    /// per heading before this. The identifier on a paragraph is the handle the walks
    /// hold (`reader.paragraph`), and the label is the paragraph itself, which is what
    /// `topParagraphLabel()` reads.
    ///
    /// The heading has no identifier, which is deliberate: `reader.chapterTitle` belongs
    /// to the floating capsule, and two elements answering to it would make either one
    /// unfindable. It is here at all because it belongs to no paragraph and so falls
    /// through everything else — and it is the only thing on screen that says which
    /// chapter a reader who scrolled into it has arrived in.
    func accessibilityElements(for container: UIView) -> [UIAccessibilityElement] {
        guard let view, let config else { return [] }
        let top = view.readingOffset
        let bottom = top + view.visibleHeight
        var result: [UIAccessibilityElement] = []
        for chapter in placed where chapter.bottom > top && chapter.top < bottom {
            guard let loaded = config.chapters.first(where: {
                $0.chapter.index == chapter.chapterIndex
            }) else { continue }
            // Everything above the first paragraph is the heading and the air under it.
            let headingHeight = chapter.column.paragraphFrames.first?.minY ?? chapter.height
            if chapter.top + headingHeight > top {
                result.append(element(
                    in: container, label: loaded.chapter.title, identifier: nil,
                    minY: chapter.top - top, height: headingHeight
                ))
            }
            let window = (top - chapter.top)..<(bottom - chapter.top)
            for frame in chapter.column.paragraphs(in: window)
            where loaded.paragraphs.indices.contains(frame.paragraph) {
                result.append(element(
                    in: container, label: loaded.paragraphs[frame.paragraph],
                    identifier: "reader.paragraph",
                    minY: chapter.top + frame.minY - top, height: frame.maxY - frame.minY
                ))
            }
        }
        return result
    }

    private func element(
        in container: UIView, label: String, identifier: String?,
        minY: CGFloat, height: CGFloat
    ) -> UIAccessibilityElement {
        let element = UIAccessibilityElement(accessibilityContainer: container)
        element.accessibilityLabel = label
        element.accessibilityIdentifier = identifier
        element.accessibilityTraits = .staticText
        element.accessibilityFrameInContainerSpace = CGRect(
            x: 0, y: minY, width: container.bounds.width, height: height
        )
        return element
    }
}
