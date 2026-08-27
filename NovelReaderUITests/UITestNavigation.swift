import XCTest

/// The tabs, in the order `RootView` declares them.
enum AppTab: Int {
    case recent, library, search, settings

    /// The SF Symbol the tab item carries. Only used on iPad — see `tabButton`.
    var symbol: String {
        switch self {
        case .recent: return "clock"
        case .library: return "books.vertical"
        case .search: return "magnifyingglass"
        case .settings: return "gearshape"
        }
    }
}

/// Getting to a tab, for the walks that start somewhere other than where the app opens.
///
/// Shared because the app no longer has one landing screen: it opens on the reading
/// history whenever there is something unfinished in it, and every demo-seeded launch
/// has exactly that. A walk that begins at a shelf row therefore has to *ask* for the
/// shelf, and six copies of the asking is six places for it to drift.
extension XCUIApplication {
    /// The button for one tab.
    ///
    /// By position within the tab bar, because that is the one handle that has held:
    /// the titles are localized, and the SF Symbol name the buttons used to answer to
    /// is not published by the tab bar this OS builds — waiting on it simply times out.
    ///
    /// The symbol is still the fallback, and only reachable on iPad, where the tabs are
    /// a row of plain buttons at the top and there is no `tabBars` to index into.
    func tabButton(_ tab: AppTab) -> XCUIElement {
        let inBar = tabBars.buttons.element(boundBy: tab.rawValue)
        return inBar.exists ? inBar : buttons[tab.symbol].firstMatch
    }

    /// Puts one tab on screen, from wherever this launch landed.
    ///
    /// - Parameter timeout: how long to wait for the shell to come up. Generous because
    ///   the first launch of a run is competing with the simulator booting.
    func openTab(_ tab: AppTab, timeout: TimeInterval = 20) {
        // Only a few seconds for the bar itself: on iPad there is no `tabBars` at all
        // and this wait can only ever run out.
        _ = tabBars.firstMatch.waitForExistence(timeout: 5)
        let button = tabButton(tab)
        XCTAssertTrue(button.waitForExistence(timeout: timeout), "the \(tab) tab should exist")
        button.tap()
    }

    func openLibraryTab(timeout: TimeInterval = 20) {
        openTab(.library, timeout: timeout)
    }

    /// The label of the topmost paragraph with any part on screen — enough to tell whether
    /// the text moved at all, which is the one thing a tap that turned nothing looks like.
    ///
    /// Filtered by frame rather than taken as the first match: the paragraph straddling
    /// the top of the window is on screen and comes first in the tree, but its own top is
    /// above the glass, so its frame alone says nothing about what the reader can see.
    func topParagraphLabel() -> String {
        let paragraphs = descendants(matching: .any).matching(identifier: "reader.paragraph")
        let window = windows.firstMatch.frame
        return (0..<paragraphs.count)
            .map { paragraphs.element(boundBy: $0) }
            .filter { $0.frame.maxY > window.minY && $0.frame.minY < window.maxY }
            .min(by: { $0.frame.minY < $1.frame.minY })?
            .label ?? ""
    }

    /// Scrolls until a row is there to be tapped.
    ///
    /// A `List` does not realise rows below the fold, so a row further down Settings is
    /// not merely off screen, it is absent from the accessibility tree.
    /// `waitForExistence` cannot help with that: nothing is on its way. Which rows are
    /// below the fold moves every time a section is added, so a walk that wants one has
    /// to go and get it rather than assume one screen holds everything.
    func reveal(_ element: XCUIElement, swipingUp: Bool = true) {
        for _ in 0..<8 where !element.exists {
            if swipingUp { swipeUp() } else { swipeDown() }
        }
    }
}
