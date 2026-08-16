import XCTest
@testable import NovelReader

/// When a reading position reaches the database.
///
/// This encodes the bug that produced it: the app only wrote on a chapter change and on
/// leaving the reader, so a process suspended in the background and then killed came back
/// at the chapter the reader had opened, throwing away everything they had read in it.
/// The fix is not "write more often" — a write per paragraph is a write per thumb flick —
/// it is that every way of leaving writes, and reading itself writes on a leash.
final class ProgressWriteRuleTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    private func position(_ paragraph: Int, chapter: String = "c1") -> ReadingPosition {
        ReadingPosition(
            siteChapterId: chapter, anchor: TextAnchor(paragraph: paragraph, characterOffset: 0)
        )
    }

    /// The first position of a session has nothing to compare against and always lands:
    /// a reader who opens a book and immediately backgrounds it has still moved.
    func testTheFirstPositionIsAlwaysWritten() {
        var rule = ProgressWriteRule()
        XCTAssertTrue(rule.shouldWrite(position(0), occasion: .reading, now: start))
    }

    /// The leash. Reading past a handful of paragraphs inside five seconds is one write,
    /// not five, and the position that eventually lands is the latest one.
    func testReadingOnWritesAtMostOncePerInterval() {
        var rule = ProgressWriteRule()
        XCTAssertTrue(rule.shouldWrite(position(0), occasion: .reading, now: start))
        XCTAssertFalse(rule.shouldWrite(position(1), occasion: .reading, now: start.addingTimeInterval(1)))
        XCTAssertFalse(rule.shouldWrite(position(2), occasion: .reading, now: start.addingTimeInterval(4)))
        XCTAssertTrue(
            rule.shouldWrite(position(3), occasion: .reading, now: start.addingTimeInterval(5)),
            "five seconds after the last write, the position on screen is worth keeping"
        )
    }

    /// The whole point. Leaving is the moment the position may never be asked for again —
    /// the app going to the background, a chapter change, the book closing — so it is not
    /// subject to the leash at all.
    func testLeavingWritesEvenInsideTheInterval() {
        var rule = ProgressWriteRule()
        XCTAssertTrue(rule.shouldWrite(position(0), occasion: .reading, now: start))
        XCTAssertTrue(
            rule.shouldWrite(position(1), occasion: .leaving, now: start.addingTimeInterval(0.2)),
            "a reader who backgrounds the app one paragraph later must not lose it"
        )
    }

    /// Refused on both occasions, and this is not an optimisation: the write stamps
    /// `Book.updatedAt`, which is how iCloud settles merges. Re-writing an unchanged
    /// position would let a device that is sitting still beat one that has read on.
    func testAnUnchangedPositionIsNeverWrittenTwice() {
        var rule = ProgressWriteRule()
        XCTAssertTrue(rule.shouldWrite(position(7), occasion: .leaving, now: start))
        XCTAssertFalse(rule.shouldWrite(position(7), occasion: .leaving, now: start.addingTimeInterval(60)))
        XCTAssertFalse(rule.shouldWrite(position(7), occasion: .reading, now: start.addingTimeInterval(60)))
        XCTAssertTrue(
            rule.shouldWrite(position(7, chapter: "c2"), occasion: .reading, now: start.addingTimeInterval(60)),
            "the same paragraph of another chapter is another position"
        )
    }
}
