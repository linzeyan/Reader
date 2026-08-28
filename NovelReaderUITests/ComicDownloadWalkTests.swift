import XCTest

/// Puts a comic chapter on the device through the screen a person uses, and takes it
/// off again the same way.
///
/// Everything below this is pinned without a network: the `.partial` write, the four
/// delete levels, the page ordering, reading file addresses instead of remote ones.
/// What none of that can see is whether the download *screen* reaches any of it for a
/// book whose chapters are directories rather than files — the screen never mentions
/// which medium it is looking at, and a comic that quietly downloads nothing, or
/// reports a chapter it did not keep, would look exactly like a working one from
/// inside a unit test.
///
/// Live, and opt-in for it: one real chapter from a real CDN. Run with
/// `make test-ui-live`.
final class ComicDownloadWalkTests: XCTestCase {
    private var app: XCUIApplication!

    /// The same book the reading walk uses, for the same reason: manhuagui is the
    /// hardest of the four surveyed sites, so a chapter that lands here did not land
    /// by luck.
    private let address = "https://m.manhuagui.com/comic/2807/"

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-library.home", "library", "-library.defaultMediaMode", "comic"]
        app.launch()
    }

    func testDownloadAChapterAndDeleteItAgain() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["NOVELREADER_LIVE"] == "1",
            "Needs the network: run `make test-ui-live`."
        )
        addTheComic()
        openTheDownloadScreen()

        XCTAssertEqual(downloadedCount(), 0, "nothing is on the device yet")

        tickTheFirstChapter()
        app.buttons["downloads.downloadSelected"].tap()
        // A comic chapter is 15–200 images fetched three at a time, which is why this
        // waits far longer than a novel's would.
        waitForCount(toRead: 1, within: 300, describedAs: "the chapter should land")
        attach("comic-downloaded")

        readTheDownloadedChapter()

        // And the same row again, which is the delete this screen owns: the chapter
        // level of the four.
        tickTheFirstChapter()
        app.buttons["downloads.deleteSelected"].tap()
        waitForCount(toRead: 0, within: 30, describedAs: "deleting the chapter should free it")
        attach("comic-download-deleted")
    }

    // MARK: - Steps

    private func addTheComic() {
        app.tabButton(.library).tap()
        let comicMode = app.buttons["library.mode.comic"]
        XCTAssertTrue(comicMode.waitForExistence(timeout: 10), "The shelf should offer a mode switch")
        comicMode.tap()

        app.buttons["library.add"].tap()
        let field = app.textFields["add.url"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(address)
        app.buttons["add.confirm"].tap()
        XCTAssertTrue(
            field.waitForNonExistence(timeout: 120), "The sheet should close once the comic is added"
        )
    }

    private func openTheDownloadScreen() {
        let bookRow = app.descendants(matching: .any).matching(identifier: "library.book").firstMatch
        XCTAssertTrue(bookRow.waitForExistence(timeout: 60), "The comic should appear on the shelf")
        // Existing is not the same as tappable while the add sheet is still sliding away.
        expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: bookRow)
        waitForExpectations(timeout: 30)
        bookRow.tap()

        // The entry is disabled until the catalog is in, so waiting for it to exist is
        // not enough — a tap on the disabled row goes nowhere and the walk then waits
        // out its timeout on the wrong screen.
        let downloads = app.descendants(matching: .any)["book.downloads"].firstMatch
        XCTAssertTrue(downloads.waitForExistence(timeout: 120), "The book screen should offer downloads")
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: downloads)
        waitForExpectations(timeout: 120)
        app.reveal(downloads)
        downloads.tap()

        XCTAssertTrue(
            summary.waitForExistence(timeout: 30), "The download screen should say what is stored"
        )
    }

    /// Opens the chapter that was just downloaded, and comes back.
    ///
    /// The reader looks on the disk before it looks anywhere else, so this is the stored
    /// pages being drawn — `ComicOfflineReadingTests` is what pins that preference, with
    /// a session that refuses every request and no site rule to fetch with. What is
    /// added here is the rest of the real app around it: file addresses going through
    /// the page store, the column, and the scroll view that draws them.
    private func readTheDownloadedChapter() {
        app.navigationBars.buttons.firstMatch.tap()
        let read = app.descendants(matching: .any).matching(identifier: "book.read").firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 60), "the book screen should offer reading")
        read.tap()

        let page = app.descendants(matching: .any).matching(identifier: "comic.page").firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 60), "the downloaded chapter should lay out")
        app.swipeUp()
        attach("comic-read-from-disk")

        app.tap()
        let back = app.buttons["comic.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), "the control bar should offer a way out")
        back.tap()
        let downloads = app.descendants(matching: .any)["book.downloads"].firstMatch
        XCTAssertTrue(downloads.waitForExistence(timeout: 30))
        app.reveal(downloads)
        downloads.tap()
        XCTAssertTrue(summary.waitForExistence(timeout: 30))
    }

    /// Ticks the first chapter of the catalog.
    ///
    /// The first deliberately: one of these sites sells its later chapters, and a
    /// purchase wall is a chapter with no images in it — a download that fails for a
    /// reason this walk is not about.
    private func tickTheFirstChapter() {
        let row = app.descendants(matching: .any).matching(identifier: "downloads.chapter").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "The catalog should be listed")
        row.tap()
        let count = app.staticTexts["downloads.selectedCount"].firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 5), "A tap should tick the row")
    }

    // MARK: - Reading the screen

    private var summary: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "downloads.summary").firstMatch
    }

    /// How many chapters the screen says are on the device.
    ///
    /// Read as the first number in the row rather than by matching its wording, so the
    /// walk does not depend on which language the simulator came up in. The row reads
    /// "已下載 1 / 355 章" or "1 of 355 chapters downloaded", and both start with the
    /// number this asks for.
    private func downloadedCount() -> Int? {
        guard summary.exists else { return nil }
        let digits = summary.label.split(whereSeparator: { !$0.isNumber })
        return digits.first.flatMap { Int($0) }
    }

    private func waitForCount(
        toRead expected: Int, within timeout: TimeInterval, describedAs what: String
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if downloadedCount() == expected { return }
            Thread.sleep(forTimeInterval: 1)
        }
        attach("comic-download-stalled")
        XCTFail("\(what); the screen reads \(summary.exists ? summary.label : "nothing")")
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
