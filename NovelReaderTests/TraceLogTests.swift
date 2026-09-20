import XCTest
@testable import NovelReader

/// The diagnostics trace: what it records, what it hands over, and what it throws away.
///
/// The promises being pinned here are the ones a reader is asked to trust before they
/// turn the switch on: nothing is recorded until they ask, turning it off leaves nothing
/// behind, and a switch left on cannot fill their phone.
///
/// On the main actor because the sampler's contract is that it runs there — its sources
/// read main-actor state, and so does the foreground/background field.
@MainActor
final class TraceLogTests: XCTestCase {
    private var tempRoot: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TraceLogTests-\(UUID().uuidString)")
        suite = "TraceLogTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func makeLog() -> TraceLog {
        TraceLog(directory: tempRoot, defaults: defaults)
    }

    /// Off is off: not a smaller trace, no trace and no file.
    func testNothingIsRecordedUntilSomebodyAsksForIt() {
        let log = makeLog()
        XCTAssertFalse(log.isOn)

        for index in 0..<100 { log.note("sample n=\(index)") }
        log.refreshSize()

        XCTAssertTrue(log.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: tempRoot.path),
            "a switch nobody touched must not have created a directory to hold nothing"
        )
    }

    /// What was noted comes back, in the order it happened, behind a line that says which
    /// build and which phone said it.
    func testTheTraceComesBackInOrderBehindItsHeader() throws {
        let log = makeLog()
        log.isOn = true
        log.note("first")
        log.note("second")

        let text = try XCTUnwrap(String(data: log.contents(), encoding: .utf8))
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(
            lines[0].contains("boot") && lines[0].contains("hw="),
            "without a header a trace cannot be attributed to a build or a phone: \(lines[0])"
        )
        XCTAssertTrue(lines[1].hasSuffix("first"))
        XCTAssertTrue(lines[2].hasSuffix("second"))
    }

    /// Recording outlives a launch, because the session worth recording is a whole
    /// evening and the app is relaunched several times inside one.
    func testARelaunchPicksTheSameTraceBackUp() throws {
        let first = makeLog()
        first.isOn = true
        first.note("before the relaunch")
        _ = first.contents()

        let second = makeLog()
        XCTAssertTrue(second.isOn, "the switch is the reader's, not the launch's")
        second.note("after the relaunch")

        let text = try XCTUnwrap(String(data: second.contents(), encoding: .utf8))
        XCTAssertTrue(text.contains("before the relaunch"), "a relaunch must not lose the run before it")
        XCTAssertTrue(text.contains("after the relaunch"))
    }

    /// Turning it off is the only way to clear it, and it clears all of it.
    func testTurningItOffLeavesNothingBehind() {
        let log = makeLog()
        log.isOn = true
        log.note("something worth keeping until it is not")
        log.refreshSize()
        XCTAssertFalse(log.isEmpty)

        log.isOn = false

        XCTAssertTrue(log.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: tempRoot.path),
            "the switch is the whole retention policy — off means gone, not hidden"
        )
    }

    /// A switch left on and forgotten costs a bounded number of megabytes, and what it
    /// spends them on is the most recent hours rather than the first ones.
    func testASwitchLeftOnKeepsTheEndOfTheEveningRatherThanTheStart() throws {
        let log = makeLog()
        log.isOn = true
        // Past two rolls, so that something has actually been dropped rather than merely
        // moved into the rolled file.
        let padding = String(repeating: "x", count: 4096)
        log.note("the very first line \(padding)")
        for index in 0..<1100 { log.note("n=\(index) \(padding)") }
        log.note("the very last line \(padding)")

        let text = try XCTUnwrap(String(data: log.contents(), encoding: .utf8))
        log.refreshSize()

        XCTAssertLessThanOrEqual(
            log.size, 5 * 1024 * 1024,
            "a trace nobody turned off has to stop somewhere"
        )
        XCTAssertTrue(
            text.contains("the very last line"),
            "and what it keeps is the end — the hours before somebody noticed a problem"
        )
        XCTAssertFalse(
            text.contains("the very first line"),
            "a trace that filled up by keeping its own beginning would answer nothing"
        )
    }

    /// A phone on a shelf records nothing. The sample runs off a timer, and a timer that
    /// wrote a line whether or not anybody was reading would fill an overnight trace with
    /// evidence that nobody was reading.
    func testAnIdleAppSamplesNothingAtAll() throws {
        let log = makeLog()
        log.isOn = true
        log.sampleNow()
        log.sampleNow()

        let text = try XCTUnwrap(String(data: log.contents(), encoding: .utf8))
        XCTAssertFalse(text.contains("sample"), "no source installed means nothing to say")

        log.watch("reader") { "loaded=4" }
        log.sampleNow()

        let after = try XCTUnwrap(String(data: log.contents(), encoding: .utf8))
        XCTAssertTrue(after.contains("loaded=4"))
        XCTAssertTrue(after.contains("rss="), "a sample with no memory in it answers nothing")
    }

    /// A source with nothing to say right now is the same as no source. The reader
    /// installs one and then goes away; the closure holds its model weakly and starts
    /// answering nil, and the trace has to fall quiet rather than log a column of zeroes.
    func testASourceThatFallsSilentStopsTheSampleWithIt() throws {
        let log = makeLog()
        log.isOn = true
        var alive = true
        log.watch("reader") { alive ? "loaded=4" : nil }
        log.sampleNow()
        alive = false
        log.sampleNow()

        let samples = try XCTUnwrap(String(data: log.contents(), encoding: .utf8))
            .split(separator: "\n")
            .filter { $0.contains("sample") }
        XCTAssertEqual(samples.count, 1)
    }

    /// Going away and coming back, with how long it lasted — the pair that every question
    /// about background audio is read against.
    func testThePhaseLineSaysHowLongTheAppWasGone() throws {
        let log = makeLog()
        log.isOn = true
        // A launch activates without ever having left, and has no duration to state.
        // `after=0` there would read as "went away and came straight back", which is a
        // real event and not this one.
        log.notePhase(true)
        log.notePhase(false)
        log.notePhase(true)

        let lines = try XCTUnwrap(String(data: log.contents(), encoding: .utf8))
            .split(separator: "\n")
            .filter { $0.contains("phase") }
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasSuffix("phase fg"), "the launch: \(lines[0])")
        XCTAssertTrue(lines[1].hasSuffix("phase bg"))
        XCTAssertTrue(
            lines[2].contains("phase fg after="),
            "a return with no duration on it cannot be told from a return after an hour"
        )
    }
}
