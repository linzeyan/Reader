import XCTest
@testable import NovelReader

/// End-to-end checks against the real sites.
///
/// Opt-in (`make test-live`) and excluded from the normal suite on purpose: it
/// needs a network, it is slow, and it fails for reasons outside the code —
/// a site redesign, a Cloudflare challenge, an outage. Mixing that into
/// `make test` would make a green build meaningless.
///
/// What it is for: the rule files carry `notes` full of "UNVERIFIED", and the
/// only way to turn those into "CONFIRMED" is to drive the real pipeline. The
/// test discovers a book from each site's own homepage rather than hardcoding
/// ids, so it also proves `idPatterns` can recover ids from real links.
@MainActor
final class LiveSiteTests: XCTestCase {
    /// One site's journey through the whole pipeline.
    private struct Report {
        let site: String
        var bookId: String?
        var title: String?
        var chapterCount: Int?
        var paragraphCount: Int?
        var searchHits: Int?
        var failures: [String] = []
        /// Stages that stopped at an interactive challenge. Reported loudly but
        /// kept out of `failures`: handing the challenge to the user *is* the
        /// designed behaviour, so failing the run for it would leave the suite
        /// permanently red for something that works.
        var challenges: [String] = []

        var line: String {
            let stages = [
                "book=\(bookId ?? "—")",
                "title=\(title ?? "—")",
                "chapters=\(chapterCount.map(String.init) ?? "—")",
                "paragraphs=\(paragraphCount.map(String.init) ?? "—")",
                "search=\(searchHits.map(String.init) ?? "n/a")",
            ]
            let verdict = !failures.isEmpty ? "FAIL" : (challenges.isEmpty ? "OK  " : "WARN")
            let notes = failures + challenges.map { "\($0) (needs the user to verify — expected)" }
            let detail = notes.isEmpty ? "" : "\n        " + notes.joined(separator: "\n        ")
            return "  \(verdict) \(site.padded(to: 10)) \(stages.joined(separator: "  "))\(detail)"
        }

        /// A challenge is a warning; anything else is a real failure.
        mutating func record(_ stage: String, _ error: any Error) {
            if case WebFetcher.FetchError.challengePresented = error {
                challenges.append("\(stage): interactive challenge")
            } else {
                failures.append("\(stage): \(error.localizedDescription)")
            }
        }
    }

