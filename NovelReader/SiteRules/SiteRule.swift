import Foundation

/// A declarative description of how to read one novel site.
///
/// The app ships with no rules at all: users add sources by importing a rule
/// file. Everything site-specific therefore has to be expressible here — any
/// `if site == "..."` in Swift is a bug, not a shortcut.
struct SiteRule: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let host: String
    let urls: URLTemplates
    let idPatterns: IDPatterns
    let search: Search?
    let book: BookFields
    let catalog: Catalog
    let chapter: Chapter
    /// Free-form provenance notes. Ignored at runtime, kept so a rule file
    /// stays self-documenting when it travels between devices.
    let notes: [String]?

    // MARK: - Nested shapes

    struct URLTemplates: Codable, Hashable {
        /// Templates use `{bookId}` / `{chapterId}` placeholders.
        let book: String
        let catalog: String
        let chapter: String
    }

    struct IDPatterns: Codable, Hashable {
        /// Regexes with one capture group, used to recover ids from a pasted URL.
        let bookId: String
        let chapterId: String
    }

    struct Search: Codable, Hashable {
        enum Method: String, Codable { case get = "GET", post = "POST" }
        let method: Method
        /// GET: a template containing `{query}`. POST: the form endpoint.
        let url: String
        /// POST field name. Unused for GET templates.
        let queryField: String
        /// Optional wrapper around the result rows. When present, the row
        /// selectors below are scoped to it, which keeps sidebars and
        /// "you may also like" blocks out of the results.
        let resultContainer: String?
        /// Selector for the link of one result row.
        let resultLinkSelector: String
        /// Optional richer fields; when absent the link text becomes the title.
        let resultTitleSelector: String?
        let resultAuthorSelector: String?
        let resultCoverSelector: String?
    }

    /// How to read one field: either an `og:`/`name=` meta tag or a CSS selector.
    /// Meta is preferred where a site provides it — it survives layout changes
    /// that break selectors.
    struct Field: Codable, Hashable {
        let meta: String?
        let selector: String?
        /// Read this attribute instead of the element's text.
        let attribute: String?
    }

    struct BookFields: Codable, Hashable {
        let title: Field
        let author: Field?
        let cover: Field?
        let category: Field?
        let status: Field?
        let intro: Field?
        let latestChapter: Field?
    }

    struct Catalog: Codable, Hashable {
        enum Order: String, Codable {
            /// Chapter 1 first (DOM order matches reading order).
            case ascending
            /// Newest first — the list has to be reversed after extraction.
            case descending
        }
        let container: String
        let linkSelector: String
        let order: Order
    }

    struct Chapter: Codable, Hashable {
        /// Tried in order; the first selector that matches a non-empty node wins.
        /// A list rather than a single value because a site's chapter markup is
        /// the part most likely to drift, and recon can't always confirm it.
        let titleSelectors: [String]
        let contentSelectors: [String]
        /// Removed from the content node before text extraction (ads, nav, scripts).
        let stripSelectors: [String]
        /// Regexes matched against each extracted paragraph; a match drops the line.
        ///
        /// Exists because these sites bury boilerplate *inside* the chapter body —
        /// "請記住本站域名: …", "本章未完，請點擊下一頁" — where no selector can reach
        /// it, especially on the sites whose text is only found by the
        /// largest-text-block heuristic. Optional so rule files written before it
        /// existed still decode.
        let dropParagraphPatterns: [String]?
        let prevSelector: String?
        let nextSelector: String?
    }
}

// MARK: - URL building / parsing

extension SiteRule {
    func bookURL(bookId: String) -> URL? {
        URL(string: urls.book.replacingOccurrences(of: "{bookId}", with: bookId))
    }

    func catalogURL(bookId: String) -> URL? {
        URL(string: urls.catalog.replacingOccurrences(of: "{bookId}", with: bookId))
    }

    func chapterURL(bookId: String, chapterId: String) -> URL? {
        let s = urls.chapter
            .replacingOccurrences(of: "{bookId}", with: bookId)
            .replacingOccurrences(of: "{chapterId}", with: chapterId)
        return URL(string: s)
    }

    /// Recovers a book id from any URL on this site, so "paste a link" works
    /// whether the user copied the book page or the catalog page.
    func bookId(from url: URL) -> String? {
        Self.firstCapture(of: idPatterns.bookId, in: url.absoluteString)
    }

    func chapterId(from url: URL) -> String? {
        Self.firstCapture(of: idPatterns.chapterId, in: url.absoluteString)
    }

    func matches(_ url: URL) -> Bool {
        url.host()?.caseInsensitiveCompare(host) == .orderedSame
    }

    /// A copy carrying a different search block. Search is the one part of a rule
    /// that can be worked out separately from the rest — it lives on pages the
    /// book-page derivation never visits — so it has to be attachable afterwards.
    func settingSearch(_ search: Search?) -> SiteRule {
        SiteRule(
            id: id, name: name, host: host, urls: urls, idPatterns: idPatterns,
            search: search, book: book, catalog: catalog, chapter: chapter, notes: notes
        )
    }

    private static func firstCapture(of pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s)
        else { return nil }
        return String(s[r])
    }
}
