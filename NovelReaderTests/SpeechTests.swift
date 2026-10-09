import Foundation
import XCTest
@testable import NovelReader

/// What the voice is going to say, and where in the book it is while it says it.
///
/// Everything a listener can see — the band under the words, the page that keeps up, the
/// position written down when the phone is taken away — is `SpokenSentence.anchor`. So
/// the script is not only a list of strings to read out: it is a claim about where each
/// of them is, and a script that is one character out puts the band under the wrong
/// clause of the right sentence and writes the reader's position to the wrong place.
@MainActor
final class SpeechTests: XCTestCase {
    private let paragraphs = [
        "他推開門。雪落在渡口的燈上。",
        "船還沒有來。"
    ]

    private func script(
        _ paragraphs: [String], chapterIndex: Int = 0, title: String = "第一章　渡口",
        chinese: ChineseScript = .off
    ) -> [SpokenSentence] {
        SpeechScript.sentences(
            chapterIndex: chapterIndex, siteChapterId: "c\(chapterIndex)", title: title,
            paragraphs: paragraphs, script: chinese
        )
    }

    // MARK: - One chapter as sentences

    func testAChapterIsSaidTitleFirstThenSentenceBySentence() {
        let sentences = script(paragraphs)
        XCTAssertEqual(
            sentences.map(\.text),
            ["第一章　渡口", "他推開門。", "雪落在渡口的燈上。", "船還沒有來。"]
        )
        XCTAssertEqual(sentences.map(\.isTitle), [true, false, false, false])
    }

    /// Each sentence knows where it is, in the terms a highlight and a reading position
    /// are stored in. The second sentence of a paragraph starts where the first one ended.
    func testEverySentenceCarriesTheAnchorItStartsAt() {
        let sentences = script(paragraphs)
        XCTAssertEqual(
            sentences.map(\.anchor),
            [
                TextAnchor(paragraph: 0, characterOffset: 0),
                TextAnchor(paragraph: 0, characterOffset: 0),
                TextAnchor(paragraph: 0, characterOffset: 5),
                TextAnchor(paragraph: 1, characterOffset: 0)
            ]
        )
    }

    /// The heading belongs to no paragraph, so it marks nothing — an empty range is what
    /// keeps a band off the first sentence of the chapter while its name is being said.
    func testTheTitleMarksNoTextOfItsOwn() {
        XCTAssertEqual(script(paragraphs).first?.range.length, 0)
    }

    func testAChapterWithNoTextIsStillAnnounced() {
        XCTAssertEqual(script([]).map(\.text), ["第一章　渡口"])
        XCTAssertEqual(script(["", "   "]).map(\.text), ["第一章　渡口"])
    }

    /// The reader's script changes the characters and must not change where anything is.
    ///
    /// `ChineseText.rendered` guarantees the UTF-16 length, which is what lets the voice
    /// say what is drawn on the page without a second set of offsets — and this is the
    /// test that would go red the day a conversion stopped honouring it: the same book
    /// read in the other script would put every band and every stored position one
    /// character further along than the words they name.
    func testTheOtherScriptSaysOtherCharactersInTheSamePlaces() {
        let paragraphs = ["他讀鬥羅大陸。書還沒有翻開。"]
        let hant = script(
            paragraphs, chinese: ChineseScript(depth: .characters, target: .traditional)
        )
        let hans = script(
            paragraphs, chinese: ChineseScript(depth: .characters, target: .simplified)
        )
        XCTAssertEqual(hant.map(\.range), hans.map(\.range))
        XCTAssertEqual(hant.map(\.anchor), hans.map(\.anchor))
        // The conversion really happened — without this the rest of the test would pass
        // just as well over two copies of the same string.
        XCTAssertNotEqual(hant.map(\.text), hans.map(\.text))
        XCTAssertEqual(
            hant.map(\.text.utf16.count), hans.map(\.text.utf16.count),
            "a conversion that changes the length moves every anchor after it"
        )
    }

