import SwiftUI
import UIKit

/// Reading appearance. Lives in `UserDefaults` rather than the database and is
/// deliberately *not* synced: type size is a per-device comfort setting, and a
/// phone and an iPad rarely want the same one.
@Observable
final class ReaderSettings {
    /// Where the reader's colours come from.
    ///
    /// Two shipped pairs rather than the nine this replaces. Nine swatches was a decision
    /// instead of a preference, and once a reader can build any surface they like, a
    /// shipped palette's whole job is to be a sane default and a place to start from —
    /// see `ReaderPalette.light` and `.dark`. Raw values are storage keys; the older ones
    /// no longer parse, so a device that was on 亞麻 comes back on the system's own.
    enum Theme: String, CaseIterable, Identifiable {
        case system, light, dark, custom

        var id: String { rawValue }

        var nameKey: LocalizedStringKey {
            switch self {
            case .system: return "reader.theme.system"
            case .light: return "reader.theme.light"
            case .dark: return "reader.theme.dark"
            case .custom: return "reader.theme.custom"
            }
        }
    }

    /// How the text moves under the reader.
    ///
    /// Two renderers rather than one engine with a flag: a continuous column across
    /// chapter boundaries and a fixed page are different reading experiences, not
    /// different animations, and readers hold strong opinions about which one a novel
    /// belongs in. Scrolling stays the default — it is what the app has always done.
    enum Mode: String, CaseIterable, Identifiable {
        case scroll, paginated

        var id: String { rawValue }

        /// A resource rather than a `LocalizedStringKey`, unlike `Theme` beside it: the
        /// reader's own picker names the default inside one of its rows — "follow the
        /// default (scrolling)" — and a key cannot be read out as the string that goes in
        /// there. `Text` takes either, so nothing that already draws this had to change.
        var nameKey: LocalizedStringResource {
            switch self {
            case .scroll: return "reader.settings.mode.scroll"
            case .paginated: return "reader.settings.mode.paginated"
            }
        }
    }

    static let shared = ReaderSettings()

