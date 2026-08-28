import XCTest

/// Reads a comic the way a person does: switch the shelf, paste an address, open the
/// book, and scroll through it.
///
/// The one walk that exercises everything the comic reader is made of at once — the
/// mode switch, the batch add sheet, the kind-routed navigation destination, the image
/// list coming out of the web view, the pages coming over `URLSession` with the headers
/// those hosts insist on, and the column correcting its estimates as they land. Every
/// one of those has a unit test or a live extraction test behind it, and not one of
/// those would notice a scroll view that never gets a content size.
///
/// Live, and opt-in for it: the pages are real files from a real CDN. Run with
/// `make test-ui-live`.
final class ComicReadingWalkTests: XCTestCase {
    private var app: XCUIApplication!

    /// manhuagui, on its mobile host because that is what the rule is written against.
    /// Chosen because it is the hardest of the four surveyed sites — its page list lives
    /// only inside a packed script and its CDN refuses a request with no `Referer` — so
    /// a walk that passes here is not passing by accident.
    private let address = "https://m.manhuagui.com/comic/2807/"

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        // Straight to the shelf, and to the comic half of it. Both are settings, so
        // whatever ran last in this simulator would otherwise decide where this lands.
        app.launchArguments = ["-library.home", "library", "-library.defaultMediaMode", "comic"]
        app.launch()
    }

    func testAddAComicAndReadIt() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["NOVELREADER_LIVE"] == "1",
            "Needs the network: run `make test-ui-live`."
        )
        openTheComicShelf()

        app.buttons["library.add"].tap()
        let field = app.textFields["add.url"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(address)
        app.buttons["add.confirm"].tap()

        // The sheet reports its own run now, and closes itself only when every pasted
        // line succeeded — so waiting for it to go is waiting for the add to work.
        XCTAssertTrue(
            field.waitForNonExistence(timeout: 120), "The sheet should close once the comic is added"
        )

        openTheBook()

        // A page view exists as soon as the chapter's *length* is known, before any
        // image has been downloaded — that is what the estimated heights are for, and a
        // reader that cannot be scrolled until the bytes land is the thing they prevent.
        let page = app.descendants(matching: .any).matching(identifier: "comic.page").firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 120), "The chapter should lay its pages out")
        attach("comic-open")

        // Images arriving replace estimates, which moves everything below them. Nothing
        // here asserts a number — the arithmetic is pinned by `ComicChapterColumnTests`
        // — only that the reader can still travel afterwards.
        let pagesBefore = app.descendants(matching: .any).matching(identifier: "comic.page").count
        XCTAssertGreaterThan(pagesBefore, 0)
        app.swipeUp()
        app.swipeUp()
        attach("comic-scrolled")

        zoomIn()
        zoomOut()

        // The middle band is the controls, in both readers — and it stays that way with a
        // double tap on the same band now meaning something else.
        app.tap()
        let capsule = app.descendants(matching: .any).matching(identifier: "comic.chapterTitle").firstMatch
        XCTAssertTrue(
            capsule.waitForExistence(timeout: 10), "Tapping the middle should reveal the chapter capsule"
        )
        attach("comic-controls")

        crossIntoTheNextChapter()
        scrollBackIntoThePreviousChapter()
        let place = settledCapsuleText()
        XCTAssertFalse(place.isEmpty, "The capsule should say which chapter and page this is")

        killAndReopen()
        openTheComicShelf()
        openTheBook()
        XCTAssertTrue(page.waitForExistence(timeout: 120), "The comic should open again")
        app.tap()
        XCTAssertTrue(capsule.waitForExistence(timeout: 10))
        // Waited for rather than read once: the capsule says the book's own name until
        // the chapter's page list has come back, and asking it the instant the reader
        // appears is asking before the answer exists.
        waitForCapsule(toRead: place)
        attach("comic-reopened")
    }

    // MARK: - Steps

    private func openTheComicShelf() {
        app.tabButton(.library).tap()
        // Stated rather than assumed: the launch argument decides the *default*, and a
        // previous walk in this simulator may have left the session on novels.
        let comicMode = app.buttons["library.mode.comic"]
        XCTAssertTrue(comicMode.waitForExistence(timeout: 10), "The shelf should offer a mode switch")
        comicMode.tap()
    }

    private func openTheBook() {
        let bookRow = app.descendants(matching: .any).matching(identifier: "library.book").firstMatch
        XCTAssertTrue(bookRow.waitForExistence(timeout: 60), "The comic should appear on the shelf")
        // Existing is not the same as tappable: the row is drawn behind the sheet while
        // that is still sliding away, and a tap in that window is swallowed.
        expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: bookRow)
        waitForExpectations(timeout: 30)
        bookRow.tap()

        let read = app.descendants(matching: .any).matching(identifier: "book.read").firstMatch
        if !read.waitForExistence(timeout: 120) {
            XCTFail("The catalog should load and enable reading\n\(app.debugDescription)")
            return
        }
        read.tap()
    }

    /// A double tap magnifies the page it landed on.
    ///
    /// Asserted on the page's own frame rather than on a screenshot: the element's width
    /// is reported in screen points, so a page that was the width of the glass being
    /// reported as half again as wide is the magnification itself, not a picture of it.
    private func zoomIn() {
        let before = pageWidth()
        XCTAssertGreaterThan(before, 0)
        app.doubleTap()
        waitForPageWidth(toPass: { $0 > before * 1.5 }, describedAs: "wider after a double tap")
        attach("comic-zoomed")
    }

    private func zoomOut() {
        let wide = pageWidth()
        app.doubleTap()
        waitForPageWidth(toPass: { $0 < wide * 0.75 }, describedAs: "back to the width of the glass")
    }

    private func pageWidth() -> CGFloat {
        app.descendants(matching: .any).matching(identifier: "comic.page").firstMatch.frame.width
    }

    private func waitForPageWidth(
        toPass test: @escaping (CGFloat) -> Bool, describedAs what: String
    ) {
        let predicate = NSPredicate { [weak self] _, _ in
            guard let self else { return false }
            return test(self.pageWidth())
        }
        expectation(for: predicate, evaluatedWith: app, handler: nil)
        waitForExpectations(timeout: 10) { error in
            if error != nil { XCTFail("The page should be \(what)") }
        }
    }

    /// The next chapter, by the control bar's own button.
    ///
    /// The reader also runs into the next chapter by scrolling, and that path is the one
    /// `askForMoreIfNeeded` drives — but it needs a whole chapter of scrolling to reach,
    /// and this asks the same model method with a landing at the top of it.
    private func crossIntoTheNextChapter() {
        let before = capsuleText()
        app.buttons["comic.nextChapter"].tap()
        // Both halves matter. While the next chapter's page list is being fetched the
        // capsule falls back to the book's own name and drops the page count, so "the
        // text changed" alone would be satisfied by the loading state and hand the walk
        // a position that is about to be replaced.
        let arrived = NSPredicate { [weak self] _, _ in
            guard let text = self?.capsuleText() else { return false }
            return text != before && text.contains("/")
        }
        expectation(for: arrived, evaluatedWith: app, handler: nil)
        waitForExpectations(timeout: 120)
        attach("comic-next-chapter")
    }

    /// Scrolls off the top of the chapter, into the one before it.
    ///
    /// The insert-above path, and the reason the reader is a column stack at all: the
    /// previous chapter goes in over the reader's head and the content shifts under them
    /// by exactly its height. Get that arithmetic wrong and the reader is thrown
    /// somewhere else in the book — which is the failure the whole architecture exists to
    /// make impossible, and the only one nothing else here would notice.
    ///
    /// A few swipes rather than one: the first only tells the model to fetch, and the
    /// chapter is held out of the stack until the hand comes off the glass.
    private func scrollBackIntoThePreviousChapter() {
        let before = capsuleText()
        for _ in 0..<8 {
            app.swipeDown()
            let now = capsuleText()
            guard now != before, now.contains("/") else { continue }
            attach("comic-previous-chapter")
            return
        }
        XCTFail(
            "Scrolling up off the top should carry the reader into the previous chapter, "
                + "and the capsule still reads \(capsuleText())"
        )
    }

    /// Backgrounds the app, kills it, and starts it again from nothing.
    ///
    /// The pause matters: the position is written when the scene leaves the foreground,
    /// and terminating the same instant would be killing the app mid-write rather than
    /// testing that what it wrote survives.
    private func killAndReopen() {
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.terminate()
        app.launch()
    }

    // MARK: - Reading the screen

    /// What the chapter capsule says: which chapter, and which page of it. One element,
    /// so one label.
    private func capsuleText() -> String {
        let capsule = app.descendants(matching: .any)
            .matching(identifier: "comic.chapterTitle").firstMatch
        return capsule.exists ? capsule.label : ""
    }

    /// What the capsule says once the scroll has stopped moving under it.
    ///
    /// A swipe carries momentum, so the page the reader is on when the finger leaves the
    /// glass is not the page they come to rest on — and the one that gets written down is
    /// the one they come to rest on. Reading the capsule any earlier is reading a number
    /// that is still changing.
    private func settledCapsuleText() -> String {
        var last = capsuleText()
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.5)
            let now = capsuleText()
            if !now.isEmpty, now == last { return now }
            last = now
        }
        return last
    }

    /// Polled by hand rather than by `XCTNSPredicateExpectation`, for the failure alone:
    /// a predicate that times out says only that it timed out, and what this walk needs
    /// to report is the page it landed on instead.
    private func waitForCapsule(toRead expected: String) {
        let deadline = Date().addingTimeInterval(60)
        var seen = ""
        while Date() < deadline {
            seen = capsuleText()
            if seen == expected { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
        attach("comic-reopened-elsewhere")
        XCTFail("The capsule should read \(expected), and reads \(seen)")
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
