#if DEBUG
import UIKit

/// A dot under every finger, for recording the App Store preview.
///
/// A preview is a recording of the simulator, and the simulator draws no fingers: a
/// walk driven by XCUITest is a screen that changes by itself, which a viewer reads as
/// an animation rather than as something they could do. The dot is what turns "the page
/// went dark" into "I can make the page go dark".
///
/// Drawn by the app rather than composited onto the video afterwards, because only the
/// app knows where a touch landed — the test knows where it *aimed*, which is a
/// different point whenever a drag has momentum or a row moved while it was reached for.
///
/// `#if DEBUG` plus a launch argument, like `DemoSeed`: not in a Release binary, and a
/// Debug build is untouched unless asked.
enum TouchIndicator {
    nonisolated static let launchArgument = "-NovelReaderShowTouches"

    /// Watches for windows rather than taking one: the key window does not exist yet when
    /// the app delegate runs, and a scene can bring up another later.
    static func armIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains(launchArgument) else { return }
        NotificationCenter.default.addObserver(
            forName: UIWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { note in
            guard let window = note.object as? UIWindow else { return }
            MainActor.assumeIsolated {
                guard !(window.gestureRecognizers ?? []).contains(where: { $0 is Watcher }) else {
                    return
                }
                window.addGestureRecognizer(Watcher())
            }
        }
    }
}

/// Sees every touch in the window and takes part in none of them.
///
/// A gesture recognizer on the window rather than a `sendEvent` override, because the
/// window is SwiftUI's to create and cannot be subclassed from here. It never leaves
/// `.possible` while a finger is down, delays nothing, cancels nothing and neither
/// prevents nor can be prevented — so every recognizer in the app sees exactly the touch
/// sequence it would have without it, which is the point of recording the real app.
private final class Watcher: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private var dots: [ObjectIdentifier: CALayer] = [:]

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let window = view else { return }
        for touch in touches {
            let dot = Self.dot()
            dot.position = touch.location(in: window)
            // Above every presented sheet: those are later subviews of the same window,
            // and a layer's z-position outranks the order its siblings were added in.
            dot.zPosition = 10_000
            window.layer.addSublayer(dot)
            dots[ObjectIdentifier(touch)] = dot
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.6
            grow.duration = 0.12
            dot.add(grow, forKey: nil)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let window = view else { return }
        CATransaction.begin()
        // Follows the finger exactly: the implicit quarter-second animation a layer
        // property change gets would draw the dot trailing behind a drag.
        CATransaction.setDisableActions(true)
        for touch in touches { dots[ObjectIdentifier(touch)]?.position = touch.location(in: window) }
        CATransaction.commit()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches) }

    override func reset() {
        super.reset()
        for dot in dots.values { dot.removeFromSuperlayer() }
        dots.removeAll()
    }

    /// Fades rather than vanishes. A synthesized tap is down for a frame or two, which a
    /// 30fps recording can miss entirely; the fade is what makes a tap visible at all.
    private func lift(_ touches: Set<UITouch>) {
        for touch in touches {
            guard let dot = dots.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.35)
            CATransaction.setCompletionBlock { dot.removeFromSuperlayer() }
            dot.opacity = 0
            dot.transform = CATransform3DMakeScale(1.35, 1.35, 1)
            CATransaction.commit()
        }
        if dots.isEmpty { state = .failed }
    }

    /// Readable on the light page, the dark one and a photograph: a pale fill with a white
    /// rim and a soft shadow, rather than one colour that vanishes on one of them.
    private static func dot() -> CALayer {
        let size: CGFloat = 44
        let dot = CALayer()
        dot.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        dot.cornerRadius = size / 2
        dot.backgroundColor = UIColor(white: 0.55, alpha: 0.45).cgColor
        dot.borderColor = UIColor(white: 1, alpha: 0.9).cgColor
        dot.borderWidth = 2
        dot.shadowColor = UIColor.black.cgColor
        dot.shadowOpacity = 0.25
        dot.shadowRadius = 4
        dot.shadowOffset = .zero
        return dot
    }
}
#endif
