import CoreText
import SwiftUI
import UIKit

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

    /// One face the reader picked out of the system panel, named as the list names it.
    ///
    /// No script test: a face asked for by name was chosen deliberately, and a list that
    /// dropped it would be answering a question the reader has already settled. Nil while
    /// this process cannot resolve the name — which is every launch until
    /// `InstalledFonts.restore(into:)` has been answered, and forever once the face has
    /// been uninstalled.
    static func entry(_ fontName: String) -> Entry? {
        guard let font = UIFont(name: fontName, size: 16) else { return nil }
        return Entry(fontName: fontName, displayName: font.familyName)
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

extension ReaderSettings {
    /// Everything the font picker offers: the Chinese faces the device came with, then
    /// whatever the reader added from the system panel. A face can be in both — picking
    /// one of the device's own out of the panel is allowed — so the second half is the
    /// names the first does not already carry.
    var faces: [FontCatalog.Entry] {
        let device = FontCatalog.chinese
        let known = Set(device.map(\.fontName))
        return device + installedFaces.filter { !known.contains($0) }.compactMap(FontCatalog.entry)
    }
}

/// The faces on this device that this app cannot see by itself.
///
/// `UIFont.familyNames` answers with the fonts iOS ships and the ones this bundle carries,
/// and with nothing the reader installed themselves. That is deliberate — the list of
/// somebody's fonts is a fingerprint — and it means no rule applied over that list can add
/// a face the list does not contain. A font the reader installed is reached two ways and
/// only two: the `com.apple.developer.user-fonts` entitlement, without which even Apple's
/// own panel shows this app the built-in faces only, and the reader picking a face out of
/// that panel, which is what grants this app access to it.
///
/// The grant is per process. A face picked today is not resolvable by name in tomorrow's
/// launch until this asks for it again — see `restore(into:)`.
enum InstalledFonts {
    /// Asks for every face the reader has picked. Called once, at launch.
    static func restore(into settings: ReaderSettings) {
        request(settings.installedFaces) { missing in
            // A face picked on this device and since uninstalled. Dropped rather than left
            // in the list promising a face nothing can draw — and dropped once, so that the
            // system's "these fonts are missing" dialog is not put up on every launch.
            settings.forget(faces: missing)
        }
    }

    /// Makes `names` resolvable by `UIFont(name:)` in this process.
    ///
    /// This is the one call that can do it: a face registered by the app that installed it
    /// is not automatically available to anybody else, and `CTFontManagerRequestFonts` is
    /// how another process asks for one it already knows the name of. It is silent for a
    /// face that is really there; the system puts a dialog up only for names it cannot find
    /// at all, which is what a removed font looks like.
    ///
    /// - Parameter missing: the names that could not be found, delivered on the main queue.
    ///   Core Text calls back on a queue of its own and is not annotated as doing so, so the
    ///   hop is made here rather than left for every caller to remember.
    static func request(_ names: [String], missing: @escaping ([String]) -> Void) {
        guard !names.isEmpty else { return missing([]) }
        let descriptors = names.map { UIFontDescriptor(fontAttributes: [.name: $0]) }
        CTFontManagerRequestFonts(descriptors as CFArray) { unresolved in
            let unresolvedNames = (unresolved as? [UIFontDescriptor] ?? []).map(\.postscriptName)
            DispatchQueue.main.async { missing(unresolvedNames) }
        }
    }
}

/// The row under the font picker that opens the system's own font panel.
///
/// One row shared by the general settings and by the per-shelf and per-book panel, which
/// each write a different layer — `selection` is whichever one the reader is editing. The
/// face they pick is chosen right there and not merely added to the list: going to the
/// panel to find a face and then having to find it again in the list below is the trip
/// nobody finishes.
struct AddInstalledFontRow: View {
    let settings: ReaderSettings
    @Binding var selection: String?

    @State private var showingPanel = false

    var body: some View {
        Button("reader.settings.font.installed") { showingPanel = true }
            .accessibilityIdentifier("reader.settings.font.installed")
            .sheet(isPresented: $showingPanel) {
                SystemFontPanel { descriptor in
                    showingPanel = false
                    keep(descriptor)
                }
            }
    }

    private func keep(_ descriptor: UIFontDescriptor) {
        let name = descriptor.postscriptName
        guard !name.isEmpty else { return }
        // Asked for even though the panel has just granted it, because this is the same
        // call every later launch makes: a face that cannot survive it is one the reader
        // would find missing tomorrow, and nothing is written down until it answers.
        InstalledFonts.request([name]) { missing in
            guard missing.isEmpty, settings.remember(face: name) else { return }
            selection = name
        }
    }
}

/// Apple's font panel, which lists what this app cannot.
///
/// Deliberately unfiltered. `filteredLanguagesPredicate` asks a font which languages it
/// declares, which is the question `FontCatalog` already asks of the device's own faces —
/// and this panel exists for the ones whose answer leaves them out, so asking it again here
/// would rebuild the wall this is a door through.
private struct SystemFontPanel: UIViewControllerRepresentable {
    let onPick: (UIFontDescriptor) -> Void

    func makeUIViewController(context: Context) -> UIFontPickerViewController {
        let configuration = UIFontPickerViewController.Configuration()
        // Faces rather than families only: a Chinese font is commonly installed as a single
        // cut, and a panel that offers families hands back a name `UIFont(name:)` may not
        // answer for. What is stored has to be the thing that draws.
        configuration.includeFaces = true
        let panel = UIFontPickerViewController(configuration: configuration)
        panel.delegate = context.coordinator
        return panel
    }

    func updateUIViewController(_ panel: UIFontPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIFontPickerViewControllerDelegate {
        private let onPick: (UIFontDescriptor) -> Void

        init(onPick: @escaping (UIFontDescriptor) -> Void) {
            self.onPick = onPick
        }

        func fontPickerViewControllerDidPickFont(_ panel: UIFontPickerViewController) {
            guard let descriptor = panel.selectedFontDescriptor else { return }
            onPick(descriptor)
        }
    }
}
