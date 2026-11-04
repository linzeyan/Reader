import XCTest

/// The shelf's novel and comic sides keep their own place: scrolled down the novels, a
/// trip to the comics and back lands on the same novel, while the comics, not yet
/// scrolled, open at their top. A relaunch forgets both.
///
/// They used to share one list, so each side opened at whatever depth the other had been
/// left at — someone who had scrolled down their novels found the comic shelf already
/// half way down, with its first books out of sight.
///
/// The demo seed holds a handful of books per side, which fits on one screen; the largest
/// accessibility text size makes each row tall enough for the shelf to scroll.
final class ShelfModeScrollTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-NovelReaderDemoSeed", "-library.home", "library", "-library.defaultMediaMode", "novel",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
    }

    @MainActor
    func testEachShelfKeepsItsOwnPlaceUntilTheAppRestarts() throws {
        app.launch()
        app.openLibraryTab()
        let novelsAtTop = try XCTUnwrap(topRow(), "the novel shelf should list the seeded books")

        // Slowly and with a hold at the end, so no fling carries it past where it was let go.
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.5)
        let left = try XCTUnwrap(topRow())
        XCTAssertNotEqual(left.label, novelsAtTop.label, "the drag should have moved the novels")
        attach("novels-left")

        app.buttons["library.mode.comic"].tap()
        let comics = try XCTUnwrap(topRow(), "the comic shelf should list the seeded comics")
        attach("comics")
        XCTAssertEqual(
            comics.label, firstRowLabel(),
            "a shelf not visited yet opens at its top, not at the depth the other one was left"
        )

        app.buttons["library.mode.novel"].tap()
        let back = try XCTUnwrap(topRow())
        attach("novels-back")
        XCTAssertEqual(back.label, left.label, "the novels should be where they were left")
        XCTAssertEqual(back.minY, left.minY, accuracy: 2, "…to the point, not just the same book")

        app.terminate()
        app.launch()
        app.openLibraryTab()
        let relaunched = try XCTUnwrap(topRow())
        XCTAssertEqual(relaunched.label, novelsAtTop.label, "a relaunch opens the shelf at its top")
    }

    // MARK: - Reading the shelf

    private struct Row {
        let label: String
        let minY: CGFloat
    }

    /// The topmost book wholly below the navigation bar, read from one snapshot so a list
    /// still settling cannot change between counting the rows and reading one.
    private func topRow() -> Row? {
        let book = app.descendants(matching: .any).matching(identifier: "library.book").firstMatch
        guard book.waitForExistence(timeout: 10) else { return nil }
        // Let a restore or a deceleration land before reading positions off it.
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        guard let window = try? app.windows.firstMatch.snapshot() else { return nil }
        let barBottom = app.navigationBars.firstMatch.frame.maxY
        return rows(in: window)
            .filter { $0.frame.minY >= barBottom - 0.5 && $0.frame.minY < window.frame.maxY }
            .min { $0.frame.minY < $1.frame.minY }
            .map { Row(label: $0.label, minY: $0.frame.minY) }
    }

    /// The first book in the shelf's own order, which a list at its top shows first.
    private func firstRowLabel() -> String? {
        guard let window = try? app.windows.firstMatch.snapshot() else { return nil }
        return rows(in: window).min { $0.frame.minY < $1.frame.minY }?.label
    }

    private func rows(in root: XCUIElementSnapshot) -> [XCUIElementSnapshot] {
        var found: [XCUIElementSnapshot] = []
        var pending = [root]
        while let node = pending.popLast() {
            pending.append(contentsOf: node.children)
            if node.identifier == "library.book" { found.append(node) }
        }
        return found
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
