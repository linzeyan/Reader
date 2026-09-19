import SwiftUI

/// Arranging one layer's bottom bar: what order its controls are in, and which of them are
/// folded away behind the last button.
///
/// One list rather than two sections of "on the bar" and "folded away". Dragging between
/// two sections is not something a `List` offers — each `onMove` belongs to its own
/// `ForEach` — and the arrangement is one order anyway: a folded control keeps its place,
/// because that place is where it sits in the menu behind the last button.
///
/// A pushed screen rather than rows in the settings sheet, because reordering wants the
/// whole width and the sheet it is reached from is half a screen tall.
struct ReaderToolbarEditor: View {
    @Bindable var settings: ReaderSettings
    let layer: ReaderSettings.Layer

    var body: some View {
        List {
            Section {
                ForEach(arrangement) { button in
                    row(button)
                }
                .onMove(perform: move)
            } header: {
                Text("reader.toolbar.order")
            } footer: {
                // The whole of what the editor promises, and the thing a reader cannot
                // work out from a list of switches: nothing is ever lost by folding it.
                Text("reader.toolbar.footer")
            }

            Section {
                followLine
            }
        }
        // Always on, because there is nothing here to select: a list whose only gesture is
        // the drag handle should show the handle.
        .environment(\.editMode, .constant(.active))
        .navigationTitle("reader.toolbar")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("reader.toolbar.editor")
    }

    // MARK: - One control

    private func row(_ button: ReaderButton) -> some View {
        let folded = layout.isFolded(button)
        let dimmed = folded ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
        return HStack(spacing: 12) {
            Image(systemName: button.icon)
                .font(.system(size: 17))
                .frame(width: 28)
                .foregroundStyle(dimmed)
            VStack(alignment: .leading, spacing: 2) {
                Text(button.nameKey).foregroundStyle(dimmed)
                // Said on every row it applies to rather than once in the footer: a reader
                // wondering why a control they turned on is not there is looking at that
                // control's row, not at the bottom of the screen.
                if let whenKey = button.whenKey {
                    Text(whenKey).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            // Borderless, and only the glyph rather than the whole row: a row in edit mode
            // carries a drag handle, and a row-sized button would swallow the drag.
            Button {
                fold(button, away: !folded)
            } label: {
                Image(systemName: folded ? "ellipsis.circle" : "checkmark.circle.fill")
                    .foregroundStyle(folded ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text(folded ? "reader.toolbar.show" : "reader.toolbar.fold"))
            .accessibilityIdentifier("reader.toolbar.\(button.rawValue)")
        }
    }

    /// What this layer would arrange its bar as if it were following, and the way back to
    /// following — `ReadingOverrideSections.followLine` in the one place that cannot use
    /// it, because what is followed here is a whole arrangement rather than one value.
    @ViewBuilder
    private var followLine: some View {
        if case .general = layer {
            // The bottom of the chain follows nobody, and a row saying so would be a
            // control that never does anything.
            EmptyView()
        } else {
            let label = isBook
                ? Text("reader.toolbar.follow.shelf")
                : Text("reader.toolbar.follow.defaults")
            if settings.overrides(of: layer).toolbar != nil {
                Button {
                    write(nil)
                } label: {
                    Label { label } icon: { Image(systemName: "arrow.uturn.backward") }
                }
                .accessibilityIdentifier("reader.toolbar.follow")
            } else {
                label.foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Reading and writing this layer

    private var layout: ReaderToolbarLayout { settings.toolbar(of: layer) }

    /// Every control this layer can arrange. The general answers are not about one shelf,
    /// so they list them all — each shelf then takes the subset it has.
    private var arrangement: [ReaderButton] { layout.arrangement(for: layer.kind) }

    private func move(from source: IndexSet, to destination: Int) {
        var order = arrangement
        order.move(fromOffsets: source, toOffset: destination)
        write(ReaderToolbarLayout(order: order, folded: order.filter(layout.isFolded)))
    }

    private func fold(_ button: ReaderButton, away: Bool) {
        let order = arrangement
        var folded = order.filter(layout.isFolded)
        folded.removeAll { $0 == button }
        if away { folded.append(button) }
        // Written in the arrangement's order rather than in the order they were folded, so
        // the menu behind the last button reads down the bar the reader arranged.
        write(ReaderToolbarLayout(order: order, folded: order.filter(folded.contains)))
    }

    /// Writes this layer's arrangement, or takes it off having one.
    ///
    /// The general answers are a property rather than an override — they are the bottom of
    /// the chain, not a layer sitting on it — so they are written where they live. Nil
    /// there would mean "follow nothing", which is not a state that exists.
    private func write(_ arrangement: ReaderToolbarLayout?) {
        guard case .general = layer else {
            var overrides = settings.overrides(of: layer)
            // An arrangement that says nothing is stored as nil: a reader who moved a
            // control and then put it back is following again, not pinned to the order
            // today's default happens to hold.
            overrides.toolbar = arrangement.flatMap { $0.isEmpty ? nil : $0 }
            settings.setOverrides(overrides, of: layer)
            return
        }
        settings.toolbar = arrangement ?? .standard
    }

    private var isBook: Bool {
        if case .book = layer { return true }
        return false
    }
}
