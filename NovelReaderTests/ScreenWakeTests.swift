import UIKit
import XCTest
@testable import NovelReader

/// Who is holding the screen awake, and whether it was ever let go.
///
/// The bug this guards against has no symptom inside the app: a phone that never sleeps
/// looks exactly like a phone that is working. The only way anyone here finds out is by
/// reading a trace from a device they cannot touch, so what these tests pin is that the
/// trace can be read at all — that the reason is named, and that an evening of toggling
/// does not bury the one transition that mattered.
@MainActor
final class ScreenWakeTests: XCTestCase {
    private var tempRoot: URL!
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ScreenWakeTests-\(UUID().uuidString)")
        suite = "ScreenWakeTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDownWithError() throws {
        // The domain first, so the trace built on the next line comes up switched off and
        // the release does not write a file back into the directory being removed. The
        // release itself is not optional: the flag belongs to the machine running the
        // suite, and a test that left it held would keep every later one awake.
        defaults.removePersistentDomain(forName: suite)
        ScreenWake.release(trace: TraceLog(directory: tempRoot, defaults: defaults))
        try? FileManager.default.removeItem(at: tempRoot)
    }

    /// The reason is the whole point of the line. "The screen is awake" is not a finding;
    /// "the screen is awake because a page is scrolling, an hour after the pages stopped"
    /// is one.
    func testEachReasonForHoldingTheScreenNamesItself() throws {
        let log = recording()

        ScreenWake.hold(keepOn: true, autoScrolling: false, trace: log)
        ScreenWake.hold(keepOn: true, autoScrolling: true, trace: log)
        ScreenWake.hold(keepOn: false, autoScrolling: true, trace: log)
        ScreenWake.release(trace: log)

        XCTAssertEqual(
            screenLines(of: log),
            ["screen awake why=keepOn", "screen awake why=keepOn+auto",
             "screen awake why=auto", "screen sleeps"]
        )
    }

    /// Every caller is an `onChange` or an `onAppear`, and they land on the combination
    /// already in force all the time — the reader's own setting has not moved, and the
    /// page has merely stopped and started. One line per call would be a column of "still
    /// awake, same reason" with the transition that mattered somewhere inside it.
    func testHoldingItForTheSameReasonTwiceIsNotWorthALine() throws {
        let log = recording()

        ScreenWake.hold(keepOn: true, autoScrolling: false, trace: log)
        for _ in 0..<20 { ScreenWake.hold(keepOn: true, autoScrolling: false, trace: log) }
        ScreenWake.release(trace: log)
        for _ in 0..<20 { ScreenWake.release(trace: log) }

        XCTAssertEqual(screenLines(of: log), ["screen awake why=keepOn", "screen sleeps"])
    }

    /// A page moving on its own outranks the reader's answer, which is what the two
    /// readers have always done: auto-scroll is the one kind of reading with no touches in
    /// it, so it is the only one the system would lock the screen in the middle of.
    func testAMovingPageHoldsTheScreenEvenWithTheSettingOff() throws {
        let log = recording()

        ScreenWake.hold(keepOn: false, autoScrolling: true, trace: log)
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)

        ScreenWake.hold(keepOn: false, autoScrolling: false, trace: log)
        XCTAssertFalse(
            UIApplication.shared.isIdleTimerDisabled,
            "and the moment it stops moving, the phone in a pocket gets its screen back"
        )
    }

    // MARK: - Helpers

    /// A trace already recording, and a screen already let go — so that what the test
    /// writes is all that is in the file, whatever the test before it left behind.
    private func recording() -> TraceLog {
        let log = TraceLog(directory: tempRoot, defaults: defaults)
        ScreenWake.release(trace: log)
        log.isOn = true
        return log
    }

    /// The screen lines, each without its leading timestamp column: what is being asserted
    /// is the event and its reason, not the second of the session it landed in.
    private func screenLines(of log: TraceLog) -> [String] {
        String(data: log.contents(), encoding: .utf8)?
            .split(separator: "\n")
            .filter { $0.contains("screen") }
            .map {
                $0.trimmingCharacters(in: .whitespaces)
                    .split(separator: " ", maxSplits: 1)
                    .last.map(String.init) ?? String($0)
            } ?? []
    }
}
