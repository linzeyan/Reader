import XCTest
@testable import NovelReader

/// End-to-end checks against the real comic sites.
///
/// Opt-in (`make test-live`) and out of the normal suite for the same reasons as
/// `LiveSiteTests`: a network, slow, and red for things outside this code.
///
/// It carries more weight than its novel counterpart, though. Every comic rule
/// was written from a recon pass made with `curl`, and `curl` cannot run a site's
/// scripts — so "the chapter's images are in this global", "this attribute holds
/// the address", "the catalog is fully present in the markup" were all readings
/// of obfuscated source until something drove a real WKWebView over a real page.
/// This is that something. A green run here is the difference between a plan and
/// a fact.
@MainActor
final class LiveComicSiteTests: XCTestCase {
    /// One site's journey through the whole comic pipeline.
    private struct Report {
        let site: String
        var bookId: String?
        var title: String?
        /// Kept because two of these sites publish it relative to the page, and an
        /// unresolved cover is not a failure anywhere — the shelf just draws
        /// nothing, silently, on every row.
        var cover: String?
        var chapterCount: Int?
        var imageCount: Int?
        var firstImageBytes: Int?
        var searchHits: Int?
        var failures: [String] = []
        /// Stages that stopped at an interactive challenge. Reported loudly but
        /// kept out of `failures`: handing the challenge to the user *is* the
        /// designed behaviour.
        var challenges: [String] = []

        var line: String {
            let stages = [
                "book=\(bookId ?? "—")",
                "title=\(title ?? "—")",
                "chapters=\(chapterCount.map(String.init) ?? "—")",
                "images=\(imageCount.map(String.init) ?? "—")",
                "firstImage=\(firstImageBytes.map { "\($0)B" } ?? "—")",
                "search=\(searchHits.map(String.init) ?? "n/a")",
            ]
            let verdict = !failures.isEmpty ? "FAIL" : (challenges.isEmpty ? "OK  " : "WARN")
            let notes = failures + challenges.map { "\($0) (needs the user to verify — expected)" }
            let detail = notes.isEmpty ? "" : "\n        " + notes.joined(separator: "\n        ")
            return "  \(verdict) \(site.padded(to: 10)) \(stages.joined(separator: "  "))\(detail)"
        }

        mutating func record(_ stage: String, _ error: any Error) {
            if case WebFetcher.FetchError.challengePresented = error {
                challenges.append("\(stage): interactive challenge")
            } else {
                failures.append("\(stage): \(error.localizedDescription)")
            }
        }
    }

