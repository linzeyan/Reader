import SwiftUI

/// The reading appearance controls, in one place.
///
/// Shared verbatim by the reader's own sheet and by Settings → Appearance.
/// Two copies of these controls would drift, and "the font picker in Settings
/// has one more option than the one in the reader" is exactly the kind of bug
/// nobody files and everybody notices.
struct ReadingAppearanceSections: View {
    @Bindable var settings: ReaderSettings

    var body: some View {
        Group {
            Section {
                // First, and segmented: it is the one setting here that changes how
                // the page behaves rather than how it looks, and the rest of this
                // form reads differently depending on which side it is on.
                Picker("reader.settings.mode", selection: $settings.mode) {
                    ForEach(ReaderSettings.Mode.allCases) { mode in
                        Text(mode.nameKey).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("reader.settings.mode")
            } footer: {
                // The one place the asymmetry between the two renderers can be stated
                // where it is actionable. Both modes make marks and both show them; how
                // finely they can aim differs, because only the paginated renderer knows
                // where each character sits — and the moment a reader picks a mode is the
                // moment that difference is worth knowing, rather than after they press a
                // paragraph and get more of it than they meant.
                Text("reader.settings.mode.footer")
            }

            Section("reader.settings.text") {
                Picker("reader.settings.font", selection: $settings.fontName) {
                    Text("reader.settings.font.system").tag(String?.none)
                    ForEach(FontCatalog.chinese) { entry in
                        // Each name is drawn in its own face: the sample is the
                        // only thing that actually tells you what you are picking.
                        Text(entry.displayName)
                            .font(.custom(entry.fontName, fixedSize: 17))
                            .tag(String?.some(entry.fontName))
                    }
                }
                .accessibilityIdentifier("reader.settings.font")

                LabeledContent("reader.settings.fontSize") {
                    Text("\(Int(settings.fontSize))")
                }
                Slider(
                    value: $settings.fontSize,
                    in: ReaderSettings.fontSizeRange,
                    step: 1
                ) {
                    Text("reader.settings.fontSize")
                } minimumValueLabel: {
                    Image(systemName: "textformat.size.smaller")
                } maximumValueLabel: {
                    Image(systemName: "textformat.size.larger")
                }

                LabeledContent("reader.settings.lineSpacing") {
                    Text("\(Int(settings.lineSpacing))")
                }
                Slider(value: $settings.lineSpacing, in: 0...20, step: 1)

                LabeledContent("reader.settings.paragraphSpacing") {
                    Text("\(Int(settings.paragraphSpacing))")
                }
                Slider(value: $settings.paragraphSpacing, in: 0...32, step: 2)
            }

            Section {
                Picker("reader.settings.chinese", selection: $settings.chineseScript.depth) {
                    ForEach(ChineseScript.Depth.allCases) { depth in
                        Text(depth.nameKey).tag(depth)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("reader.settings.chinese.depth")

                // Only where it means something. A direction to convert *to* is not a
                // choice a reader who is not converting has, and showing it greyed out
                // would just be a second thing to read past.
                if settings.chineseScript.depth != .off {
                    Picker(
                        "reader.settings.chinese.target",
                        selection: $settings.chineseScript.target
                    ) {
                        ForEach(ChineseScript.Target.allCases) { target in
                            Text(target.nameKey).tag(target)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("reader.settings.chinese.target")
                }
            } header: {
                Text("reader.settings.chinese")
            } footer: {
                // The difference between the two tiers is one example long, and the
                // example is the only form of it anybody can act on.
                Text("reader.settings.chinese.footer")
            }

            Section("reader.settings.theme") {
                ThemePicker(settings: settings)
                NavigationLink("reader.theme.custom.edit") {
                    ReaderThemeEditor(settings: settings)
                }
                .accessibilityIdentifier("reader.settings.customTheme")
            }

            // Only where it can do anything. Paginated reading turns pages by tapping
            // already and cannot be talked out of it, so offering the switch there would
            // be offering to turn off something that is not on.
            if settings.mode == .scroll {
                Section {
                    Toggle("reader.settings.tapToTurn", isOn: $settings.tapToTurnPage)
                        .accessibilityIdentifier("reader.settings.tapToTurn")
                } footer: {
                    // Which part of the screen does what, said once, here. A reader who
                    // has to find the zones by tapping finds the wrong one first.
                    Text("reader.settings.tapToTurn.footer")
                }
            }

            Section {
                Toggle("reader.settings.keepScreenOn", isOn: $settings.keepScreenOn)
                    .onChange(of: settings.keepScreenOn) { _, on in
                        UIApplication.shared.isIdleTimerDisabled = on
                    }
            }
        }
    }
}

/// Themes as swatches rather than a segmented control.
///
/// A colour is not something a word describes well — "淺色" and "自訂" mean nothing until
/// you see them — so each swatch is drawn in the surface it selects, and the custom one
/// shows whatever the reader last built. The row is a preview of the choice rather than
/// a list of names.
struct ThemePicker: View {
    @Bindable var settings: ReaderSettings
    /// What the theme that follows the system would resolve to. Inside the reader this
    /// reads back whatever `preferredColorScheme` is forcing, so the 跟隨系統 swatch
    /// previews the theme in force rather than the device's — which is what it becomes
    /// the moment it is tapped and the forcing goes away.
    @Environment(\.colorScheme) private var systemColorScheme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(ReaderSettings.Theme.allCases) { theme in
                    Button {
                        settings.theme = theme
                    } label: {
                        swatch(theme)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(theme.nameKey))
                    .accessibilityAddTraits(theme == settings.theme ? [.isSelected] : [])
                }
            }
            .padding(.vertical, 6)
        }
        .accessibilityIdentifier("reader.settings.themes")
    }

    private func swatch(_ theme: ReaderSettings.Theme) -> some View {
        let palette = preview(of: theme)
        let selected = theme == settings.theme
        return VStack(spacing: 6) {
            ZStack {
                ReaderBackgroundView(background: palette.background)
                Text(verbatim: "文")
                    .font(.system(size: 20))
                    .foregroundStyle(palette.ink)
            }
            .frame(width: 52, height: 52)
            .clipShape(.rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        selected ? Color.accentColor : Color(.separator),
                        lineWidth: selected ? 3 : 1
                    )
            }
            Text(theme.nameKey)
                .font(.caption2)
                .foregroundStyle(selected ? Color.accentColor : .secondary)
        }
    }

    private func preview(of theme: ReaderSettings.Theme) -> ReaderPalette {
        switch theme {
        case .system: return systemColorScheme == .dark ? .dark : .light
        case .light: return .light
        case .dark: return .dark
        case .custom: return settings.customPalette
        }
    }
}

/// Settings → Appearance. The same controls the reader sheet shows, reachable
/// without having a book open.
struct AppearanceSettingsView: View {
    @State private var settings = ReaderSettings.shared

    var body: some View {
        Form {
            ReadingAppearanceSections(settings: settings)
        }
        .navigationTitle("settings.appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}
