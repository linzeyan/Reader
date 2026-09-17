import Foundation
import XCTest
@testable import NovelReader

/// What a sentence is, for the finger and for the voice.
///
/// These rules were the paginated reader's selection snap and nothing else, and they were
/// asked one question: which sentence surrounds this offset. Reading a book out loud asks
/// the other one — give me every sentence, in order, with nothing missed and nothing said
/// twice — and a rule that answers the first correctly can still lose a clause on the
/// second. What is pinned here is that walking a paragraph end to end covers it exactly:
/// the sentences a reader hears are the sentences they could have marked.
final class SentenceRulesTests: XCTestCase {
    private func split(_ paragraph: String) -> [String] {
        let text = paragraph as NSString
        let whole = NSRange(location: 0, length: text.length)
        return SentenceRules.sentences(in: whole, of: text).map { text.substring(with: $0) }
    }

    func testAParagraphIsCutAtItsFullStops() {
        XCTAssertEqual(
            split("他推開門。雪落在渡口的燈上。船還沒有來。"),
            ["他推開門。", "雪落在渡口的燈上。", "船還沒有來。"]
        )
    }

    /// The reason `closers` exists at all: a quotation ends after the bracket that closes
    /// it, not between the full stop and the bracket — which would have the voice pausing
    /// before a single stray 」.
    func testAQuotationEndsAfterTheBracketThatClosesIt() {
        XCTAssertEqual(
            split("她說：「船要來了。」他沒有回答。"),
            ["她說：「船要來了。」", "他沒有回答。"]
        )
    }

    /// A paragraph with no terminator in it is one sentence. Anything else would mean
    /// picking a length to break at, and the voice would breathe mid-clause.
    func testAParagraphWithNoTerminatorIsOneSentence() {
        XCTAssertEqual(split("渡口的燈還亮著"), ["渡口的燈還亮著"])
    }

    /// Silence is not a sentence. An utterance with nothing to say finishes the instant it
    /// starts, which at the foot of a chapter sounds like the voice skipping ahead.
    func testRunsOfPunctuationOnTheirOwnAreNotSpoken() {
        XCTAssertEqual(split("好。……！？　他走了。"), ["好。", "他走了。"])
    }

    func testAnEmptyParagraphHasNothingToSay() {
        XCTAssertEqual(split(""), [])
        XCTAssertEqual(split("　 \n "), [])
    }

    /// The guarantee the voice depends on and the finger never needed: walking a paragraph
    /// end to end says every word in it, once, in order. A rule that drops a clause here is
    /// a book that skips a line out loud, and nothing on screen would say so.
    ///
    /// What may be left out is punctuation nobody can pronounce — see the silence test
    /// above — so the gaps are asserted to hold no words rather than to be empty.
    func testWalkingAParagraphSaysEveryWordOnceAndInOrder() {
        let paragraph = "「你真的要走？」她問。他點頭，說：「明天。」雪還在下……渡口沒有人"
        let text = paragraph as NSString
        let whole = NSRange(location: 0, length: text.length)
        let ranges = SentenceRules.sentences(in: whole, of: text)
        XCTAssertFalse(ranges.isEmpty)
        let silent = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        var reach = 0
        for range in ranges {
            XCTAssertGreaterThanOrEqual(
                range.location, reach, "a sentence ran back over the one before it"
            )
            let skipped = text.substring(with: NSRange(location: reach, length: range.location - reach))
            XCTAssertTrue(
                skipped.trimmingCharacters(in: silent).isEmpty,
                "the words \(skipped) were never said"
            )
            reach = NSMaxRange(range)
        }
        XCTAssertEqual(reach, text.length, "the last sentence stopped short of the paragraph")
    }

    /// Sentences are found inside the paragraph they are asked about and nowhere else:
    /// a chapter is one string, and a paragraph that reached into its neighbour would put
    /// the band under the wrong words and the anchor in the wrong paragraph.
    func testSentencesStayInsideTheParagraphTheyWereAskedAbout() {
        let chapter = "第一段。還有一句。\n第二段。" as NSString
        let second = NSRange(location: 9, length: chapter.length - 9)
        XCTAssertEqual(
            SentenceRules.sentences(in: second, of: chapter).map { chapter.substring(with: $0) },
            ["第二段。"]
        )
    }

    /// The question the selection snap asks, still answered the same way — this rule is
    /// shared, and the highlight tests are the other half of its safety net.
    func testAnOffsetInsideASentenceGrowsToTheWholeOfIt() {
        let text = "他推開門。雪落在渡口的燈上。船還沒有來。" as NSString
        let whole = NSRange(location: 0, length: text.length)
        let start = SentenceRules.start(at: 8, in: whole, of: text)
        let end = SentenceRules.end(at: 8, in: whole, of: text)
        XCTAssertEqual(text.substring(with: NSRange(location: start, length: end - start)), "雪落在渡口的燈上。")
    }
}
