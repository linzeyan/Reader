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

    /// A `Slider` clamps a value outside its range and writes the clamp back, so a default
    /// outside the range the panel offers would be silently re-set the first time a reader
    /// opened it — changing a speed they never touched.
    func testTheDefaultPaceIsInsideTheRangeTheSliderOffers() {
        XCTAssertTrue(ReadingPace.range.contains(ReadingPace.standard.linesPerMinute))
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
}