    func testLiveSites() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["NOVELREADER_LIVE"] == "1",
            "Live site tests are opt-in: run `make test-live`."
        )
        let rules = try loadSeededRules()
        XCTAssertFalse(rules.isEmpty, "No development rules in the app bundle — is this a Debug build?")

        var reports: [Report] = []
        for rule in rules {
            reports.append(await exercise(rule))
        }

        print("\n=== live site report ===\n" + reports.map(\.line).joined(separator: "\n") + "\n")

        let broken = reports.filter { !$0.failures.isEmpty }
        if !broken.isEmpty {
            XCTFail("\(broken.count)/\(reports.count) sites failed:\n" + broken.map(\.line).joined(separator: "\n"))
        }
    }

    /// Cancelling a download while a chapter fetch is in flight.
    ///
    /// This is the shape that crashed the shipping app: tap "download all", tap
    /// cancel, and the run loop came back from a fetch to find the queue it was
    /// working through emptied underneath it. A unit test pins the bookkeeping,
    /// but only a real fetch is slow enough to actually be interrupted — which
    /// is the whole reason the bug survived to a device in the first place.
    func testCancellingADownloadMidFlightDoesNotCrash() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["NOVELREADER_LIVE"] == "1",
            "Live site tests are opt-in: run `make test-live`."
        )
        let rules = try loadSeededRules()
        // hjwzw is used only because it is the fastest of the confirmed sites
        // and has no challenge in front of it; nothing here is specific to it.
        guard let rule = rules.first(where: { $0.id.contains("hjwzw") }) else {
            throw XCTSkip("No hjwzw rule seeded")
        }

        let fetcher = WebFetcher()
        let database = try AppDatabase.makeInMemory()
        let repo = LibraryRepo(database: database)
        let files = ChapterFileStore(root: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let service = BookService(fetcher: fetcher, repo: repo)
        let manager = DownloadManager(
            service: service,
            downloads: DownloadStore(database: database, files: files),
            pacer: RequestPacer(gap: 0.2...0.4)
        )

        let discovered = try await discoverBookId(rule: rule, fetcher: fetcher)
        let bookId = try XCTUnwrap(discovered)
        let info = try await service.info(rule: rule, siteBookId: bookId)
        let book = try repo.bookmark(siteId: rule.id, siteBookId: bookId, title: info.title)
        let chapters = try await service.refreshCatalog(rule: rule, book: book)
        XCTAssertFalse(chapters.isEmpty)

        manager.start(book: book, rule: rule, chapters: Array(chapters.prefix(5)))
        // Long enough to be inside a fetch, short enough to be before it returns.
        try await Task.sleep(for: .milliseconds(400))
        manager.cancel()
        // The crash landed when the in-flight fetch came back, not at the tap.
        try await Task.sleep(for: .seconds(6))

        XCTAssertEqual(manager.status, .idle, "A cancelled run must settle as idle")
        XCTAssertNil(manager.progress)
        print("\n=== cancel-mid-download: survived, status=\(manager.status) ===\n")
    }

    /// Derives a rule for each known site *from nothing but a book URL*, and
    /// checks the result actually reads that book.
    ///
    /// The six hand-written rules are the control group: they were verified
    /// against the live sites, so if derivation reproduces working catalogs and
    /// readable chapter text on the same six, it has a real chance on the
    /// seventh site nobody has looked at. The hand rules are used only to find a
    /// book to point at — the derivation itself sees a URL and a web view.
    func testDerivesWorkingRulesFromScratch() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["NOVELREADER_LIVE"] == "1",
            "Live site tests are opt-in: run `make test-live`."
        )
        let rules = try loadSeededRules()
        XCTAssertFalse(rules.isEmpty, "No development rules in the app bundle — is this a Debug build?")

        var reports: [Report] = []
        for rule in rules {
            reports.append(await deriveAndExercise(rule))
        }

        print("\n=== rule derivation report ===\n" + reports.map(\.line).joined(separator: "\n") + "\n")

        let broken = reports.filter { !$0.failures.isEmpty }
        if !broken.isEmpty {
            XCTFail("derivation failed for \(broken.count)/\(reports.count) sites:\n"
                    + broken.map(\.line).joined(separator: "\n"))
        }
    }

    /// Derives each site's *search* from its own search box, and checks the
    /// derived block really returns books.
    ///
    /// Reported per site rather than asserted globally: two of these six sites
    /// genuinely cannot be searched by this route — quanben5 has no search form
    /// at all, 69shuba's endpoint throws an interactive challenge — and a suite
    /// that failed for that would be red forever. What must not happen is a site
    /// whose hand-written rule searches fine yielding nothing here.
    func testDerivesSearchFromTheSitesOwnForm() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["NOVELREADER_LIVE"] == "1",
            "Live site tests are opt-in: run `make test-live`."
        )
        let rules = try loadSeededRules()
        var lines: [String] = []
        var regressions: [String] = []

        for rule in rules {
            let fetcher = WebFetcher()
            let host = HeadlessHost(webView: fetcher.webView)
            defer { host.tearDown() }
            do {
                let derived = try await SearchDeriver(fetcher: fetcher).derive(for: rule, probe: Self.searchProbe)
                lines.append("  OK   \(rule.id.padded(to: 10)) \(derived.search.method.rawValue) "
                             + "\(derived.search.url)  hits=\(derived.sampleTitles.count)")
            } catch {
                // A site the hand-written rule can search must be derivable too —
                // but only failures of *this* logic count. A site with no search
                // at all, and anything the network layer reported (a challenge to
                // hand to the user, a refused connection from a host that
                // throttles automation), say nothing about the derivation.
                let excused = rule.search == nil || error is WebFetcher.FetchError
                let line = "  \(excused ? "—   " : "FAIL") \(rule.id.padded(to: 10)) "
                    + "\(excused ? "note" : "REGRESSION"): \(error.localizedDescription)"
                lines.append(line)
                if !excused { regressions.append(line) }
            }
        }

        print("\n=== search derivation report ===\n" + lines.joined(separator: "\n") + "\n")
        if !regressions.isEmpty {
            XCTFail("search derivation lost sites that the hand-written rules can search:\n"
                    + regressions.joined(separator: "\n"))
        }
    }

    private func deriveAndExercise(_ known: SiteRule) async -> Report {
        var report = Report(site: known.id)
        let fetcher = WebFetcher()
        let host = HeadlessHost(webView: fetcher.webView)
        defer { host.tearDown() }

        // The known rule is used for one thing only: finding a real book URL to
        // hand over. Everything after this point is derivation.
        let bookURL: URL
        do {
            guard let id = try await discoverBookId(rule: known, fetcher: fetcher),
                  let url = known.bookURL(bookId: id)
            else {
                report.failures.append("homepage: no book link found")
                return report
            }
            report.bookId = id
            bookURL = url
        } catch {
            report.record("homepage", error)
            return report
        }

        do {
            let draft = try await RuleDeriver(fetcher: fetcher).derive(from: bookURL)
            report.title = draft.preview.bookTitle
            report.chapterCount = draft.preview.chapterCount
            report.paragraphCount = draft.preview.excerpt.count

            // The derived rule has to be able to find the book again from the
            // same URL, or the user could add the source but not the book.
            if draft.rule.bookId(from: bookURL) != report.bookId {
                report.failures.append(
                    "derived bookId pattern does not recover \(report.bookId ?? "—") from the book URL"
                )
            }
            if draft.preview.excerpt.count < 60 {
                report.failures.append("derived rule extracted only \(draft.preview.excerpt.count) characters")
            }
            // A template missing its placeholder builds the same URL for every
            // chapter — which still previews fine, because the preview reads a
            // real catalog link rather than a built URL.
            if !draft.rule.urls.chapter.contains("{chapterId}") {
                report.failures.append("chapter template has no {chapterId}: \(draft.rule.urls.chapter)")
            }
            if !draft.rule.urls.catalog.contains("{bookId}") {
                report.failures.append("catalog template has no {bookId}: \(draft.rule.urls.catalog)")
            }
            // An http template on a site served over https downgrades every
            // later request to plaintext. It is not blocked — the app allows
            // arbitrary loads inside web content, which these sites need — so
            // nothing would ever surface it except this check.
            if bookURL.scheme == "https", !draft.rule.urls.chapter.hasPrefix("https://") {
                report.failures.append("chapter template is not https: \(draft.rule.urls.chapter)")
            }
        } catch {
            report.record("derive", error)
        }
        return report
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

        // 1. Find a book the site itself links to.
        do {
            report.bookId = try await discoverBookId(rule: rule, fetcher: fetcher)
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
            book = try repo.bookmark(
                siteId: rule.id, siteBookId: siteBookId,
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

        // 4. Chapter text — the stage the rule notes are least sure about.
        if let first = chapters.first {
            do {
                let paragraphs = try await service.chapterParagraphs(rule: rule, chapter: first)
                report.paragraphCount = paragraphs.count
                let text = paragraphs.joined()
                if text.count < 100 {
                    report.failures.append("chapter: only \(text.count) characters extracted")
                }
            } catch {
                report.record("chapter", error)
            }
        }

        // 5. Search, where the rule claims to support it.
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

    /// Two characters, not one: twking rejects anything under 4 bytes
    /// ("搜索關鍵字請不要少于 4 個字節"), and a probe that a healthy site refuses
    /// would report the rule as broken when it is fine.
    private static let searchProbe = "劍來"

    /// Reads every link on the site's front page and returns the first that the
    /// rule can read a book id from — while rejecting chapter links, which on
    /// several of these sites also match the book pattern.
    private func discoverBookId(rule: SiteRule, fetcher: WebFetcher) async throws -> String? {
        struct Links: Decodable { let hrefs: [String] }
        guard let home = URL(string: "https://\(rule.host)/") else { return nil }
        let script = """
        (function () {
          return {
            hrefs: Array.prototype.slice.call(document.querySelectorAll('a[href]'))
              .map(function (a) { return a.href; })
          };
        })()
        """
        let links = try await fetcher.fetch(home, extracting: script, as: Links.self)
        for href in links.hrefs {
            guard let url = URL(string: href), rule.matches(url) else { continue }
            guard rule.chapterId(from: url) == nil, let id = rule.bookId(from: url) else { continue }
            return id
        }
        return nil
    }

    // MARK: - Fixtures

    /// The rules the Debug build phase copied into the app bundle. The test
    /// bundle is hosted by the app, so `Bundle.main` is the app.
    private func loadSeededRules() throws -> [SiteRule] {
        guard let folder = Bundle.main.url(forResource: "DevSiteRules", withExtension: nil) else {
            return []
        }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let decoder = JSONDecoder()
        return try files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try decoder.decode(SiteRule.self, from: try Data(contentsOf: $0)) }
    }
}

/// Puts the fetcher's web view in a real window.
///
/// Not optional: WKWebView never completes layout-dependent work — including the
/// JS that clears a non-interactive Cloudflare challenge — while it has no
/// window, so a windowless fetch against these hosts times out every time.
@MainActor
private final class HeadlessHost {
    private let window: UIWindow

    init(webView: UIView) {
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = false
        window.addSubview(webView)
    }

    func tearDown() {
        window.subviews.forEach { $0.removeFromSuperview() }
        window.isHidden = true
    }
}

private extension String {
    func padded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
