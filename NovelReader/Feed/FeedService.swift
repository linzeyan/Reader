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

    /// How far the first read of a subscription has got.
    ///
    /// Counted in articles rather than reported as a share, because that is the unit the
    /// work is actually done in and the one a reader can judge: "3 of 27" says both how
    /// long is left and that something is happening, while a bar creeping across says
    /// only the second. It also stops the moment the reader can see: what is counted is
    /// articles *stored*, so a feed of twenty-seven that reaches twenty-seven has nothing
    /// left to do.
    struct Progress: Equatable {
        /// Articles whose body has been read and written to the device.
        let stored: Int
        /// How many this document gave a body to store. Zero for a feed that publishes
        /// headlines and links only — which is finished the moment it starts, and is why
        /// nothing here divides by it.
        let total: Int
    }

    typealias ProgressHandler = (Progress) -> Void

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
    ///
    /// - Parameter progress: called as each article's body lands. Worth wiring at all
    ///   because this is the one slow thing a subscription ever does: a feed's whole
    ///   window is read here, article by article through the web view and picture by
    ///   picture off the network, and without it a busy feed is a spinner that looks
    ///   stuck for a minute.
    @discardableResult
    func subscribe(
        to address: String, progress: @escaping ProgressHandler = { _ in }
    ) async throws -> Book {
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
        try await store(parsed, in: book, progress: progress)
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

    // MARK: - Full text

    /// Reads the piece off the page it actually lives on.
    ///
    /// For the feed that published a headline, a link and nothing else. That is not a
    /// failure to fetch anything and there is nothing in the document to ask for again —
    /// which is why the reader's retry button could never help here, and why this replaces
    /// it rather than sitting beside it. Measured across a real shelf of thirteen, two of
    /// them do exactly this: `<description>` elements averaging a hundred and fifty
    /// characters, with no `content:encoded` anywhere in the file.
    ///
    /// Over `URLSession` rather than the shared web view, which is the exit the whole of
    /// this service takes: a blog is a static page on somebody's host, not one of the
    /// challenged novel sites, and evicting whatever the reader is part way through to
    /// fetch one article would be a poor trade for it. Only the extraction borrows the
    /// isolated import view, exactly as an article whose body *did* arrive in the document
    /// does — and it is stored by the same writer, so images, retention and offline
    /// reading all carry on knowing nothing about where the markup came from.
    /// Returns as soon as the words are stored. The pictures are `fetchImages`, which the
    /// caller runs afterwards with the article already on screen.
    @discardableResult
    func fetchFullText(for chapter: Chapter, in book: Book) async throws -> FullText {
        guard let url = chapter.webURL else { throw FeedError.emptyArticle }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(WebFetcher.mobileSafariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.acceptedPageTypes, forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else { throw FeedError.http(status) }
        let landed = response.url ?? url

        // The address it landed on as the base, so everything relative inside the page
        // resolves — the import view reads markup with a base of `about:blank`, and a
        // redirect to a canonical URL is what most of these links are.
        let script = try ExtractorScript.article(
            baseURL: landed.absoluteString, title: chapter.title
        )
        fetcher.holdImportView()
        defer { fetcher.releaseImportView() }
        let payload = try await fetcher.extract(
            html: data, extracting: script, as: ExtractorScript.ArticlePayload.self
        )
        // A page that reads to nothing is the same answer as before, not a new failure: a
        // paywall, a consent wall, or a site that builds its article in JavaScript the
        // import view is not allowed to run.
        guard payload.blocks.contains(where: { !$0.plainText.isEmpty || $0.kind == .image })
        else { throw FeedError.emptyArticle }

        // Stored without its pictures, and that is the whole difference between this and a
        // refresh. A refresh is nobody's afternoon: it runs while the phone is in a pocket,
        // so it is worth waiting for every picture to make the article readable offline
        // later. This runs because somebody tapped a button and is looking at the screen —
        // and measured on a shelf of thirteen feeds, pictures are where a subscribe spends
        // ninety per cent of its time, thirty to forty seconds an article on the illustrated
        // ones, against four milliseconds to extract. Waiting for them here is what made a
        // button that fetches one article slower than opening the page in a browser, which
        // shows the words first and fills the pictures in behind them. So does this now.
        try downloads.save(
            blocks: payload.blocks, book: book, siteChapterId: chapter.siteChapterId
        )
        return FullText(blocks: payload.blocks, page: landed)
    }

    /// An article's own page, read but not yet illustrated.
    struct FullText {
        let blocks: [ArticleBlock]
        /// Where the page landed, which is the `Referer` its pictures will be asked for
        /// with — not the address the entry linked to, which is often a redirect away.
        let page: URL
    }

    /// The pictures for an article `fetchFullText` has already stored as words.
    ///
    /// Separated so the words can be on screen while this runs, and safe to lose: a picture
    /// that will not arrive is not an error anywhere in this app — the block keeps its
    /// address and the reader draws its alt text — so an interrupted run leaves an article
    /// that reads, which is the state `ArticleImages` already documents for a picture the
    /// publisher's CDN refuses.
    ///
    /// - Returns: whether anything new reached the disk, so a reader showing the article
    ///   knows whether re-reading it is worth a re-layout.
    @discardableResult
    func fetchImages(
        for text: FullText, chapter: Chapter, in book: Book
    ) async throws -> Bool {
        guard text.blocks.contains(where: { $0.kind == .image }) else { return false }
        let illustrated = try await images.stored(
            text.blocks, book: book, siteChapterId: chapter.siteChapterId, referer: text.page
        )
        // Nothing came back: the save and the reader's re-layout would both be for a file
        // set identical to the one already there.
        guard illustrated.contains(where: { $0.image?.file != nil }) else { return false }
        try downloads.save(
            blocks: illustrated, book: book, siteChapterId: chapter.siteChapterId
        )
        return true
    }

    /// What a request for a *page* will take, as against `acceptedTypes`, which asks for a
    /// feed. Safari's own header: the hosts that serve one document to browsers and
    /// another to readers key off exactly this, and here the browser's copy is the one
    /// wanted — it is the page a person would see.
    private static let acceptedPageTypes =
        "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"

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
    private func store(
        _ parsed: ParsedFeed, in book: Book, progress: @escaping ProgressHandler = { _ in }
    ) async throws {
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
        // not a hop it would have to await. The claim is what makes it safe to have
        // several feeds in this loop at once — see `WebFetcher.holdImportView`.
        fetcher.holdImportView()
        defer { fetcher.releaseImportView() }
        progress(Progress(stored: 0, total: pending.count))
        for (index, item) in pending.enumerated() {
            // Before the extraction, not after: each article is a round trip through the
            // web view, and one of those is the whole distance between "it stopped" and
            // "it stops eventually".
            try Task.checkCancellation()
            // On every way out of this iteration, including the two that store nothing.
            // An article the publisher gave no body is one this loop is done with, and a
            // count that stalled on it would report a subscription as stuck when it is
            // simply reading things that take no time.
            defer { progress(Progress(stored: index + 1, total: pending.count)) }
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
