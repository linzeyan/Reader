import UIKit

/// The two grips at the ends of a selection, and the drag that moves one.
///
/// Shared by both renderers because what a grip is — where it is drawn, how much of the
/// glass around it answers to a thumb, and the loupe that shows what the thumb is hiding
/// — belongs to the reader's hand rather than to either layout. Each renderer answers the
/// two things only it can: where the ends of its selection are, and what a grip dragged
/// to a point has moved them to.
@MainActor
final class SelectionGrips: NSObject, UIGestureRecognizerDelegate {
    enum End {
        case start
        case end
    }

    /// No `cancelled`, unlike a press. A grip is on a passage that was a real selection
    /// before it was taken hold of and is one after, so a touch the system takes away —
    /// a call coming in — leaves it wherever it had got to, and the bar asks about that.
    enum Phase {
        case began
        case moved
        case ended
    }

    /// The two ends of a selection as the line-high slivers a caret would occupy, in the
    /// host view's coordinates. Nil for an end the host is not showing — the far end of a
    /// passage that runs onto another page, or into a chapter scrolled out of the stack.
    struct Carets {
        var start: CGRect?
        var end: CGRect?
    }

    /// Where the ends are right now. Asked when a finger comes down, so it is only ever
    /// asked about a selection the reader can see.
    var carets: () -> Carets? = { nil }

    /// A grip moved. The point is where the grabbed end's caret is being aimed: the
    /// finger plus the distance it took hold at, so the caret stays where the thumb
    /// found it instead of jumping under the thumb — which is the text the loupe is
    /// there to show.
    var onDrag: (End, CGPoint, Phase) -> Void = { _, _, _ in }

    private weak var host: UIView?
    private var grabbed: End?
    private var grip: CGSize = .zero
    private var loupe: UITextLoupeSession?

    init(host: UIView) {
        self.host = host
        super.init()
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(hold(_:)))
        // On contact. A grip is a thing to take hold of rather than a gesture to wait
        // out, and a recogniser that begins on touch-down is one the scroll, the page
        // turn and the long press never get the chance to claim.
        hold.minimumPressDuration = 0
        hold.allowableMovement = .greatestFiniteMagnitude
        hold.delegate = self
        host.addGestureRecognizer(hold)
    }

    /// Only a touch that lands on a grip. Every other touch never meets this recogniser
    /// at all, so nothing about tapping, pressing or scrolling the text changes because
    /// grips exist.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch
    ) -> Bool {
        guard let host, let carets = carets() else { return false }
        return Self.end(at: touch.location(in: host), of: carets) != nil
    }

    @objc private func hold(_ gesture: UILongPressGestureRecognizer) {
        guard let host else { return }
        let point = gesture.location(in: host)
        switch gesture.state {
        case .began:
            guard let carets = carets(), let end = Self.end(at: point, of: carets),
                  let caret = end == .start ? carets.start : carets.end
            else { return }
            grabbed = end
            let aim = CGPoint(x: caret.midX, y: caret.midY)
            grip = CGSize(width: aim.x - point.x, height: aim.y - point.y)
            loupe = UITextLoupeSession.begin(at: aim, fromSelectionWidgetView: nil, in: host)
            onDrag(end, aim, .began)
        case .changed:
            guard let grabbed else { return }
            let aim = aimed(point)
            // The caret, not the touch: the thumb is on the knob, outside the line, and
            // the loupe is for the characters the caret is moving between.
            loupe?.move(to: aim, withCaretRect: .null, trackingCaret: false)
            onDrag(grabbed, aim, .moved)
        case .ended, .cancelled, .failed:
            guard let grabbed else { return }
            self.grabbed = nil
            hideLoupe()
            onDrag(grabbed, aimed(point), .ended)
        default:
            break
        }
    }

    private func aimed(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x + grip.width, y: point.y + grip.height)
    }

    // MARK: - Loupe

    /// The loupe for a press that is still sliding, which has no grip to hold it: the
    /// same magnifier, over the point under the finger.
    func showLoupe(at point: CGPoint) {
        guard let host else { return }
        if let loupe {
            loupe.move(to: point, withCaretRect: .null, trackingCaret: false)
        } else {
            loupe = UITextLoupeSession.begin(at: point, fromSelectionWidgetView: nil, in: host)
        }
    }

    func hideLoupe() {
        loupe?.invalidate()
        loupe = nil
    }

    // MARK: - Geometry

    private static let knobRadius: CGFloat = 5
    private static let barWidth: CGFloat = 2

    /// The grip a point takes hold of, if any.
    ///
    /// Generous, because a grip is a sliver and a thumb is not: a thumb's width across
    /// the bar, and from beyond the knob to just past the far edge of the line. The
    /// nearer of the two when a short passage puts both within reach.
    static func end(at point: CGPoint, of carets: Carets) -> End? {
        let reach: CGFloat = 22
        let candidates: [(End, CGRect)] = [
            carets.start.map {
                (.start, CGRect(
                    x: $0.midX - reach, y: $0.minY - reach - knobRadius,
                    width: reach * 2, height: $0.height + reach + knobRadius + 4
                ))
            },
            carets.end.map {
                (.end, CGRect(
                    x: $0.midX - reach, y: $0.minY - 4,
                    width: reach * 2, height: $0.height + reach + knobRadius + 4
                ))
            },
        ].compactMap { $0 }
        return candidates
            .filter { $0.1.contains(point) }
            .min { hypot($0.1.midX - point.x, $0.1.midY - point.y)
                < hypot($1.1.midX - point.x, $1.1.midY - point.y) }?
            .0
    }

    /// Draws both grips: a bar the height of the caret, and a knob on the outside of the
    /// passage — above its first character, below its last — where a thumb can hold it
    /// without covering the text being picked out.
    ///
    /// The knob is kept inside `bounds`. Both renderers draw into a view exactly as wide
    /// as the text, so a passage that starts at the left edge would otherwise have half
    /// its knob cut away — and a half-knob reads as something broken, not as a handle.
    static func draw(
        _ carets: Carets, color: UIColor, keptInside bounds: CGRect, in context: CGContext
    ) {
        context.saveGState()
        color.setFill()
        for (caret, above) in [(carets.start, true), (carets.end, false)] {
            guard let caret else { continue }
            let x = min(max(caret.midX, bounds.minX + barWidth / 2), bounds.maxX - barWidth / 2)
            // A path rather than `UIRectFill`, which fills in copy mode and would punch
            // a hole through the page on a picture or gradient background.
            UIBezierPath(rect: CGRect(
                x: x - barWidth / 2, y: caret.minY, width: barWidth, height: caret.height
            )).fill()
            let center = CGPoint(
                x: min(max(x, bounds.minX + knobRadius), bounds.maxX - knobRadius),
                y: min(
                    max(
                        above ? caret.minY - knobRadius : caret.maxY + knobRadius,
                        bounds.minY + knobRadius
                    ),
                    bounds.maxY - knobRadius
                )
            )
            UIBezierPath(
                arcCenter: center, radius: knobRadius, startAngle: 0, endAngle: .pi * 2,
                clockwise: true
            ).fill()
        }
        context.restoreGState()
    }
}
