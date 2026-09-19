import Foundation
import XCTest
@testable import NovelReader

/// What the bar at the foot of a book holds, in what order, and whose answer decides.
///
/// An arrangement is stored as what the reader said rather than as the finished bar, and
/// every test here is about a consequence of that: a control this version has never heard
/// of, a control a later version will add, and a bar that has to keep working through both
/// without the reader arranging it again. The one thing that must never happen is a
/// control with no way to reach it.
@MainActor
final class ReaderToolbarTests: XCTestCase {
    // MARK: - What a shelf has

    /// A reader who has never opened the editor reads with the bar as it was designed.
    func testAnArrangementNobodyMadeIsTheOrderTheBarWasDesignedIn() {
        let (bar, folded) = ReaderToolbarLayout.standard.resolve(for: .novel)
        XCTAssertEqual(
            bar,
            [.back, .catalog, .bookmark, .previousChapter, .nextChapter,
             .autoScroll, .speech, .settings]
        )
        XCTAssertTrue(folded.isEmpty, "nothing is folded away until somebody folds it")
    }

    /// A bookmark is a text anchor and there is nothing in a comic to read aloud; only a
    /// subscription has a page its text came from. A shelf is offered what it has.
    func testEachShelfIsOfferedOnlyTheControlsItHas() {
        let comic = ReaderToolbarLayout.standard.resolve(for: .comic).bar
        XCTAssertFalse(comic.contains(.bookmark))
        XCTAssertFalse(comic.contains(.speech))
        XCTAssertFalse(comic.contains(.original))

        XCTAssertFalse(
            ReaderToolbarLayout.standard.resolve(for: .novel).bar.contains(.original),
            "a novel is fully here; there is no page to go back to"
        )
        XCTAssertTrue(ReaderToolbarLayout.standard.resolve(for: .feed).bar.contains(.original))
    }

    // MARK: - Arranging it

    func testFoldingAControlTakesItOffTheBarAndLeavesItReachable() {
        let layout = ReaderToolbarLayout(
            order: ReaderButton.allCases, folded: [.bookmark]
        )
        let (bar, folded) = layout.resolve(for: .novel)
        XCTAssertFalse(bar.contains(.bookmark))
        XCTAssertEqual(folded, [.bookmark], "folded away is not gone")
    }

    /// The order the reader put them in, and the folded ones keep their place in it —
    /// which is the order they are listed in behind the last button.
    func testTheFoldedKeepTheirPlaceInTheOrder() {
        let layout = ReaderToolbarLayout(
            order: [.settings, .speech, .catalog, .bookmark, .autoScroll],
            folded: [.speech, .bookmark]
        )
        let (bar, folded) = layout.resolve(for: .novel)
        XCTAssertEqual(
            bar,
            // `back`, `previousChapter` and `nextChapter` went unmentioned, so each took
            // its designed place: the first at the head, the other two after the bookmark
            // they were designed to follow.
            [.back, .settings, .catalog, .previousChapter, .nextChapter, .autoScroll]
        )
        XCTAssertEqual(
            folded, [.speech, .bookmark],
            "the menu reads down the bar the reader arranged, not the order they hid things"
        )
    }

    // MARK: - Outliving the version it was made in

    /// A control a later version adds goes where it was designed to sit.
    ///
    /// Appending it would put a new chapter button after the settings button — the one
    /// place nobody looks — and the reader would have to arrange their bar again to find
    /// something they never asked to move.
    func testAControlTheArrangementNeverHeardOfTakesItsDesignedPlace() {
        // Says only "settings before catalog" and nothing about the other six.
        let layout = ReaderToolbarLayout(order: [.settings, .catalog])
        XCTAssertEqual(
            layout.resolve(for: .novel).bar,
            [.back, .settings, .catalog, .bookmark, .previousChapter, .nextChapter,
             .autoScroll, .speech],
            "the ones never arranged follow the neighbour they were designed to follow"
        )
    }

