import UIKit
import XCTest
@testable import NovelReader

/// What a page that moves on its own has to promise.
///
/// Every test here drives `tick(at:)` by hand and never yields, which is also why none of
/// them is `async`: `setSpeed` puts a real `CADisplayLink` on the main run loop, and a
/// test that gave the run loop a chance to spin would have frames arriving between its own
/// assertions.
@MainActor
final class AutoScrollTests: XCTestCase {
    /// Every distance the driver asked for, in order.
    private var asked: [CGFloat] = []
    /// What the surface pretends it managed to move. The default is a surface with room.
    private var surfaceMoves: (CGFloat) -> CGFloat = { $0 }

    private func makeDriver() -> AutoScrollDriver {
        AutoScrollDriver { [weak self] distance in
            guard let self else { return 0 }
            asked.append(distance)
            return surfaceMoves(distance)
        }
    }

    private func metrics(fontSize: Double) -> ReadingMetrics {
        ReadingMetrics(
            fontName: nil, fontSize: fontSize, lineSpacing: 9, paragraphSpacing: 14,
            script: .off
        )
    }

    // MARK: - The unit the speed is stated in

    /// The whole reason the setting is lines a minute and not points a second.
    ///
    /// A reader who sets a comfortable speed and then makes the text bigger has not asked
    /// to read more slowly — but a speed stored as distance would do exactly that, because
    /// the same number of points is fewer lines once the lines are taller. Stored as lines,
    /// the distance moves with the type size and the reading speed stays where they put it.
    func testTheSameSpeedTravelsFurtherAtALargerTypeSize() {
        let pace = ReadingPace(linesPerMinute: 20)
        let small = metrics(fontSize: 14)
        let large = metrics(fontSize: 28)
        let slow = pace.pointsPerSecond(lineHeight: small.lineHeight)
        let fast = pace.pointsPerSecond(lineHeight: large.lineHeight)

        XCTAssertGreaterThan(fast, slow)
        XCTAssertEqual(
            fast / slow, large.lineHeight / small.lineHeight, accuracy: 0.001,
            "the difference has to be the line heights' and nothing the pace invented"
        )
        XCTAssertEqual(slow * 60 / small.lineHeight, 20, accuracy: 0.001)
        XCTAssertEqual(fast * 60 / large.lineHeight, 20, accuracy: 0.001)
    }

    /// One slider, one meaning, in a renderer that has nothing to scroll.
    ///
    /// A page does not travel: it is held and then turned. So the same pace has to be
    /// answerable in seconds as well as in points a second, and the two answers have to be
    /// the same reading speed — otherwise a reader who set a comfortable pace while
    /// scrolling and then switched to pages would have to find it again, with the slider
    /// showing the number they already chose.
    func testAPageIsHeldForAsLongAsScrollingPastItWouldTake() {
        let pace = ReadingPace(linesPerMinute: 24)
        let lineHeight = metrics(fontSize: 19).lineHeight
        let page: CGFloat = 600

        XCTAssertEqual(
            pace.seconds(forTextHeight: page, lineHeight: lineHeight),
            Double(page / pace.pointsPerSecond(lineHeight: lineHeight)),
            accuracy: 0.001
        )
    }

    /// The last page of a chapter is a few lines. Timed as a whole page it would leave the
    /// reader watching nothing happen for most of a minute before the chapter turned.
    func testAPageWithLessTextOnItIsHeldForLess() {
        let pace = ReadingPace.standard
        let lineHeight = metrics(fontSize: 19).lineHeight

        let full = pace.seconds(forTextHeight: 600, lineHeight: lineHeight)
        let short = pace.seconds(forTextHeight: 120, lineHeight: lineHeight)
        XCTAssertEqual(full / short, 5, accuracy: 0.001)
        XCTAssertEqual(
            pace.seconds(forTextHeight: 0, lineHeight: lineHeight), 0,
            "a page with nothing on it is a page to turn now"
        )
    }

    /// A `Slider` clamps a value outside its range and writes the clamp back, so a default
    /// outside the range the panel offers would be silently re-set the first time a reader
    /// opened it — changing a speed they never touched.
    func testTheDefaultPaceIsInsideTheRangeTheSliderOffers() {
        XCTAssertTrue(ReadingPace.range.contains(ReadingPace.standard.linesPerMinute))
    }

    // MARK: - The unit a comic is paced by

    /// Why a comic's speed is screens a minute rather than the novel's lines, or points.
    ///
    /// Magnifying to 2x halves how much of the book the glass holds — `visibleHeight` is
    /// content points — so a speed in points would be twice the reading the moment somebody
    /// pinched, with the same number in the settings meaning something else. Stated in
    /// screens, a screenful goes past in the same time at every magnification.
    func testMagnifyingDoesNotChangeHowFastAComicGoesPast() {
        let pace = ComicPace(screensPerMinute: 3)
        let window: CGFloat = 800

        let unmagnified = window / pace.pointsPerSecond(windowHeight: window)
        let magnified = (window / 2) / pace.pointsPerSecond(windowHeight: window / 2)
        XCTAssertEqual(unmagnified, 20, accuracy: 0.001, "three screens a minute is one every twenty seconds")
        XCTAssertEqual(magnified, unmagnified, accuracy: 0.001)
    }