    /// How text is turned, in every book that has not been given an answer of its own and
    /// in every medium that has not either.
    var mode: Mode { didSet { defaults.set(mode.rawValue, forKey: Keys.mode) } }
    /// The default for subscriptions, where the reader wants one of its own. Nil is "the
    /// same as everything else", which is where every device starts.
    ///
    /// The one medium that gets its own default, because it is the one whose content is a
    /// different shape rather than a different taste. An article is a few screens long, it
    /// carries pictures and headings, and it *ends* — pages cut a five-minute read at
    /// boundaries it did not ask for, while a novel is the thing pages were invented for.
    /// A reader who wants that distinction should not have to make it forty times, once
    /// per subscription, and then again for every feed they add afterwards.
    ///
    /// Comics have no such setting to inherit: they are drawn by a renderer of their own
    /// that never reads this type.
    var feedMode: Mode? {
        didSet { defaults.set(feedMode?.rawValue, forKey: Keys.feedMode) }
    }
    /// The books that are read in a mode of their own, by book id.
    ///
    /// One dictionary rather than a key per book, and dropped when the book is — the shape
    /// `LibrarySettings.catalogDescending` already uses for the same kind of answer, for
    /// the same reasons. What differs is what an override stores: that one writes *no
    /// entry* when the choice equals the default, because a catalog's default is a
    /// constant per medium. This default is the reader's own `mode` and they can change it
    /// tomorrow, so "scrolling, explicitly" and "whatever the default is" have to stay
    /// different things on disk — collapsing them would silently unpin every book that was
    /// pinned to the mode the default happened to hold that day.
    ///
    /// Raw values because this goes into `UserDefaults`, which holds property-list types
    /// and not enums.
    private(set) var modeByBook: [String: String] {
        didSet { defaults.set(modeByBook, forKey: Keys.modeByBook) }
    }
    var fontSize: Double { didSet { defaults.set(fontSize, forKey: Keys.fontSize) } }
    var lineSpacing: Double { didSet { defaults.set(lineSpacing, forKey: Keys.lineSpacing) } }
    var paragraphSpacing: Double { didSet { defaults.set(paragraphSpacing, forKey: Keys.paragraphSpacing) } }
    var theme: Theme { didSet { defaults.set(theme.rawValue, forKey: Keys.theme) } }
    /// The surface the reader built, held whether or not it is the one in force.
    ///
    /// A reader who tries the two shipped palettes and comes back has to find their own
    /// gradient exactly where they left it — otherwise looking at an alternative costs
    /// them the thing they made.
    var customPalette: ReaderPalette {
        didSet {
            guard let data = try? JSONEncoder().encode(customPalette) else { return }
            defaults.set(data, forKey: Keys.customPalette)
        }
    }
    /// A font name usable with `UIFont(name:size:)`, or nil for the system face.
    ///
    /// Written as the empty string when nil, because an absent key and a chosen system
    /// face are different answers: the first is a device that has never picked and gets
    /// `defaultFontName`, the second is one that picked, and removing the key would turn
    /// "system font" back into Songti on the next launch.
    var fontName: String? {
        didSet { defaults.set(fontName ?? "", forKey: Keys.fontName) }
    }
    /// Which Chinese script the reader sees, whatever the site served — see
    /// `ChineseScript`. Stored as two keys rather than one encoded value so that a UI
    /// walk can set either half from a launch argument.
    var chineseScript: ChineseScript {
        didSet {
            defaults.set(chineseScript.depth.rawValue, forKey: Keys.chineseDepth)
            defaults.set(chineseScript.target.rawValue, forKey: Keys.chineseTarget)
            ChineseText.prewarm(chineseScript)
        }
    }
    /// Keeps the screen awake while reading — the single most requested reader
    /// setting, and the one users notice most when it is missing.
    var keepScreenOn: Bool {
        didSet {
            defaults.set(keepScreenOn, forKey: Keys.keepScreenOn)
        }
    }
    /// Turns the scrolling reader's screen into tap zones — see `ReaderTapZone`.
    ///
    /// Off by default, and deliberately not "on for everyone": a tap in the scrolling
    /// reader has always meant "show me the controls", and quietly turning most of the
    /// screen into a page turn would move the text under readers who tapped for the
    /// controls. Paginated reading has its own zones and ignores this.
    var tapToTurnPage: Bool {
        didSet {
            defaults.set(tapToTurnPage, forKey: Keys.tapToTurnPage)
        }
    }

    /// How this book is read: its own answer where it has one, its medium's otherwise.
    ///
    /// The whole resolution, in the order a reader would say it out loud — this book, then
    /// this kind of reading, then what I usually do.
    func resolvedMode(forBook bookId: String, kind: SiteRule.Kind) -> Mode {
        chosenMode(forBook: bookId) ?? defaultMode(for: kind)
    }

    /// What a medium is read in before any book of it disagrees.
    ///
    /// Comics are answered too, and with the reader's usual mode, which is neither wrong
    /// nor used: nothing draws a comic through these settings. A `switch` that refused
    /// them would be a crash waiting for the day one does.
    func defaultMode(for kind: SiteRule.Kind) -> Mode {
        kind == .feed ? (feedMode ?? mode) : mode
    }

    /// The mode this book was explicitly given, or nil for one that follows the default.
    ///
    /// What the reader's own picker is bound to. A resolved mode cannot say "following",
    /// and following is a state the picker has to be able to show and to return to.
    func chosenMode(forBook bookId: String) -> Mode? {
        modeByBook[bookId].flatMap(Mode.init(rawValue:))
    }

    /// Nil puts the book back to following the default.
    func setMode(_ mode: Mode?, forBook bookId: String) {
        modeByBook[bookId] = mode?.rawValue
    }

    /// Dropped along with the book — `LibrarySettings.forgetCatalogOrder`'s reason: a book
    /// removed and added again would otherwise come back in a mode the reader never chose
    /// for it.
    func forgetMode(forBook bookId: String) {
        modeByBook[bookId] = nil
    }