    /// A name this version does not know is dropped, and the rest of the arrangement
    /// survives. The alternative is an arrangement that will not decode at all, which is a
    /// reader whose bar silently reverts.
    func testANameThisVersionDoesNotKnowIsDroppedRatherThanBreakingTheArrangement() throws {
        let stored = #"{"order":["settings","semaphore","catalog"],"folded":["semaphore"]}"#
        let layout = try JSONDecoder().decode(
            ReaderToolbarLayout.self, from: Data(stored.utf8)
        )
        let (bar, folded) = layout.resolve(for: .novel)
        XCTAssertEqual(
            bar,
            [.back, .settings, .catalog, .bookmark, .previousChapter, .nextChapter,
             .autoScroll, .speech],
            "what the arrangement did say — settings before catalog — has to survive it"
        )
        XCTAssertTrue(folded.isEmpty, "a control that does not exist cannot be folded away")
    }

    /// An arrangement survives being written down and read back — it is stored in a
    /// backup file, and a bar that comes back different is a setting that did not restore.
    func testAnArrangementSurvivesBeingStored() throws {
        let layout = ReaderToolbarLayout(
            order: [.settings, .catalog, .speech], folded: [.speech]
        )
        let round = try JSONDecoder().decode(
            ReaderToolbarLayout.self, from: JSONEncoder().encode(layout)
        )
        XCTAssertEqual(round, layout)
    }

    // MARK: - Whose arrangement

    /// A shelf's answer beats the general one, and a book's beats its shelf's — the
    /// layering every other reading setting already has.
    func testABookFollowsItsShelfAndAShelfFollowsTheDefaults() {
        let settings = ReaderSettings(defaults: scratchDefaults())
        settings.toolbar = ReaderToolbarLayout(order: ReaderButton.allCases, folded: [.speech])

        XCTAssertEqual(
            settings.resolvedToolbar(forBook: "b1", kind: .novel).folded, [.speech],
            "a book that says nothing reads with what the shelf above it says"
        )

        settings.setOverrides(
            .init(toolbar: ReaderToolbarLayout(order: ReaderButton.allCases, folded: [.bookmark])),
            of: .shelf(.novel)
        )
        XCTAssertEqual(settings.resolvedToolbar(forBook: "b1", kind: .novel).folded, [.bookmark])

        settings.setOverrides(
            .init(toolbar: ReaderToolbarLayout(order: ReaderButton.allCases, folded: [.catalog])),
            of: .book(id: "b1", kind: .novel)
        )
        XCTAssertEqual(settings.resolvedToolbar(forBook: "b1", kind: .novel).folded, [.catalog])
        XCTAssertEqual(
            settings.resolvedToolbar(forBook: "b2", kind: .novel).folded, [.bookmark],
            "one book arranged is one book, not the shelf"
        )
    }

    /// Put back to following, a book must leave no row behind — the rule every other
    /// override obeys, so that the defaults do not collect an entry per book ever opened.
    func testABookPutBackToFollowingLeavesNothingStored() {
        let settings = ReaderSettings(defaults: scratchDefaults())
        let layer = ReaderSettings.Layer.book(id: "b1", kind: .novel)
        settings.setOverrides(
            .init(toolbar: ReaderToolbarLayout(order: ReaderButton.allCases, folded: [.speech])),
            of: layer
        )
        XCTAssertNotNil(settings.overrides(of: layer).toolbar)

        settings.setOverrides(.init(), of: layer)
        XCTAssertNil(settings.overrides(of: layer).toolbar)
        XCTAssertTrue(settings.overridesByBook.isEmpty, "an empty layer is stored as no layer")
    }

    /// The general answers list every control there is, because they are not about any one
    /// shelf: each shelf then takes the subset it has.
    func testTheGeneralAnswersArrangeEveryControlThereIs() {
        XCTAssertEqual(
            ReaderToolbarLayout.standard.arrangement(for: nil), ReaderButton.allCases
        )
    }

    // MARK: - Helpers

    private func scratchDefaults() -> UserDefaults {
        let suite = "ReaderToolbarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return defaults
    }
}
