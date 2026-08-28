import Foundation
import WebKit

/// Downloads the image bytes of one comic chapter.
///
/// The image *list* comes out of the fetcher's web view, because only a real
/// engine can run the sites' packed scripts. The bytes deliberately do not: a
/// chapter is 15–50 images and the app owns exactly one `WebFetcher` web view, so
/// loading them there would hold it for the whole download — no paging, no
/// searching, no catalog refresh until the last image landed. `URLSession` has no
/// such single-lane constraint, and the four surveyed CDNs serve plain files that
/// need no JS engine to fetch.
///
/// What it costs to leave WebKit is that everything WebKit was doing for free has
/// to be done by hand: the `Referer` those hosts demand, the same browser identity
/// the page was fetched with, and the cookies the site set on that page. That
/// list is the whole of this type.
///
/// Nothing here caches, decodes or writes anything. The caller gets the bytes in
/// page order, or an error naming the page that broke.
@MainActor
final class ImageFetcher {
    private let session: URLSession
    private let maxConcurrent: Int

    /// - Parameters:
    ///   - session: `.shared` in the app, which is what puts these downloads
    ///     through `URLCache.shared` — the cache online reading is meant to lean
    ///     on. "Settings → clear cache" covers it already and needs no change:
    ///     `WebCache.clear()` calls `URLCache.shared.removeAllCachedResponses()`.
    ///     Injected in tests, which is the only way to exercise any of this without
    ///     a network.
    ///
    ///     One caveat that belongs to whoever wires online reading up rather than
    ///     to this type: `URLCache.shared` comes up sized for cover thumbnails —
    ///     measured on the simulator, 512KB in memory and 10MB on disk — while a
    ///     comic chapter is 5–20MB. Unless that capacity is raised at launch, one
    ///     chapter evicts the one before it and "read it again for free" is not
    ///     true of anything but the page just turned.
    ///   - maxConcurrent: how many of a chapter's images are in flight at once.
    ///     Small on purpose, and *not* run through `RequestPacer`: a person opening
    ///     a comic page in a browser fires that page's images at once, so a handful
    ///     in parallel is the ordinary shape of this traffic, while one image every
    ///     1.5 seconds forever is a shape no browser has ever made. The unit that
    ///     stays paced is the *page* — chapter to chapter — which is the caller's
    ///     existing business and is not touched from here.
    init(session: URLSession = .shared, maxConcurrent: Int = 3) {
        self.session = session
        // Clamped rather than trusted: a zero would add no tasks, return an empty
        // array and report a chapter of nothing as a success.
        self.maxConcurrent = max(1, maxConcurrent)
    }

    // MARK: - Cookies

    /// Every cookie WebKit is holding, read once for a whole chapter.
    ///
    /// Why WebKit's store and not `HTTPCookieStorage`: the session cookie these
    /// sites set, and the `cf_clearance` a cleared Cloudflare challenge leaves
    /// behind, were both set on navigations made by `WebFetcher`'s web view, so
    /// they live in WebKit's jar. A `URLSession` request never sees them, and the
    /// image comes back 403.
    ///
    /// Deliberately *not* folded into `chapterImages`, which takes the jar as a
    /// value instead: this call is main-actor and asynchronous, and doing it per
    /// image would be fifty hops per chapter plus fifty chances for one image's
    /// read to interleave with another's. Reading it here, once, is the seam.
    static func siteCookies() async -> [HTTPCookie] {
        await WKWebsiteDataStore.default().httpCookieStore.allCookies()
    }

    // MARK: - Fetching

    /// Downloads every image of one chapter and returns them in page order.
    ///
    /// - Parameters:
    ///   - urls: the chapter's images, in reading order. Page order *is* the
    ///     chapter, so the result is sorted back into this order however the
    ///     responses arrive.
    ///   - chapterPage: the page the images were listed on. Sent as `Referer`.
    ///   - cookies: read once with `siteCookies()`. Each request is given the
    ///     subset that belongs to its own host, not the whole jar.
    /// - Throws: on the first page that fails. A chapter is all of its pages or
    ///   none of them — one that came back missing pages 12–17 while claiming to
    ///   be complete is worse than one that failed out loud.
    func chapterImages(at urls: [URL], chapterPage: URL, cookies: [HTTPCookie]) async throws -> [Data] {
        let requests = urls.map { Self.request(for: $0, chapterPage: chapterPage, cookies: cookies) }
        let session = self.session
        // One place where a page is fetched; the window below only decides when.
        let fetch: @Sendable (Int) async throws -> (index: Int, bytes: Data) = { index in
            let bytes = try await Self.load(requests[index], page: index + 1, in: session)
            return (index, bytes)
        }

        var collected: [(index: Int, bytes: Data)] = []
        collected.reserveCapacity(requests.count)
        try await withThrowingTaskGroup(of: (index: Int, bytes: Data).self) { group in
            // A sliding window rather than "add them all and let the runtime sort
            // it out": a group runs every task it is given, so adding fifty would
            // put fifty requests on the wire at once.
            var next = 0
            let opening = min(maxConcurrent, requests.count)
            while next < opening {
                let index = next
                group.addTask { try await fetch(index) }
                next += 1
            }
            while let page = try await group.next() {
                collected.append(page)
                guard next < requests.count else { continue }
                let index = next
                group.addTask { try await fetch(index) }
                next += 1
            }
        }
        // Reached only when the group filled every slot, since any throw leaves
        // through the line above.
        return collected.sorted { $0.index < $1.index }.map(\.bytes)
    }

