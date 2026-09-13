import SwiftUI

/// One layer's own answers: a shelf's, or a single book's.
///
/// The same controls the general settings offer, minus the ones neither a shelf nor a book
/// has an opinion on — the script conversion, the way out of a book, the screen. See
/// `ReaderSettings.Overrides`. Each control sits over a line naming what it would read with
/// if it had not been asked, which is also the way back to following.
///
/// One view for both layers rather than two nearly identical ones. What differs between a
/// shelf and a book is which layer is written and which one is followed, and `layer`
/// carries both.
struct ReadingOverrideSections: View {
    @Bindable var settings: ReaderSettings
    let layer: ReaderSettings.Layer

    var body: some View {
        // A comic has no type to set: the pages are pictures, so the mode, the face, the
        // spacings and the surface all describe text that is not there. How it is turned is
        // the one question a comic answers, so it is the only one put.
        if layer.kind == .comic {
            pageTurnSection
        } else {
            modeSection
            textSection
            themeSection
            pageTurnSection
        }
    }

    // MARK: - The controls

    private var modeSection: some View {
        Section {
            Picker("reader.settings.mode", selection: binding(\.mode, general: \.mode)) {
                ForEach(ReaderSettings.Mode.allCases) { mode in
                    Text(mode.nameKey).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("reader.settings.mode")

            followLine(
                String(localized: inherited(\.mode, general: \.mode).nameKey),
                revert: revert(\.mode)
            )
        } header: {
            // The general settings' reason, and one more here: a shelf or a book shows
            // fewer sections, so the picker can end up with nothing around it to say what
            // it is about.
            Text("reader.settings.mode")
        } footer: {
            Text("reader.settings.mode.footer")
        }
    }

    private var textSection: some View {
        Section("reader.settings.text") {
            Picker("reader.settings.font", selection: face) {
                Text("reader.settings.font.system").tag(String?.none)
                ForEach(FontCatalog.chinese) { entry in
                    // Each name is drawn in its own face: the sample is the only thing that
                    // actually tells you what you are picking.
                    Text(entry.displayName)
                        .font(.custom(entry.fontName, fixedSize: 17))
                        .tag(String?.some(entry.fontName))
                }
            }
            .accessibilityIdentifier("reader.settings.font")

            followLine(
                Self.faceName(settings.fontName(of: layer.above)),
                revert: revert(\.fontName)
            )

            LabeledContent("reader.settings.fontSize") {
                Text("\(Int(shown(\.fontSize, general: \.fontSize)))")
            }
            Slider(
                value: binding(\.fontSize, general: \.fontSize),
                in: ReaderSettings.fontSizeRange,
                step: 1
            ) {
                Text("reader.settings.fontSize")
            } minimumValueLabel: {
                Image(systemName: "textformat.size.smaller")
            } maximumValueLabel: {
                Image(systemName: "textformat.size.larger")
            }

            followLine(
                "\(Int(inherited(\.fontSize, general: \.fontSize)))",
                revert: revert(\.fontSize)
            )

            LabeledContent("reader.settings.lineSpacing") {
                Text("\(Int(shown(\.lineSpacing, general: \.lineSpacing)))")
            }
            Slider(value: binding(\.lineSpacing, general: \.lineSpacing), in: 0...20, step: 1)

            followLine(
                "\(Int(inherited(\.lineSpacing, general: \.lineSpacing)))",
                revert: revert(\.lineSpacing)
            )

            LabeledContent("reader.settings.paragraphSpacing") {
                Text("\(Int(shown(\.paragraphSpacing, general: \.paragraphSpacing)))")
            }
            Slider(
                value: binding(\.paragraphSpacing, general: \.paragraphSpacing),
                in: 0...32,
                step: 2
            )

            followLine(
                "\(Int(inherited(\.paragraphSpacing, general: \.paragraphSpacing)))",
                revert: revert(\.paragraphSpacing)
            )
        }
    }

    private var themeSection: some View {
        Section {
            ThemePicker(settings: settings, selection: binding(\.theme, general: \.theme))
            // Reachable from here too, because this layer can be set to the custom palette
            // from the row above and would otherwise be pinned to colours it has no way to
            // see, let alone change. What it opens is the one shared palette, which is what
            // the footer is for.
            NavigationLink("reader.theme.custom.edit") {
                ReaderThemeEditor(settings: settings)
            }
            .accessibilityIdentifier("reader.settings.customTheme")

            followLine(
                String(localized: inherited(\.theme, general: \.theme).nameKey),
                revert: revert(\.theme)
            )
        } header: {
            Text("reader.settings.theme")
        } footer: {
            Text("reader.settings.theme.custom.shared")
        }
    }

    private var pageTurnSection: some View {
        Section {
            Picker(
                "reader.settings.pageTurn", selection: binding(\.pageTurn, general: \.pageTurn)
            ) {
                ForEach(ReaderSettings.PageTurn.allCases) { turn in
                    Text(turn.nameKey).tag(turn)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("reader.settings.pageTurn")

            followLine(
                String(localized: inherited(\.pageTurn, general: \.pageTurn).nameKey),
                revert: revert(\.pageTurn)
            )
        } header: {
            Text("reader.settings.pageTurn")
        } footer: {
            Text("reader.settings.pageTurn.footer")
        }
    }

    // MARK: - Reading and writing this layer

    /// What the control shows: the *resolved* value. A control has to show something, and
    /// what this layer is being read with right now is the only honest answer.
    private func shown<Value>(
        _ field: KeyPath<ReaderSettings.Overrides, Value?>,
        general: KeyPath<ReaderSettings, Value>
    ) -> Value {
        settings.value(field, of: layer, general: general)
    }

    /// What this layer would read with if it were following — what the line under the
    /// control names.
    private func inherited<Value>(
        _ field: KeyPath<ReaderSettings.Overrides, Value?>,
        general: KeyPath<ReaderSettings, Value>
    ) -> Value {
        settings.value(field, of: layer.above, general: general)
    }

    /// Shows the resolved value and writes an override, because moving one of these is
    /// exactly what taking this layer off what it follows means.
    private func binding<Value>(
        _ field: WritableKeyPath<ReaderSettings.Overrides, Value?>,
        general: KeyPath<ReaderSettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { shown(field, general: general) },
            set: { write(field, $0) }
        )
    }

    /// The face, where nil is the system one — a real choice rather than an absence, which
    /// is why it is written down as the empty string. See `ReaderSettings.Overrides`.
    private var face: Binding<String?> {
        Binding(
            get: { settings.fontName(of: layer) },
            set: { write(\.fontName, $0 ?? "") }
        )
    }

    private func write<Value>(
        _ field: WritableKeyPath<ReaderSettings.Overrides, Value?>, _ value: Value?
    ) {
        var overrides = settings.overrides(of: layer)
        overrides[keyPath: field] = value
        settings.setOverrides(overrides, of: layer)
    }

    /// The way back to following for one field, or nil where it is already following.
    /// `write(field, nil)` by another name, because following is what the reader asked for
    /// and nil is only how it is stored.
    private func revert<Value>(
        _ field: WritableKeyPath<ReaderSettings.Overrides, Value?>
    ) -> (() -> Void)? {
        guard settings.overrides(of: layer)[keyPath: field] != nil else { return nil }
        return { write(field, nil) }
    }

    // MARK: - Saying what is being followed

    /// The line under one of these controls, naming what it would read with otherwise —
    /// and, once this layer has been given its own answer, the way back.
    ///
    /// There in both states, because a control showing an inherited value looks exactly like
    /// one showing a chosen value. The line names what is above it either way; that it
    /// becomes tappable is what says this layer has stopped following.
    @ViewBuilder
    private func followLine(_ inherited: String, revert: (() -> Void)?) -> some View {
        // Which layer is being followed, by name. A book follows its shelf, and "follow the
        // default" under a book whose shelf has an answer of its own would name something
        // the reader would then go and fail to find.
        let label = isBook
            ? Text("reader.settings.follow.shelf \(inherited)")
            : Text("reader.settings.follow.defaults \(inherited)")
        if let revert {
            Button(action: revert) {
                Label { label } icon: { Image(systemName: "arrow.uturn.backward") }
            }
            .font(.footnote)
        } else {
            label
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var isBook: Bool {
        if case .book = layer { return true }
        return false
    }

    /// A face as the picker names it: the family a reader would recognise, or the system
    /// row's own label, so that "follow the shelf (系統字體)" reads like the row above it
    /// rather than like a PostScript name.
    private static func faceName(_ fontName: String?) -> String {
        guard let fontName else { return String(localized: "reader.settings.font.system") }
        return FontCatalog.chinese.first { $0.fontName == fontName }?.displayName ?? fontName
    }
}
