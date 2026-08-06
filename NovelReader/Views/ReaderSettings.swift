import SwiftUI
import UIKit

/// Reading appearance. Lives in `UserDefaults` rather than the database and is
/// deliberately *not* synced: type size is a per-device comfort setting, and a
/// phone and an iPad rarely want the same one.
@Observable
final class ReaderSettings {
    /// Backgrounds are paper colours, not brand colours: each one is a surface a
    /// person could stand to look at for an hour. Kept to nine — past that the
    /// picker becomes a decision instead of a preference.
    ///
    /// Raw values are storage keys, so the original four keep theirs.
    enum Theme: String, CaseIterable, Identifiable {
        case system, paper, sepia, linen, mint, sky, slate, night, black

        var id: String { rawValue }

        var nameKey: LocalizedStringKey {
            switch self {
            case .system: return "reader.theme.system"
            case .paper: return "reader.theme.paper"
            case .sepia: return "reader.theme.sepia"
            case .linen: return "reader.theme.linen"
            case .mint: return "reader.theme.mint"
            case .sky: return "reader.theme.sky"
            case .slate: return "reader.theme.slate"
            case .night: return "reader.theme.night"
            case .black: return "reader.theme.black"
            }
        }

        var background: Color {
            switch self {
            case .system: return Color(.systemBackground)
            case .paper: return Color(white: 1.0)
            case .sepia: return Color(red: 0.98, green: 0.94, blue: 0.86)
            case .linen: return Color(red: 0.95, green: 0.93, blue: 0.89)
            case .mint: return Color(red: 0.88, green: 0.94, blue: 0.89)
            case .sky: return Color(red: 0.89, green: 0.93, blue: 0.96)
            case .slate: return Color(red: 0.16, green: 0.17, blue: 0.19)
            case .night: return Color(white: 0.07)
            case .black: return Color(white: 0.0)
            }
        }

        var foreground: Color {
            switch self {
            case .system: return Color(.label)
            case .paper: return Color(white: 0.12)
            case .sepia: return Color(red: 0.24, green: 0.19, blue: 0.13)
            case .linen: return Color(red: 0.21, green: 0.19, blue: 0.16)
            case .mint: return Color(red: 0.13, green: 0.22, blue: 0.16)
            case .sky: return Color(red: 0.13, green: 0.18, blue: 0.24)
            case .slate: return Color(white: 0.80)
            case .night: return Color(white: 0.78)
            // Pure white on pure black smears on OLED; 0.72 is the comfortable
            // ceiling for body text at this size.
            case .black: return Color(white: 0.72)
            }
        }

        var isDark: Bool {
            switch self {
            case .slate, .night, .black: return true
            default: return false
            }
        }

        /// A dark background must force dark chrome even when the system is in
        /// light mode, otherwise the status bar and bars sit at the wrong contrast.
        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            default: return isDark ? .dark : .light
            }
        }
    }

    static let shared = ReaderSettings()

    var fontSize: Double { didSet { defaults.set(fontSize, forKey: Keys.fontSize) } }
    var lineSpacing: Double { didSet { defaults.set(lineSpacing, forKey: Keys.lineSpacing) } }
    var paragraphSpacing: Double { didSet { defaults.set(paragraphSpacing, forKey: Keys.paragraphSpacing) } }
    var theme: Theme { didSet { defaults.set(theme.rawValue, forKey: Keys.theme) } }
    /// A font name usable with `UIFont(name:size:)`, or nil for the system face.
    var fontName: String? {
        didSet { defaults.set(fontName, forKey: Keys.fontName) }
    }
    /// Keeps the screen awake while reading — the single most requested reader
    /// setting, and the one users notice most when it is missing.
    var keepScreenOn: Bool {
        didSet {
            defaults.set(keepScreenOn, forKey: Keys.keepScreenOn)
        }
    }

    private enum Keys {
        static let fontSize = "reader.fontSize"
        static let lineSpacing = "reader.lineSpacing"
        static let paragraphSpacing = "reader.paragraphSpacing"
        static let theme = "reader.theme"
        static let fontName = "reader.fontName"
        static let keepScreenOn = "reader.keepScreenOn"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        fontSize = defaults.object(forKey: Keys.fontSize) as? Double ?? 19
        lineSpacing = defaults.object(forKey: Keys.lineSpacing) as? Double ?? 9
        paragraphSpacing = defaults.object(forKey: Keys.paragraphSpacing) as? Double ?? 14
        theme = (defaults.string(forKey: Keys.theme).flatMap(Theme.init(rawValue:))) ?? .system
        // A font that was uninstalled with its app would render as the system
        // face anyway, so an unknown name is simply dropped on load.
        let storedFont = defaults.string(forKey: Keys.fontName)
        fontName = storedFont.flatMap { UIFont(name: $0, size: 16) == nil ? nil : $0 }
        keepScreenOn = defaults.object(forKey: Keys.keepScreenOn) as? Bool ?? true
    }

    var font: Font {
        guard let fontName else { return .system(size: fontSize) }
        // Fixed size, not `relativeTo:`: the reader already has its own size
        // slider, and layering Dynamic Type on top of it makes the slider lie.
        return .custom(fontName, fixedSize: fontSize)
    }

    static let fontSizeRange: ClosedRange<Double> = 13...32
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

    /// The regular face of a family. `UIFont(name:)` accepts a family name for
    /// most families but not all, so fall back to the first concrete face.
    private static func usableName(in family: String) -> String? {
        if UIFont(name: family, size: 16) != nil { return family }
        return UIFont.fontNames(forFamilyName: family).first
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
