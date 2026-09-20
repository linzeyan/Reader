import XCTest
@testable import NovelReader

/// What the reader holds on to while a session goes on, and what it gives back.
///
/// Measured before any of this existed (STATUS, 2026-09-20): thirty-three minutes of
/// continuous reading grew the window to thirty-five chapters and resident memory tracked
/// it exactly, at 1.65 MB a chapter, because a loaded chapter is a laid-out column and not
/// the seventy kilobytes of text inside it. Nothing ever gave one back — the only trim
/// there had ever been ran on a memory warning, which in an unattended listening session
/// may not arrive before the app is killed.
///
/// So the window is trimmed as it grows. These are the rules that makes it safe: the
/// chapter being read is never the one given back, a reader turning around finds what they
/// turned towards, and a trim never argues with a finger on the glass.
@MainActor
final class ReaderLoadedWindowTests: XCTestCase {
    private var tempRoot: URL!
    private var env: AppEnvironment!
    private var book: Book!

    /// Comfortably more than twice the window, so a walk to the end of it has to have
    /// dropped something rather than merely run out of book.
    private let chapterCount = 24

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NovelReaderTests-\(UUID().uuidString)")
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
        book = try env.repo.bookmark(siteId: "alpha", siteBookId: "1", title: "A")
        try env.repo.replaceCatalog(bookId: book.id, entries: (1...chapterCount).map {
            (siteChapterId: "c\($0)", title: "第\($0)章", url: "https://alpha/\($0)")
        })
        // All on disk, so nothing here depends on a network or a site rule.
        for index in 1...chapterCount {
            try env.downloads.save(
                paragraphs: ["第\(index)章的一段"], book: book, siteChapterId: "c\(index)"
            )
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    /// Reading forward for a long time does not hold every chapter crossed.
    func testReadingOnDoesNotHoldEveryChapterItCrossed() async throws {
        let model = ReaderModel(book: book, env: env)
        await model.start(at: .chapterStart("c1"))
        await readForward(model, chapters: chapterCount - 1)

        XCTAssertLessThanOrEqual(
            model.loaded.count, model.loadedReach * 2 + 1,
            "a session that crossed \(chapterCount) chapters should not be holding them all"
        )
        XCTAssertGreaterThan(
            model.loaded.count, model.loadedReach,
            "and should not have given back the chapters around the reader either"
        )
    }

    /// The chapter being read is the one thing a trim may never take, and the one behind
    /// it is where a reader turning back goes.
    func testTheChapterBeingReadAndTheOneBehindItSurvive() async throws {
        let model = ReaderModel(book: book, env: env)
        await model.start(at: .chapterStart("c1"))
        await readForward(model, chapters: chapterCount - 1)

        let held = Set(model.loaded.map(\.chapter.index))
        XCTAssertTrue(
            held.contains(model.currentChapterIndex),
            "the chapter under the reader is the one thing that cannot be given back"
        )
        XCTAssertTrue(
            held.contains(model.currentChapterIndex - 1),
            "and turning back a chapter must not wait for a fetch"
        )
    }

    /// Real memory pressure trims far harder than the routine one: the trade there is
    /// everything for staying alive.
    func testAMemoryWarningGivesBackMoreThanTheRoutineTrim() async throws {
        let model = ReaderModel(book: book, env: env)
        await model.start(at: .chapterStart("c1"))
        await readForward(model, chapters: chapterCount - 1)
        let routine = model.loaded.count

        model.dropDistantChapters(keeping: 1)
        XCTAssertLessThan(model.loaded.count, routine)
        XCTAssertLessThanOrEqual(model.loaded.count, 3)
        XCTAssertTrue(
            model.loaded.contains { $0.chapter.index == model.currentChapterIndex },
            "even under pressure the reader keeps what is under their eyes"
        )
    }

    /// A trim is never urgent enough to argue with a gesture.
    ///
    /// A pan and the coast after it both carry a destination computed before the content
    /// above the reader got shorter — the reason an arriving chapter waits for the same
    /// moment. Taking chapters out mid-pan would move the page under the finger.
    func testAFingerOnTheGlassHoldsTheTrimOff() async throws {
        let model = ReaderModel(book: book, env: env)
        await model.start(at: .chapterStart("c1"))
        model.touch(down: true)
        await readForward(model, chapters: chapterCount - 1)

        XCTAssertEqual(
            model.loaded.count, chapterCount,
            "nothing may be taken out from under a finger that is still on the glass"
        )
    }

    /// Nor with a page turn the reader tapped for and that is still on its way.
    ///
    /// The device trace of 2026-09-20 caught this seven times out of seven: a turn is what
    /// asks for the next chapter, the chapter arriving is what trims the window, and the
    /// trim therefore always lands inside the turn's own quarter-second animation. The
    /// turn carries an absolute offset computed against the taller stack, so the trim took
    /// a chapter — ten thousand points — out from under a destination that could no longer
    /// be re-aimed, and the reader got half a screen of the page they had just left.
    func testATurnStillInTheAirHoldsTheTrimOff() async throws {
        let model = ReaderModel(book: book, env: env)
        await model.start(at: .chapterStart("c1"))
        model.turning(true)
        await readForward(model, chapters: chapterCount - 1)

        XCTAssertEqual(
            model.loaded.count, chapterCount,
            "the ground may not move while a turn is still travelling across it"
        )

        // Deferred, not cancelled — asserted here rather than in a test of its own
        // because on its own it passes with the bug still in: the trim it is meant to be
        // waiting for has already happened by then.
        model.turning(false)
        XCTAssertLessThanOrEqual(
            model.loaded.count, model.loadedReach * 2 + 1,
            "and the turn landing is what releases the chapters it held on to"
        )
    }

    // MARK: - Helpers

    /// Reads on the way a reader does: the next chapter arrives, and the reader is in it.
    ///
    /// The position is moved by `noteSpoken`, which is the one path that reports a place
    /// with nothing drawn — and listening with the screen off is the session this whole
    /// rule exists for.
    private func readForward(_ model: ReaderModel, chapters: Int) async {
        for _ in 1...chapters {
            await model.loadNext()
            guard let arrived = model.loaded.last else { return }
            model.noteSpoken(chapterIndex: arrived.chapter.index, anchor: .start)
        }
    }
}
