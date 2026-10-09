import XCTest

/// Queues several real books from their own screens, and watches the queue work through
/// them by itself: one book at a time, the next starting when the one before it is done,
/// and a book the reader holds stepped over rather than holding everything up.
///
/// Every rule under this is pinned without a network in `DownloadManagerTests`. What
/// those cannot see is the walk a person takes — four screens, two shelves, novels and
/// comics from different sites interleaved — and whether the queue screen tells the
/// truth about it while it happens.
///
/// Live, against the reader's own library, so it is opt-in by naming the books:
/// `TEST_RUNNER_QUEUE_BOOKS="comic:書名|novel:書名|…"` on the xcodebuild command line.
/// Books nobody has started, so the chapters it downloads take nothing away.
final class DownloadQueueWalkTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    /// Launches onto the shelf `kind` lives on.
    ///
    /// A launch per book rather than the shelf's mode switch: on the XR a synthesized tap
    /// that high on the screen was taken for a pull-down from the top edge, and the walk
    /// spent itself opening the system's overlay. Relaunching under a running queue also
    /// makes every book after the first a check that the queue survives the process.
    ///
    /// One flat list, so a book is found by its name whatever the reader folded; and the
    /// trace on, so the queue's own account of the run can be read off the phone.
    private func launch(onto kind: String) {
        app.terminate()
        app.launchArguments = [
            "-library.home", "library", "-library.grouping", "none", "-trace.isOn", "YES",
            "-library.defaultMediaMode", kind,
        ]
        app.launch()
    }

    func testTheQueueWorksThroughBooksInOrder() throws {
        let books = try queuedBooks()
        for book in books {
            queue(book)
        }

        openQueue()
        attach("queue-full")

        holdTheFirstBookAndLetItGo()

        // Comic chapters are tens of images each, at the queue's polite pace.
        let rows = app.descendants(matching: .any).matching(identifier: "downloads.job")
        let deadline = Date().addingTimeInterval(1500)
        var lastShot = Date()
        while rows.count > 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 5)
            if Date().timeIntervalSince(lastShot) > 60 {
                attach("queue-\(rows.count)-left")
                lastShot = Date()
            }
        }
        attach("queue-end")
        XCTAssertEqual(rows.count, 0, "every queued book should have come down by itself")
    }

    /// Focus download, on a phone: the black comes down after the countdown, a tap brings
    /// the queue back and counts down again, leaving the screen ends it, and the queue
    /// coming to rest ends it with a word about how. Brightness cannot be seen from here;
    /// the trace's `focus dark` and `focus light` lines say what it was set to.
    ///
    /// Needs a queue that runs for well over half a minute: two chapters of two comics.
    func testFocusDownloadDarkensAndEndsWithTheQueue() throws {
        let books = try queuedBooks()
        for book in books {
            queue(book)
        }
        openQueue()

        let rows = app.descendants(matching: .any).matching(identifier: "downloads.job")
        let focus = app.buttons["downloads.focus"]
        let stop = app.buttons["downloads.focus.stop"]
        let dark = app.descendants(matching: .any)["downloads.focus.dark"].firstMatch

        // Every book held during the countdown: nothing is left to keep the screen for.
        XCTAssertTrue(focus.waitForExistence(timeout: 30), "focus is offered over a running queue")
        focus.tap()
        XCTAssertTrue(stop.waitForExistence(timeout: 3), "the countdown should show")
        for i in 0..<rows.count {
            rows.element(boundBy: i).buttons.element(boundBy: 0).tap()
        }
        let stopped = app.descendants(matching: .any)["downloads.focus.stopped"].firstMatch
        XCTAssertTrue(stopped.waitForExistence(timeout: 60), "a queue with every book held ends focus")
        XCTAssertFalse(stop.exists)
        XCTAssertFalse(dark.exists)
        attach("focus-stopped")

        for i in 0..<rows.count {
            rows.element(boundBy: i).buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(focus.waitForExistence(timeout: 30))
        XCTAssertFalse(stopped.exists, "the queue going again takes the message away")

        // Leaving the screen ends it. The tab bar rather than the back button: on the XR
        // a tap that high is taken for a pull-down from the top edge.
        focus.tap()
        XCTAssertTrue(stop.waitForExistence(timeout: 3))
        app.openTab(.library)
        app.openTab(.settings)
        XCTAssertTrue(focus.waitForExistence(timeout: 10), "leaving the queue screen should end focus")
        XCTAssertFalse(stop.exists)

        focus.tap()
        XCTAssertTrue(dark.waitForExistence(timeout: 20), "the screen should go dark after the countdown")
        Thread.sleep(forTimeInterval: 3)
        attach("focus-dark")
        dark.tap()
        XCTAssertTrue(stop.waitForExistence(timeout: 3), "a tap should bring the queue back")
        XCTAssertFalse(dark.exists)
        attach("focus-woken")
        XCTAssertTrue(dark.waitForExistence(timeout: 20), "…and count down to dark again")

        // Waited on by the word the end leaves, not by the black lifting: a tap on the
        // phone lifts it too, and on the last run one did, with three books still going.
        let finished = app.descendants(matching: .any)["downloads.focus.finished"].firstMatch
        XCTAssertTrue(finished.waitForExistence(timeout: 1500), "focus should end with the queue, and say so")
        XCTAssertFalse(dark.exists, "the black lifts when the queue is done")
        XCTAssertFalse(stop.exists, "and focus is over, not counting down again")
        XCTAssertEqual(rows.count, 0)
        attach("focus-finished")
    }

    // MARK: - Steps

    private struct QueuedBook {
        let kind: String
        let title: String
        /// How many rows from the top to tick. Rows already on the device are ticked and
        /// then skipped by the queue, so a book walked before is named with more.
        let rows: Int
    }

    private func queuedBooks() throws -> [QueuedBook] {
        let spec = ProcessInfo.processInfo.environment["QUEUE_BOOKS"] ?? ""
        try XCTSkipIf(spec.isEmpty, "Names real books: set TEST_RUNNER_QUEUE_BOOKS.")
        // `kind:title`, or `kind:title:rows`.
        return spec.split(separator: "|").map {
            let parts = $0.split(separator: ":", maxSplits: 2).map(String.init)
            let rows = parts.count > 2 ? Int(parts[2]) ?? 0 : (parts[0] == "comic" ? 2 : 3)
            return QueuedBook(kind: parts[0], title: parts[1], rows: rows)
        }
    }

    /// From the shelf to the download screen and back, ticking the first few chapters.
    private func queue(_ book: QueuedBook) {
        launch(onto: book.kind)
        app.openLibraryTab()

        let row = app.descendants(matching: .any).matching(identifier: "library.book")
            .containing(.staticText, identifier: book.title).firstMatch
        app.reveal(row)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "\(book.title) should be on the shelf")
        row.tap()

        let downloads = app.descendants(matching: .any)["book.downloads"].firstMatch
        XCTAssertTrue(downloads.waitForExistence(timeout: 120), "\(book.title) should offer downloads")
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: downloads)
        waitForExpectations(timeout: 120)
        app.reveal(downloads)
        downloads.tap()

        // The titles alone: a downloaded row's mark carries the same identifier, and
        // counting it as a row ticked that chapter and then unticked it again.
        let chapters = app.staticTexts.matching(identifier: "downloads.chapter")
        XCTAssertTrue(chapters.firstMatch.waitForExistence(timeout: 30), "the catalog should be listed")
        for index in 0..<book.rows {
            chapters.element(boundBy: index).tap()
        }
        app.buttons["downloads.downloadSelected"].tap()
        // The bar the selection gave way to: the tap has to have queued something.
        let bar = app.descendants(matching: .any)["downloads.queue"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "\(book.title) should show as queued")
        attach("queued-\(book.title)")
    }

    private func openQueue() {
        app.openTab(.settings)
        let link = app.descendants(matching: .any)["settings.downloadQueue"].firstMatch
        app.reveal(link)
        link.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 10))
    }

    /// Holds the book at the head of the queue, sees the queue go on without it, and
    /// lets it go again.
    private func holdTheFirstBookAndLetItGo() {
        let first = app.descendants(matching: .any).matching(identifier: "downloads.job").firstMatch
        guard first.waitForExistence(timeout: 5) else { return }
        let pause = first.buttons.element(boundBy: 0)
        pause.tap()
        Thread.sleep(forTimeInterval: 3)
        attach("queue-first-held")
        first.buttons.element(boundBy: 0).tap()
        Thread.sleep(forTimeInterval: 2)
        attach("queue-first-let-go")
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
