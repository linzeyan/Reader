import Foundation
import OpenCC
import SwiftUI

/// What script the reader wants Chinese text in, and how much of the language the
/// conversion is allowed to know about.
///
/// The app's sources are split down the middle and not even consistent with themselves:
/// 69shuba serves GBK simplified and flips it in the browser, so the same book arrives
/// traditional or simplified depending on which settle path won the race. Nothing
/// downstream can un-mix that, and a reader who wants one script should not have to care
/// which site a chapter came from.
struct ChineseScript: Equatable, Hashable {
    /// The script to render in.
    enum Target: String, CaseIterable, Identifiable {
        case traditional, simplified

        var id: String { rawValue }

        var nameKey: LocalizedStringKey {
            switch self {
            case .traditional: return "reader.settings.chinese.traditional"
            case .simplified: return "reader.settings.chinese.simplified"
            }
        }
    }

    /// How the conversion reads the text.
    enum Depth: String, CaseIterable, Identifiable {
        /// Exactly what the site served, mixed scripts and all.
        case off
        /// One character at a time (ICU). Free, instant, and right most of the time —
        /// but it resolves each merged character on its own, so 「斗罗大陆」 comes out
        /// 「鬥羅大陸」, and it leaves vocabulary where it found it: 「鼠标」 stays 「鼠標」.
        case characters
        /// Words first, characters after (OpenCC). Gets 「斗羅大陸」 and 「滑鼠」, and pays
        /// for it with a few megabytes of dictionaries loaded the first time it is asked.
        case phrases

        var id: String { rawValue }

        var nameKey: LocalizedStringKey {
            switch self {
            case .off: return "reader.settings.chinese.off"
            case .characters: return "reader.settings.chinese.characters"
            case .phrases: return "reader.settings.chinese.phrases"
            }
        }
    }

    var depth: Depth
    var target: Target

    /// Leave the text alone — what every caller that has no reader behind it wants.
    static let off = ChineseScript(depth: .off, target: .traditional)

    /// What script this device most likely reads, for a reader who has never chosen.
    ///
    /// Taken from the language the phone is set to rather than defaulted to traditional
    /// because this app is authored in it: defaulting the other way would mean a reader
    /// in Shanghai finds their first chapter quietly rewritten into a script they did
    /// not ask for, which is the exact complaint this whole layer exists to answer.
    static var deviceDefault: Target {
        let preferred = Locale.preferredLanguages.first ?? "zh-Hant"
        // Two hops: `script` answers nil for a plain "zh-CN", which names a region and
        // leaves the script implied. `maximalIdentifier` is what fills the implication in.
        let maximal = Locale.Language(identifier: preferred).maximalIdentifier
        return Locale.Language(identifier: maximal).script?.identifier == "Hans"
            ? .simplified
            : .traditional
    }
}

/// The 簡繁 conversion itself.
///
/// Two tiers rather than one because they are different trades, not better and worse.
/// ICU's transform is built into the system, starts instantly, and maps one character to
/// one character — which is why it can never move an offset, and why it reads 「斗罗大陆」
/// as 「鬥羅大陸」: nothing tells it those four characters are a title. OpenCC reads words,
/// gets that one and 「鼠标」→「滑鼠」 with it, and costs a few megabytes of dictionaries.
enum ChineseText {
    /// The text in the reader's script, or the text as it arrived where converting it
    /// would move offsets.
    ///
    /// Every mark a reader has made — highlights, bookmarks, where they stopped reading —
    /// is stored as a paragraph index and a UTF-16 offset inside that paragraph. A
    /// character map cannot move those; a dictionary lookup can, because nothing promises
    /// a replacement is as long as what it replaced, and the dictionaries here ship with a
    /// package that will be updated without asking. So a run whose length would change
    /// steps down to character conversion, and one that still would is left as it arrived.
    ///
    /// Losing one word on one paragraph is something nobody notices. Moving every
    /// highlight in the chapter by one character is not.
    static func rendered(_ text: String, in script: ChineseScript) -> String {
        guard script.depth != .off, text.unicodeScalars.contains(where: isHan) else { return text }

        if script.depth == .phrases, let converter = phraseConverter(for: script.target) {
            let phrased = converter.convert(text)
            if phrased.utf16.count == text.utf16.count { return phrased }
        }

        guard let mapped = transformed(text, using: script.target.transform),
              mapped.utf16.count == text.utf16.count
        else { return text }
        return mapped
    }