    /// A `Slider` clamps a value outside its range and writes the clamp back — see the
    /// novel's copy of this, which is the same trap.
    func testTheDefaultComicPaceIsInsideTheRangeTheSliderOffers() {
        XCTAssertTrue(ComicPace.range.contains(ComicPace.standard.screensPerMinute))
    }

    // MARK: - What one frame is worth

    /// A speed whose frame is comfortably worth more than a pixel, so that this measures the
    /// arithmetic rather than which side of the threshold `speed × 1/60` lands on in
    /// floating point — a page moving at a fraction of a pixel a frame is what
    /// `testFractionsOfAPointAddUpInsteadOfRoundingAway` is for.
    func testThePageTravelsWhatTheElapsedTimeBoughtIt() {
        let driver = makeDriver()
        driver.setSpeed(120)

        driver.tick(at: 100)
        XCTAssertTrue(asked.isEmpty, "the first frame has no elapsed time to spend")

        driver.tick(at: 100 + 1.0 / 60)
        XCTAssertEqual(asked.first ?? 0, 2, accuracy: 0.01)
    }

    /// A display link that has not fired for a while reports the whole gap as elapsed —
    /// the app was in the switcher, or the main thread was busy. Honouring it would throw
    /// the reader half a minute down the book in one frame, which is not catching up, it is
    /// losing their place.
    func testAGapBetweenFramesIsNotPaidForAllAtOnce() {
        let driver = makeDriver()
        driver.setSpeed(600)

        driver.tick(at: 0)
        driver.tick(at: 30)

        XCTAssertEqual(asked.first ?? 0, 600.0 / 30, accuracy: 0.001)
    }

    /// The failure this driver's carry exists for, measured on an iPhone SE.
    ///
    /// At a reading pace one frame is worth a fraction of a point, and a scroll view can
    /// only sit on a whole device pixel. Handed over as it was earned, every frame's travel
    /// rounded away: the page stood perfectly still — and because each of those frames also
    /// reported not moving, the driver read a book the reader was in the middle of as one
    /// that had run out, and switched itself off five seconds in.
    func testFractionsOfAPointAddUpInsteadOfRoundingAway() {
        let driver = makeDriver()
        var ended = 0
        var travelled: CGFloat = 0
        driver.onRanAground = { ended += 1 }
        // A surface on a half-point grid, which is what the reader's own is at 2x.
        surfaceMoves = { distance in
            let granted = (distance / 0.5).rounded(.down) * 0.5
            travelled += granted
            return granted
        }

        // Ten points a second is a real reading pace on a small screen: a sixth of a point
        // a frame, and not one of those frames can move anything by itself.
        driver.setSpeed(10)
        var now: CFTimeInterval = 0
        for _ in 0..<600 {
            driver.tick(at: now)
            now += 1.0 / 60
        }

        XCTAssertEqual(travelled, 100, accuracy: 1, "ten seconds at ten points a second")
        XCTAssertEqual(ended, 0, "a page that is moving must not be read as one that cannot")
        XCTAssertTrue(driver.isRunning)
    }

    func testASpeedOfZeroIsOff() {
        let driver = makeDriver()
        driver.setSpeed(0)
        XCTAssertFalse(driver.isRunning)

        driver.tick(at: 0)
        driver.tick(at: 1)
        XCTAssertTrue(asked.isEmpty)
    }

    // MARK: - The reader's own hand

    /// A page being dragged while something else also moves it is a page nobody is
    /// steering. The second half matters as much as the first: the hold is not time the
    /// reader owes the driver, so letting go must not deliver it in one step.
    func testAFingerTakesThePageAndLettingGoDoesNotPayForTheHold() {
        let driver = makeDriver()
        driver.setSpeed(60)
        driver.tick(at: 10)

        driver.hold(true)
        driver.tick(at: 11)
        XCTAssertTrue(asked.isEmpty)

        driver.hold(false)
        driver.tick(at: 12)
        XCTAssertTrue(asked.isEmpty, "the first frame after a hold only restarts the clock")

        driver.tick(at: 12 + 1.0 / 60)
        XCTAssertEqual(asked.first ?? 0, 1, accuracy: 0.001)
    }

    // MARK: - Running out of text

