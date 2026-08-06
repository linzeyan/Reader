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

            Section("reader.settings.theme") {
                ThemePicker(selection: $settings.theme)
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

/// Backgrounds as swatches rather than a segmented control.
///
/// Nine options do not fit in a segmented control, and a colour is not something
/// a word describes well anyway — "亞麻" and "紙白" mean nothing until you see
/// them side by side. Each swatch is drawn in its own background and foreground,
/// so the row is a preview of the choice rather than a list of names.
struct ThemePicker: View {
    @Binding var selection: ReaderSettings.Theme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(ReaderSettings.Theme.allCases) { theme in
                    Button {
                        selection = theme
                    } label: {
                        swatch(theme)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(theme.nameKey))
                    .accessibilityAddTraits(theme == selection ? [.isSelected] : [])
                }
            }
            .padding(.vertical, 6)
        }
        .accessibilityIdentifier("reader.settings.themes")
    }

    private func swatch(_ theme: ReaderSettings.Theme) -> some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.background)
                Text(verbatim: "文")
                    .font(.system(size: 20))
                    .foregroundStyle(theme.foreground)
            }
            .frame(width: 52, height: 52)
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        theme == selection ? Color.accentColor : Color(.separator),
                        lineWidth: theme == selection ? 3 : 1
                    )
            }
            Text(theme.nameKey)
                .font(.caption2)
                .foregroundStyle(theme == selection ? Color.accentColor : .secondary)
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
