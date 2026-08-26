import XCTest
@testable import NovelReader

/// How a prefetched chapter is allowed to arrive.
///
/// The report behind this: on device, the read-ahead's append was one SwiftUI
/// transaction growing the lazy stack by a whole chapter — 300–440ms of main-thread
/// graph work, a frozen screen for whoever tapped during it. Deferring it to a quiet
/// viewport (1.3.2) moved the freeze off the turn animation but kept its size. The
/// rule these tests pin: a chapter fetched *ahead* of the reader must never arrive
/// as a single mutation; it grows in slices, each small enough to fit a frame.
///
/// The jump path stays atomic on purpose — it fills an empty screen, where there is
/// no animation to freeze and nothing on screen to grow beneath.
@MainActor
final class ReaderChapterAppendTests: XCTestCase {
    private var tempRoot: URL!
    private var env: AppEnvironment!
    private var files: ChapterFileStore!
    private var book: Book!

    private let siteId = "alpha"
    private let siteBookId = "1"
    /// Long enough that slicing is observable: several slices' worth of paragraphs.
    private let secondChapterLength = 200

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NovelReaderTests-\(UUID().uuidString)")
        files = ChapterFileStore(root: tempRoot.appendingPathComponent("files"))
        env = AppEnvironment(
            database: try AppDatabase.makeInMemory(),
            files: files,
            sites: SiteStore(directory: tempRoot.appendingPathComponent("sites")),
            queueStore: DownloadQueueStore(url: tempRoot.appendingPathComponent("queue.json"))
        )
        book = try env.repo.bookmark(siteId: siteId, siteBookId: siteBookId, title: "A")
        try env.repo.replaceCatalog(bookId: book.id, entries: [
            (siteChapterId: "c1", title: "第1章", url: "https://alpha/1"),
            (siteChapterId: "c2", title: "第2章", url: "https://alpha/2"),
        ])
        try env.downloads.save(paragraphs: ["第一章的一段"], book: book, siteChapterId: "c1")
        try env.downloads.save(
            paragraphs: (0..<secondChapterLength).map { "第二章第\($0)段" },
            book: book, siteChapterId: "c2"
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    /// The read-ahead chapter must pass through at least one partial state on its
    /// way in — that is the whole difference between one 400ms transaction and a
    /// handful of invisible ones.
    func testPrefetchedChapterGrowsInSlicesRatherThanArrivingWhole() async throws {
        let model = ReaderModel(book: book, env: env)
        await model.start(at: .chapterStart("c1"))
        XCTAssertEqual(model.loaded.count, 1)

        // Sample the tail chapter while the append runs. Each slice rests on the
        // screen for tens of milliseconds, so a fine sampler cannot miss them all.
        let sampler = Task { @MainActor in
            var seen: Set<Int> = []
            while !Task.isCancelled {
                if let tail = model.loaded.last, tail.chapter.siteChapterId == "c2" {
                    seen.insert(tail.paragraphs.count)
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return seen
        }
        await model.loadNext()
        sampler.cancel()
        let seen = await sampler.value

        XCTAssertEqual(
            model.loaded.last?.paragraphs.count, secondChapterLength,
            "the chapter must be complete once loadNext returns"
        )
        XCTAssertTrue(
            seen.contains { $0 < secondChapterLength },
            "the chapter must arrive through partial states, not as one mutation — saw \(seen)"
        )
    }

    /// Chapters the reader has moved past collapse into the gap spacer before new
    /// ones arrive — and nothing about it may move the screen.
    ///
    /// The report behind this one: the stalls grew the longer the session ran —
    /// ~25ms more per accumulated chapter on device, for the append *and* for every
    /// page turn — because `loaded` only ever grew and a lazy stack never releases
    /// a row it has built. The first fix *removed* read chapters and re-aimed with a
    /// correction; that correction flinched the screen backwards at every seam and
    /// its arrival gate held progress writes shut — which is why this test pins
    /// `scrollTarget` staying nil through both the collapse and the way back, not
    /// just the window's size.
    func testChaptersFarBehindTheReaderCollapseIntoTheGap() async throws {
        try env.repo.replaceCatalog(bookId: book.id, entries: (1...7).map {
            (siteChapterId: "c\($0)", title: "第\($0)章", url: "https://alpha/\($0)")
        })
        for chapter in 1...7 {
            try env.downloads.save(
                paragraphs: (0..<30).map { "第\(chapter)章第\($0)段" },
                book: book, siteChapterId: "c\(chapter)"
            )
        }
        let model = ReaderModel(book: book, env: env)
        await model.start(at: .chapterStart("c1"))

        // Read forward, reporting what the view would: every row of a chapter passes
        // through the frames as it is read (40pt each), and each seam shows the 60pt
        // title gap between the last row of one chapter and the head of the next.
        // The heights are what the collapse sums — chapter heads are never on screen
        // together, so positions could never be compared directly.
        for index in 0..<5 {
            model.noteFrames((0..<30).map {
                visible(chapterIndex: index, paragraph: $0, minY: CGFloat($0) * 40)
            })
            if index > 0 {
                model.noteFrames([
                    visible(chapterIndex: index - 1, paragraph: 29, minY: 0),
                    visible(chapterIndex: index, paragraph: 0, minY: 100),
                ])
            }
            _ = model.viewportChanged(
                top: visible(chapterIndex: index, paragraph: 0, minY: 0),
                bottom: visible(chapterIndex: index, paragraph: 1, minY: 44)
            )
            await model.loadNext()
        }

        XCTAssertEqual(
            model.loaded.map(\.chapter.index), [3, 4, 5],
            "the window is the kept chapter, the current one and the frontier"
        )
        // 60pt of title plus thirty 40pt rows, three chapters over.
        XCTAssertEqual(
            model.readGapHeight, 3 * (60 + 30 * 40),
            "collapsed chapters must stand in as exactly their measured height"
        )
        XCTAssertNil(
            model.scrollTarget,
            "a collapse preserves every height above the reader, so no correction may be aimed"
        )

        // The way back: a collapsed chapter re-inflates out of the gap — the spacer
        // shortens by the height the chapter renders at, so this too needs no
        // correction.
        await model.loadPrevious(before: 3)
        model.touch(down: true)
        model.touch(down: false)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.loaded.first?.chapter.index != 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(
            model.loaded.first?.chapter.index, 2,
            "a collapsed chapter must come back through the backtrack path"
        )
        XCTAssertEqual(
            model.readGapHeight, 2 * (60 + 30 * 40),
            "the gap must shorten by exactly the height the chapter takes back"
        )
        XCTAssertNil(
            model.scrollTarget,
            "re-inflating from the gap must not aim a correction either"
        )
    }

    private func visible(
        chapterIndex: Int, paragraph: Int, minY: CGFloat
    ) -> ReaderTapZone.VisibleParagraph {
        ReaderTapZone.VisibleParagraph(
            chapterIndex: chapterIndex, paragraph: paragraph,
            id: "", minY: minY, maxY: minY + 40
        )
    }

    // No regression test pins the frontier-failure respawn fix (`error == nil` in
    // `viewportChanged`'s prefetch guard): the eternal-spinner state it prevents
    // needs a *slow* failure — the error's nil window between respawns is only
    // observable across a suspension — and every failure this seam can produce
    // throws within one main-actor slice, so a test here passes with the bug
    // present. The device probes (`fetch`/`fetchFailed` lines) are the check: one
    // failure line and then silence, not one per tap.

    /// A jump mid-growth replaces the world; the abandoned growth must not write a
    /// stale slice over the chapter the reader jumped to.
    func testJumpDuringGrowthAbandonsThePartialChapter() async throws {
        let model = ReaderModel(book: book, env: env)
        await model.start(at: .chapterStart("c1"))

        let growth = Task { @MainActor in await model.loadNext() }
        // Wait until the growing chapter has visibly started.
        let started = ContinuousClock.now
        while model.loaded.last?.chapter.siteChapterId != "c2" {
            try await Task.sleep(for: .milliseconds(10))
            XCTAssertLessThan(
                ContinuousClock.now, started.advanced(by: .seconds(5)),
                "the prefetched chapter never started arriving"
            )
        }
        await model.jump(toChapterAt: 0)
        await growth.value
        // Give an abandoned loop every chance to misbehave before asserting.
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(model.loaded.count, 1, "the jump's chapter must be alone on screen")
        XCTAssertEqual(model.loaded.first?.chapter.siteChapterId, "c1")
        XCTAssertEqual(
            model.loaded.first?.paragraphs.count, 1,
            "no slice of the abandoned chapter may survive the jump"
        )
    }
}
