import XCTest
@testable import NovelReader

/// What reading online leaves behind.
///
/// Two promises, and they pull against each other. The cache has to actually answer —
/// a chapter read a minute ago must not be fetched again, or the reader pays twice for
/// the same page and the six-page memory window becomes a downgrade rather than a fix.
/// And it has to stay inside the ceiling the reader set, without their say-so, which
/// means throwing away things nobody deleted. Getting the second one wrong quietly fills
/// a phone; getting it wrong the other way throws out the chapter somebody is reading.
@MainActor
final class ChapterCacheTests: XCTestCase {
    private var root: URL!
    private var cache: ChapterCache!
    private var book: Book!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ChapterCacheTests-\(UUID().uuidString)")
        cache = ChapterCache(
            files: ChapterFileStore(root: root),
            // Its own defaults: the limit is persisted, and a test must not leave one
            // behind for the app or for the next test.
            defaults: UserDefaults(suiteName: root.lastPathComponent)!
        )
        book = Self.makeBook(id: "b1", siteId: "alpha", siteBookId: "1")
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removeSuite(named: root.lastPathComponent)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Answering

    func testAChapterOfTextReadOnlineIsThereTheSecondTime() async throws {
        cache.store(paragraphs: ["一", "二"], of: book, siteChapterId: "c1")
        await cache.work?.value

        let read = await cache.paragraphs(of: book, siteChapterId: "c1")
        XCTAssertEqual(read, ["一", "二"])
    }

    func testAChapterThatWasNeverReadAnswersWithNothing() async {
        let text = await cache.paragraphs(of: book, siteChapterId: "c1")
        XCTAssertNil(text)
        XCTAssertNil(cache.page(0, of: book, siteChapterId: "c1"))
    }

    /// A cached page comes back as a *file*, which is the whole trick: `ComicPageStore`
    /// branches on the address, so a page that answers from here takes the same path a
    /// downloaded one does — read off the disk, no cookies, no referer, and no second
    /// copy of the bytes held in memory.
    func testAPageReadOnlineComesBackAsAFileTheNextTime() async throws {
        cache.store(Data("page 3".utf8), page: 3, of: book, siteChapterId: "c1")
        await cache.work?.value

        let url = try XCTUnwrap(cache.page(3, of: book, siteChapterId: "c1"))
        XCTAssertTrue(url.isFileURL)
        XCTAssertEqual(try Data(contentsOf: url), Data("page 3".utf8))
        XCTAssertNil(
            cache.page(4, of: book, siteChapterId: "c1"),
            "Only the page that was kept; a neighbour must not answer for it"
        )
    }

    func testTwoBooksOnTheSameSiteDoNotShareAPage() async throws {
        let other = Self.makeBook(id: "b2", siteId: "alpha", siteBookId: "2")
        cache.store(Data("mine".utf8), page: 0, of: book, siteChapterId: "c1")
        await cache.work?.value

        XCTAssertNotNil(cache.page(0, of: book, siteChapterId: "c1"))
        XCTAssertNil(cache.page(0, of: other, siteChapterId: "c1"))
    }

    // MARK: - The ceiling

    /// The ceiling is the reason this is a cache and not a second downloads folder. Past
    /// it, chapters go — and what goes is measured in whole chapters, because half a
    /// comic chapter is a page the reader scrolls into and waits for, having saved one
    /// page's worth of disk.
    func testChaptersAreDroppedWholeUntilTheCacheIsUnderItsCeiling() async throws {
        cache.limit = 2_500
        for chapter in 0..<5 {
            for page in 0..<2 {
                cache.store(
                    Data(repeating: 7, count: 500), page: page,
                    of: book, siteChapterId: "c\(chapter)"
                )
            }
        }
        await cache.work?.value

        await cache.measure()
        XCTAssertLessThanOrEqual(cache.used ?? .max, 2_500)
        // Whatever survived, survived entire. A chapter of one page where two were
        // written is the failure this is really about.
        for chapter in 0..<5 {
            let kept = (0..<2).filter {
                cache.page($0, of: book, siteChapterId: "c\(chapter)") != nil
            }
            XCTAssertTrue(
                kept.isEmpty || kept.count == 2,
                "chapter c\(chapter) was left with \(kept.count) of its 2 pages"
            )
        }
    }