    private enum Keys {
        static let mode = "reader.mode"
        static let feedMode = "reader.feedMode"
        static let modeByBook = "reader.modeByBook"
        static let fontSize = "reader.fontSize"
        static let lineSpacing = "reader.lineSpacing"
        static let paragraphSpacing = "reader.paragraphSpacing"
        static let theme = "reader.theme"
        static let customPalette = "reader.customPalette"
        static let fontName = "reader.fontName"
        static let chineseDepth = "reader.chinese.depth"
        static let chineseTarget = "reader.chinese.target"
        static let keepScreenOn = "reader.keepScreenOn"
        static let tapToTurnPage = "reader.tapToTurnPage"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = (defaults.string(forKey: Keys.mode).flatMap(Mode.init(rawValue:))) ?? .scroll
        // No key at all is the default here, so nothing needs the sentinel `fontName` uses
        // below: "follows the general answer" and "has never been set" are the same state.
        feedMode = defaults.string(forKey: Keys.feedMode).flatMap(Mode.init(rawValue:))
        modeByBook = defaults.dictionary(forKey: Keys.modeByBook) as? [String: String] ?? [:]
        fontSize = defaults.object(forKey: Keys.fontSize) as? Double ?? 19
        lineSpacing = defaults.object(forKey: Keys.lineSpacing) as? Double ?? 9
        paragraphSpacing = defaults.object(forKey: Keys.paragraphSpacing) as? Double ?? 14
        theme = (defaults.string(forKey: Keys.theme).flatMap(Theme.init(rawValue:))) ?? .system
        // A palette written by a newer build, or by hand, is not worth failing over: the
        // shipped light one is a page anybody can read.
        customPalette = defaults.data(forKey: Keys.customPalette)
            .flatMap { try? JSONDecoder().decode(ReaderPalette.self, from: $0) } ?? .light
        switch defaults.string(forKey: Keys.fontName) {
        case nil:
            let resolved = Self.defaultFontName
            fontName = resolved
            // Written down at once. Resolving it means asking every family on the device
            // for Han glyphs (see `FontCatalog`), and that is a question with one answer
            // per device — not one worth re-asking on every cold start.
            defaults.set(resolved ?? "", forKey: Keys.fontName)
        case let stored?:
            // A font that was uninstalled with its app would render as the system face
            // anyway, so an unknown name is simply dropped on load — as is the empty
            // string, which is how a chosen system face is written down.
            fontName = stored.isEmpty || UIFont(name: stored, size: 16) == nil ? nil : stored
        }
        // Per-character by default: it costs nothing to start, never moves a stored
        // offset, and is right far more often than it is wrong. Words are the tier a
        // reader opts into once they have seen 「頭發」 one time too many.
        chineseScript = ChineseScript(
            depth: defaults.string(forKey: Keys.chineseDepth)
                .flatMap(ChineseScript.Depth.init(rawValue:)) ?? .characters,
            target: defaults.string(forKey: Keys.chineseTarget)
                .flatMap(ChineseScript.Target.init(rawValue:)) ?? ChineseScript.deviceDefault
        )
        keepScreenOn = defaults.object(forKey: Keys.keepScreenOn) as? Bool ?? true
        // `bool(forKey:)` rather than the `object(forKey:) as? Bool` the settings above
        // use: it answers false for a key nobody has set, which is this flag's default
        // anyway, and unlike the cast it also reads the value out of a launch argument —
        // which is the only way a UI walk can turn the zones on without persisting the
        // choice into the simulator for every test that runs after it.
        tapToTurnPage = defaults.bool(forKey: Keys.tapToTurnPage)
        // `didSet` does not run for the value an initializer assigns, and the dictionaries
        // are wanted before the first chapter is composed rather than during it.
        ChineseText.prewarm(chineseScript)
    }

