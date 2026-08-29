import XCTest
@testable import NovelReader

/// A comic chapter is 15–50 files fetched outside WebKit, which means everything
/// WebKit was doing for free — the `Referer` the hosts demand, the browser
/// identity, the site's cookies — is now something this app has to get right by
/// hand, and gets wrong silently. Silently is the problem: a chapter that comes
/// back missing pages 12–17 and says nothing is only discovered offline, which is
/// the one place it cannot be fixed. Which page is absent is therefore part of what
/// a fetch returns, rather than something the caller has to notice.
///
/// The whole suite runs without a network: the fetcher's `URLSession` is injected,
/// and `StubOrigin` below answers for the origin server.
@MainActor
final class ImageFetcherTests: XCTestCase {
    private var session: URLSession!

    private let chapterPage = URL(string: "https://comic.example.com/chapters/1024")!

    override func setUp() {
        super.setUp()
        StubOrigin.script.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubOrigin.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        super.tearDown()
    }

    // MARK: - What every request has to carry

    /// Three of the four surveyed sites answer 403 to an image request with no
    /// `Referer`, and every one of them expects the identity and the session that
    /// asked for the page the images were listed on. Any of the three going missing
    /// turns a whole comic source into "downloads always fail" — with a 403 that
    /// says nothing about which header was dropped.
    func testEveryImageCarriesTheRefererTheFetcherUserAgentAndTheSiteCookie() async throws {
        let urls = (1...3).map { URL(string: "https://img.example.com/\($0).png")! }
        for (page, url) in urls.enumerated() { StubOrigin.script.serve(url, body: png(page: UInt8(page))) }
        let cookie = cookie(named: "sessionid", value: "abc123", domain: "img.example.com")

        _ = try await ImageFetcher(session: session)
            .chapterImages(at: urls, chapterPage: chapterPage, cookies: [cookie])

        let requests = StubOrigin.script.requests
        XCTAssertEqual(requests.count, 3)
        for request in requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), chapterPage.absoluteString)
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "User-Agent"), WebFetcher.mobileSafariUserAgent,
                "The bytes must be asked for by the same browser that asked for the page"
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "sessionid=abc123")
        }
    }

    /// The cookie jar is every site the user has ever opened, session tokens
    /// included, and comic images usually live on a different company's CDN than
    /// the page listing them. Sending the jar wholesale would hand one site's
    /// session to another — a privacy hole with no upside, since the CDN has no use
    /// for a cookie it did not set.
    func testCookiesBelongingToAnotherSiteAreNotSentToTheImageHost() async throws {
        let url = URL(string: "https://img.example.com/1.png")!
        StubOrigin.script.serve(url, body: png(page: 1))
        let jar = [
            cookie(named: "sessionid", value: "abc123", domain: "img.example.com"),
            cookie(named: "novelsite", value: "secret", domain: "some-novel-site.example"),
        ]

        _ = try await ImageFetcher(session: session)
            .chapterImages(at: [url], chapterPage: chapterPage, cookies: jar)

        let sent = StubOrigin.script.requests.first?.value(forHTTPHeaderField: "Cookie")
        XCTAssertEqual(sent, "sessionid=abc123")
    }

    // MARK: - Order

    /// Page order *is* the chapter. Responses arrive in whatever order the network
    /// hands them over, and several are in flight at once by design, so "the order
    /// they finished" and "the order they are read in" are different lists.
    func testPagesComeBackInPageOrderWhenTheOriginAnswersBackwards() async throws {
        let urls = (1...4).map { URL(string: "https://img.example.com/\($0).png")! }
        for (index, url) in urls.enumerated() {
            // Page 1 answers last, page 4 first.
            StubOrigin.script.serve(
                url, body: png(page: UInt8(index + 1)),
                delay: 0.20 - Double(index) * 0.05
            )
        }

        let pages = try await ImageFetcher(session: session, maxConcurrent: 4)
            .chapterImages(at: urls, chapterPage: chapterPage, cookies: [])

        XCTAssertEqual(pages.map { $0?.last }, [1, 2, 3, 4])
    }

    // MARK: - A bad page, and a chapter that is not there

    /// One dead image is an ordinary thing on these sites, and it used to cost the
    /// reader the other forty-nine pages *and* leave them a chapter that failed the
    /// same way every time they tried again. So the gap comes back as a gap, in the
    /// place it belongs: page 3 is `nil`, pages 1, 2, 4 and 5 are the pages.
    func testAPageThatWillNotComeBackIsAGapAndTheRestOfTheChapterStillLands() async throws {
        let urls = (1...5).map { URL(string: "https://img.example.com/\($0).png")! }
        for (index, url) in urls.enumerated() { StubOrigin.script.serve(url, body: png(page: UInt8(index))) }
        StubOrigin.script.serve(urls[2], status: 404, body: Data())

        let pages = try await ImageFetcher(session: session, maxConcurrent: 1)
            .chapterImages(at: urls, chapterPage: chapterPage, cookies: [])

        XCTAssertEqual(pages.count, 5, "A gap keeps its place, or every page after it moves")
        XCTAssertNil(pages[2])
        XCTAssertEqual(
            pages.map { $0?.last }, [0, 1, nil, 3, 4],
            "The pages that came back are the pages that came back"
        )
    }

    /// The failure these hosts actually produce is a 200 that is not the image: a
    /// WAF interstitial, a login page, a hotlink-denied stub — served, often
    /// enough, under an `image/*` content type. Trusting the header would put HTML
    /// error pages on disk and call them a chapter, and the reader would show 30
    /// blank pages with nothing to explain them.
    func testABodyThatIsNotAnImageIsAGapEvenWhenItClaimsToBeAnImage() async throws {
        let urls = (1...3).map { URL(string: "https://img.example.com/\($0).png")! }
        for (index, url) in urls.enumerated() { StubOrigin.script.serve(url, body: png(page: UInt8(index))) }
        StubOrigin.script.serve(
            urls[1], contentType: "image/jpeg",
            body: Data("<html><body>Access denied</body></html>".utf8)
        )

        let pages = try await ImageFetcher(session: session, maxConcurrent: 1)
            .chapterImages(at: urls, chapterPage: chapterPage, cookies: [])

        XCTAssertNil(pages[1], "HTML under an image content type is not a page")
        XCTAssertNotNil(pages[0])
        XCTAssertNotNil(pages[2])
    }

    /// A chapter where nothing at all came back is not a chapter with holes in it —
    /// it is a chapter that is not there, and the difference decides what the
    /// download queue does with it. Kept, retried and reported when every page
    /// failed; written to disk when even one page landed. The reason travels with
    /// it because "page 1: 403" is what says the referer or the clearance is what
    /// broke, and forty identical failures say it once.
    func testAChapterWhereNoPageCameBackFailsWithTheFirstPagesReason() async throws {
        let urls = (1...4).map { URL(string: "https://img.example.com/\($0).png")! }
        for url in urls { StubOrigin.script.serve(url, status: 403, body: Data()) }

        do {
            _ = try await ImageFetcher(session: session, maxConcurrent: 1)
                .chapterImages(at: urls, chapterPage: chapterPage, cookies: [])
            XCTFail("a chapter of nothing must not be returned as a chapter")
        } catch let error as ImageFetchError {
            guard case .httpStatus(let page, let status) = error else {
                return XCTFail("expected an HTTP failure, got \(error)")
            }
            XCTAssertEqual(page, 1, "Page numbers in errors are the ones printed on the reader")
            XCTAssertEqual(status, 403)
        }
    }

    /// The mirror of the test above: the check has to know the formats these sites
    /// serve. manhuagui serves WebP, so a JPEG/PNG-only sniff would fail every
    /// chapter of a working source and blame the site for it.
    func testAWebPPageIsAcceptedAsAnImage() async throws {
        let url = URL(string: "https://img.example.com/1.webp")!
        var webp = Data("RIFF".utf8)
        webp.append(contentsOf: [0x1A, 0x00, 0x00, 0x00])
        webp.append(contentsOf: Array("WEBPVP8 ".utf8))
        StubOrigin.script.serve(url, contentType: "image/webp", body: webp)

        let pages = try await ImageFetcher(session: session)
            .chapterImages(at: [url], chapterPage: chapterPage, cookies: [])

        XCTAssertEqual(pages, [webp])
    }

    // MARK: - Cancellation and concurrency

    /// Leaving a chapter, or cancelling a queued download, has to stop the bytes
    /// actually moving — a chapter is 5–20MB, and finishing it after the user left
    /// spends their data on something nobody will read.
    ///
    /// It has to stop as a `CancellationError` in particular: the download queue
    /// tells "the user left" from "this chapter is broken" by that type alone, and
    /// counts the second kind towards the streak that pauses the whole queue.
    func testCancellingStopsTheDownloadInsteadOfWaitingItOut() async throws {
        let urls = (1...6).map { URL(string: "https://img.example.com/\($0).png")! }
        for url in urls { StubOrigin.script.serve(url, body: png(page: 1), delay: 5) }
        let fetcher = ImageFetcher(session: session, maxConcurrent: 2)

        let started = ContinuousClock.now
        let work = Task { try await fetcher.chapterImages(at: urls, chapterPage: chapterPage, cookies: []) }
        while StubOrigin.script.requests.count < 2, ContinuousClock.now - started < .seconds(2) {
            try await Task.sleep(for: .milliseconds(10))
        }
        work.cancel()

        do {
            _ = try await work.value
            XCTFail("a cancelled chapter must not come back as a chapter")
        } catch is CancellationError {
            XCTAssertLessThan(
                ContinuousClock.now - started, .seconds(3),
                "Cancellation has to reach the requests in flight, not wait for them"
            )
            XCTAssertLessThan(
                StubOrigin.script.requests.count, urls.count,
                "The pages that had not started yet must never be asked for"
            )
        } catch {
            XCTFail("expected cancellation, got \(error)")
        }
    }

    /// A chapter's images go out at browser-like concurrency and deliberately skip
    /// `RequestPacer` — a person opening a page in a browser fires that page's
    /// images at once, so the throttled unit is the page, not the image. That only
    /// stays defensible while "a handful" really is a handful: hand a task group 50
    /// tasks and it runs 50 requests, which is a burst no browser makes and a good
    /// way to be blocked.
    func testNoMoreThanTheConfiguredNumberOfImagesAreInFlightAtOnce() async throws {
        let urls = (1...9).map { URL(string: "https://img.example.com/\($0).png")! }
        for (index, url) in urls.enumerated() {
            StubOrigin.script.serve(url, body: png(page: UInt8(index)), delay: 0.15)
        }

        let pages = try await ImageFetcher(session: session, maxConcurrent: 3)
            .chapterImages(at: urls, chapterPage: chapterPage, cookies: [])

        XCTAssertEqual(pages.count, 9)
        XCTAssertLessThanOrEqual(StubOrigin.script.peakInFlight, 3)
        XCTAssertGreaterThan(
            StubOrigin.script.peakInFlight, 1,
            "One at a time would make a 30-page chapter take 30 round trips"
        )
    }

    // MARK: - Helpers

    /// A PNG signature plus one byte naming the page, which is all the fetcher
    /// looks at and all these tests need to tell pages apart.
    private func png(page: UInt8) -> Data {
        Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, page])
    }

    private func cookie(named name: String, value: String, domain: String) -> HTTPCookie {
        HTTPCookie(properties: [
            .name: name, .value: value, .domain: domain, .path: "/",
        ])!
    }
}

