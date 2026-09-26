import SwiftUI

/// A settings title with a "?" after it, for an explanation longer than one short sentence.
///
/// One sentence stays a footer, where it is read in passing. Anything longer turned the
/// settings screens into columns of grey text under every control, which is read by
/// nobody — so it waits behind the title it explains, for the reader who wants it.
struct HelpLabel: View {
    let title: LocalizedStringKey
    let help: LocalizedStringKey

    init(_ title: LocalizedStringKey, help: LocalizedStringKey) {
        self.title = title
        self.help = help
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            HelpButton(help)
        }
    }
}

/// The "?" itself: the explanation in a small bubble, gone after ten seconds or at a tap.
///
/// Presented by UIKit rather than with SwiftUI's `.popover`. On every screen pushed below
/// the settings root, `.popover` put the bubble up and took it down again within half a
/// second — measured: the action ran, the content was hosted three times over, and the
/// system set the binding back to false — while the same button on the root screen
/// worked. A popover UIKit owns is not tied to SwiftUI's updates, so only the reader, or
/// the ten seconds, closes it.
struct HelpButton: View {
    let help: LocalizedStringKey
    @State private var anchor = HelpAnchor()

    init(_ help: LocalizedStringKey) {
        self.help = help
    }

    var body: some View {
        Button {
            anchor.present(help)
        } label: {
            Image(systemName: "questionmark.circle")
        }
        // Borderless, or a row holding this beside a control answers every tap with both.
        .buttonStyle(.borderless)
        // A header's glyph is a small target; the bubble should not take aiming.
        .contentShape(Rectangle().inset(by: -10))
        .background(HelpAnchorView(anchor: anchor))
        .accessibilityLabel(Text("common.help"))
        .accessibilityIdentifier("help")
    }
}

/// The UIKit view behind the "?" that the bubble points at, and the presenting of it.
@MainActor
private final class HelpAnchor {
    weak var view: UIView?

    func present(_ help: LocalizedStringKey) {
        guard let view,
              let presenter = sequence(first: view as UIResponder, next: { $0.next })
                  .lazy.compactMap({ $0 as? UIViewController }).first,
              presenter.presentedViewController == nil
        else { return }
        let bubble = HelpBubble(help)
        bubble.modalPresentationStyle = .popover
        if let popover = bubble.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = view.bounds
            popover.delegate = bubble
        }
        presenter.present(bubble, animated: true)
    }
}

private struct HelpAnchorView: UIViewRepresentable {
    let anchor: HelpAnchor

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        anchor.view = view
    }
}

private final class HelpBubble: UIHostingController<HelpBubbleText>,
    UIPopoverPresentationControllerDelegate {
    init(_ help: LocalizedStringKey) {
        super.init(rootView: HelpBubbleText(help: help))
        rootView.close = { [weak self] in self?.close() }
        sizingOptions = .preferredContentSize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Not timed away from someone listening to it: VoiceOver reads at its own pace,
        // and a bubble that closes mid-sentence cannot be read at all.
        guard !UIAccessibility.isVoiceOverRunning else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            self?.close()
        }
    }

    private func close() {
        guard presentingViewController != nil, !isBeingDismissed else { return }
        dismiss(animated: true)
    }

    /// A bubble on a phone too, rather than a sheet for three lines of text.
    func adaptivePresentationStyle(
        for controller: UIPresentationController, traitCollection: UITraitCollection
    ) -> UIModalPresentationStyle {
        .none
    }
}

private struct HelpBubbleText: View {
    let help: LocalizedStringKey
    var close: () -> Void = {}

    var body: some View {
        Text(help)
            .font(.callout)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 280, alignment: .leading)
            .padding()
            .contentShape(.rect)
            .onTapGesture { close() }
            .accessibilityIdentifier("help.text")
    }
}
