import Foundation

/// Works out a site's URL templates and id regexes from one book URL plus the
/// chapter links found on it.
///
/// This is the part of rule authoring that is pure guesswork by hand and pure
/// arithmetic by machine: every one of these sites encodes the book id and the
/// chapter id somewhere in the path, and the chapter links on a catalog page are
/// a free set of examples showing exactly which part varies.
///
/// Deliberately a pure function over URLs, with no DOM and no network, because
/// it is the piece most likely to be subtly wrong and the only way to know is to
/// pin it against real URL shapes from real sites.
enum URLPatternInference {
    struct Inferred: Equatable {
        var bookId: String
        var bookTemplate: String
        var chapterTemplate: String
        var bookIdPattern: String
        var chapterIdPattern: String
    }

    static let bookIdPlaceholder = "{bookId}"
    static let chapterIdPlaceholder = "{chapterId}"

    /// Character class used for ids that are not purely numeric. Slug ids on
    /// these sites are alphanumeric with the occasional dash or underscore.
    private static let slugClass = "[0-9A-Za-z_-]"

    /// Path words that carry no identity — a rule that captured one of these as
    /// the book id would match every page on the site.
    private static let structuralWords: Set<String> = [
        "book", "books", "novel", "novels", "n", "txt", "read", "chapter",
        "chapters", "list", "info", "index", "html", "htm", "php", "shtml",
        "xiaoshuo", "content", "view", "page", "comic", "comics", "manga",
    ]

    // MARK: - Entry point

    /// - Parameters:
    ///   - bookURL: the page the user pasted.
    ///   - chapterURLs: chapter links harvested from the catalog. Two or more
    ///     make the inference exact; one still works but has to guess which
    ///     token varies.
    static func infer(bookURL: URL, chapterURLs: [URL]) -> Inferred? {
        let chapters = chapterURLs.map(stripQuery).uniqued()
        guard !chapters.isEmpty else { return nil }
        guard let bookId = inferBookId(bookURL: bookURL, chapterURLs: chapters) else { return nil }

        let bookTemplate = substituting(bookId, with: bookIdPlaceholder, in: bookURL.absoluteString)
        // Only this book's links may shape the chapter template. Catalog markup
        // routinely mixes in a site-wide "recently updated" list, and one foreign
        // link at the head of the list would otherwise become the template —
        // silently pinning every chapter URL to somebody else's book.
        let owned = chapters.filter { $0.contains(bookId) }
        guard !owned.isEmpty else { return nil }
        let chapterBodies = owned.map { substituting(bookId, with: bookIdPlaceholder, in: $0) }
        guard let chapterId = inferChapterId(in: chapterBodies, bookId: bookId),
              let first = chapterBodies.first
        else { return nil }
        let chapterTemplate = substituting(chapterId, with: chapterIdPlaceholder, in: first)

        return Inferred(
            bookId: bookId,
            bookTemplate: bookTemplate,
            chapterTemplate: chapterTemplate,
            bookIdPattern: bookIdPattern(from: bookTemplate, bookId: bookId),
            chapterIdPattern: chapterIdPattern(from: chapterTemplate, chapterId: chapterId)
        )
    }

    /// Path tokens from `url` that look like identifiers rather than structure,
    /// best first. Used to find other pages about the same book before anything
    /// is known about the site.
    ///
    /// A structural word is excluded outright rather than ranked last, and by
    /// name rather than by score. Scoring it down cannot express "never": the
    /// penalty competes with token length, so a long enough structural word
    /// survives it — `mycomic.com/comics/19799` offers `comics`, which outlived
    /// the penalty and, because every link in the page's related-comics strip
    /// contains it, was accepted as the book id. The rule that came out said the
    /// book was called "comics" and its chapters were other people's books.
    static func identifierTokens(in url: URL) -> [String] {
        tokens(in: url.path)
            .filter { $0.count >= 2 && !structuralWords.contains($0.lowercased()) }
            .sorted { score($0) > score($1) }
    }

    /// Rewrites `urlString` into a template by replacing a known book id with the
    /// placeholder. Used for the catalog URL, which may be a different page from
    /// the one the ids were inferred from.
    static func template(for urlString: String, bookId: String) -> String {
        substituting(bookId, with: bookIdPlaceholder, in: urlString)
    }

    // MARK: - Which token is the book id

    /// The book id is the token in the book URL's path that also shows up in
    /// (almost) every chapter link. "Almost" rather than "every" because
    /// catalogs habitually mix in a stray link to a related book.
    private static func inferBookId(bookURL: URL, chapterURLs: [String]) -> String? {
        // `identifierTokens` has already dropped the structural words. Accepting
        // one as a fallback is worse than failing: "/book/90442.htm" against a
        // list of *other* books' pages would settle on "book", producing a rule
        // that treats every page on the site as the same book. Failing instead
        // lets the caller go and find the real catalog.
        let candidates = identifierTokens(in: bookURL)
        // Well under a majority: a catalog container often holds the book's own
        // chapters *and* a site-wide recent-updates list, so the real book id can
        // be a minority of the links in it. The foreign links are filtered out
        // afterwards; what matters here is finding the token, not counting it.
        let needed = Int((Double(chapterURLs.count) * 0.3).rounded(.up))
        for candidate in candidates {
            let hits = chapterURLs.filter { $0.contains(candidate) }.count
            if hits >= max(needed, 1) { return candidate }
        }
        return nil
    }

