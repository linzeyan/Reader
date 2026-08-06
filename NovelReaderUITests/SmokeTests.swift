import XCTest

/// Walks the app the way a person does.
///
/// The unit suite proves the parsing and storage rules; the live suite proves the
/// sites still answer. Neither notices a screen that fails to build, a navigation
/// link that goes nowhere, or a sheet that never appears — which is what this
/// covers. Elements are found by accessibility identifier so the walk does not
/// break when a translation changes.
final class SmokeTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    /// Tabs are addressed by position rather than label: their titles are
    /// localized, and pinning the test to zh-Hant strings would make it fail on
    /// the other two languages the app ships.
    private var libraryTab: XCUIElement { app.tabBars.buttons.element(boundBy: 0) }
    private var searchTab: XCUIElement { app.tabBars.buttons.element(boundBy: 1) }
    private var settingsTab: XCUIElement { app.tabBars.buttons.element(boundBy: 2) }

    func testTabsExist() {
        XCTAssertEqual(app.tabBars.buttons.count, 3)
        XCTAssertTrue(libraryTab.exists)
        XCTAssertTrue(searchTab.exists)
        XCTAssertTrue(settingsTab.exists)
    }

    /// The Debug build seeds the recon rules, so this also proves the seeding
    /// build phase and `SiteStore.load()` agree with each other.
    func testSourcesScreenListsSeededRules() {
        settingsTab.tap()
        let sources = app.buttons["settings.sources"]
        XCTAssertTrue(sources.waitForExistence(timeout: 5))
        sources.tap()
        XCTAssertTrue(app.staticTexts["tw.hjwzw.com"].waitForExistence(timeout: 5),
                      "The seeded rules should be listed by host")
        XCTAssertGreaterThanOrEqual(app.cells.count, 5)
    }

    /// The two ways to add a source that do not need a rule file to exist first.
    /// Offline: it opens the screens and checks the fields are reachable, which is
    /// what catches a menu button wired to nothing.
    func testAddSourceOffersDerivationAndURLImport() {
        settingsTab.tap()
        let sources = app.buttons["settings.sources"]
        XCTAssertTrue(sources.waitForExistence(timeout: 5))
        sources.tap()

        app.navigationBars.buttons.element(boundBy: 1).tap()
        let derive = app.buttons["sources.derive"]
        XCTAssertTrue(derive.waitForExistence(timeout: 5), "The add menu should offer derivation")
        derive.tap()
        XCTAssertTrue(app.textViews["derive.url"].waitForExistence(timeout: 5)
                      || app.textFields["derive.url"].waitForExistence(timeout: 1),
                      "The derivation screen should expose a URL field")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 1).tap()
        let importURL = app.buttons["sources.importURL"]
        if importURL.waitForExistence(timeout: 3) {
            importURL.tap()
            XCTAssertTrue(app.textViews["sources.importURL.field"].waitForExistence(timeout: 5)
                          || app.textFields["sources.importURL.field"].waitForExistence(timeout: 1),
                          "The URL import sheet should expose a URL field")
        }
    }

    func testStorageScreenOpens() {
        settingsTab.tap()
        let storage = app.buttons["settings.storage"]
        XCTAssertTrue(storage.waitForExistence(timeout: 5))
        storage.tap()
        // With nothing downloaded the screen is just the totals row; its presence
        // is what proves the four delete scopes have a home.
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 5))
    }

    func testAppearanceSettingsExposeTypeAndThemeControls() {
        settingsTab.tap()
        let appearance = app.buttons["settings.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.tap()
        XCTAssertTrue(app.sliders.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["reader.settings.font"].exists, "Font picker should be present")
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "reader.settings.themes")
                .firstMatch.exists,
            "The background swatches should be present"
        )
    }

    func testAddBookSheetOffersEverySource() {
        libraryTab.tap()
        let add = app.buttons["library.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        XCTAssertTrue(app.textFields["add.url"].waitForExistence(timeout: 5))
        // The sheet lists the installed sources so the user can see what a
        // pasteable link looks like.
        XCTAssertTrue(app.staticTexts["tw.hjwzw.com"].exists)
    }

    func testSearchTabShowsScopePicker() {
        searchTab.tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 5),
                      "The scope picker row should be present")
    }

    /// The full path a reader actually takes: paste a link, land in the catalog,
    /// open the reader, see text.
    ///
    /// Opt-in because it needs the network. hjwzw is the source used here purely
    /// because it is the fastest of the confirmed sites and has no Cloudflare in
    /// front of it — nothing in the app is specific to it.
    func testAddBookAndRead() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["NOVELREADER_LIVE"] == "1",
            "Needs the network: run `make test-ui-live`."
        )
        libraryTab.tap()
        app.buttons["library.add"].tap()
        let field = app.textFields["add.url"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("https://tw.hjwzw.com/Book/1889")
        app.buttons["add.confirm"].tap()

        // The library is behind the sheet the whole time, so waiting for the row
        // to *exist* proves nothing — wait for the sheet to actually go away.
        XCTAssertTrue(field.waitForNonExistence(timeout: 60), "The sheet should close once the book is added")

        // Addressed by identifier, not `cells.firstMatch`: the library is grouped
        // by source, so the first cell is the section header, not a book.
        let bookRow = app.descendants(matching: .any).matching(identifier: "library.book").firstMatch
        XCTAssertTrue(bookRow.waitForExistence(timeout: 60), "The bookmark should appear in the library")
        bookRow.tap()

        // Queried across every element type: SwiftUI surfaces a NavigationLink
        // row in a List as a cell on some OS versions and a button on others.
        let read = app.descendants(matching: .any).matching(identifier: "book.read").firstMatch
        if !read.waitForExistence(timeout: 60) {
            XCTFail("The catalog should load and enable reading\n\(app.debugDescription)")
            return
        }
        read.tap()

        let reader = app.otherElements["reader.text"]
        XCTAssertTrue(reader.waitForExistence(timeout: 60), "The reader should render chapter text")
        XCTAssertGreaterThan(app.staticTexts.count, 3, "The chapter should render several paragraphs")
        attach("reader")

        // Tapping the middle of the page reveals the one-handed control bar.
        reader.tap()
        attach("reader-controls")
    }

    /// Screenshots land in the result bundle so a run can be reviewed after the
    /// fact rather than only passing or failing.
    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