    // MARK: - What goes into one utterance

    /// Short paragraphs are one thing to say, and a heading is its own.
    ///
    /// The synthesiser is handed a run at a time rather than a sentence at a time because
    /// every utterance boundary restarts the audio pipeline — measured at fifteen restarts
    /// a minute when the unit was the sentence, and still nine at a paragraph in dialogue,
    /// where a paragraph is one line. Glue a chapter's name to its first paragraph, though,
    /// and the voice reads the title as the opening clause.
    func testShortParagraphsAreOneThingToSayAndAHeadingIsItsOwn() {
        XCTAssertEqual(
            SpeechScript.runs(of: script(paragraphs)).map { $0.map(\.text) },
            [
                ["第一章　渡口"],
                ["他推開門。", "雪落在渡口的燈上。", "船還沒有來。"]
            ]
        )
    }

    /// A run takes paragraphs until it is past its budget, and then the next one starts
    /// afresh — but a paragraph is never cut, however long: the seam between utterances is
    /// a pause, and in the middle of a paragraph it would be a pause the author never wrote.
    func testARunStopsTakingParagraphsPastItsBudgetAndNeverSplitsOne() {
        // 51 units each: two and a line break are still under 120, three are past it.
        let short = String(repeating: "雪", count: 50) + "。"
        // Seventy sentences, 140 units: past the budget on its own.
        let long = String(repeating: "燈。", count: 70)
        let runs = SpeechScript.runs(of: script([short, short, short, short, long, short]))
        // Which paragraphs each run says; a split paragraph would turn up in two of them.
        XCTAssertEqual(
            runs.map { Set($0.filter { !$0.isTitle }.map(\.paragraph)) },
            [[], [0, 1, 2], [3, 4], [5]]
        )
        XCTAssertEqual(runs[2].count, 71, "the long paragraph goes whole, all seventy sentences")
    }

    /// The voice is chosen once per utterance, so a paragraph in another language is never
    /// folded into a run: an English line read by the Mandarin voice is what that would do.
    func testAParagraphInAnotherLanguageStartsARunOfItsOwn() {
        XCTAssertEqual(
            SpeechScript.runs(of: script(["他推開門。", "The ferry is late."])).map { $0.map(\.text) },
            [["第一章　渡口"], ["他推開門。"], ["The ferry is late."]]
        )
    }

    /// What is actually handed over is the sentences and nothing between them.
    ///
    /// `SentenceRules` drops the indent in 「　　他推開門。」 and any run of punctuation
    /// with no words in it, so the paragraph as it sits on the page is *not* what its
    /// sentences add up to. Saying the paragraph instead would read the indent out as a
    /// pause the author never wrote.
    func testAParagraphIsSaidAsItsSentencesAndNothingBetweenThem() {
        let sentences = script(["　　他推開門。　　雪落在渡口的燈上。"])
        let run = Array(sentences.dropFirst())
        XCTAssertEqual(SpeechScript.spoken(run).text, "他推開門。雪落在渡口的燈上。")
    }

    /// Where each sentence starts inside the string its paragraph is said as.
    ///
    /// This is what turns "the voice is at character 5 of this utterance" back into a
    /// place in the book, and everything a listener can see hangs off it: one offset wrong
    /// and the band sits under the previous sentence for a whole paragraph.
    func testEverySentenceKnowsWhereItStartsInsideWhatIsSaid() {
        let run = Array(script(paragraphs).dropFirst().prefix(2))
        let (text, starts) = SpeechScript.spoken(run)
        XCTAssertEqual(starts, [0, 5])
        XCTAssertEqual(
            starts.last.map { (text as NSString).substring(from: $0) },
            "雪落在渡口的燈上。",
            "the offset has to name the sentence the synthesiser would be reading there"
        )
    }

