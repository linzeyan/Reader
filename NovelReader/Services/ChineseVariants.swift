import Foundation

/// Traditional / simplified forms of a search query.
///
/// These sites are split down the middle: some serve simplified text, some
/// traditional, and a title indexed in one script simply does not match a query
/// typed in the other. A reader in Taiwan typing 「鬥破蒼穹」 should not get an
/// empty page from a simplified site that has the book — so both forms are
/// searched and the results merged.
///
/// Conversion is character-by-character (ICU), which is right far more often
/// than not but has no idea about phrases: 「斗羅大陸」 converts to 「鬥羅大陸」
/// because 斗/鬥 merged in simplification. That is exactly why the form the user
/// actually typed is always searched too, and first — the converted form is an
/// extra chance, never a replacement.
enum ChineseVariants {
    /// The distinct queries worth sending, in the order to send them. Always
    /// starts with the query as typed, and is at most two entries: three
    /// requests per site for one search is not politeness, it is a burst.
    static func forms(of query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.unicodeScalars.contains(where: isHan) else {
            return trimmed.isEmpty ? [] : [trimmed]
        }
        // Try the direction that changes something. A traditional query has a
        // simplified counterpart and vice versa; running both directions would
        // just produce the same pair twice.
        if let simplified = converted(trimmed, using: "Traditional-Simplified"), simplified != trimmed {
            return [trimmed, simplified]
        }
        if let traditional = converted(trimmed, using: "Simplified-Traditional"), traditional != trimmed {
            return [trimmed, traditional]
        }
        return [trimmed]
    }

    private static func converted(_ text: String, using transform: String) -> String? {
        let mutable = NSMutableString(string: text)
        guard CFStringTransform(mutable, nil, transform as CFString, false) else { return nil }
        return mutable as String
    }

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
