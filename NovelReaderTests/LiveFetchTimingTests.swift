import XCTest
@testable import NovelReader

/// How long a catalog, and a comic chapter's page list, take to read off each real site —
/// and whether reading them as soon as they are there (`WebFetcher.fetch(readyWhen:)`)
/// loses anything.
///
/// A measurement, not a check: its verdict is the table it prints. Opt-in for the same
/// reasons as `LiveSiteTests`, and not part of `make test-live` — it loads every page
/// several times, which is fine to ask of a site once while tuning and rude to ask on
/// every run. Run it alone (`NOVELREADER_TIMING_KIND=comic` narrows it to one kind):
///
///     TEST_RUNNER_NOVELREADER_LIVE=1 xcodebuild test … \
///       -only-testing:NovelReaderTests/LiveFetchTimingTests
///
/// The `settled` read is the yardstick for "complete": the fetch as it was before
/// `readyWhen` — the load event, or the readable grace — and then ten more seconds before
/// extracting, longer than any site has been seen to keep adding to a list. So `settled`
/// minus ten is roughly what the old way took on this run. A faster read that differs
/// from it is a read that stopped too early, and the row says so.
@MainActor
final class LiveFetchTimingTests: XCTestCase {
    private typealias Cell = (seconds: Double, count: Int)

    private struct Row {
        let site: String
        var book = "—"
        var first: Cell?
        var second: Cell?
        var settled: Cell?
        var pages: Cell?
        var pagesSettled: Cell?
        var notes: [String] = []

        var line: String {
            func cell(_ v: Cell?) -> String {
                v.map { String(format: "%5.1fs %5d", $0.seconds, $0.count) } ?? "    —      —"
            }
            var text = "  \(site.padding(toLength: 20, withPad: " ", startingAt: 0))"
                + " \(book.padding(toLength: 12, withPad: " ", startingAt: 0))"
                + " catalog \(cell(first)) again \(cell(second)) settled \(cell(settled))"
            if pages != nil || pagesSettled != nil {
                text += "  pages \(cell(pages)) settled \(cell(pagesSettled))"
            }
            return text + (notes.isEmpty ? "" : "  " + notes.joined(separator: "; "))
        }
    }

    func testFetchTimings() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["NOVELREADER_LIVE"] == "1",
            "Live timing is opt-in: see the type's comment."
        )
        let only = ProcessInfo.processInfo.environment["NOVELREADER_TIMING_KIND"]
        let rules = try LiveSiteRules.seeded()
            .filter { only == nil || $0.kind.rawValue == only }
            .sorted { ($0.kind.rawValue, $0.id) < ($1.kind.rawValue, $1.id) }
        XCTAssertFalse(rules.isEmpty, "No rules in the app bundle — is this a Debug build?")

        var rows: [Row] = []
        for rule in rules where rule.kind != .feed {
            rows.append(await time(rule))
            print(rows.last!.line)
        }
        print("\n=== fetch timing ===\n" + rows.map(\.line).joined(separator: "\n") + "\n")
    }

    private func time(_ rule: SiteRule) async -> Row {
        var row = Row(site: "\(rule.kind.rawValue)/\(rule.id)")
        let fetcher = WebFetcher()
        let host = HeadlessHost(webView: fetcher.webView)
        defer { host.tearDown() }
        guard let database = try? AppDatabase.makeInMemory() else {
            row.notes.append("no database")
            return row
        }
        let repo = LibraryRepo(database: database)
        let service = BookService(fetcher: fetcher, repo: repo)

        let candidates: [String]
        do {
            candidates = try await LiveSiteRules.discoverBookIds(rule: rule, fetcher: fetcher, limit: 6)
        } catch {
            row.notes.append("homepage: \(error.localizedDescription)")
            return row
        }
        for siteBookId in candidates {
            guard let info = try? await service.info(rule: rule, siteBookId: siteBookId),
                  let book = try? repo.bookmark(
                      siteId: rule.id, siteBookId: siteBookId, kind: rule.kind,
                      title: info.title, author: info.author, coverURL: info.cover
                  )
            else { continue }
            let start = ContinuousClock.now
            guard let chapters = try? await service.refreshCatalog(rule: rule, book: book),
                  !chapters.isEmpty
            else { continue }
            row.book = siteBookId
            row.first = (Self.seconds(since: start), chapters.count)
            let early = chapters.map(\.siteChapterId)

            let again = ContinuousClock.now
            if let chapters = try? await service.refreshCatalog(rule: rule, book: book) {
                row.second = (Self.seconds(since: again), chapters.count)
            }

            // The yardstick: the old way in, then a selector that never matches, so the
            // extraction waits out the whole late-content grace first.
            let settled = ContinuousClock.now
            if let url = rule.catalogURL(bookId: siteBookId),
               let script = try? ExtractorScript.catalog(rule),
               let payload = try? await fetcher.fetch(
                   url, extracting: script, as: ExtractorScript.CatalogPayload.self,
                   signIn: rule.signIn, waitingFor: Self.neverMatches
               ) {
                let late = BookService.entries(from: payload, rule: rule, siteBookId: siteBookId)
                    .map(\.siteChapterId)
                row.settled = (Self.seconds(since: settled), late.count)
                // Same chapters in the same order, not just as many: a list read before a
                // page re-sorted it would count the same and be backwards.
                if late != early { row.notes.append("catalog DIFFERS from the settled read") }
            }

            // The first chapter, for the reason `LiveComicSiteTests` gives: later ones can
            // be behind a purchase wall.
            if rule.kind == .comic, let first = chapters.first {
                await timePages(of: first, rule: rule, service: service, fetcher: fetcher, into: &row)
            }
            return row
        }
        row.notes.append("no candidate opened (\(candidates.count) tried)")
        return row
    }

    private func timePages(
        of chapter: Chapter, rule: SiteRule, service: BookService, fetcher: WebFetcher,
        into row: inout Row
    ) async {
        let start = ContinuousClock.now
        let early: [URL]
        do {
            early = try await service.chapterImageURLs(rule: rule, chapter: chapter)
            row.pages = (Self.seconds(since: start), early.count)
        } catch {
            row.notes.append("pages: \(error.localizedDescription)")
            return
        }
        let settled = ContinuousClock.now
        guard let url = URL(string: chapter.url),
              let script = try? ExtractorScript.comicImages(rule),
              let payload = try? await fetcher.fetch(
                  url, extracting: script, as: ExtractorScript.ComicImagesPayload.self,
                  signIn: rule.signIn, waitingFor: Self.neverMatches
              )
        else { return }
        let late = payload.imageURLs.compactMap { URL(string: $0) }
        row.pagesSettled = (Self.seconds(since: settled), late.count)
        if late != early { row.notes.append("pages DIFFER from the settled read") }
    }

    private static let neverMatches = "#__fetch_timing_never_matches__"

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let c = (ContinuousClock.now - start).components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
