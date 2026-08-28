import Foundation

/// One hit from a site's search results.
struct SearchResult: Identifiable, Hashable {
    /// `siteId|siteBookId` — the same identity the library uses, so a result can
    /// be checked against existing bookmarks without another lookup shape.
    let id: String
    let siteId: String
    let siteName: String
    let siteBookId: String
    let title: String
    let author: String?
    let coverURL: String?
}

/// What one site produced for a query. Carries the failure rather than throwing
/// it, because a cross-site search must report "3 sites answered, 1 needs
/// verification, 1 has no search support" instead of collapsing on the first
/// site that misbehaves.
struct SiteSearchOutcome: Identifiable {
    var id: String { siteId }
    let siteId: String
    let siteName: String
    let results: [SearchResult]
    let failure: (any Error)?
}

/// Searches one site, or every site in turn.
@MainActor
final class SearchService {
    private let fetcher: WebFetcher

    init(fetcher: WebFetcher) {
        self.fetcher = fetcher
    }

    // MARK: - Single site

    /// Searches a site for every script form of `query` and merges the hits.
    ///
    /// The first form is what the user typed, so its results lead. A later form
    /// only contributes books the earlier ones did not already find; a site that
    /// happens to match both scripts must not show every book twice.
    ///
    /// A failure on the *first* form propagates — that is the search the user
    /// asked for, and swallowing its error would show an empty page with no
    /// explanation. A failure on a follow-up form is ignored: it was a bonus.
    func search(_ query: String, in rule: SiteRule) async throws -> [SearchResult] {
        var merged: [SearchResult] = []
        var seen: Set<String> = []
        for (index, form) in ChineseVariants.forms(of: query).enumerated() {
            let hits: [SearchResult]
            if index == 0 {
                hits = try await searchOnce(form, in: rule)
            } else {
                guard let extra = try? await searchOnce(form, in: rule) else { continue }
                hits = extra
            }
            for hit in hits where seen.insert(hit.id).inserted {
                merged.append(hit)
            }
        }
        return merged
    }

    private func searchOnce(_ query: String, in rule: SiteRule) async throws -> [SearchResult] {
        guard let search = rule.search else { throw ExtractorScript.BuildError.searchUnsupported }
        let extractor = try ExtractorScript.searchResults(rule)

        let payload: ExtractorScript.SearchPayload
        switch search.method {
        case .get:
            guard let url = Self.getSearchURL(search, query: query) else {
                throw ExtractorScript.BuildError.encodingFailed
            }
            payload = try await fetcher.fetch(
                url, extracting: extractor, as: ExtractorScript.SearchPayload.self,
                signIn: rule.signIn
            )
        case .post:
            // Land on the site first so the submitted form inherits the site's
            // charset and cookies, then post from inside the page.
            guard let origin = URL(string: search.url).flatMap({ url -> URL? in
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                components?.path = "/"
                components?.query = nil
                return components?.url
            }) else { throw ExtractorScript.BuildError.encodingFailed }
            let submit = try ExtractorScript.submitSearch(rule, query: query)
            payload = try await fetcher.fetch(
                origin, submitting: submit, extracting: extractor,
                as: ExtractorScript.SearchPayload.self, signIn: rule.signIn
            )
        }

        return payload.rows.compactMap { row in
            guard let url = URL(string: row.url), let bookId = rule.bookId(from: url) else { return nil }
            return SearchResult(
                id: Book.makeId(siteId: rule.id, siteBookId: bookId),
                siteId: rule.id,
                siteName: rule.name,
                siteBookId: bookId,
                title: row.title,
                author: row.author,
                coverURL: row.cover
            )
        }
    }

    /// Pure URL templating — no main-actor state involved, so it stays callable
    /// from anywhere (and directly testable).
    nonisolated static func getSearchURL(_ search: SiteRule.Search, query: String) -> URL? {
        let escaped = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return URL(string: search.url.replacingOccurrences(of: "{query}", with: escaped))
    }

    // MARK: - All sites

    /// Searches every rule and yields each site's outcome as it lands.
    ///
    /// Sequential by necessity, not by choice: the fetcher owns a single
    /// WKWebView, so pages can only be loaded one at a time. Streaming the
    /// outcomes means the UI fills in site by site instead of staring at a
    /// spinner until the slowest source replies.
    func searchAll(_ query: String, in rules: [SiteRule]) -> AsyncStream<SiteSearchOutcome> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                for rule in rules {
                    if Task.isCancelled { break }
                    do {
                        let results = try await self.search(query, in: rule)
                        continuation.yield(SiteSearchOutcome(
                            siteId: rule.id, siteName: rule.name, results: results, failure: nil
                        ))
                    } catch {
                        continuation.yield(SiteSearchOutcome(
                            siteId: rule.id, siteName: rule.name, results: [], failure: error
                        ))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
