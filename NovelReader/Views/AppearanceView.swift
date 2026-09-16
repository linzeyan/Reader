import SwiftUI

/// The reading appearance controls, in one place.
///
/// Shared verbatim by the reader's own sheet and by Settings → Appearance.
/// Two copies of these controls would drift, and "the font picker in Settings
/// has one more option than the one in the reader" is exactly the kind of bug
/// nobody files and everybody notices.
struct ReadingAppearanceSections: View {
    @Bindable var settings: ReaderSettings
    /// The book these controls are being shown inside, or nil in Settings.
    ///
    /// What the scope switch offers differs between the two places: inside a book there is
    /// a "this book" to point at and exactly one shelf worth naming, while Settings has no
    /// book and so names every shelf.
    ///
    /// The whole book rather than its id, because a layer takes both halves of what a book
    /// is: which one it is, and what kind of reading it is.
    var book: Book?

    /// Which layer the controls below are writing to.
    ///
    /// Starts on the general answers everywhere, every time the panel opens. That is what
    /// this panel has always done, and a reader who opens it to make the text bigger
    /// everywhere must not have to notice a switch to get what they have always got.
    /// Narrowing to a shelf or a book is the deliberate act, so it is the one that costs a
    /// tap.
    @State private var scope = ReaderSettings.Layer.general

    var body: some View {
        Group {
            Section {
                Picker("reader.settings.scope", selection: $scope) {
                    ForEach(scopes, id: \.self) { layer in
                        Text(name(of: layer)).tag(layer)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("reader.settings.scope")
            } footer: {
                // How far a change below will reach, said before it is made rather than
                // found out afterwards, in a different book, by a reader who has forgotten
                // they were ever offered a choice about it.
                Text(scopeFooter)
            }

            if case .general = scope {
                generalSections
            } else {
                ReadingOverrideSections(settings: settings, layer: scope)
            }
        }
    }

    // MARK: - The scope switch

    /// The layers this panel can write to, widest first.
    ///
    /// Three inside a book — everything, this shelf, this book — and in Settings the
    /// shelves by name, because there is no "this" there to point at.
    private var scopes: [ReaderSettings.Layer] {
        guard let book else { return [.general] + MediaMode.allCases.map { .shelf($0) } }
        return [.general, .shelf(book.kind), .book(id: book.id, kind: book.kind)]
    }

    private func name(of layer: ReaderSettings.Layer) -> LocalizedStringKey {
        switch layer {
        case .general: return "reader.settings.scope.defaults"
        // Named in Settings, pointed at in a book. Four segments where none of them is the
        // shelf you are standing on can only be told apart by name; inside a book there is
        // one shelf in question, and naming it would leave the reader working out whether
        // 小說 is the shelf this book is on.
        case .shelf(let kind): return book == nil ? kind.nameKey : "reader.settings.scope.shelf"
        case .book: return "reader.settings.scope.book"
        }
    }

    private var scopeFooter: LocalizedStringKey {
        switch scope {
        case .general: return "reader.settings.scope.defaults.footer"
        case .shelf: return "reader.settings.scope.shelf.footer"
        case .book: return "reader.settings.scope.book.footer"
        }
    }

    /// What this panel is about, where that is one medium: the book it was opened in, or
    /// the shelf the scope names. Nil in Settings on the widest scope, which is about
    /// everything at once.
    private var subject: SiteRule.Kind? { book?.kind ?? scope.kind }

    // MARK: - The general answers

    /// The reader's usual answers, which nearly every book is read with — so this is the
    /// side the panel opens on, in Settings and in a book alike.
    @ViewBuilder
    private var generalSections: some View {
        // Everything about type, skipped where the panel was opened on comics. The pages
        // are pictures: a face and a line spacing have nothing to apply to, and a panel
        // that offers them is one a reader adjusts and then goes looking for the effect of.
        // See `ReadingOverrideSections`, which draws the same line for a shelf and a book.
        if subject != .comic {
            Section {
                // First: it is the one setting here that changes how the page behaves
                // rather than how it looks, and the rest of this form reads differently
                // depending on which side it is on.
                Picker("reader.settings.mode", selection: $settings.mode) {
                    ForEach(ReaderSettings.Mode.allCases) { mode in
                        Text(mode.nameKey).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("reader.settings.mode")
            } header: {
                // Named, because a segmented picker swallows its own label and this form
                // now holds two of them — 閱讀方式 and 翻頁方式 — one above the other. Two
                // unnamed rows of segments is a reader guessing which is which.
                Text("reader.settings.mode")
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
                    ForEach(settings.faces) { entry in
                        // Each name is drawn in its own face: the sample is the
                        // only thing that actually tells you what you are picking.
                        Text(entry.displayName)
                            .font(.custom(entry.fontName, fixedSize: 17))
                            .tag(String?.some(entry.fontName))
                    }
                }
                .accessibilityIdentifier("reader.settings.font")

                AddInstalledFontRow(settings: settings, selection: $settings.fontName)

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
                ThemePicker(settings: settings, selection: $settings.theme)
                NavigationLink("reader.theme.custom.edit") {
                    ReaderThemeEditor(settings: settings)
                }
                .accessibilityIdentifier("reader.settings.customTheme")
            }
        }

        Section {
            Picker("reader.settings.pageTurn", selection: $settings.pageTurn) {
                ForEach(ReaderSettings.PageTurn.allCases) { turn in
                    Text(turn.nameKey).tag(turn)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("reader.settings.pageTurn")
        } header: {
            Text("reader.settings.pageTurn")
        } footer: {
            // Which part of the screen does what, and the one thing this cannot promise:
            // scrolling stays. A reader who has to find the zones by tapping finds the
            // wrong one first, and one who picks 點擊 expecting the page to stop moving
            // under their thumb has been told something untrue.
            Text("reader.settings.pageTurn.footer")
        }

        Section {
            Toggle("reader.settings.swipeToGoBack", isOn: $settings.swipeToGoBack)
                .accessibilityIdentifier("reader.settings.swipeToGoBack")
        } footer: {
            // Both halves of the bargain, because both are visible changes to a screen
            // the reader is about to be looking at: the button goes away, and in the
            // paginated reader the edge stops turning pages.
            Text("reader.settings.swipeToGoBack.footer")
        }

        Section {
            Toggle("reader.settings.keepScreenOn", isOn: $settings.keepScreenOn)
                .onChange(of: settings.keepScreenOn) { _, wake in
                    UIApplication.shared.isIdleTimerDisabled = wake
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
    /// Only for the custom swatch's preview: whatever the reader last built is drawn on it
    /// wherever this row appears, including in a book that is not using it.
    @Bindable var settings: ReaderSettings
    /// Which swatch is lit, and where a tap goes. A binding rather than `settings.theme`,
    /// because the same row edits one book's own colours when the panel is scoped to a book.
    @Binding var selection: ReaderSettings.Theme
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
        let palette = preview(of: theme)
        let selected = theme == selection
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
