import XCTest
@testable import NovelReader

/// How chapters arrive, leave, and are asked for.
///
/// All of it used to be geometry. A chapter arrived in forty-row slices landed on a
/// still viewport, read chapters were collapsed into spacers of their measured height,
/// and every one of those mutations was paid for with a scroll correction that measured
/// its own miss — because a `LazyVStack` never released a row it built and would not say
/// how tall the rows it had just built were. `ReaderScrollingText` lays each chapter out
/// once, off the main thread, and knows its height, so `loaded` is now an ordinary array
/// and what is left to pin here is the ordinary array's rules: a load that outlived its
/// window, a chapter held back until the reader's hand is off the glass, and a failure
/// that stops the reader being asked for again on every frame.
@MainActor
final class ReaderChapterAppendTests: XCTestCase {
    private var tempRoot: URL!
    private var env: AppEnvironment!
    private var files: ChapterFileStore!
    private var book: Book!

    private let siteId = "alpha"
    private let siteBookId = "1"
    private let secondChapterLength = 200

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NovelReaderTests-\(UUID().uuidString)")
        files = ChapterFileStore(root: tempRoot.appendingPathComponent("files"))
        env = AppEnvironment(
            database: try AppDatabase.makeInMemory(),
            files: files,
            coverFiles: CoverStore(root: tempRoot.appendingPathComponent("covers")),
            sites: SiteStore(directory: tempRoot.appendingPathComponent("sites")),
            queueStore: DownloadQueueStore(url: tempRoot.appendingPathComponent("queue.json"))
        )
        book = try env.repo.bookmark(siteId: siteId, siteBookId: siteBookId, title: "A")
        try env.repo.replaceCatalog(bookId: book.id, entries: [
            (siteChapterId: "c1", title: "第1章", url: "https://alpha/1"),
            (siteChapterId: "c2", title: "第2章", url: "https://alpha/2"),
            // In the catalog, on no disk, and behind no site rule this environment
            // holds: the shape a frontier failure has.
            (siteChapterId: "c3", title: "第3章", url: "https://alpha/3"),
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

    /// A jump replaces the world, and a load that was in flight when it happened must
    /// not put its chapter into the new one.
    ///
    /// `loaded` alone cannot decide this. A jump empties it, and an empty window is
    /// exactly what that jump's own load is about to fill — so "the window is empty,
    /// this chapter may go in" is true for both the load the reader is waiting for and
    /// the load they walked away from. Only a generation stamp tells them apart.
    func testAJumpDuringALoadAbandonsTheChapterItWasFetching() async throws {
        let model = ReaderModel(book: book, env: env)
        await model.start(at: .chapterStart("c1"))

        let growth = Task { @MainActor in await model.loadNext() }
        await model.jump(toChapterAt: 0)
        await growth.value
        // Give an abandoned load every chance to misbehave before asserting.
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(
            model.loaded.map(\.chapter.siteChapterId), ["c1"],
            "the jump's chapter must be alone on screen"
        )
        XCTAssertEqual(
            model.currentChapterIndex, 0,
            "and the reader must still be in the chapter they jumped to"
        )
    }

    /// The chapter above the reader waits for their hand to leave the glass.
    ///
    /// The insert itself is exact now — the renderer moves the content and the scroll
    /// offset together — but the *offset* is not the renderer's to keep while a gesture
    /// is running: a pan recomputes it from where the finger started, and a
    /// deceleration is coasting toward a destination worked out before the insert.
    /// Either one puts the reader straight back where the insert found them, which
    /// leaves them at the opening of the previous chapter with the way back consumed.
    func testAChapterFetchedForTheReaderBehindWaitsForTheirHandToLeaveTheGlass() async throws {
        let model = ReaderModel(book: book, env: env)
        await model.start(at: .chapterStart("c2"))
        XCTAssertEqual(model.loaded.map(\.chapter.siteChapterId), ["c2"])

        model.touch(down: true)
        await model.loadPrevious(before: 1)

        XCTAssertEqual(
            model.loaded.map(\.chapter.siteChapterId), ["c2"],
            "text may not appear above a finger that is still dragging"
        )
        model.touch(down: false)
        XCTAssertEqual(
            model.loaded.map(\.chapter.siteChapterId), ["c1", "c2"],
            "and it must arrive the moment the gesture is over, not a gesture later"
        )
    }

    /// A chapter that will not load stops being asked for.
    ///
    /// The renderer asks on every scrolled frame the reader spends inside the prefetch
    /// lead, and `append` clears the error on entry — so an ask that ignored the failure
    /// kept the chapter in an eternal spinner. The retry button was never on screen long
    /// enough to exist and the reader was walled in with every tap doing nothing.
    func testAChapterThatWillNotLoadStopsBeingAskedFor() async throws {
        let model = ReaderModel(book: book, env: env)
        await model.start(at: .chapterStart("c2"))
        XCTAssertTrue(
            model.canLoadNext,
            "there is a chapter after this one and nothing has gone wrong yet"
        )

        await model.loadNext()

        XCTAssertNotNil(
            model.error, "the fixture has to actually fail, or this asserts nothing"
        )
        XCTAssertFalse(
            model.canLoadNext,
            "one failure, one visible retry — not one request per frame"
        )
    }

    /// What the renderer says is what gets stored, character offset included.
    ///
    /// The offset is the part that is new. A lazy stack of `Text` knew only which
    /// paragraph had come into view, so a scrolled position was always the *top of a
    /// paragraph* — and in these books a paragraph routinely runs taller than a screen,
    /// so switching to paginated reading mid-paragraph threw the reader pages backwards.
    /// A laid-out column knows which character the top line begins on.
    func testThePlaceTheRendererStatesIsWhatGetsStored() async throws {
        let model = ReaderModel(book: book, env: env)
        await model.start(at: .chapterStart("c1"))
        await model.loadNext()

        model.notePlace(ReaderPlace(
            chapterIndex: 1,
            anchor: TextAnchor(paragraph: 12, characterOffset: 40),
            fraction: 0.37
        ))

        XCTAssertEqual(model.currentChapterIndex, 1)
        XCTAssertEqual(model.currentAnchor, TextAnchor(paragraph: 12, characterOffset: 40))
        XCTAssertEqual(
            model.currentFraction, 0.37,
            "the share the renderer measured, not one recomputed from the anchor — that "
                + "would measure to where the screen begins rather than what was read"
        )
        XCTAssertEqual(
            model.currentPosition?.siteChapterId, "c2",
            "anything written down names the chapter by its site id, not its place in "
                + "the catalog"
        )
    }
}