    /// Prefers tokens that look like identifiers: digits are a strong signal,
    /// length is a weak one, and a structural path word is pushed down. Ranking
    /// only — `identifierTokens` is where a structural word is refused outright.
    private static func score(_ token: String) -> Int {
        var value = token.count
        if token.contains(where: \.isNumber) { value += 2 }
        if structuralWords.contains(token.lowercased()) { value -= 5 }
        return value
    }

    // MARK: - Which token is the chapter id

    /// With two or more chapter links, the chapter id is simply the token that
    /// differs between them at the same position. With only one, fall back to
    /// scoring, the same way the book id is chosen.
    private static func inferChapterId(in chapterBodies: [String], bookId: String) -> String? {
        if chapterBodies.count >= 2 {
            let a = tokens(in: chapterBodies[0])
            for other in chapterBodies.dropFirst() {
                let b = tokens(in: other)
                guard a.count == b.count else { continue }
                // Last differing token: a URL that varies in two places (a volume
                // folder plus a chapter file) identifies the chapter by the more
                // specific one.
                if let index = a.indices.last(where: { a[$0] != b[$0] }) {
                    return a[index]
                }
            }
        }
        // Path only: with a single example there is nothing to diff against, and
        // scoring the whole URL would let a host token ("hetubook") outrank the id.
        return tokens(in: pathPortion(of: chapterBodies[0]))
            .filter { $0.count >= 2 && $0 != bookId && $0 != "bookId" }
            .max { score($0) < score($1) }
    }

    // MARK: - Regexes

    /// Anchors on the literal path that precedes the id, and stops right after
    /// it (keeping a trailing `/` when there is one).
    ///
    /// Truncating rather than using the whole template is what lets the pattern
    /// recover the book id from a *chapter* URL too, which is how "paste any link
    /// from this book" works. It cannot always: when a site puts chapters on a
    /// different path prefix than book pages, only the book page URL will resolve.
    private static func bookIdPattern(from bookTemplate: String, bookId: String) -> String {
        let path = pathPortion(of: bookTemplate)
        guard let range = path.range(of: bookIdPlaceholder) else { return path }
        var literal = String(path[path.startIndex..<range.lowerBound])
        var suffix = ""
        if path[range.upperBound...].first == "/" { suffix = "/" }
        // Escape only the literal part; the placeholder becomes the capture.
        literal = NSRegularExpression.escapedPattern(for: literal)
        return literal + "(" + characterClass(for: bookId) + "+)" + NSRegularExpression.escapedPattern(for: suffix)
    }

    /// Uses the whole chapter path so the pattern cannot match a book page URL —
    /// telling those two apart is the entire job of `chapterId`.
    private static func chapterIdPattern(from chapterTemplate: String, chapterId: String) -> String {
        var out = ""
        var rest = Substring(pathPortion(of: chapterTemplate))
        while let hit = [rest.range(of: bookIdPlaceholder), rest.range(of: chapterIdPlaceholder)]
            .compactMap({ $0 }).min(by: { $0.lowerBound < $1.lowerBound })
        {
            out += NSRegularExpression.escapedPattern(for: String(rest[rest.startIndex..<hit.lowerBound]))
            out += rest[hit] == bookIdPlaceholder
                ? slugClass + "+"
                : "(" + characterClass(for: chapterId) + "+)"
            rest = rest[hit.upperBound...]
        }
        return out + NSRegularExpression.escapedPattern(for: String(rest))
    }

    private static func characterClass(for id: String) -> String {
        id.allSatisfy(\.isNumber) ? "\\d" : slugClass
    }

    // MARK: - String plumbing

    /// Runs of identifier characters. Underscores and dashes are *inside* a
    /// token, not separators: twking's book id is literally `216_216497`, and
    /// splitting it would leave two half-ids that match the wrong things.
    static func tokens(in string: String) -> [String] {
        var out: [String] = []
        var current = ""
        for character in string {
            if character.isLetter || character.isNumber || character == "_" || character == "-" {
                current.append(character)
            } else if !current.isEmpty {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Replaces the id in the path, never in the host — `hetubook.com` contains
    /// tokens that a short numeric id could collide with.
    private static func substituting(_ id: String, with placeholder: String, in urlString: String) -> String {
        guard let hostEnd = hostEndIndex(of: urlString) else {
            return urlString.replacingOccurrences(of: id, with: placeholder)
        }
        let head = String(urlString[urlString.startIndex..<hostEnd])
        let tail = String(urlString[hostEnd...])
        guard let range = tail.range(of: id) else { return urlString }
        return head + tail.replacingCharacters(in: range, with: placeholder)
    }

    private static func hostEndIndex(of urlString: String) -> String.Index? {
        guard let schemeEnd = urlString.range(of: "://")?.upperBound else { return nil }
        return urlString[schemeEnd...].firstIndex(of: "/") ?? urlString.endIndex
    }

    private static func pathPortion(of template: String) -> String {
        guard let hostEnd = hostEndIndex(of: template) else { return template }
        return String(template[hostEnd...])
    }

    private static func stripQuery(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        return components?.url?.absoluteString ?? url.absoluteString
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
