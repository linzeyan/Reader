import Foundation

/// Fetches book metadata, catalogs and chapter text through the rule engine.
///
/// Everything site-specific arrives as a `SiteRule`; this type only knows how to
/// drive the fetcher and how to reconcile what comes back with the database.
@MainActor
final class BookService {
    /// The site-provided description of a book, before it becomes a bookmark.
    struct Info: Equatable {
        var title: String
        var author: String?
        var cover: String?
        var category: String?
        var status: String?
        var intro: String?
        var latestChapter: String?
    }

    enum ServiceError: LocalizedError {
        case badURL
        case noTitle
        case emptyCatalog
        case emptyChapter

        var errorDescription: String? {
            switch self {
            case .badURL: return String(localized: "error.badURL")
            case .noTitle: return String(localized: "error.noTitle")
            case .emptyCatalog: return String(localized: "error.emptyCatalog")
            case .emptyChapter: return String(localized: "error.emptyChapter")
            }
        }
    }

    private let fetcher: WebFetcher
    private let repo: LibraryRepo

    init(fetcher: WebFetcher, repo: LibraryRepo) {
        self.fetcher = fetcher
        self.repo = repo
    }

    // MARK: - Book page

    func info(rule: SiteRule, siteBookId: String) async throws -> Info {
        guard let url = rule.bookURL(bookId: siteBookId) else { throw ServiceError.badURL }
        let script = try ExtractorScript.book(rule)
        let payload = try await fetcher.fetch(url, extracting: script, as: ExtractorScript.BookPayload.self)
        guard let title = payload.title, !title.isEmpty else { throw ServiceError.noTitle }
        return Info(
            title: title, author: payload.author, cover: payload.cover,
            category: payload.category, status: payload.status,
            intro: payload.intro, latestChapter: payload.latestChapter
        )
    }

    // MARK: - Catalog

    /// Fetches the catalog and writes it over the book's chapter index.
    ///
    /// Links are filtered through `idPatterns.chapterId` rather than trusted
    /// wholesale: a CSS selector broad enough to catch every chapter (several of
    /// these catalogs have no container of their own) also catches navigation,
    /// "latest chapters" teasers and cross-links to other books. The id pattern is
    /// the only thing that actually says "this is a chapter of this book".
    @discardableResult
    func refreshCatalog(rule: SiteRule, book: Book) async throws -> [Chapter] {
        guard let url = rule.catalogURL(bookId: book.siteBookId) else { throw ServiceError.badURL }
        let script = try ExtractorScript.catalog(rule)
        let payload = try await fetcher.fetch(url, extracting: script, as: ExtractorScript.CatalogPayload.self)

        var seen = Set<String>()
        var entries: [(siteChapterId: String, title: String, url: String)] = []
        for entry in payload.entries {
            guard let entryURL = URL(string: entry.url),
                  let chapterId = rule.chapterId(from: entryURL)
            else { continue }
            // A chapter URL that carries a *different* book id belongs to another
            // book; one that carries none is accepted, since not every site puts
            // the book id in its chapter path.
            if let owner = rule.bookId(from: entryURL), owner != book.siteBookId { continue }
            guard seen.insert(chapterId).inserted else { continue }
            entries.append((chapterId, entry.title, entry.url))
        }
        guard !entries.isEmpty else { throw ServiceError.emptyCatalog }

        try repo.replaceCatalog(bookId: book.id, entries: entries)
        return try repo.chapters(bookId: book.id)
    }

    // MARK: - Chapter text

    /// Reads one chapter's paragraphs. The chapter's stored URL is preferred over
    /// a rebuilt one — the catalog gave us the link the site itself uses, and some
    /// sites' templates do not round-trip through `{bookId}/{chapterId}`.
    ///
    /// Retried once when the page yields nothing. Observed on ad-heavy sites: an
    /// ad script navigates the page out from under the extractor, so the script
    /// runs against a document that has no chapter in it. A second attempt lands
    /// on the real page. Bounded to one retry — a chapter that is genuinely empty
    /// must surface as an error, not as a loop against the site.
    func chapterParagraphs(rule: SiteRule, chapter: Chapter) async throws -> [String] {
        do {
            return try await fetchParagraphs(rule: rule, chapter: chapter)
        } catch ServiceError.emptyChapter {
            return try await fetchParagraphs(rule: rule, chapter: chapter)
        }
    }

    private func fetchParagraphs(rule: SiteRule, chapter: Chapter) async throws -> [String] {
        guard let url = URL(string: chapter.url) else { throw ServiceError.badURL }
        let script = try ExtractorScript.chapter(rule)
        let payload = try await fetcher.fetch(url, extracting: script, as: ExtractorScript.ChapterPayload.self)
        let paragraphs = Self.dropping(rule.chapter.dropParagraphPatterns, from: payload.paragraphs)
        guard !paragraphs.isEmpty else { throw ServiceError.emptyChapter }
        return paragraphs
    }

    /// Applies a rule's `dropParagraphPatterns`.
    ///
    /// Filtered in Swift rather than inside the extractor so the patterns use the
    /// same regex engine as `idPatterns` — one flavour to learn when writing a
    /// rule file, instead of ICU in one field and JavaScript in another.
    /// An unparseable pattern is skipped rather than fatal: a typo in one line of
    /// a user-imported rule must not make the whole chapter unreadable.
    /// Pure — `nonisolated` so it stays callable (and testable) off the main actor.
    nonisolated static func dropping(_ patterns: [String]?, from paragraphs: [String]) -> [String] {
        guard let patterns, !patterns.isEmpty else { return paragraphs }
        let regexes = patterns.compactMap { try? NSRegularExpression(pattern: $0) }
        guard !regexes.isEmpty else { return paragraphs }
        return paragraphs.filter { paragraph in
            let range = NSRange(paragraph.startIndex..., in: paragraph)
            return !regexes.contains { $0.firstMatch(in: paragraph, range: range) != nil }
        }
    }
}
