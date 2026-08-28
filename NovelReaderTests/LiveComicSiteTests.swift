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
        /// Stages that stopped at a wall only a person can get past — a human
        /// check, or a site that wants the reader signed in. Reported loudly but
        /// kept out of `failures`: handing those to the user *is* the designed
        /// behaviour, and no change to this code could turn them green.
        var challenges: [String] = []
        /// Books the site published but would not open, and why. Printed rather
        /// than failed: a member-only or anime-only title is the site working as
        /// designed, and the run continues to the next candidate.
        var passedOver: [String] = []

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
            let notes = failures
                + challenges.map { "\($0) (only a person can clear this — expected)" }
                + passedOver.map { "passed over \($0)" }
            let detail = notes.isEmpty ? "" : "\n        " + notes.joined(separator: "\n        ")
            return "  \(verdict) \(site.padded(to: 10)) \(stages.joined(separator: "  "))\(detail)"
        }

        mutating func record(_ stage: String, _ error: any Error) {
            if WebFetcher.needsTheUser(error) {
                challenges.append("\(stage): \(error.localizedDescription)")
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

        // 1. Find books the site itself links to.
        //
        // Several, not one. A comic site's front page leads with whatever it is
        // promoting today, and on 8comic that is regularly a title it will not
        // serve to a signed-out reader, or an anime entry with no chapters at all.
        // Both are the site behaving correctly, so the rule is only broken if
        // *none* of the candidates opens.
        var candidates: [String] = []
        do {
            candidates = try await LiveSiteRules.discoverBookIds(
                rule: rule, fetcher: fetcher, limit: Self.bookCandidates
            )
        } catch {
            report.record("homepage", error)
            return report
        }
        guard !candidates.isEmpty else {
            report.failures.append("homepage: no link matched idPatterns.bookId")
            return report
        }

        // 2 & 3. The first candidate that yields a book page *and* a catalog.
        //
        // Taken together because a book page that reads fine but has no chapters
        // is exactly what an anime-only entry looks like, and there is no point
        // carrying it into the image stage.
        var chapters: [Chapter] = []
        for siteBookId in candidates {
            do {
                let info = try await service.info(rule: rule, siteBookId: siteBookId)
                let book = try repo.bookmark(
                    siteId: rule.id, siteBookId: siteBookId, kind: rule.kind,
                    title: info.title, author: info.author, coverURL: info.cover
                )
                let found = try await service.refreshCatalog(rule: rule, book: book)
                report.bookId = siteBookId
                report.title = info.title
                report.cover = info.cover
                report.chapterCount = found.count
                // A cover the page published relative to itself has to come back
                // resolved, because nothing downstream can resolve it: the shelf
                // hands the string to `URL(string:)` and draws whatever comes back,
                // so "//cdn…" or "/pics/1.jpg" is an empty row and no error at all.
                if let cover = info.cover, !cover.isEmpty,
                   !(cover.hasPrefix("https://") || cover.hasPrefix("http://")) {
                    report.failures.append("book: cover is not an absolute URL: \(cover)")
                }
                chapters = found
                break
            } catch {
                // A challenge stops the whole site: it is the same wall for every
                // book, and hammering it with more candidates is both pointless
                // and rude.
                if case WebFetcher.FetchError.challengePresented = error {
                    report.record("book", error)
                    return report
                }
                report.passedOver.append("\(siteBookId): \(error.localizedDescription)")
            }
        }
        guard !chapters.isEmpty else {
            report.failures.append(
                "none of \(candidates.count) books off the front page opened with a catalog"
            )
            return report
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

    /// How many front-page books to try before calling a rule broken.
    ///
    /// Six covers the observed rate — a scan of 28 8comic books found 3 gated
    /// behind a login and 4 anime-only, so a run of six failures in a row is far
    /// more likely to be a broken rule than bad luck — while keeping the worst
    /// case to a dozen page loads against someone else's server.
    private static let bookCandidates = 6

    /// A title both surveyed sites carry, in the script each of them publishes in.
    /// A probe that one site simply does not stock would report a working rule as
    /// broken.
    private static let searchProbe = "海賊王"
}