    /// Least recently *read*, not written longest ago. A book someone keeps coming back
    /// to should outlive one they abandoned in an evening — and the chapter they are
    /// looking at right now is the one thing that must never go.
    func testTheChapterReadMostRecentlyIsTheLastToGo() async throws {
        cache.limit = .max
        for chapter in 0..<4 {
            cache.store(
                Data(repeating: 7, count: 1_000), page: 0, of: book, siteChapterId: "c\(chapter)"
            )
            await cache.work?.value
            // Distinguishable modification times: the filesystem stores these at a
            // resolution a tight loop can write four chapters inside of.
            try await Task.sleep(for: .milliseconds(20))
        }
        // The oldest one is opened again, which is what should save it.
        XCTAssertNotNil(cache.page(0, of: book, siteChapterId: "c0"))

        cache.limit = 1_000
        await cache.work?.value

        XCTAssertNotNil(
            cache.page(0, of: book, siteChapterId: "c0"),
            "The chapter that was read last must be the one that survives"
        )
        XCTAssertNil(cache.page(0, of: book, siteChapterId: "c1"))
    }

    /// A ceiling that only applied to future reading would be a setting that did not do
    /// what it said — the reader lowers it to get the space back *now*.
    func testLoweringTheCeilingTakesEffectAtOnce() async throws {
        cache.limit = .max
        for chapter in 0..<3 {
            cache.store(
                Data(repeating: 7, count: 1_000), page: 0, of: book, siteChapterId: "c\(chapter)"
            )
        }
        await cache.work?.value
        await cache.measure()
        XCTAssertEqual(cache.used, 3_000)

        cache.limit = 1_500
        await cache.work?.value

        await cache.measure()
        XCTAssertLessThanOrEqual(cache.used ?? .max, 1_500)
    }

    /// Never larger than the disk, because a ceiling that cannot be reached is not a
    /// choice; never empty, because a nearly full phone still has to be able to pick
    /// something; and always containing what is already set, or the picker opens with no
    /// row selected and the reader's own setting is not on the list.
    func testTheCeilingsOfferedFitTheDeviceAndIncludeWhateverIsSet() {
        let roomy = ChapterCache.limits(free: 100 << 30, current: 1 << 30)
        XCTAssertEqual(roomy, ChapterCache.limitChoices)

        let tight = ChapterCache.limits(free: 700 << 20, current: 512 << 20)
        XCTAssertEqual(tight, [256 << 20, 512 << 20])

        let full = ChapterCache.limits(free: 0, current: 5 << 30)
        XCTAssertEqual(full, [256 << 20, 5 << 30])
        XCTAssertTrue(full.contains(5 << 30), "The picker must be able to show what is set")
    }

    // MARK: - Taking it back

    func testClearingABookLeavesTheOtherBooksAlone() async throws {
        let other = Self.makeBook(id: "b2", siteId: "beta", siteBookId: "9")
        cache.store(Data(repeating: 1, count: 100), page: 0, of: book, siteChapterId: "c1")
        cache.store(paragraphs: ["keep me"], of: other, siteChapterId: "c1")
        await cache.work?.value

        cache.clear(book)
        await cache.work?.value

        XCTAssertNil(cache.page(0, of: book, siteChapterId: "c1"))
        let kept = await cache.paragraphs(of: other, siteChapterId: "c1")
        XCTAssertEqual(kept, ["keep me"])
    }

    func testClearingEverythingEmptiesTheCache() async throws {
        cache.store(Data(repeating: 1, count: 100), page: 0, of: book, siteChapterId: "c1")
        await cache.work?.value

        cache.clearEverything()
        await cache.work?.value

        XCTAssertNil(cache.page(0, of: book, siteChapterId: "c1"))
        await cache.measure()
        XCTAssertEqual(cache.used, 0)
    }

    func testTheSizeShownPerBookIsTheBytesThatBookIsHolding() async throws {
        let other = Self.makeBook(id: "b2", siteId: "beta", siteBookId: "9")
        cache.store(Data(repeating: 1, count: 400), page: 0, of: book, siteChapterId: "c1")
        cache.store(Data(repeating: 1, count: 100), page: 0, of: other, siteChapterId: "c1")
        await cache.work?.value

        let sizes = await cache.sizes(of: [book, other])
        XCTAssertEqual(sizes["b1"], 400)
        XCTAssertEqual(sizes["b2"], 100)
    }

    private static func makeBook(id: String, siteId: String, siteBookId: String) -> Book {
        Book(
            id: id, siteId: siteId, siteBookId: siteBookId, kind: .comic, title: "t",
            displayName: nil, author: nil, coverURL: nil, addedAt: Date(), updatedAt: Date(),
            lastReadSiteChapterId: nil, lastReadParagraph: nil,
            lastReadCharacterOffset: nil, lastReadFraction: nil, lastReadAt: nil,
            catalogUpdatedAt: nil
        )
    }
}
