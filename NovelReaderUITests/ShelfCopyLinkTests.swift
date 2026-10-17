import XCTest

/// Copying a book's address off its shelf row, with a swipe to the right.
///
/// A walk because the whole feature is a gesture and where its button sits: the address
/// itself comes from `SiteStore.sourceURL`, which the model can answer without a screen.
/// The copy is checked by pasting it into the app's own add sheet rather than by reading
/// the pasteboard from the test runner, which is not frontmost and is refused it on a
/// device — and pasting into an address field is exactly what the copy is for.
final class ShelfCopyLinkTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        // English for the edit menu's Paste, which is the system's word, not ours.
        app.launchArguments = ["-NovelReaderDemoSeed", "-library.home", "library", "-AppleLanguages", "(en)"]
        app.launch()
    }

    func testASwipeRightCopiesTheAddressTheBookCameFrom() {
        let row = app.demoNovelRow()
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the demo library should be seeded")

        row.swipeRight()
        // A swipe long enough to be a full one copies on its own and leaves no button.
        let copy = app.buttons["library.copyLink"]
        if copy.waitForExistence(timeout: 3) { copy.tap() }

        app.buttons["library.add"].tap()
        let field = app.textFields["add.url"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let paste = app.menuItems["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "a focused field's first tap should offer Paste")
        paste.tap()

        let pasted = field.value as? String ?? ""
        XCTAssertTrue(
            pasted.contains("demo.example.com") && pasted.contains("1042"),
            "the pasteboard should hold 星河渡口's own address, not \(pasted)"
        )
    }
}
