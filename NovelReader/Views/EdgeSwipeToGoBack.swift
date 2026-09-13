import SwiftUI

/// Hands the leading edge back to the navigation controller on a screen that has hidden
/// its navigation bar.
///
/// Both readers hide that bar deliberately: one that comes and goes changes the safe area,
/// which moves every line of text under the reader and re-measures the page breaks. The
/// cost, measured rather than reasoned about, is that the swipe every other iOS screen is
/// left by stops working. Made visible on the same screen the swipe works and nothing else
/// changes, which is what says the bar is the whole of the reason.
///
/// What actually refuses is UIKit's own delegate for the gesture. The recognizer is
/// enabled the entire time — `_UIParallaxTransitionPanGestureRecognizer`, still listening
/// — and `_UINavigationInteractiveTransition` is what declines to begin while the bar is
/// hidden. So the delegate is borrowed for as long as the reader wants the gesture, and
/// given straight back. Borrowed rather than replaced: it belongs to the navigation
/// controller, which outlives this screen and governs every other one on the stack.
///
/// Nothing is touched at all unless `ReaderSettings.swipeToGoBack` is on, so a reader who
/// never asked for this gets the app exactly as UIKit arranges it.
struct EdgeSwipeToGoBack: UIViewControllerRepresentable {
    let isEnabled: Bool

    func makeUIViewController(context: Context) -> Host {
        let host = Host()
        host.view.isUserInteractionEnabled = false
        host.view.backgroundColor = .clear
        host.onAppear = { [coordinator = context.coordinator] navigation in
            coordinator.arrived(on: navigation)
        }
        host.onDisappear = { [coordinator = context.coordinator] in coordinator.left() }
        return host
    }

    func updateUIViewController(_ host: Host, context: Context) {
        // Only the answer, never the finding: asked here, `navigationController` is nil.
        // SwiftUI runs this during the first layout pass, before the screen holding it
        // has been attached to the stack — measured, not assumed, and the reason the
        // stack is found from `viewDidAppear` instead.
        context.coordinator.isEnabled = isEnabled
    }

    static func dismantleUIViewController(_ host: Host, coordinator: Coordinator) {
        coordinator.left()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Draws nothing and takes no touches. It exists in order to be *somewhere*: a view
    /// controller in the hierarchy is the only thing that can be asked which stack it is
    /// on, and `viewDidAppear` is the earliest moment it has an answer.
    final class Host: UIViewController {
        var onAppear: ((UINavigationController?) -> Void)?
        var onDisappear: (() -> Void)?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onAppear?(navigationController)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            // Given back on the way out rather than only when torn down. A cancelled
            // interactive pop brings this screen back and `viewDidAppear` asks again, so
            // the borrowing follows what is actually on screen.
            onDisappear?()
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// Changeable while the reader is open — the settings panel is one sheet away —
        /// so the edge is taken and given back as the answer moves.
        var isEnabled = false {
            didSet { if isEnabled != oldValue { sync() } }
        }
        private weak var navigation: UINavigationController?
        private weak var lender: (any UIGestureRecognizerDelegate)?
        private var isBorrowing = false

        func arrived(on navigation: UINavigationController?) {
            guard navigation !== self.navigation else { return sync() }
            left()
            self.navigation = navigation
            sync()
        }

        func left() {
            handBack()
            navigation = nil
        }

        private func sync() {
            isEnabled ? borrow() : handBack()
        }

        private func borrow() {
            guard !isBorrowing, let gesture = navigation?.interactivePopGestureRecognizer
            else { return }
            lender = gesture.delegate
            gesture.delegate = self
            isBorrowing = true
        }

        private func handBack() {
            guard isBorrowing else { return }
            navigation?.interactivePopGestureRecognizer?.delegate = lender
            lender = nil
            isBorrowing = false
        }

        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard isEnabled, let navigation else { return false }
            // Never with nothing behind it. A pop that cannot happen leaves UIKit part way
            // through a transition it will not finish, and every push after that is
            // refused — the failure this delegate is famous for, and the reason to answer
            // the question rather than simply say yes.
            return navigation.viewControllers.count > 1
        }
    }
}

extension View {
    /// Puts the leading edge back in the navigation controller's hands, on a screen that
    /// has taken the navigation bar away from it. Draws nothing.
    func edgeSwipeGoesBack(_ isEnabled: Bool) -> some View {
        background {
            EdgeSwipeToGoBack(isEnabled: isEnabled).frame(width: 0, height: 0)
        }
    }
}