    func testLiveComicSites() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["NOVELREADER_LIVE"] == "1",
            "Live site tests are opt-in: run `make test-live`."
        )
        let rules = try LiveSiteRules.seeded().filter { $0.kind == .comic }
        XCTAssertFalse(rules.isEmpty, "No comic rules in the app bundle — is this a Debug build?")

        var reports: [Report] = []
        for rule in rules {
            reports.append(await exercise(rule))
        }

        print("\n=== live comic site report ===\n" + reports.map(\.line).joined(separator: "\n") + "\n")

        let broken = reports.filter { !$0.failures.isEmpty }
        if !broken.isEmpty {
            XCTFail("\(broken.count)/\(reports.count) comic sites failed:\n"
                    + broken.map(\.line).joined(separator: "\n"))
        }
    }

    /// Whether the app can open a site that refuses recon tooling outright.
    ///
    /// One surveyed site answers `curl` with a flat Cloudflare block — not a
    /// challenge page, a 403 that never reaches the origin — while serving that
    /// same address's static files from the same machine happily. So the block is
    /// keyed on how the client looks, and the app does not look like `curl`: it
    /// asks through WebKit, over Apple's own TLS stack, as mobile Safari. Whether
    /// that is enough decides whether the site can ship a rule file at all, and
    /// nothing short of asking it can say.
    ///
    /// **The verdict is the printed line, not the exit code.** A block is a fact
    /// about someone else's WAF, and the plan already accepts shipping without
    /// this source — failing the suite for it would leave a red build that no
    /// change to this code could ever turn green.
    func testWhetherAWAFBlockedSiteServesTheApp() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["NOVELREADER_LIVE"] == "1",
            "Live site tests are opt-in: run `make test-live`."
        )
        struct Probe: Decodable {
            let title: String
            let blocked: Bool
            let bodyLength: Int
            let url: String
        }
        let script = """
        (function () {
          var text = (document.body && document.body.textContent) || '';
          return {
            title: document.title || '',
            blocked: text.indexOf('you have been blocked') !== -1
              || text.indexOf('Attention Required') !== -1
              || (document.title || '').indexOf('Attention Required') !== -1,
            bodyLength: text.length,
            url: location.href
          };
        })()
        """

        let fetcher = WebFetcher()
        let host = HeadlessHost(webView: fetcher.webView)
        defer { host.tearDown() }

        for address in Self.unreachableByRecon {
            guard let url = URL(string: address) else { continue }
            do {
                let probe = try await fetcher.fetch(url, extracting: script, as: Probe.self)
                let verdict = probe.blocked ? "BLOCKED" : "SERVED "
                print("\n=== WAF probe === \(verdict) \(address) "
                      + "title=\"\(probe.title)\" body=\(probe.bodyLength) landed=\(probe.url)\n")
            } catch {
                print("\n=== WAF probe === ERROR   \(address) \(error.localizedDescription)\n")
            }
        }
    }

    /// Addresses recon could not reach, kept here rather than as a rule file: there
    /// is nothing to write a rule from until one of them answers.
    private static let unreachableByRecon = ["https://mycomic.com/"]

    // MARK: - One site

    private func exercise(_ rule: SiteRule) async -> Report {
        var report = Report(site: rule.id)
        let fetcher = WebFetcher()
        let host = HeadlessHost(webView: fetcher.webView)
        defer { host.tearDown() }

        guard let database = try? AppDatabase.makeInMemory() else {
            report.failures.append("could not open an in-memory database")
            return report
        }
        let repo = LibraryRepo(database: database)
        let service = BookService(fetcher: fetcher, repo: repo)

        // 1. Find a book the site itself links to.
        do {
            report.bookId = try await LiveSiteRules.discoverBookId(rule: rule, fetcher: fetcher)
        } catch {
            report.record("homepage", error)
            return report
        }
        guard let siteBookId = report.bookId else {
            report.failures.append("homepage: no link matched idPatterns.bookId")
            return report
        }

        // 2. Book page.
        var book: Book
        do {
            let info = try await service.info(rule: rule, siteBookId: siteBookId)
            report.title = info.title
            report.cover = info.cover
            // A cover the page published relative to itself has to come back
            // resolved, because nothing downstream can resolve it: the shelf hands
            // the string to `URL(string:)` and draws whatever comes back, so "//cdn…"
            // or "/pics/1.jpg" is an empty row and no error at all.
            if let cover = info.cover, !cover.isEmpty,
               !(cover.hasPrefix("https://") || cover.hasPrefix("http://")) {
                report.failures.append("book: cover is not an absolute URL: \(cover)")
            }
            book = try repo.bookmark(
                siteId: rule.id, siteBookId: siteBookId, kind: rule.kind,
                title: info.title, author: info.author, coverURL: info.cover
            )
        } catch {
            report.record("book", error)
            return report
        }

        // 3. Catalog.
        var chapters: [Chapter] = []
        do {
            chapters = try await service.refreshCatalog(rule: rule, book: book)
            report.chapterCount = chapters.count
        } catch {
            report.record("catalog", error)
        }

        // 4. The pages of a chapter — the claim recon could not make with `curl`.
        //
        // The *first* chapter deliberately: one of these sites sells its later
        // chapters, and a purchase wall returns a page with no images at all. That
        // is the site working correctly, and a suite that picked a random chapter
        // would report it as a broken rule.
        var imageURLs: [URL] = []
        if let first = chapters.first {
            do {
                imageURLs = try await service.chapterImageURLs(rule: rule, chapter: first)
                report.imageCount = imageURLs.count
            } catch {
                report.record("images", error)
            }
        }

        // 5. And that an address off that list actually serves bytes to *us*.
        //
        // The stage the whole `ImageFetcher` exists for. Three of the four surveyed
        // sites answer 403 without a `Referer`, and the failure is invisible from
        // the extraction side: the list is perfect and every page is blank. Only
        // the first image, to stay a polite visitor — one page proves the headers.
        if let firstImage = imageURLs.first, let chapter = chapters.first,
           let chapterPage = URL(string: chapter.url) {
            do {
                let bytes = try await ImageFetcher().chapterImages(
                    at: [firstImage], chapterPage: chapterPage,
                    cookies: await ImageFetcher.siteCookies()
                )
                report.firstImageBytes = bytes.first?.count
                // `ImageFetcher` already refuses anything that does not begin like
                // an image, so arriving here with bytes is the assertion. Size is
                // checked separately because a 200 of a few bytes is what a hotlink
                // stub looks like, and one site's is literally three dots.
                if (bytes.first?.count ?? 0) < 1024 {
                    report.failures.append(
                        "image: \(bytes.first?.count ?? 0) bytes — too small to be a page"
                    )
                }
            } catch {
                report.record("image", error)
            }
        }

        // 6. Search, where the rule claims to support it.
        if rule.search != nil {
            do {
                let hits = try await SearchService(fetcher: fetcher).search(Self.searchProbe, in: rule)
                report.searchHits = hits.count
                if hits.isEmpty { report.failures.append("search: returned no rows") }
            } catch {
                report.record("search", error)
            }
        }

        return report
    }

    /// A title both surveyed sites carry, in the script each of them publishes in.
    /// A probe that one site simply does not stock would report a working rule as
    /// broken.
    private static let searchProbe = "海賊王"
}
