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

    /// Chapters the reader has moved past give their rows back before new ones
    /// arrive, each standing in as a spacer of its own measured height — and nothing
    /// about it may move the screen.
    ///
    /// The report behind this one: the stalls grew the longer the session ran —
    /// ~25ms more per accumulated chapter on device, for the append *and* for every
    /// page turn — because `loaded` only ever grew and a lazy stack never releases
    /// a row it has built. The first fix *removed* read chapters and re-aimed with a
    /// correction; that correction flinched the screen backwards at every seam and
    /// its arrival gate held progress writes shut — which is why this test pins
    /// `scrollTarget` staying nil through both the collapse and the way back, not
    /// just how much of the window is live.
    func testChaptersFarBehindTheReaderCollapseInPlace() async throws {
        let model = try await readForward(chapters: 5)

        XCTAssertEqual(
            model.loaded.filter { $0.collapsedHeight == nil }.map(\.chapter.index),
            [3, 4, 5],
            "only the kept chapter, the current one and the frontier may still hold rows"
        )
        // 60pt of title plus thirty 40pt rows, for each chapter over.
        XCTAssertEqual(
            model.loaded.compactMap(\.collapsedHeight), Array(repeating: 60 + 30 * 40, count: 3),
            "a collapsed chapter must stand in as exactly its measured height"
        )
        XCTAssertNil(
            model.scrollTarget,
            "a collapse must not aim the scroll at a row — that correction snaps to the "
                + "paragraph boundary, which is the flinch the first trim attempt died of"
        )
        // A spacer is only ever an estimate of what the container was giving the
        // chapter — measured against a sweep of spacer heights, it holds a released
        // chapter at about four fifths of what its own rows measure — so the collapse
        // states the reader's place exactly instead of trusting the heights to match.
        XCTAssertEqual(
            model.scrollCorrection?.minY, 0,
            "a collapse must state where the reader was, to the point"
        )

        // The way back: the chapter above re-inflates where it stands, so this too
        // needs no correction — and only one chapter comes back per turn round, or a
        // flick upward would rebuild the whole session at once.
        _ = model.viewportChanged(
            top: visible(chapterIndex: 3, paragraph: 5, minY: 0),
            bottom: visible(chapterIndex: 3, paragraph: 15, minY: 400)
        )
        _ = model.viewportChanged(
            top: visible(chapterIndex: 3, paragraph: 2, minY: 0),
            bottom: visible(chapterIndex: 3, paragraph: 12, minY: 400)
        )

        XCTAssertNil(
            model.loaded.first { $0.chapter.index == 2 }?.collapsedHeight,
            "the chapter above a reader heading up must have its rows back before they arrive"
        )
        XCTAssertNotNil(
            model.loaded.first { $0.chapter.index == 1 }?.collapsedHeight,
            "the chapter beyond that stays collapsed until the reader keeps going"
        )
        XCTAssertNil(
            model.scrollTarget,
            "re-inflating must not snap to a paragraph either — it states the reader's "
                + "place the same way the collapse does"
        )
    }

    /// A chapter whose rows were never all measured cannot be priced — and must not
    /// stop the chapters behind it from collapsing.
    ///
    /// This is the shape every real session has: a landing pulls the chapter before
    /// it in (`loadStoredPrevious`) and the reader never scrolls back through it, so
    /// its rows are never measured. While collapsed chapters were pooled into one
    /// spacer at the head of the column, that unpriceable chapter stood at the front
    /// of a queue and dammed everything behind it: a device trace of an ordinary
    /// evening showed zero collapses, a window growing all session, and finally an
    /// eviction whose correction slid the page backwards under the reader.
    func testAnUnpriceableChapterDoesNotDamTheChaptersBehindIt() async throws {
        let model = try await readForward(chapters: 5, unmeasured: [0])

        XCTAssertNil(
            model.loaded.first?.collapsedHeight,
            "a chapter with unmeasured rows cannot be priced, so it keeps its own"
        )
        XCTAssertEqual(
            model.loaded.filter { $0.collapsedHeight != nil }.map(\.chapter.index), [1, 2],
            "every chapter behind it that *can* be priced must still collapse"
        )
        XCTAssertNil(
            model.scrollTarget,
            "and none of it may be paid for with a correction"
        )
    }

    /// A backlog of collapsible chapters is paid off one per append, not all at once.
    ///
    /// Nothing can be collapsed until some seam has priced a title, and a session can
    /// read several chapters before one does — the reader who opens mid-book and turns
    /// pages forward crosses no seam at all until the first prefetched chapter lands.
    /// The instant a seam does arrive, every chapter behind the reader becomes
    /// collapsible together, and taking them together is one mutation handing several
    /// chapters' rows back to the container in a single frame. That is the blink at the
    /// seam this throttle exists for; `reinflateChapterAbove` has always had it, and
    /// the way down was missing it.
    ///
    /// The ordinary case cannot see this at all — one chapter is read, one chapter
    /// falls behind — which is why it needs a test of its own.
    func testACollapseBacklogIsPaidOffOneChapterPerAppend() async throws {
        let count = 10
        try env.repo.replaceCatalog(bookId: book.id, entries: (1...count).map {
            (siteChapterId: "c\($0)", title: "第\($0)章", url: "https://alpha/\($0)")
        })
        for chapter in 1...count {
            try env.downloads.save(
                paragraphs: (0..<30).map { "第\(chapter)章第\($0)段" },
                book: book, siteChapterId: "c\(chapter)"
            )
        }
        let model = ReaderModel(book: book, env: env)
        await model.start(at: .chapterStart("c1"))

        // Five chapters read with every row measured, but no seam ever reported: the
        // heights are all on record and not one of them can be turned into a spacer.
        for index in 0..<5 {
            model.noteFrames((0..<30).map {
                visible(chapterIndex: index, paragraph: $0, minY: CGFloat($0) * 40)
            })
            _ = model.viewportChanged(
                top: visible(chapterIndex: index, paragraph: 0, minY: 0),
                bottom: visible(chapterIndex: index, paragraph: 1, minY: 44)
            )
            await model.loadNext()
        }
        XCTAssertTrue(
            model.loaded.allSatisfy { $0.collapsedHeight == nil },
            "with no title priced, nothing can collapse however far behind it has fallen"
        )

        // The first seam of the session. Chapters 0, 1 and 2 all become collapsible in
        // the same instant — three chapters' worth of rows, all due at once.
        model.noteFrames([
            visible(chapterIndex: 3, paragraph: 29, minY: 0),
            visible(chapterIndex: 4, paragraph: 0, minY: 100),
        ])
        _ = model.viewportChanged(
            top: visible(chapterIndex: 4, paragraph: 0, minY: 0),
            bottom: visible(chapterIndex: 4, paragraph: 1, minY: 44)
        )
        await model.loadNext()

        XCTAssertEqual(
            model.loaded.filter { $0.collapsedHeight != nil }.map(\.chapter.index), [0],
            "a backlog of three must cost one chapter's rows per append, not three"
        )

        // And the rest is not stranded: it drains at the rate it accrued.
        _ = model.viewportChanged(
            top: visible(chapterIndex: 4, paragraph: 2, minY: 0),
            bottom: visible(chapterIndex: 4, paragraph: 3, minY: 44)
        )
        await model.loadNext()

        XCTAssertEqual(
            model.loaded.filter { $0.collapsedHeight != nil }.map(\.chapter.index), [0, 1],
            "the backlog must drain one per append rather than sit there"
        )
    }

    /// Reads forward through `chapters` chapters, reporting the frames the view would.
    ///
    /// Every row of a chapter passes through the frames as it is read (40pt each), and
    /// each seam shows the 60pt title gap between the last row of one chapter and the
    /// head of the next. Those heights are what the collapse sums — chapter heads are
    /// never on screen together, so positions could never be compared directly.
    ///
    /// - Parameter unmeasured: chapters whose rows are never reported, standing in for
    ///   a chapter the reader never scrolled through.
    private func readForward(
        chapters: Int, unmeasured: Set<Int> = []
    ) async throws -> ReaderModel {
        try env.repo.replaceCatalog(bookId: book.id, entries: (1...(chapters + 2)).map {
            (siteChapterId: "c\($0)", title: "第\($0)章", url: "https://alpha/\($0)")
        })
        for chapter in 1...(chapters + 2) {
            try env.downloads.save(
                paragraphs: (0..<30).map { "第\(chapter)章第\($0)段" },
                book: book, siteChapterId: "c\(chapter)"
            )
        }
        let model = ReaderModel(book: book, env: env)
        await model.start(at: .chapterStart("c1"))

        for index in 0..<chapters {
            if !unmeasured.contains(index) {
                model.noteFrames((0..<30).map {
                    visible(chapterIndex: index, paragraph: $0, minY: CGFloat($0) * 40)
                })
            }
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
        return model
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
