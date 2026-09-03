import Foundation

/// Subscriptions: reading a feed document, and keeping a book of chapters in step with
/// it.
///
/// The one source in this app that does not go through the shared `WebFetcher`. A feed is
/// a static XML or JSON document on whoever's host, not one of the challenged novel
/// sites, and routing it through the single web view would evict whatever page the reader
/// or a download is part way through — for a document that never needed a browser engine
/// to be read. `SiteStore.importRule(fromRemote:)` and `ImageFetcher` take the same
/// exit for the same reason.
///
/// The web view is still used for one thing: turning an article's markup into the blocks it
/// will be laid out as, which is `ExtractorScript.article` and the isolated import view —
/// the very same path an EPUB's documents take. That is where a refresh spends its time,
/// and it is why only articles that have no text yet are put through it.
@MainActor
final class FeedService {
    enum FeedError: LocalizedError {
        case badAddress
        case http(Int)
        /// An article the feed listed but published no readable body for. Thrown by the
        /// reader rather than here: this is not a failure to fetch anything, it is an
        /// article that never had text, and the only moment it matters is when someone
        /// opens it.
        case emptyArticle

        var errorDescription: String? {
            switch self {
            case .badAddress: return String(localized: "feed.error.badAddress")
            case .http(let code): return String(localized: "feed.error.http \(code)")
            case .emptyArticle: return String(localized: "feed.error.emptyArticle")
            }
        }
    }

    private let repo: LibraryRepo
    private let downloads: DownloadStore
    private let fetcher: WebFetcher
    private let session: URLSession
    private let images: ArticleImages

    init(
        repo: LibraryRepo,
        downloads: DownloadStore,
        fetcher: WebFetcher,
        session: URLSession = .shared
    ) {
        self.repo = repo
        self.downloads = downloads
        self.fetcher = fetcher
        self.session = session
        self.images = ArticleImages(session: session, downloads: downloads)
    }

    // MARK: - Subscribing

    /// Subscribes to a feed and pulls its first batch of articles in the same breath.
    ///
    /// Both halves here, rather than leaving the articles to the first open, for the
    /// reason `AppEnvironment.addBook` gives: subscribing is already a "wait for the
    /// network" moment, and a feed that appears on the shelf and then turns out to be an
    /// empty screen is the one moment a new subscription has to feel like it worked.
    ///
    /// What is pasted is usually the site, not its feed, so a document that turns out to
    /// be a web page is asked what feed it declares before the attempt is given up on —
    /// see `FeedDiscovery`.
    @discardableResult
    func subscribe(to address: String) async throws -> Book {
        guard let url = Self.url(from: address) else { throw FeedError.badAddress }
        var response = try await read(url, validators: nil)
        // "Nothing has changed" against a request that carried no validators. No correct
        // server does this, and there is nothing to fall back on — a subscription with no
        // document behind it would be a row on the shelf that opens onto nothing.
        guard let body = response.body else { throw FeedError.http(304) }

        var parsed: ParsedFeed
        do {
            parsed = try FeedParser.parse(body, url: response.landed)
        } catch {
            // The original error, not a discovery one, when the page names no feed: an
            // address that is simply not a feed is what the reader has to be told, and
            // "no feed was declared" would be a sentence about a page they did not know
            // they had fetched.
            guard let declared = FeedDiscovery.feedURL(inHTML: body, at: response.landed) else {
                throw error
            }
            response = try await read(declared, validators: nil)
            guard let declaredBody = response.body else { throw FeedError.http(304) }
            parsed = try FeedParser.parse(declaredBody, url: response.landed)
        }
        // The address it *landed* on, not the one that was typed. A feed reached over
        // `http` that redirects to `https`, or through a trailing-slash rewrite, would
        // otherwise be two different books on the shelf holding the same articles —
        // `Book.id` is built out of this string.
        let book = try repo.bookmark(
            siteId: Book.feedSiteId,
            siteBookId: response.landed.absoluteString,
            kind: .feed,
            title: Self.name(of: parsed, at: response.landed),
            coverURL: parsed.iconURL
        )
        try repo.saveFeedFetchState(response.state(for: book.id))
        try await store(parsed, in: book)
        return book
    }

    /// Reads a subscription again and takes in whatever is new.
    @discardableResult
    func refresh(_ book: Book) async throws -> [Chapter] {
        guard let url = Self.url(from: book.siteBookId) else { throw FeedError.badAddress }
        let response = try await read(url, validators: try repo.feedFetchState(bookId: book.id))
        try repo.saveFeedFetchState(response.state(for: book.id))
        if let body = response.body {
            // No discovery on this path, unlike subscribing. A subscription's address was
            // a feed the day it was added, so a page coming back from it means the
            // publisher moved or lost it — and following whatever that page declares
            // would quietly repoint the book at another feed's articles.
            try await store(try FeedParser.parse(body, url: response.landed), in: book)
        } else {
            // A `304` is a successful read of the index that found nothing in it, so the
            // catalog is as fresh as if the whole document had come back. Without this
            // the feed would still look stale and every visit to its screen would ask
            // again — which is the one thing conditional requests exist to stop.
            try repo.touchCatalog(bookId: book.id)
        }
        return try repo.chapters(bookId: book.id)
    }

