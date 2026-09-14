import XCTest

/// Folding a shelf up, at both of the levels that have a heading.
///
/// A walk rather than a unit test because there is nothing here the model can answer:
/// `LibraryShelf` decides what the sections *are*, and the whole of this feature is
/// whether tapping one of their headings puts the books away and brings them back. The
/// SDK's own `Section(_:isExpanded:)` is not what does it either — measured to draw no
/// triangle and take no tap under `.insetGrouped`, which is the sort of thing only a
/// running app says.
final class ShelfFoldingTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    /// The arrangement comes in through a launch argument rather than the menu: the
    /// menu's rows are localized and reachable only by position, and `LibrarySettings`
    /// reads this key as a string out of the argument domain the same way the reader's
    /// settings read theirs. See `ReaderPageTurnGestureTests`.
    private func launch(grouping: String) {
        app = XCUIApplication()
        app.launchArguments = [
            "-NovelReaderDemoSeed", "-library.home", "library", "-library.grouping", grouping
        ]
        app.launch()
        XCTAssertTrue(books.firstMatch.waitForExistence(timeout: 20), "the demo library should be seeded")
    }

    private var books: XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "library.book")
    }

    private var firstSectionHeader: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "library.section").firstMatch
    }

    func testASourceFoldsItsBooksAwayAndGivesThemBack() {
        launch(grouping: "source")
        let all = books.count
        XCTAssertGreaterThan(all, 0)

        firstSectionHeader.tap()
        XCTAssertLessThan(books.count, all, "the books under a folded heading should be gone")

        firstSectionHeader.tap()
        XCTAssertEqual(books.count, all, "and every one of them should come back")
    }

    /// The heading has to keep saying what it is holding while it is shut — a fold with
    /// nothing behind it to look at is one nobody opens twice.
    func testAFoldedHeadingStillCountsWhatIsUnderIt() {
        launch(grouping: "source")
        let label = firstSectionHeader.label
        firstSectionHeader.tap()
        XCTAssertEqual(firstSectionHeader.label, label, "the count belongs to the heading, open or shut")
        XCTAssertTrue(
            label.contains(where: \.isNumber),
            "and the heading should carry one: \(label)"
        )
    }

    /// The second level, which is a `DisclosureGroup` rather than a section heading —
    /// different control, same promise.
    func testAnAuthorCohortFoldsUpInsideItsSource() {
        launch(grouping: "sourceThenAuthor")
        let author = app.descendants(matching: .any).matching(identifier: "library.author").firstMatch
        XCTAssertTrue(author.waitForExistence(timeout: 10), "the demo shelf should hold one cohort")

        let all = books.count
        author.tap()
        XCTAssertLessThan(books.count, all, "the cohort's books should go behind the triangle")

        author.tap()
        XCTAssertEqual(books.count, all)
    }

    /// What was folded is a choice, not a scroll position: it is stored beside the sort
    /// and the filter, and leaving the shelf must not quietly undo it.
    func testAFoldOutlivesLeavingTheShelf() {
        launch(grouping: "source")
        let all = books.count
        firstSectionHeader.tap()
        let folded = books.count

        app.openTab(.settings)
        app.openLibraryTab()

        XCTAssertTrue(firstSectionHeader.waitForExistence(timeout: 10))
        XCTAssertEqual(books.count, folded, "the shelf should come back the way it was left")
        XCTAssertLessThan(folded, all)
    }
}
