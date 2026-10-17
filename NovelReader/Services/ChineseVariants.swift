import Foundation

/// Traditional / simplified forms of a search query.
///
/// These sites are split down the middle: some serve simplified text, some
/// traditional, and a title indexed in one script simply does not match a query
/// typed in the other. A reader in Taiwan typing 「鬥破蒼穹」 should not get an
/// empty page from a simplified site that has the book — so both forms are
/// searched and the results merged.
///
/// Conversion is the reader's character tier, which is right far more often
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
        guard !trimmed.isEmpty, trimmed.unicodeScalars.contains(where: ChineseText.isHan) else {
            return trimmed.isEmpty ? [] : [trimmed]
        }
        // Try the direction that changes something. A traditional query has a
        // simplified counterpart and vice versa; running both directions would
        // just produce the same pair twice.
        for target in [ChineseScript.Target.simplified, .traditional] {
            let other = ChineseText.rendered(trimmed, in: ChineseScript(depth: .characters, target: target))
            if other != trimmed { return [trimmed, other] }
        }
        return [trimmed]
    }
}
