import XCTest
@testable import NovelReader

/// Downloads are the only traffic this app generates with nobody watching, so
/// "Wi-Fi only" has to mean it — including for the connections that do not
/// announce themselves as cellular, and including the case where the connection
/// changes after the queue has already started.
@MainActor
final class DownloadNetworkPolicyTests: XCTestCase {
    // MARK: - What counts as cellular

    /// The case that matters most and looks least like cellular: tethering to a
    /// phone's hotspot is reported as a Wi-Fi interface. Classifying by interface
    /// type alone would answer "Wi-Fi" and quietly spend someone else's data.
    func testAPersonalHotspotCountsAsCellular() {
        XCTAssertEqual(
            NetworkMonitor.classify(isSatisfied: true, usesCellular: false, isExpensive: true),
            .cellular
        )
    }

    func testTheRemainingInterfaceKindsMapAsExpected() {
        XCTAssertEqual(
            NetworkMonitor.classify(isSatisfied: true, usesCellular: true, isExpensive: true),
            .cellular
        )
        XCTAssertEqual(
            NetworkMonitor.classify(isSatisfied: true, usesCellular: false, isExpensive: false),
            .wifi
        )
        XCTAssertEqual(
            NetworkMonitor.classify(isSatisfied: false, usesCellular: true, isExpensive: true),
            .offline,
            "An unsatisfied path is no connection at all, whatever interfaces it names"
        )
    }

    // MARK: - The policy

    func testWifiOnlyAsksBeforeSpendingCellularData() {
        XCTAssertTrue(DownloadSettings.NetworkPolicy.wifiOnly.needsConfirmation(on: .cellular))
        XCTAssertFalse(DownloadSettings.NetworkPolicy.wifiOnly.needsConfirmation(on: .wifi))
    }

    /// The entire point of the second option: no detection, no prompt.
    func testWifiAndCellularNeverAsks() {
        for connection in [NetworkMonitor.Connection.wifi, .cellular, .offline, .unknown] {
            XCTAssertFalse(
                DownloadSettings.NetworkPolicy.wifiAndCellular.needsConfirmation(on: connection),
                "\(connection) must not produce a prompt once cellular is allowed"
            )
        }
    }

    /// Before the first path report there is nothing to warn about, and a prompt
    /// on a device that turns out to be on Wi-Fi would be a lie.
    func testAnUnknownConnectionDoesNotAsk() {
        XCTAssertFalse(DownloadSettings.NetworkPolicy.wifiOnly.needsConfirmation(on: .unknown))
    }

    /// The default is the promise: a fresh install must not be able to spend
    /// cellular data on a download without being asked.
    func testThePolicyDefaultsToWifiOnlyAndPersists() throws {
        let suite = "DownloadNetworkPolicyTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(DownloadSettings(defaults: defaults).network, .wifiOnly)
        DownloadSettings(defaults: defaults).network = .wifiAndCellular
        XCTAssertEqual(DownloadSettings(defaults: defaults).network, .wifiAndCellular)
    }

    // MARK: - Pausing a run that is already going

    /// Leaving Wi-Fi mid-download pauses rather than cancels, and says why: the
    /// remaining chapters have to survive so resume picks up where it stopped,
    /// and a queue that stops with no message reads as a bug.
    func testPausingWithAReasonKeepsTheQueueAndExplainsItself() throws {
        let database = try AppDatabase.makeInMemory()
        let files = ChapterFileStore(
            root: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        let manager = DownloadManager(
            service: BookService(fetcher: WebFetcher(), repo: LibraryRepo(database: database)),
            downloads: DownloadStore(database: database, files: files),
            pacer: RequestPacer()
        )
        let book = Book(
            id: "book", siteId: "demo", siteBookId: "1", title: "t", displayName: nil,
            author: nil, coverURL: nil, addedAt: Date(), updatedAt: Date(),
            lastReadChapterIndex: nil, lastReadOffset: nil, catalogUpdatedAt: nil
        )
        let chapters = (1...2).map {
            Chapter(
                id: "\($0)", bookId: "book", siteChapterId: "\($0)", index: $0,
                title: "chapter", url: "https://example.com/\($0)", downloadedAt: nil
            )
        }
        manager.start(book: book, rule: makeRule(), chapters: chapters)

        manager.pause(reason: "on cellular")

        XCTAssertEqual(manager.status, .paused)
        XCTAssertTrue(manager.canResume, "A policy pause must not throw away the queue")
        XCTAssertEqual(manager.lastError, "on cellular")
        manager.cancel()
    }

    private func makeRule() -> SiteRule {
        SiteRule(
            id: "demo", name: "Demo", host: "demo.test",
            urls: .init(
                book: "https://demo.test/book/{bookId}",
                catalog: "https://demo.test/book/{bookId}/",
                chapter: "https://demo.test/txt/{bookId}/{chapterId}"
            ),
            idPatterns: .init(bookId: "/book/(\\d+)", chapterId: "/txt/\\d+/(\\d+)"),
            search: nil,
            book: .init(
                title: .init(meta: nil, selector: "h1", attribute: nil),
                author: nil, cover: nil, category: nil, status: nil, intro: nil,
                latestChapter: nil
            ),
            catalog: .init(container: "#catalog", linkSelector: "a", order: .ascending),
            chapter: .init(
                titleSelectors: ["h1"], contentSelectors: [".content"],
                stripSelectors: [], dropParagraphPatterns: nil, prevSelector: nil,
                nextSelector: nil
            ),
            notes: nil
        )
    }
}
