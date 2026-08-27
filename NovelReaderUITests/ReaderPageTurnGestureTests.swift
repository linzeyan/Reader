import XCTest

/// One claim about the scrolling reader that only a running app can settle: a page turned
/// by tapping stays where it landed.
///
/// The report is that it sometimes does not. The page turns, and a moment later the text
/// slides forward on its own by a fraction of a screen with nobody touching the glass —
/// seemingly near a chapter seam, where the reader pulls the next chapter in. Nothing
/// offline can see it: the anchor, the share and the stored position are all in agreement
/// throughout. Only the frame of a paragraph on screen knows.
///
/// Offline throughout: the fictional demo library, so no site rule and no network.
final class ReaderPageTurnGestureTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // The renderer and the tap-to-turn setting both come from launch arguments rather
        // than from tapping them in Settings: tapping would persist the choice into this
        // simulator and decide what every later test gets. See `ScrollHighlightGestureTests`.
        // `1` rather than `YES`: the argument domain hands `YES` over as a string, and the
        // setting is read as `object(forKey:) as? Bool`, which a string fails. A launch
        // argument that quietly does nothing would leave this walk tapping the chrome and
        // reporting green — see the guard the first turn makes.
        app.launchArguments = [
            "-NovelReaderDemoSeed", "-reader.mode", "scroll", "-reader.tapToTurnPage", "1",
        ]
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

    /// Turns eight pages by tapping, and after each one watches the text.
    ///
    /// The watch begins only once the turn has settled. A turn in flight is the reader
    /// doing exactly what it was told, and sampling during it would measure the page turn
    /// rather than the bug; what is being claimed here is about the quiet afterwards.
    ///
    /// Eight turns rather than one because a demo chapter is twenty-nine paragraphs, so a
    /// seam falls every third or fourth page — and *which* turn drifts is the evidence
    /// that says whether the seam is the cause. For the same reason the loop runs to the
    /// end and reports one timeline: a run that stopped at the first bad turn would answer
    /// "it drifts" and leave the question that matters unasked.
    func testATappedPageStaysWhereItLanded() throws {
        openReader()

        // Let the opening landing finish first: opening at a stored position converges
        // over a few layout passes, and the first tap must not land in the middle of them.
        Thread.sleep(forTimeInterval: 1.5)

        // Far enough to leave the downloaded chapters behind. The demo book opens in its
        // fourth chapter and only its first twelve are on disk, so the first seam a page
        // turn has to wait at — the one where the next chapter is not already in hand — is
        // eight chapters and something over twenty pages away. A walk that stopped short
        // of it would only ever measure the case that already works.
        let turns = 32
        var samples: [(turn: Int, label: String, settled: CGFloat, later: CGFloat)] = []
        // What the top of the window showed before any tap. If tap-to-turn is not actually
        // on, every tap in this loop toggles the control bar instead of turning a page and
        // the whole walk passes without once exercising what it claims to test.
        let beforeAnyTurn = app.topParagraphLabel()

        for turn in 1...turns {
            // Half way across and most of the way down is inside the forward zone and
            // clear of the middle cell, which toggles the chrome instead of turning.
            app.otherElements["reader.text"]
                .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
                .tap()

            // The turn's own animation is 0.2s; the rest is the layout pass behind it.
            Thread.sleep(forTimeInterval: 0.8)

            if turn == 1 {
                XCTAssertNotEqual(
                    app.topParagraphLabel(), beforeAnyTurn,
                    "the first tap must turn a page — tap-to-turn is not on for this launch"
                )
            }

            let paragraphs = app.descendants(matching: .any).matching(identifier: "reader.paragraph")
            XCTAssertTrue(paragraphs.firstMatch.waitForExistence(timeout: 20))
            // Clear of both ends of the window, so that a row part-way out of frame is
            // never the one being watched — the same pick `ReaderChromeGestureTests` makes.
            let reachable = app.windows.firstMatch.frame.insetBy(dx: 0, dy: 120)
            guard let watched = (0..<paragraphs.count)
                .map({ paragraphs.element(boundBy: $0) })
                .first(where: { reachable.contains($0.frame) })
            else { continue }
            let label = watched.label
            let settled = watched.frame.minY

            // Nobody touches the app. Any movement now is the reader moving itself.
            Thread.sleep(forTimeInterval: 1.2)

            // Found again rather than held: the reader builds its accessibility elements
            // from what is on screen, so the index a paragraph answered to before the
            // wait is not the paragraph it answers to after one.
            let again = app.descendants(matching: .any)
                .matching(identifier: "reader.paragraph")
                .matching(NSPredicate(format: "label == %@", label))
            // Every demo chapter carries the same twenty-nine paragraphs, so a label names
            // a row only together with a position: the identical paragraph exists again a
            // chapter further on. Nearest to where it was cannot pick that one — duplicates
            // are several screens apart and the drift being measured is a fraction of one —
            // while `firstMatch` could, and would report a fabricated number.
            guard let nearest = (0..<again.count)
                .map({ again.element(boundBy: $0) })
                .min(by: { abs($0.frame.minY - settled) < abs($1.frame.minY - settled) })
            else { continue }

            samples.append((turn: turn, label: label, settled: settled, later: nearest.frame.minY))
        }

        let drifted = samples.filter { abs($0.settled - $0.later) > 0.5 }
        let timeline = samples
            .map { "turn \($0.turn) \"\($0.label.prefix(24))\" settled=\($0.settled) later=\($0.later)" }
            .joined(separator: "\n")
        XCTAssertTrue(
            drifted.isEmpty,
            """
            \(drifted.count) of \(samples.count) turns drifted \
            (\(turns - samples.count) turns had no paragraph to watch):
            \(timeline)
            """
        )
    }
}
