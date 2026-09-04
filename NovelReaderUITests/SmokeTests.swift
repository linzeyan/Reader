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
        // The renderer this walk asserts about, stated rather than inherited. The
        // reading mode is a persisted setting, so whatever ran last in this
        // simulator would otherwise decide which reader these tests get — and
        // `reader.text` is published by the scrolling one alone.
        app.launchArguments = ["-reader.mode", "scroll"]
        app.launch()
    }

    /// Tabs are addressed by position rather than label: their titles are
    /// localized, and pinning the test to zh-Hant strings would make it fail on
    /// the other two languages the app ships. `AppTab` is where that position
    /// lives, so the walks that navigate and the walk that counts the tabs cannot
    /// end up with different ideas of the order.
    private var recentTab: XCUIElement { app.tabButton(.recent) }
    private var libraryTab: XCUIElement { app.tabButton(.library) }
    private var searchTab: XCUIElement { app.tabButton(.search) }
    private var settingsTab: XCUIElement { app.tabButton(.settings) }

    func testTabsExist() {
        XCTAssertEqual(app.tabBars.buttons.count, 4)
        XCTAssertTrue(recentTab.exists)
        XCTAssertTrue(libraryTab.exists)
        XCTAssertTrue(searchTab.exists)
        XCTAssertTrue(settingsTab.exists)
    }

    /// The reading history is the app's first screen, and it has to be *arrived at* —
    /// the whole feature is that a reader with a book on the go opens the app onto it
    /// without tapping anything.
    ///
    /// Driven through the demo seed, which wipes and re-seeds the library on every
    /// launch: a UI-test simulator carries whatever the previous case left behind, and
    /// "did the app open here" is exactly the question leftover state would answer
    /// wrongly. One of the seeded books has a reading position part-way into a chapter,
    /// so the history has something unfinished in it by construction.
    func testALaunchWithSomethingUnfinishedOpensOnTheReadingHistory() {
        app.terminate()
        app.launchArguments = ["-NovelReaderDemoSeed", "-reader.mode", "scroll"]
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "recent.book")
                .firstMatch.waitForExistence(timeout: 20),
            "A half-read book should put the launch on the reading history"
        )
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
        app.reveal(storage)
        XCTAssertTrue(storage.waitForExistence(timeout: 5))
        storage.tap()
        // With nothing downloaded the screen is just the totals row; its presence
        // is what proves the four delete scopes have a home.
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 5))
    }

    /// The cache is its own screen beside the downloads, not a detail inside them: the
    /// two are different promises about the same disk. This also covers the settings
    /// list's shape — the link is in a section that has to exist for it to be reachable.
    func testCacheScreenOpens() {
        settingsTab.tap()
        let cache = app.buttons["settings.cache"]
        app.reveal(cache)
        XCTAssertTrue(cache.waitForExistence(timeout: 5))
        cache.tap()
        XCTAssertTrue(
            app.buttons["storage.clearCache"].waitForExistence(timeout: 5),
            "The cache screen should say which caches its button clears"
        )
        XCTAssertTrue(
            app.sliders["cache.limit"].exists,
            "The ceiling is set with a slider, not a list of sizes"
        )
    }

    /// The one screen through which a reader's marks and saved positions can leave this
    /// device at all: iCloud sync deliberately carries neither. Both directions have to be
    /// on it — an export nobody can restore is not a backup — and it has to be reachable
    /// from a settings list that has grown a section since it was put there.
    func testBackupScreenOffersBothDirections() {
        settingsTab.tap()
        let backup = app.buttons["settings.backup"]
        app.reveal(backup)
        XCTAssertTrue(backup.waitForExistence(timeout: 5))
        backup.tap()
        XCTAssertTrue(app.buttons["backup.export"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["backup.restore"].exists)
    }

    func testAppearanceSettingsExposeTypeAndThemeControls() {
        settingsTab.tap()
        let appearance = app.buttons["settings.appearance"]
        // Several sections down, and a `List` does not realise rows below the fold —
        // see `XCUIApplication.reveal`. Waiting would time out on a row that is not on
        // its way, which is what adding a section above it did.
        app.reveal(appearance)
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
