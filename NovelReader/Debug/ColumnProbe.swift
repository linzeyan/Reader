#if DEBUG
import Foundation
import QuartzCore
import UIKit

/// What the scrolling column was asked to draw, and what it had to draw it with.
///
/// A hunt kit, like `ReaderProbe`, and meant to be stripped once the question is
/// answered — see PITFALLS 2026-08-28. The question: on a device the reader draws the
/// top of the window correctly and then stops part-way down, drawing fewer paragraphs
/// the further in the reader gets, while the simulator draws every window whole.
/// Nothing offline reproduces it, so the device has to say which of the three inputs is
/// wrong — the window it was handed, the geometry it recorded, or the two together.
///
/// Unconditional in DEBUG rather than armed by a launch argument, because whoever is
/// looking at this is looking at a device console with a screenshot in their other hand.
/// Throttled, because drawing runs at frame rate.
///
/// Read it in Xcode's console, or:
/// ```
/// xcrun devicectl / log stream --predicate 'eventMessage CONTAINS "[DEBUG-col]"'
/// ```
enum ColumnProbe {
    private static var lastDrawLog: Double = 0
    /// Four a second: enough to watch a boundary move, few enough to read.
    private static let interval: Double = 0.25

    /// One chapter, once, as its layout pass left it.
    static func placed(_ index: Int, report: String) {
        NSLog("[DEBUG-col] placed idx=%d %@", index, report)
    }

    /// One drawn window, throttled.
    ///
    /// `drawn` against `of` says whether the draw list was short; `lastY` against the
    /// window's foot says whether it was short because the text ran out or because the
    /// window was believed to be smaller than it is.
    static func drew(
        window: CGRect, drawn: Int, of total: Int,
        firstY: CGFloat?, lastY: CGFloat?, height: CGFloat
    ) {
        let now = CACurrentMediaTime()
        guard now - lastDrawLog >= interval else { return }
        lastDrawLog = now
        NSLog(
            "[DEBUG-col] draw window=%.0f..%.0f (h=%.0f) drawn=%d/%d "
                + "firstY=%.0f lastY=%.0f columnHeight=%.0f",
            window.minY, window.maxY, window.height, drawn, total,
            firstY ?? -1, lastY ?? -1, height
        )
    }

    /// The scroll view's own numbers, for the same beat: if the window handed to the
    /// column is short, this says whether it was short on arrival.
    static func viewport(bounds: CGRect, offset: CGFloat, contentHeight: CGFloat, canvas: CGRect) {
        NSLog(
            "[DEBUG-col] viewport bounds=%.0fx%.0f offset=%.0f content=%.0f "
                + "canvas=(%.0f,%.0f %.0fx%.0f)",
            bounds.width, bounds.height, offset, contentHeight,
            canvas.minX, canvas.minY, canvas.width, canvas.height
        )
    }
}
#endif