    private static func request(for url: URL, chapterPage: URL, cookies: [HTTPCookie]) -> URLRequest {
        var request = URLRequest(url: url)
        // The chapter page, always. Three of the four surveyed sites answer 403
        // without it and 200 with it, and this is exactly what a browser sends:
        // the page the <img> is on. Deliberately not a rule field — no site needs a
        // different value, and a field nobody needs is one more way to write a rule
        // that half works.
        request.setValue(chapterPage.absoluteString, forHTTPHeaderField: "Referer")
        // The identity the page itself was fetched with. A host that sees mobile
        // Safari ask for the HTML and something else ask for its images has been
        // handed the one signal we can avoid handing it.
        request.setValue(WebFetcher.mobileSafariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.cookieHeader(for: url, from: cookies), forHTTPHeaderField: "Cookie")
        // The session's jar is not WebKit's jar — it is empty of everything that
        // matters here. Left switched on it would add, or replace, the header set
        // above with cookies this app never got from the site.
        request.httpShouldHandleCookies = false
        return request
    }

    /// The cookies from `jar` that a browser would send to `url`.
    ///
    /// The jar is every site the user has ever opened in the app, session tokens
    /// included, and a comic page is usually not even on the same host as its
    /// images (manhuagui pages, `i.hamreus.com` images). Handing it over wholesale
    /// would post one site's session to another company's CDN, so the request gets
    /// the subset that is addressed to it — which is also just what the `Cookie`
    /// header means.
    ///
    /// Host-only cookies are matched against subdomains too, which is looser than
    /// the browser rule. The leak that costs something is cross-*site*, and this
    /// cannot produce one.
    private static func cookieHeader(for url: URL, from jar: [HTTPCookie]) -> String? {
        guard let host = url.host()?.lowercased() else { return nil }
        let secure = url.scheme?.lowercased() == "https"
        let path = url.path().isEmpty ? "/" : url.path()
        let now = Date()
        let addressed = jar.filter { cookie in
            if let expiry = cookie.expiresDate, expiry < now { return false }
            if cookie.isSecure && !secure { return false }
            guard path.hasPrefix(cookie.path) else { return false }
            let domain = cookie.domain.hasPrefix(".")
                ? String(cookie.domain.dropFirst()).lowercased()
                : cookie.domain.lowercased()
            return host == domain || host.hasSuffix("." + domain)
        }
        guard !addressed.isEmpty else { return nil }
        return HTTPCookie.requestHeaderFields(with: addressed)["Cookie"]
    }

    /// `nonisolated` so the download runs where it was started — on the group's
    /// task, not back on the main actor holding a chapter's worth of bytes.
    nonisolated private static func load(
        _ request: URLRequest, page: Int, in session: URLSession
    ) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // A cancelled URLSession task reports `URLError.cancelled`, but the
            // download queue tells "the user left" from "this chapter is broken" by
            // `CancellationError` alone. Reported as a failure, a chapter the user
            // cancelled would count towards the streak that pauses the whole queue.
            try Task.checkCancellation()
            throw error
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ImageFetchError.httpStatus(page: page, status: http.statusCode)
        }
        guard isImage(data) else { throw ImageFetchError.notAnImage(page: page) }
        return data
    }

    /// Whether these bytes begin the way an image file begins.
    ///
    /// The case this exists for is a 200 that is not the image: a WAF interstitial,
    /// a login page, a hotlink-denied stub. The bytes are sniffed rather than the
    /// `Content-Type` trusted because the header is the part that lies — an HTML
    /// error page served as `image/jpeg` is precisely what a header check waves
    /// through — and rather than the image decoded because the reader decodes it
    /// later anyway, and paying for fifty decodes a chapter to learn what twelve
    /// bytes already say is a real cost on a phone.
    ///
    /// Truncation is beyond either check: nothing short of parsing the whole file
    /// tells a half-written JPEG from a whole one.
    nonisolated private static func isImage(_ data: Data) -> Bool {
        let leading: [[UInt8]] = [
            [0xFF, 0xD8, 0xFF],        // JPEG
            [0x89, 0x50, 0x4E, 0x47],  // PNG
            [0x47, 0x49, 0x46, 0x38],  // GIF87a / GIF89a
        ]
        if leading.contains(where: { data.starts(with: $0) }) { return true }
        // WebP and the ISO base media family (HEIC, AVIF) put a size or container
        // magic first, so the tag that identifies them sits further in. WebP is not
        // optional here: it is what manhuagui serves.
        guard data.count >= 12 else { return false }
        let head = [UInt8](data.prefix(12))
        if Array(head[0..<4]) == Array("RIFF".utf8), Array(head[8..<12]) == Array("WEBP".utf8) {
            return true
        }
        return Array(head[4..<8]) == Array("ftyp".utf8)
    }
}

/// Why a chapter of images could not be downloaded.
///
/// Both cases fail the whole chapter. Skipping the page and carrying on would
/// produce a download that looks complete and reads with holes in it, and the
/// holes would only be discovered offline, which is the one place they cannot be
/// fixed.
enum ImageFetchError: LocalizedError {
    /// `page` is 1-based here and nowhere else in the type: this text is read by
    /// someone looking at a chapter that would not download, and "page 0" is not a
    /// page they can find.
    case httpStatus(page: Int, status: Int)
    case notAnImage(page: Int)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let page, let status):
            return String(localized: "comic.image.error.http \(page) \(status)")
        case .notAnImage(let page):
            return String(localized: "comic.image.error.notImage \(page)")
        }
    }
}