    // MARK: - Retention

    /// Deletes the articles this subscription is no longer keeping, and their text.
    ///
    /// The rules are `FeedRetention.purgeable`'s; what is here is the order the two halves
    /// happen in. The file goes first and the row second, which is `DownloadStore`'s
    /// doctrine turned around for the one case where the row is going too: a crash between
    /// them leaves a row whose text is gone — an article the reader is offered and told is
    /// not downloaded — where the other order would leave a file nothing can ever find or
    /// delete.
    ///
    /// - Returns: how many articles went, so a caller can decide whether anything on
    ///   screen needs re-reading.
    @discardableResult
    func purge(_ book: Book, policy: FeedRetention.Policy, now: Date = Date()) throws -> Int {
        guard book.kind == .feed, policy.keepCount > 0 else { return 0 }
        let chapters = try repo.chapters(bookId: book.id)
        let marked = Set(
            try repo.readingBookmarks(bookId: book.id).map(\.siteChapterId)
                + (try repo.highlights(bookId: book.id).map(\.siteChapterId))
        )
        let doomed = FeedRetention.purgeable(
            from: chapters,
            lastReadIndex: book.lastReadIndex(in: chapters),
            marked: marked,
            stillPublished: try repo.feedFetchState(bookId: book.id)?.windowOldestAt,
            policy: policy,
            now: now
        )
        guard !doomed.isEmpty else { return 0 }

        for chapter in doomed {
            try? downloads.delete(.chapter(book: book, siteChapterId: chapter.siteChapterId))
        }
        try repo.removeChapters(bookId: book.id, siteChapterIds: doomed.map(\.siteChapterId))
        return doomed.count
    }

    // MARK: - Fetching

    /// One response, before anything about it has reached the database.
    ///
    /// The bytes rather than a parsed feed, because what came back is not always a feed:
    /// subscribing takes a page it cannot parse and asks it what feed it declares, which
    /// needs the document itself.
    private struct Response {
        var landed: URL
        var etag: String?
        var lastModified: String?
        /// Nil exactly when the server said nothing has changed.
        var body: Data?
        var checkedAt: Date

        func state(for bookId: String) -> FeedFetchState {
            FeedFetchState(
                bookId: bookId, etag: etag, lastModified: lastModified, checkedAt: checkedAt
            )
        }
    }

    private func read(_ url: URL, validators: FeedFetchState?) async throws -> Response {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw FeedError.badAddress
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        // This app's own conditional request, not `URLSession`'s. Left on the default
        // policy the session revalidates on its own terms and hands back a `200` built
        // out of its cache, so the `304` this is written around would never be seen and
        // the validators stored per feed would be dead weight.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // The same user agent the web view sends. Some hosts answer a default
        // `URLSession` agent with a 403, and a feed is exactly the kind of document
        // behind that kind of rule.
        request.setValue(WebFetcher.mobileSafariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.acceptedTypes, forHTTPHeaderField: "Accept")
        if let etag = validators?.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = validators?.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let landed = response.url ?? url
        let status = http?.statusCode ?? 200
        // A `304` carries no validators of its own, so the ones that produced it are
        // kept. Dropping them would make the *next* request unconditional, and the feed
        // would be downloaded in full once for every two times it is checked.
        let etag = http?.value(forHTTPHeaderField: "Etag") ?? validators?.etag
        let lastModified =
            http?.value(forHTTPHeaderField: "Last-Modified") ?? validators?.lastModified

        if status == 304 {
            return Response(
                landed: landed, etag: etag, lastModified: lastModified, body: nil,
                checkedAt: Date()
            )
        }
        guard (200..<300).contains(status) else { throw FeedError.http(status) }
        return Response(
            landed: landed, etag: etag, lastModified: lastModified, body: data,
            checkedAt: Date()
        )
    }

    /// What this app will take. Not a filter — a host is free to ignore it and most do —
    /// but the sites that serve one document to browsers and another to readers key off
    /// exactly this header, and being asked for HTML is how a reader ends up parsing a
    /// web page.
    private static let acceptedTypes =
        "application/atom+xml, application/rss+xml, application/feed+json, application/xml;q=0.9,"
        + " text/xml;q=0.9, application/json;q=0.8, */*;q=0.5"

    // MARK: - Storing

