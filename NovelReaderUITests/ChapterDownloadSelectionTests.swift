import XCTest

/// The download-management screen's range selection: tick one chapter, long-press
/// another, and everything between them is ticked too.
///
/// Driven through the demo seed, whose chapter titles are deterministic — 第1章 is
/// always 夜渡 — so the walk can name the rows it touches instead of counting
/// cells past the header sections.
///
/// The single-tap assertion is not a warm-up: the long-press gesture is attached
/// to the same rows the list's edit-mode selection owns, and the known failure
/// mode of that combination is the added recognizer delaying or stealing the tap.
/// If ticking one row ever stops working, this is the test that must say so.
final class ChapterDownloadSelectionTests: XCTestCase {
    @MainActor
    func testLongPressSelectsTheRangeFromTheLastTick() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-NovelReaderDemoSeed"]
        app.launch()

        app.openLibraryTab()
        let book = app.staticTexts["山海拾遺"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 10), "the demo library should list the seeded book")
        book.tap()

        let downloads = app.descendants(matching: .any)["book.downloads"].firstMatch
        XCTAssertTrue(downloads.waitForExistence(timeout: 10), "the book screen should offer download management")
        app.reveal(downloads)
        downloads.tap()

        let first = app.staticTexts["第1章　夜渡"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5), "the chapter list should show the demo catalog")
        first.tap()

        let count = app.staticTexts["downloads.selectedCount"].firstMatch
        XCTAssertTrue(
            count.waitForExistence(timeout: 3),
            "a tap must tick the row and bring up the selection bar"
        )
        XCTAssertTrue(count.label.contains("1"), "one tap, one ticked chapter; got: \(count.label)")

        app.staticTexts["第5章　無名的燈"].firstMatch.press(forDuration: 0.9)
        XCTAssertTrue(
            waitForLabel(of: count, containing: "5"),
            "long-pressing chapter five must tick chapters one through five; got: \(count.label)"
        )
    }

    /// Polls for a label change. The selection count updates in place — there is no
    /// appearance or disappearance for `waitForExistence` to watch.
    private func waitForLabel(
        of element: XCUIElement, containing text: String, timeout: TimeInterval = 3
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.label.contains(text) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return element.label.contains(text)
    }
}