    /// The end of the book, or a chapter that will not load: either way the page stops
    /// moving, and a switch left on over a page that cannot move is a control lying about
    /// what it is doing.
    func testAPageWithNowhereToGoSwitchesItselfOff() {
        let driver = makeDriver()
        var ended = 0
        driver.onRanAground = { ended += 1 }
        surfaceMoves = { _ in 0 }

        driver.setSpeed(60)
        driver.tick(at: 0)
        driver.tick(at: 1)
        XCTAssertEqual(ended, 0)

        driver.tick(at: 3)
        XCTAssertEqual(ended, 0, "a chapter still being fetched is not the end of the book")

        driver.tick(at: 6.5)
        XCTAssertEqual(ended, 1)
        XCTAssertFalse(driver.isRunning)
    }

    /// The foot of the loaded text is a place the reader passes *through* on the way into
    /// the next chapter. A driver that counted those seconds towards giving up would switch
    /// itself off every time the network was slower than the reading — and, worse, the
    /// second time it happened it would be part way through its patience already.
    func testTextArrivingUnderTheReaderForgivesTheStall() {
        let driver = makeDriver()
        var ended = 0
        driver.onRanAground = { ended += 1 }
        surfaceMoves = { _ in 0 }

        driver.setSpeed(60)
        driver.tick(at: 0)
        driver.tick(at: 1)
        driver.tick(at: 4)

        asked.removeAll()
        surfaceMoves = { $0 }
        driver.tick(at: 5)
        XCTAssertFalse(asked.isEmpty, "the chapter landed, so the page moves again")

        surfaceMoves = { _ in 0 }
        driver.tick(at: 6)
        driver.tick(at: 9)
        XCTAssertEqual(ended, 0, "the patience starts over, it is not carried forward")
        XCTAssertTrue(driver.isRunning)

        driver.tick(at: 12)
        XCTAssertEqual(ended, 1)
    }

    // MARK: - What the trace is told about it

    /// The pair is the whole diagnosis, and this is the shape that says nothing is wrong:
    /// the surface was given very nearly everything it was asked for.
    ///
    /// Over the same SE grid `testFractionsOfAPointAddUpInsteadOfRoundingAway` uses,
    /// because a line reading `asked=99.8 moved=99.5` on a phone where the page is visibly
    /// moving is the reference somebody needs in front of them before they can call a
    /// different one a fault.
    func testASampleOfAHealthyPageSaysItGotWhatItAskedFor() throws {
        let driver = makeDriver()
        surfaceMoves = { ($0 / 0.5).rounded(.down) * 0.5 }
        driver.setSpeed(10)

        var now: CFTimeInterval = 0
        for _ in 0..<600 {
            driver.tick(at: now)
            now += 1.0 / 60
        }

        let (asked, moved) = try autoPair(driver.traceFields())
        XCTAssertEqual(asked, 100, accuracy: 1, "ten seconds at ten points a second")
        XCTAssertEqual(
            moved, asked, accuracy: 1,
            "a page nobody would complain about gets what it was promised"
        )
    }

    /// And the shape that says something is: asked for, never granted.
    ///
    /// Then the driver gives up, and from that moment the trace goes *quiet* rather than
    /// logging zeroes — which is the same rule the whole file follows. A silence where
    /// `auto` lines used to be is a page that stopped moving, and it takes nothing working
    /// to be readable.
    func testAPageThatWillNotMoveSaysSoAndThenStopsSayingAnything() throws {
        let driver = makeDriver()
        surfaceMoves = { _ in 0 }
        driver.setSpeed(60)

        driver.tick(at: 0)
        driver.tick(at: 1)
        driver.tick(at: 2)

        let (asked, moved) = try autoPair(driver.traceFields())
        XCTAssertGreaterThan(asked, 0)
        XCTAssertEqual(moved, 0, "the page was offered somewhere to go and went nowhere")

        driver.tick(at: 8)
        XCTAssertFalse(driver.isRunning)
        XCTAssertNil(
            driver.traceFields(),
            "a driver that switched itself off has nothing to report, and its silence is"
                + " the report"
        )
    }

    /// Each line covers the window it sits at the end of. Counters that were never reset
    /// would turn a rate into a running total, and an hour in, every line would look alike.
    func testReadingTheSampleStartsTheNextWindow() throws {
        let driver = makeDriver()
        driver.setSpeed(60)
        driver.tick(at: 0)
        driver.tick(at: 1)
        XCTAssertGreaterThan(try autoPair(driver.traceFields()).asked, 0)

        XCTAssertEqual(
            try autoPair(driver.traceFields()).asked, 0,
            "nothing happened between the two reads, so the second window is empty"
        )
    }

    /// The `asked=…/moved=…` pair out of one sample line.
    private func autoPair(_ fields: String?) throws -> (asked: Double, moved: Double) {
        let field = try XCTUnwrap(
            XCTUnwrap(fields).split(separator: " ").first { $0.hasPrefix("auto=") }
        )
        let pair = field.dropFirst("auto=".count).split(separator: "/")
        return (try XCTUnwrap(Double(pair[0])), try XCTUnwrap(Double(pair[1])))
    }
}
