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
    /// The only difference between the two places this view appears, and what the scope
    /// switch needs to exist: three of these settings can be answered by one book
    /// differently from the rest, and only a panel opened inside a book has a book to
    /// answer for. Settings has no second layer to offer and shows the defaults alone.
    ///
    /// The whole book rather than its id, because resolving those settings takes both
    /// halves of what a book is: which one it is, and what kind of reading it is.
    var book: Book?

    /// Which layer the controls below are writing to.
    ///
    /// Starts on the defaults in every book, every time the panel opens. That is what this
    /// panel has always done, and a reader who opens it to make the text bigger everywhere
    /// must not have to notice a switch to get what they have always got. Taking one book
    /// off the defaults is the deliberate act, so it is the one that costs a tap.
    @State private var scope = Scope.defaults

    /// The two layers a reader can edit from inside a book — see `ReaderSettings.Overrides`
    /// for why there is no third one here for the medium.
    enum Scope: String, CaseIterable, Identifiable {
        case defaults, book

        var id: String { rawValue }

        var nameKey: LocalizedStringResource {
            switch self {
            case .defaults: return "reader.settings.scope.defaults"
            case .book: return "reader.settings.scope.book"
            }
        }
    }

    var body: some View {
        Group {
            if book != nil {
                Section {
                    Picker("reader.settings.scope", selection: $scope) {
                        ForEach(Scope.allCases) { scope in
                            Text(scope.nameKey).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("reader.settings.scope")
                } footer: {
                    // How far a change below will reach, said before it is made rather than
                    // found out afterwards, in a different book, by a reader who has
                    // forgotten they were ever offered a choice about it.
                    Text(
                        scope == .book
                            ? "reader.settings.scope.book.footer"
                            : "reader.settings.scope.defaults.footer"
                    )
                }
            }

            if let book, scope == .book {
                bookSections(book)
            } else {
                defaultSections
            }
        }
    }

    /// The reader's usual answers, which nearly every book is read with — so this is the
    /// side the panel opens on, in Settings and in a book alike.
    @ViewBuilder
    private var defaultSections: some View {
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

            // Subscriptions, which are the one medium whose content is a different shape
            // rather than a different taste — see `ReaderSettings.Overrides`. A row among
            // the defaults rather than a third scope at the top: it *is* a default, and a
            // reader who wants every article turned the same way should not have to open
            // an article to say so.
            Picker("reader.settings.mode.feed", selection: feedMode) {
                followRow(settings.mode)
                ForEach(ReaderSettings.Mode.allCases) { mode in
                    Text(mode.nameKey).tag(ReaderSettings.Mode?.some(mode))
                }
            }
            .accessibilityIdentifier("reader.settings.mode.feed")
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
            ThemePicker(settings: settings, selection: $settings.theme)
            NavigationLink("reader.theme.custom.edit") {
                ReaderThemeEditor(settings: settings)
            }
            .accessibilityIdentifier("reader.settings.customTheme")
        }

        // Always, even where the reader is looking at pages and it can do nothing for
        // them. It used to hide itself behind the mode in force, which stopped making
        // sense the moment one book could hold its own: these are the defaults, there
        // are now three modes that could be in force behind them, and a global switch
        // that vanishes because *this* book was pinned to pages is a setting the reader
        // cannot find from the book they are in.
        Section {
            Toggle("reader.settings.tapToTurn", isOn: $settings.tapToTurnPage)
                .accessibilityIdentifier("reader.settings.tapToTurn")
        } footer: {
            // Which part of the screen does what, said once, here. A reader who
            // has to find the zones by tapping finds the wrong one first.
            Text("reader.settings.tapToTurn.footer")
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

    /// How this book is laid out, where it does not want what everything else gets. Each
    /// control sits over a line naming what it would read with if it had not been asked.
    ///
    /// The same controls as the defaults, minus the ones that are not a book's to hold —
    /// the script conversion, the tap zones, the screen — see `ReaderSettings.Overrides`.
    /// A panel that offered those under 這本書 and then changed every book would be lying
    /// about its own heading.
    @ViewBuilder
    private func bookSections(_ book: Book) -> some View {
        let overrides = settings.overrides(forBook: book.id)

        Section {
            Picker("reader.settings.mode", selection: bookMode(book)) {
                ForEach(ReaderSettings.Mode.allCases) { mode in
                    Text(mode.nameKey).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("reader.settings.mode")

            followLine(
                String(localized: settings.defaultMode(for: book.kind).nameKey),
                revert: overrides.mode == nil ? nil : { follow(\.mode, for: book) }
            )
        } footer: {
            Text("reader.settings.mode.footer")
        }

        Section("reader.settings.text") {
            Picker("reader.settings.font", selection: bookFontName(book)) {
                Text("reader.settings.font.system").tag(String?.none)
                ForEach(FontCatalog.chinese) { entry in
                    Text(entry.displayName)
                        .font(.custom(entry.fontName, fixedSize: 17))
                        .tag(String?.some(entry.fontName))
                }
            }
            .accessibilityIdentifier("reader.settings.font")

            followLine(
                faceName(settings.defaultFontName(for: book.kind)),
                revert: overrides.fontName == nil ? nil : { follow(\.fontName, for: book) }
            )

            LabeledContent("reader.settings.fontSize") {
                Text("\(Int(settings.resolvedFontSize(forBook: book.id, kind: book.kind)))")
            }
            Slider(
                value: bookFontSize(book),
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
                "\(Int(settings.defaultFontSize(for: book.kind)))",
                revert: overrides.fontSize == nil ? nil : { follow(\.fontSize, for: book) }
            )

            LabeledContent("reader.settings.lineSpacing") {
                Text("\(Int(settings.resolvedLineSpacing(forBook: book.id, kind: book.kind)))")
            }
            Slider(value: bookLineSpacing(book), in: 0...20, step: 1)

            followLine(
                "\(Int(settings.defaultLineSpacing(for: book.kind)))",
                revert: overrides.lineSpacing == nil ? nil : { follow(\.lineSpacing, for: book) }
            )

            LabeledContent("reader.settings.paragraphSpacing") {
                Text(
                    "\(Int(settings.resolvedParagraphSpacing(forBook: book.id, kind: book.kind)))"
                )
            }
            Slider(value: bookParagraphSpacing(book), in: 0...32, step: 2)

            followLine(
                "\(Int(settings.defaultParagraphSpacing(for: book.kind)))",
                revert: overrides.paragraphSpacing == nil
                    ? nil
                    : { follow(\.paragraphSpacing, for: book) }
            )
        }

        Section {
            ThemePicker(settings: settings, selection: bookTheme(book))
            // Reachable from here too, because a book can be set to the custom palette
            // from the row above and would otherwise be pinned to colours it has no way
            // to see, let alone change. What it opens is the one shared palette, which is
            // what the footer is for.
            NavigationLink("reader.theme.custom.edit") {
                ReaderThemeEditor(settings: settings)
            }
            .accessibilityIdentifier("reader.settings.customTheme")

            followLine(
                String(localized: settings.defaultTheme(for: book.kind).nameKey),
                revert: overrides.theme == nil ? nil : { follow(\.theme, for: book) }
            )
        } header: {
            Text("reader.settings.theme")
        } footer: {
            Text("reader.settings.theme.custom.shared")
        }
    }

    /// The "follow" row of an inheriting picker, naming what it would inherit.
    ///
    /// Spelled out rather than left as the word "default": a reader deciding whether to
    /// override something has to see what they would be overriding.
    private func followRow(_ inherited: ReaderSettings.Mode) -> some View {
        Text("reader.settings.followDefault \(String(localized: inherited.nameKey))")
            .tag(ReaderSettings.Mode?.none)
    }

    /// A face as the picker names it: the family a reader would recognise, or the system
    /// row's own label, so that "follow the default (系統字體)" reads like the row above it
    /// rather than like a PostScript name.
    private func faceName(_ fontName: String?) -> String {
        guard let fontName else { return String(localized: "reader.settings.font.system") }
        return FontCatalog.chinese.first { $0.fontName == fontName }?.displayName ?? fontName
    }

    /// The line under one of this book's controls, naming what it would read with
    /// otherwise — and, once the book has been given its own answer, the way back.
    ///
    /// There in both states, because a control showing an inherited value looks exactly
    /// like one showing a chosen value. The line names the default either way; that it
    /// becomes tappable is what says this book has stopped following it.
    @ViewBuilder
    private func followLine(_ inherited: String, revert: (() -> Void)?) -> some View {
        let label = Text("reader.settings.followDefault \(inherited)")
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

    /// What this whole medium is turned like, with nil meaning "follow the general answer"
    /// in both directions: it is what the picker shows for a medium that has never been
    /// given one, and what it writes back when the reader picks that row again.
    private var feedMode: Binding<ReaderSettings.Mode?> {
        Binding(
            get: { settings.feedOverrides.mode },
            set: { settings.feedOverrides.mode = $0 }
        )
    }

    /// This book's own answers. Each reads the *resolved* value — a control has to show
    /// something, and what the book is being read with right now is the only honest
    /// answer — and writes an override, because moving one of these is exactly what taking
    /// this book off the default means.
    private func bookMode(_ book: Book) -> Binding<ReaderSettings.Mode> {
        Binding(
            get: { settings.resolvedMode(forBook: book.id, kind: book.kind) },
            set: { write(\.mode, $0, for: book) }
        )
    }

    /// The face, where nil is the system one — a real choice rather than an absence, which
    /// is why it is written down as the empty string. See `ReaderSettings.Overrides`.
    private func bookFontName(_ book: Book) -> Binding<String?> {
        Binding(
            get: { settings.resolvedFontName(forBook: book.id, kind: book.kind) },
            set: { write(\.fontName, $0 ?? "", for: book) }
        )
    }

    private func bookFontSize(_ book: Book) -> Binding<Double> {
        Binding(
            get: { settings.resolvedFontSize(forBook: book.id, kind: book.kind) },
            set: { write(\.fontSize, $0, for: book) }
        )
    }

    private func bookLineSpacing(_ book: Book) -> Binding<Double> {
        Binding(
            get: { settings.resolvedLineSpacing(forBook: book.id, kind: book.kind) },
            set: { write(\.lineSpacing, $0, for: book) }
        )
    }

    private func bookParagraphSpacing(_ book: Book) -> Binding<Double> {
        Binding(
            get: { settings.resolvedParagraphSpacing(forBook: book.id, kind: book.kind) },
            set: { write(\.paragraphSpacing, $0, for: book) }
        )
    }

    private func bookTheme(_ book: Book) -> Binding<ReaderSettings.Theme> {
        Binding(
            get: { settings.resolvedTheme(forBook: book.id, kind: book.kind) },
            set: { write(\.theme, $0, for: book) }
        )
    }

    private func write<Value>(
        _ field: WritableKeyPath<ReaderSettings.Overrides, Value?>,
        _ value: Value?,
        for book: Book
    ) {
        var overrides = settings.overrides(forBook: book.id)
        overrides[keyPath: field] = value
        settings.setOverrides(overrides, forBook: book.id)
    }

    /// Puts one field back to following — `write(field, nil,)` by another name, because
    /// "follow" is what the reader asked for and nil is only how it is stored.
    private func follow<Value>(
        _ field: WritableKeyPath<ReaderSettings.Overrides, Value?>,
        for book: Book
    ) {
        write(field, nil, for: book)
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
