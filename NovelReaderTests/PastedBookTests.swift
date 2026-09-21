import XCTest
@testable import NovelReader

/// A pasted address whose site has no source, through the whole environment.
///
/// Only the refusal is offline. Every path that ends in a new source goes through a real
/// page in a real web view, which no stub reaches — that half is
/// `LiveSiteTests.testPastingABookFromASiteWithNoSourceInstallsOne`.
@MainActor
final class PastedBookTests: XCTestCase {
    private var tempRoot: URL!
    private var env: AppEnvironment!

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PastedBookTests-\(UUID().uuidString)")
        env = AppEnvironment(
            database: try AppDatabase.makeInMemory(),
            files: ChapterFileStore(root: tempRoot.appendingPathComponent("files")),
            cache: ChapterCache(
                files: ChapterFileStore(root: tempRoot.appendingPathComponent("cache"))
            ),
            coverFiles: CoverStore(root: tempRoot.appendingPathComponent("covers")),
            sites: SiteStore(directory: tempRoot.appendingPathComponent("sites")),
            queueStore: DownloadQueueStore(url: tempRoot.appendingPathComponent("queue.json"))
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    /// No source is no longer the end of the line — the paste tries to make one — so an
    /// address that cannot become one has to say so on its own row, with the derivation's
    /// reason, which is the part that tells the reader what to paste instead. And it must
    /// leave nothing behind: a source installed for a site that was never read would be
    /// listed in settings and match every later paste from that host.
    func testAnAddressNoSourceCanBeMadeForFailsOnItsRowAndInstallsNothing() async throws {
        XCTAssertTrue(env.sites.rules.isEmpty, "the premise: nothing installed")

        env.additions.start(AddBookLine.pasted("ftp://example.com/book/1"), as: .book)
        await env.additions.settle()

        let reason = AppEnvironment.AddBookError
            .derivationFailed(RuleDeriver.DeriveError.badURL.localizedDescription)
            .localizedDescription
        XCTAssertEqual(env.additions.failures, 1)
        XCTAssertEqual(env.additions.lines.first?.status.note, reason)
        XCTAssertTrue(env.sites.rules.isEmpty, "nothing installed for a site that was never read")
        XCTAssertTrue(env.books.isEmpty)
    }
}
