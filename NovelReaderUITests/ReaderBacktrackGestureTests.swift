import XCTest

/// Two claims about the scrolling reader that only a running app can settle: that the
/// text does not move on its own while nobody is touching it, and that scrolling up
/// from a chapter opened mid-book reaches the chapter before it.
///
/// Both are the report that produced the viewport rework. Rows a lazy stack has not
/// built are positioned from estimates, and every correction of an estimate above the
/// viewport slides the text under the reader — at its worst that drift walked the book
/// backwards a chapter every two seconds, re-triggering the previous-chapter prefetch
/// as it went. Nothing offline can see any of it: the position model and the anchors
/// are all unaffected. Only the frame of a paragraph on screen knows.
///
/// Offline throughout: the fictional demo library, so no site rule and no network.
final class ReaderBacktrackGestureTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // The renderer comes from the launch arguments, never from tapping the setting:
        // tapping would persist the choice into this simulator and decide which renderer
        // every later test gets. See `ScrollHighlightGestureTests`.
        app.launchArguments = ["-NovelReaderDemoSeed", "-reader.mode", "scroll"]
        app.launch()
    }

    private func openReader() {
        // The app opens on the reading history, which the demo seed always leaves
        // something unfinished in. This walk starts from the shelf, so it asks for it.
        app.openLibraryTab()
        let book = app.descendants(matching: .any).matching(identifier: "library.book").firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20), "the demo library should be seeded")
        book.tap()
        let read = app.descendants(matching: .any).matching(identifier: "book.read").firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 20))
        read.tap()
        XCTAssertTrue(
            app.otherElements["reader.text"].waitForExistence(timeout: 20),
            "the scrolling renderer should be showing"
        )
    }

    func testTheTextStaysPutWithNobodyTouchingIt() throws {
        openReader()

        // Let the landing finish first: opening at a stored position converges over a
        // few layout passes, and sampling during them would measure the jump itself.
        Thread.sleep(forTimeInterval: 1.5)

        // A paragraph wholly inside the window, and clear of both ends of it — the
        // same pick `ReaderChromeGestureTests` makes, for the same reasons.
        let paragraphs = app.descendants(matching: .any).matching(identifier: "reader.paragraph")
        XCTAssertTrue(paragraphs.firstMatch.waitForExistence(timeout: 20))
        let reachable = app.windows.firstMatch.frame.insetBy(dx: 0, dy: 120)
        let paragraph = try XCTUnwrap(
            (0..<paragraphs.count)
                .map { paragraphs.element(boundBy: $0) }
                .first { reachable.contains($0.frame) },
            "the reader should have a paragraph fully on screen to watch"
        )
        let before = paragraph.frame

        // Nobody touches the app. Any movement now is the reader moving itself.
        Thread.sleep(forTimeInterval: 3)

        XCTAssertEqual(
            paragraph.frame.minY, before.minY, accuracy: 0.5,
            "the text must not move on its own while nobody is touching it"
        )
    }

    func testScrollingUpReachesThePreviousChapter() {
        openReader()

        // The demo book opens part-way into 第4章, so the chapter before it is above
        // the window — and, until the prefetch pulls it in, not loaded at all. Its
        // heading appearing is the whole claim: the top of an opened chapter used to
        // be a wall.
        let previousChapter = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "第3章")
        ).firstMatch

        // Bounded rather than while-not-found: a reader that cannot get there should
        // fail here, not hang the suite.
        for _ in 0..<12 {
            if previousChapter.exists && previousChapter.isHittable { break }
            app.otherElements["reader.text"].swipeDown()
        }

        XCTAssertTrue(
            previousChapter.exists && previousChapter.isHittable,
            "scrolling up must reach the previous chapter rather than hitting a wall"
        )
    }
}