    /// Loads the phrase dictionaries off the main thread, if that is the tier in force.
    ///
    /// A few megabytes of tables, and the paginated reader composes its chapter on the
    /// main thread — so without this the first page after choosing 字彙 hitches on the one
    /// frame the reader is looking at. A no-op at every other depth.
    static func prewarm(_ script: ChineseScript) {
        guard script.depth == .phrases else { return }
        DispatchQueue.global(qos: .utility).async {
            _ = phraseConverter(for: script.target)
        }
    }

    // MARK: - Converters

    private static let lock = NSLock()
    private static var converters: [ChineseScript.Target: ChineseConverter] = [:]
    /// Targets whose dictionaries would not load. Remembered so a device that cannot
    /// build one does not pay to rediscover that on every paragraph.
    private static var unavailable: Set<ChineseScript.Target> = []

    /// Built once and shared. `ChineseConverter` is documented immutable and threadsafe,
    /// and the lock is held across the build on purpose: two columns laying out at once
    /// should wait for one set of dictionaries rather than each load their own.
    private static func phraseConverter(for target: ChineseScript.Target) -> ChineseConverter? {
        lock.lock()
        defer { lock.unlock() }
        if let existing = converters[target] { return existing }
        guard !unavailable.contains(target) else { return nil }
        guard let built = try? ChineseConverter(options: target.openCCOptions) else {
            unavailable.insert(target)
            return nil
        }
        converters[target] = built
        return built
    }

    private static func transformed(_ text: String, using transform: String) -> String? {
        let mutable = NSMutableString(string: text)
        guard CFStringTransform(mutable, nil, transform as CFString, false) else { return nil }
        return mutable as String
    }

    /// Worth asking before anything else: most of what goes through here on an English
    /// article, and every marker and rule in a Chinese one, has no Han character in it at
    /// all, and both converters cost more than this scan.
    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,   // CJK Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xF900...0xFAFF:   // Compatibility ideographs
            return true
        default:
            return false
        }
    }
}

private extension ChineseScript.Target {
    /// The ICU transform that lands *in* this script — named for where it goes, so
    /// `.traditional` reads from simplified.
    var transform: String {
        switch self {
        case .traditional: return "Simplified-Traditional"
        case .simplified: return "Traditional-Simplified"
        }
    }

    /// Taiwan's standard and its vocabulary in both directions, rather than the
    /// mainland-published traditional forms: this app is authored and read in Taiwan,
    /// where 「裡」 and 「著」 have one right answer each, and a reader who asks for
    /// simplified wants 「软件」 rather than a transliterated 「軟體」.
    var openCCOptions: ChineseConverter.Options {
        switch self {
        case .traditional: return [.traditionalize, .twStandard, .twIdiom]
        case .simplified: return [.simplify, .twStandard, .twIdiom]
        }
    }
}

extension ArticleBlock {
    /// The block with its prose in the reader's script.
    ///
    /// Run by run rather than on the joined text, which is what keeps each run's length
    /// intact and therefore the paragraph's; and never a listing, because converting code
    /// rewrites identifiers into characters no compiler has heard of.
    func rendered(in script: ChineseScript) -> ArticleBlock {
        guard script.depth != .off, kind != .code, !runs.isEmpty else { return self }
        var converted = self
        converted.runs = runs.map { run in
            var run = run
            run.text = ChineseText.rendered(run.text, in: script)
            return run
        }
        return converted
    }
}