    /// Paragraphs said as one meet at a line break, and the offsets count it: one unit
    /// short and every sentence after the first paragraph is banded one character early.
    func testParagraphsSaidAsOneMeetAtALineBreakTheOffsetsCount() {
        let (text, starts) = SpeechScript.spoken(Array(script(paragraphs).dropFirst()))
        XCTAssertEqual(text, "他推開門。雪落在渡口的燈上。\n船還沒有來。")
        XCTAssertEqual(starts, [0, 5, 15])
        XCTAssertEqual((text as NSString).substring(from: 15), "船還沒有來。")
    }

    /// Taking a run takes what `runs(of:)` would have grouped, and nothing else.
    ///
    /// They are the two callers of one rule — the next run out of the book, and the rest
    /// of it handed back at a new speed — and a disagreement between them is a paragraph
    /// said twice or skipped the moment the reader touches the slider.
    func testTakingARunTakesWhatTheRestOfItWouldBeGroupedInto() async {
        let short = String(repeating: "雪", count: 50) + "。"
        let chapter = script(paragraphs + [short, short, short, "The ferry is late."])
        let sequence = SpeechSequence { index in index == 0 ? chapter : nil }
        _ = await sequence.begin(chapterIndex: 0, anchor: .start)
        var said: [[SpokenSentence]] = []
        while true {
            let run = await sequence.takeRun()
            guard !run.isEmpty else { break }
            said.append(run)
        }
        XCTAssertEqual(said, SpeechScript.runs(of: chapter))
        XCTAssertGreaterThan(said.count, 3, "a fixture that groups into one run proves nothing")
    }

    /// A run never spans two chapters: the next chapter's name is its own utterance, and
    /// reaching for it would mean loading a chapter to find out it did not belong.
    func testAParagraphRunStopsAtTheEndOfItsChapter() async {
        let sequence = SpeechSequence { [self] index in
            guard index < 2 else { return nil }
            return script(["第\(index)章的一句話。"], chapterIndex: index, title: "第\(index)章")
        }
        _ = await sequence.begin(chapterIndex: 0, anchor: .start)
        var said: [[String]] = []
        while true {
            let run = await sequence.takeRun()
            guard !run.isEmpty else { break }
            said.append(run.map(\.text))
        }
        XCTAssertEqual(
            said, [["第0章"], ["第0章的一句話。"], ["第1章"], ["第1章的一句話。"]]
        )
    }

    /// Picking up mid-paragraph hands over the rest of it and not the whole of it — the
    /// reader who pressed the headphones halfway down a paragraph must not hear the half
    /// they have already read.
    func testTakingARunTheReaderIsInsideStartsWhereTheyAre() async {
        let sequence = SpeechSequence { [self] index in
            index == 0 ? script(paragraphs, chapterIndex: 0) : nil
        }
        _ = await sequence.begin(
            chapterIndex: 0, anchor: TextAnchor(paragraph: 0, characterOffset: 5)
        )
        let run = await sequence.takeRun()
        XCTAssertEqual(run.map(\.text), ["雪落在渡口的燈上。", "船還沒有來。"])
    }

    // MARK: - Where to pick up

    func testStartingAtTheTopOfAChapterSaysItsNameFirst() {
        XCTAssertEqual(SpeechScript.index(forAnchor: .start, in: script(paragraphs)), 0)
    }

    /// A reader who has been reading for ten minutes is not arriving anywhere, and being
    /// told the chapter's name would say they were.
    func testStartingInsideAChapterDoesNotAnnounceIt() {
        let sentences = script(paragraphs)
        let index = SpeechScript.index(
            forAnchor: TextAnchor(paragraph: 1, characterOffset: 0), in: sentences
        )
        XCTAssertEqual(sentences[index].text, "船還沒有來。")
    }

    /// Erring backwards, the way every other anchor in this app errs: an offset inside a
    /// sentence hears that sentence from its start. Skipping it would be the voice
    /// silently leaving out a line the reader never read.
    func testAPositionInsideASentenceHearsTheWholeOfIt() {
        let sentences = script(paragraphs)
        let index = SpeechScript.index(
            forAnchor: TextAnchor(paragraph: 0, characterOffset: 8), in: sentences
        )
        XCTAssertEqual(sentences[index].text, "雪落在渡口的燈上。")
    }