    /// Writes what the document said into the book: the catalog first, then the body of
    /// every article that has none yet.
    ///
    /// That second half is the expensive one and is deliberately scoped to what is
    /// missing. It runs each article's markup through the shared web view and then fetches
    /// its pictures, which is several round trips apiece and is queued behind whatever the
    /// reader is doing, so a refresh that put all fifty of a feed's articles through it
    /// every time would be a refresh nobody could read during.
    private func store(_ parsed: ParsedFeed, in book: Book) async throws {
        try repo.mergeCatalog(
            bookId: book.id,
            entries: parsed.items.map {
                (
                    siteChapterId: $0.identity,
                    title: $0.title?.nonBlank ?? String(localized: "feed.article.untitled"),
                    // Empty for an article that published no address of its own. Honest,
                    // and the only alternative — the feed's own address — would send a
                    // reader asking for the original to a document instead of a page.
                    url: $0.url ?? "",
                    publishedAt: $0.datePublished
                )
            }
        )

        // Where the publisher's window currently starts, which is the line retention will
        // not delete past. Read back off the rows rather than off the document, because
        // an item the publisher gave no date is stamped with its arrival time on the way
        // in, and that stamp is what everything downstream compares against.
        let listed = Set(parsed.items.map(\.identity))
        let stored = try repo.chapters(bookId: book.id)
        if let oldest = stored.filter({ listed.contains($0.siteChapterId) })
            .compactMap(\.publishedAt).min(),
           var state = try repo.feedFetchState(bookId: book.id) {
            state.windowOldestAt = oldest
            try repo.saveFeedFetchState(state)
        }

        let missing = Set(stored.filter { !$0.isDownloaded }.map(\.siteChapterId))
        let pending = parsed.items.filter { missing.contains($0.identity) }
        guard !pending.isEmpty else { return }

        // `defer` works here where `LocalBookImporter` had to spell both exits out,
        // because this type is main-actor isolated and giving the view back is therefore
        // not a hop it would have to await.
        defer { fetcher.releaseImportView() }
        for item in pending {
            // Before the extraction, not after: each article is a round trip through the
            // web view, and one of those is the whole distance between "it stopped" and
            // "it stops eventually".
            try Task.checkCancellation()
            guard let html = item.contentHTML?.nonBlank else { continue }
            // The article's own address as the base for everything relative inside it.
            // The import view reads this markup with a base of `about:blank`, so without
            // one every relative link and picture in the document resolves to nothing. The
            // feed's address stands in where an item published none — same host, usually,
            // which is the whole of what a base is being asked for.
            let script = try ExtractorScript.article(
                baseURL: item.url?.nonBlank ?? book.siteBookId, title: item.title
            )
            // One article that will not read must not cost the refresh the other
            // forty-nine. It simply stays without text, which the reader reports as an
            // article with no content — the same state as one the publisher summarised
            // to nothing.
            guard let payload = try? await fetcher.extract(
                html: Data(html.utf8), extracting: script,
                as: ExtractorScript.ArticlePayload.self
            ), payload.blocks.contains(where: { !$0.plainText.isEmpty || $0.kind == .image })
            else { continue }
            let illustrated = try await images.stored(
                payload.blocks, book: book, siteChapterId: item.identity,
                referer: item.url.flatMap { URL(string: $0) }
            )
            try? downloads.save(blocks: illustrated, book: book, siteChapterId: item.identity)
        }
    }

    // MARK: - Addresses

    /// The address to fetch, from whatever the reader pasted.
    ///
    /// Two repairs, both for things that are handed out as feed addresses in the wild.
    /// `feed://` is the scheme a browser puts on a subscribe link and no network stack
    /// has ever spoken; it is `http` in a costume. A bare `example.com/feed.xml` has no
    /// scheme at all, which is how an address arrives when it was read off a page rather
    /// than copied from a bar.
    static func url(from address: String) -> URL? {
        guard let trimmed = address.nonBlank else { return nil }
        if let scheme = URL(string: trimmed)?.scheme?.lowercased() {
            switch scheme {
            case "http", "https": return URL(string: trimmed)
            case "feed":
                // `feed:https://…` is also legal and is the whole address with a prefix.
                let rest = String(trimmed.dropFirst("feed:".count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return URL(string: rest.contains("://") ? rest : "https://\(rest)")
            default: return nil
            }
        }
        return URL(string: "https://\(trimmed)")
    }

    /// What to call a subscription on the shelf.
    ///
    /// The host is the fallback rather than the whole address because a shelf row is
    /// about a thumbnail wide: a feed with no title of its own reads far better as
    /// "example.com" than as forty characters of path ending in `/feed.xml`.
    private static func name(of feed: ParsedFeed, at url: URL) -> String {
        feed.title?.nonBlank ?? url.host() ?? url.absoluteString
    }
}
