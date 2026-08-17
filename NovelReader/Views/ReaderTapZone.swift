import CoreGraphics
import SwiftUI

/// What a tap on the scrolling reader means, and where it takes the text.
///
/// Turning pages by tapping is off by default and on for the readers who want it, so the
/// screen has to answer three questions at once: go on, go back, and show me the
/// controls. Three rows and three columns, with only the middle cell reserved for the
/// controls — the top row and the left column go back, the bottom row and the right
/// column go on. Rows are decided before columns so that each corner has exactly one
/// answer instead of being an argument between two rules.
///
/// Pure, and separate from the view, for the same reason `ChapterPaginator`'s geometry
/// is: a rule about where a finger landed is worth being able to state and test, and a
/// rule buried in a gesture handler is one every reader has to discover for themselves.
enum ReaderTapZone {
    enum Zone: Equatable {
        case previous
        case controls
        case next
    }

    /// Where the middle band begins and ends, as a share of the screen. The controls cell
    /// is the one a thumb has to find without looking, so it is the largest single target
    /// on the page — and it is in the middle, where a thumb already rests.
    static let bandStart: CGFloat = 0.3
    static let bandEnd: CGFloat = 0.7

    static func zone(at point: CGPoint, in size: CGSize) -> Zone {
        guard size.width > 0, size.height > 0 else { return .controls }
        let y = point.y / size.height
        if y < bandStart { return .previous }
        if y > bandEnd { return .next }
        let x = point.x / size.width
        if x < bandStart { return .previous }
        if x > bandEnd { return .next }
        return .controls
    }

    /// One paragraph, as the scroll view currently has it placed in the window.
    ///
    /// Carries which text the frame belongs to, not only where it sits: the same
    /// measurements now serve two readers — the tap zones aim scrolls by `id`, and the
    /// reading position needs the chapter and paragraph the top of the window is in.
    struct VisibleParagraph: Equatable {
        /// Reading-order index of the chapter this paragraph belongs to.
        let chapterIndex: Int
        /// The paragraph's index within its chapter — what a `TextAnchor` stores.
        let paragraph: Int
        /// The scroll destination for this paragraph — `TextAnchor.paragraphID`.
        let id: String
        /// Distance from the top of the window to the top of the paragraph. Negative once
        /// the paragraph has started to scroll off.
        let minY: CGFloat
        let maxY: CGFloat

        var height: CGFloat { maxY - minY }
    }

    /// Where to scroll to turn one page: a paragraph to aim at, and the point of it to
    /// line up with the same point of the window.
    struct PageScroll: Equatable {
        let id: String
        let anchor: UnitPoint
    }

    /// A page turn expressed as a scroll destination.
    ///
    /// A window's worth of text, named by a paragraph rather than by a distance, because
    /// `ScrollViewProxy` can only be pointed at a view. Going on aims at the last
    /// paragraph that *starts* on screen and puts it at the top, so the one the reader
    /// could only half see arrives whole rather than being skipped. Going back aims the
    /// first visible paragraph at the bottom, which lands a window earlier and keeps the
    /// line they were on in sight — a page turn that overlaps is a page turn nobody has
    /// to double-check.
    ///
    /// - Returns: nil when there is nothing to move to, which is also the honest answer
    ///   for a tap on the controls band.
    static func pageScroll(
        _ zone: Zone, over visible: [VisibleParagraph], viewport: CGFloat
    ) -> PageScroll? {
        guard zone != .controls, viewport > 0 else { return nil }
        let onScreen = visible
            .filter { $0.maxY > 0 && $0.minY < viewport }
            .sorted { $0.minY < $1.minY }
        guard let first = onScreen.first else { return nil }

        switch zone {
        case .next:
            if let last = onScreen.last(where: { $0.minY > 0 }) {
                return PageScroll(id: last.id, anchor: .top)
            }
            // Nothing on screen starts on screen, so a single paragraph is taller than
            // the window and the move has to be made inside it.
            return within(first, by: viewport, viewport: viewport)
        case .previous:
            guard first.height <= viewport else {
                return within(first, by: -viewport, viewport: viewport)
            }
            return PageScroll(id: first.id, anchor: .bottom)
        case .controls:
            return nil
        }
    }

    /// The first and the last paragraph with any part inside the window.
    ///
    /// What turns the frames the scroll view reports into a reading position: the top of
    /// the span is where the text on screen begins, which is what the position stores,
    /// and the bottom is what edge-prefetch measures from. One function for both ends so
    /// they cannot be computed against two different ideas of "visible".
    static func visibleSpan(
        of visible: [VisibleParagraph], viewport: CGFloat
    ) -> (top: VisibleParagraph, bottom: VisibleParagraph)? {
        guard viewport > 0 else { return nil }
        let onScreen = visible
            .filter { $0.maxY > 0 && $0.minY < viewport }
            .sorted { $0.minY < $1.minY }
        guard let first = onScreen.first, let last = onScreen.last else { return nil }
        return (top: first, bottom: last)
    }

    /// A move that stays inside one paragraph, for the case where it is taller than the
    /// window and there is no other paragraph to aim at.
    ///
    /// `scrollTo` lines up the anchor point of the target with the same point of the
    /// window, so for a paragraph of height `h` shown in a window of height `v`, an anchor
    /// of `a` puts the paragraph's top at `a * (v - h)`. Solving that for the top the
    /// reader should end up at is the whole of this function; clamping is what stops it
    /// walking off either end of the paragraph.
    private static func within(
        _ paragraph: VisibleParagraph, by delta: CGFloat, viewport: CGFloat
    ) -> PageScroll? {
        let span = paragraph.height - viewport
        guard span > 0 else { return nil }
        let anchor = min(max((delta - paragraph.minY) / span, 0), 1)
        return PageScroll(id: paragraph.id, anchor: UnitPoint(x: 0, y: anchor))
    }
}

/// Collects the paragraphs on screen, which is how the scrolling reader knows where
/// the reader is — and, when tap-to-turn is on, where a tapped page should scroll to.
///
/// Always attached, no longer gated on the tap-to-turn setting: the reading position
/// is derived from these frames, and every reader has a position. The cost is one
/// `GeometryReader` behind each paragraph the lazy stack has actually built, which the
/// tap-to-turn feature was already paying.
struct VisibleParagraphsKey: PreferenceKey {
    static var defaultValue: [ReaderTapZone.VisibleParagraph] = []

    static func reduce(
        value: inout [ReaderTapZone.VisibleParagraph],
        nextValue: () -> [ReaderTapZone.VisibleParagraph]
    ) {
        value.append(contentsOf: nextValue())
    }
}