    var font: Font {
        guard let fontName else { return .system(size: fontSize) }
        // Fixed size, not `relativeTo:`: the reader already has its own size
        // slider, and layering Dynamic Type on top of it makes the slider lie.
        return .custom(fontName, fixedSize: fontSize)
    }

    /// The colours in force.
    ///
    /// The system's answer is passed in rather than read here: `ReaderSettings` lives
    /// outside the view tree and has no traits to resolve against, and a stored copy of
    /// the system's appearance is a copy that is one frame stale every time the reader
    /// walks under a lamp.
    func palette(systemIsDark: Bool) -> ReaderPalette {
        switch theme {
        case .system: return systemIsDark ? .dark : .light
        case .light: return .light
        case .dark: return .dark
        case .custom: return customPalette
        }
    }

    /// A dark page must force dark chrome even when the system is in light mode,
    /// otherwise the bars floating over the text sit at the wrong contrast. Nil for
    /// `.system`, which is the one case with nothing to override.
    var forcedColorScheme: ColorScheme? {
        switch theme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        case .custom: return customPalette.isDark ? .dark : .light
        }
    }

    static let fontSizeRange: ClosedRange<Double> = 13...32

    /// The device's own Song face, which is what a Chinese book is set in — a screen of
    /// prose in the system's sans reads as an interface, not a page.
    ///
    /// Taken from `FontCatalog` rather than named outright, so that the face a reader
    /// starts on is exactly the entry the font picker shows selected. A device without it
    /// falls back to the system face, which is what an unknown name would draw as anyway.
    static let defaultFontName: String? = FontCatalog.songti
}

/// The fonts on this device that can actually render Chinese.
///
/// `UIFont.familyNames` is around eighty families, nearly all of them Latin-only:
/// offering them would mean offering a list where most choices turn the book
/// into blank boxes. So each family is asked for glyphs for a handful of common
/// Han characters, and only the ones that answer are shown.
enum FontCatalog {
    struct Entry: Identifiable, Hashable {
        /// Usable with `UIFont(name:size:)` and `Font.custom`.
        let fontName: String
        let displayName: String
        var id: String { fontName }
    }

    /// Traditional and simplified, common and less common, plus punctuation:
    /// a family that misses any of these is not usable as a body face here.
    private static let probe = Array("國国說说一二三的了，。".utf16)

    static let chinese: [Entry] = {
        UIFont.familyNames
            .sorted()
            .compactMap { family in
                guard let name = usableName(in: family), supportsChinese(name) else { return nil }
                return Entry(fontName: name, displayName: family)
            }
    }()

    /// The device's Song face, as this catalog names it.
    ///
    /// Traditional first, because that is the language the app is authored in; then
    /// Simplified, the same face cut for the other script. Matched by family name against
    /// the catalog rather than by font name against the system, so that the default
    /// reading face and the picker's Songti row are the same string — a default nothing
    /// in the list matches shows as a picker with no selection.
    static var songti: String? {
        ["Songti TC", "Songti SC"]
            .lazy
            .compactMap { family in chinese.first { $0.displayName == family } }
            .first?
            .fontName
    }

    /// The regular face of a family. `UIFont(name:)` accepts a family name for
    /// most families but not all, so fall back to a concrete face.
    private static func usableName(in family: String) -> String? {
        if UIFont(name: family, size: 16) != nil { return family }
        let names = UIFont.fontNames(forFamilyName: family)
        // Explicitly the regular cut. `fontNames(forFamilyName:)` is in no documented
        // order, so taking the first can hand back a light or bold face and set a whole
        // book in it.
        return names.first { $0.hasSuffix("-Regular") } ?? names.first
    }

    private static func supportsChinese(_ fontName: String) -> Bool {
        guard let font = UIFont(name: fontName, size: 16) else { return false }
        var characters = probe
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        // Returns false as soon as one character has no glyph, which is exactly
        // the question being asked.
        return CTFontGetGlyphsForCharacters(font as CTFont, &characters, &glyphs, characters.count)
    }
}