    /// A position past everything in the chapter is a chapter already read. Answering one
    /// past the end is what sends the voice into the next one instead of starting this
    /// one again.
    func testAPositionPastTheEndOfAChapterIsPastItsLastSentence() {
        let sentences = script(paragraphs)
        let index = SpeechScript.index(
            forAnchor: TextAnchor(paragraph: 9, characterOffset: 0), in: sentences
        )
        XCTAssertEqual(index, sentences.count)
    }

    // MARK: - Reading on

    /// A book is one thing to listen to, not a series of chapters that each stop. This is
    /// the whole of "跨章不斷句": the sentence after a chapter's last one is the next
    /// chapter's title, with nothing in between for the reader to do.
    func testTheVoiceReadsOnIntoTheNextChapterWithoutBeingAsked() async {
        let sequence = SpeechSequence { [self] index in
            guard index < 2 else { return nil }
            return script(["第\(index)章的一句話。"], chapterIndex: index, title: "第\(index)章")
        }
        let opened = await sequence.begin(chapterIndex: 0, anchor: .start)
        XCTAssertTrue(opened)
        var said: [String] = []
        while let sentence = await sequence.take() { said.append(sentence.text) }
        XCTAssertEqual(said, ["第0章", "第0章的一句話。", "第1章", "第1章的一句話。"])
    }

    /// The end of the book is the one place the voice stops on its own.
    func testTheVoiceStopsWhenTheBookRunsOut() async {
        let sequence = SpeechSequence { [self] index in
            index == 0 ? script(["只有一章。"], chapterIndex: 0, title: "末章") : nil
        }
        let opened = await sequence.begin(chapterIndex: 0, anchor: .start)
        XCTAssertTrue(opened)
        let title = await sequence.take()
        XCTAssertEqual(title?.text, "末章")
        let only = await sequence.take()
        XCTAssertEqual(only?.text, "只有一章。")
        let past = await sequence.take()
        XCTAssertNil(past)
        // And stays stopped, rather than looping back into the chapter it holds.
        let stillPast = await sequence.take()
        XCTAssertNil(stillPast)
    }

    /// A subscription can hold an article that is a headline and a dead link. One of those
    /// in the middle of the list must not be the end of the listening.
    func testAChapterWithNothingInItIsSteppedOver() async {
        let sequence = SpeechSequence { [self] index in
            switch index {
            case 0: return script(["第一章的話。"], chapterIndex: 0, title: "第一章")
            case 1: return []
            case 2: return script(["第三章的話。"], chapterIndex: 2, title: "第三章")
            default: return nil
            }
        }
        let opened = await sequence.begin(chapterIndex: 0, anchor: .start)
        XCTAssertTrue(opened)
        var said: [String] = []
        while let sentence = await sequence.take() { said.append(sentence.text) }
        XCTAssertEqual(said, ["第一章", "第一章的話。", "第三章", "第三章的話。"])
    }

    /// Listening starts where the reading stopped, which is the one thing that makes the
    /// two halves of this feature the same book: pressing the headphones must not take the
    /// reader back to the top of the chapter they are halfway through.
    func testListeningBeginsWhereTheReaderIsStanding() async {
        let sequence = SpeechSequence { [self] index in
            index == 0 ? script(paragraphs, chapterIndex: 0) : nil
        }
        let opened = await sequence.begin(
            chapterIndex: 0, anchor: TextAnchor(paragraph: 0, characterOffset: 5)
        )
        XCTAssertTrue(opened)
        let first = await sequence.take()
        XCTAssertEqual(first?.text, "雪落在渡口的燈上。")
    }

    func testAChapterThatWillNotLoadIsNotSomethingToListenTo() async {
        let sequence = SpeechSequence { _ in nil }
        let opened = await sequence.begin(chapterIndex: 0, anchor: .start)
        XCTAssertFalse(opened)
    }
}