// MARK: - A scripted origin server

/// Answers the fetcher's requests from a script, and records what it was asked.
///
/// `URLProtocol` is the only seam the URL loading system offers, and the system
/// instantiates it itself — so everything a test needs to set or read has to live
/// on one shared object, and that object is reached from several threads at once
/// because several requests really are in flight. Hence the lock.
private final class StubOrigin: URLProtocol {
    static let script = Script()

    final class Script: @unchecked Sendable {
        struct Reply {
            var status = 200
            var contentType = "image/png"
            var body = Data()
            var delay: TimeInterval = 0
        }

        private let lock = NSLock()
        private var replies: [URL: Reply] = [:]
        private var recorded: [URLRequest] = []
        private var inFlight = 0
        private var peak = 0

        func reset() {
            lock.lock(); defer { lock.unlock() }
            replies = [:]
            recorded = []
            inFlight = 0
            peak = 0
        }

        func serve(
            _ url: URL, status: Int = 200, contentType: String = "image/png",
            body: Data, delay: TimeInterval = 0
        ) {
            lock.lock(); defer { lock.unlock() }
            replies[url] = Reply(status: status, contentType: contentType, body: body, delay: delay)
        }

        var requests: [URLRequest] {
            lock.lock(); defer { lock.unlock() }
            return recorded
        }

        var peakInFlight: Int {
            lock.lock(); defer { lock.unlock() }
            return peak
        }

        fileprivate func begin(_ request: URLRequest) -> Reply {
            lock.lock(); defer { lock.unlock() }
            recorded.append(request)
            inFlight += 1
            peak = max(peak, inFlight)
            // An unscripted URL is a 404 so a test that forgets one fails loudly.
            return request.url.flatMap { replies[$0] } ?? Reply(status: 404)
        }

        fileprivate func end() {
            lock.lock(); defer { lock.unlock() }
            inFlight -= 1
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private let lock = NSLock()
    private var settled = false

    /// True the first time only, so a request that is cancelled while its reply is
    /// pending is counted as ending exactly once.
    private func settle() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if settled { return false }
        settled = true
        return true
    }

    override func startLoading() {
        let reply = Self.script.begin(request)
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [weak self] in
            guard let self, self.settle(), let url = self.request.url else { return }
            Self.script.end()
            let response = HTTPURLResponse(
                url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": reply.contentType]
            )!
            // `.notAllowed`: these responses must never reach the shared URLCache
            // the app reads in earnest.
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: reply.body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        if settle() { Self.script.end() }
    }
}
