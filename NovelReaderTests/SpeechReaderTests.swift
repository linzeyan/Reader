import AVFoundation
import Foundation
import MediaPlayer
import XCTest
@testable import NovelReader

/// What listening has to survive: a phone call, a pair of headphones being pulled out,
/// and a reader who put the book down on purpose.
///
/// These are the rules that only show themselves on a locked phone, which is exactly
/// where nothing can be watched. Getting the last one wrong is the loudest bug this
/// feature has: a book that starts reading itself out of somebody's pocket, on the train,
/// because a timer went off ten minutes after they pressed pause.
@MainActor
final class SpeechReaderTests: XCTestCase {
    private var reader: SpeechReader!
    private var trace: TraceLog!
    private var traceRoot: URL!

    override func setUp() {
        super.setUp()
        // A trace of its own, over a directory nothing else touches, so that a developer
        // with diagnostics switched on does not have these tests writing into the trace
        // they are collecting.
        traceRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SpeechReaderTests-\(UUID().uuidString)")
        trace = TraceLog(
            directory: traceRoot,
            defaults: UserDefaults(suiteName: traceRoot.lastPathComponent)!
        )
        reader = SpeechReader(trace: trace)
    }

    private func traceLines(_ event: String) -> [String] {
        String(data: trace.contents(), encoding: .utf8)?
            .split(separator: "\n")
            .filter { $0.contains(event) }
            .map(String.init) ?? []
    }

    /// Waits for a trace line to show up, because everything this class does that is
    /// worth recording happens when the synthesiser gets round to it.
    private func waitForTrace(
        _ event: String, within seconds: Double = 20
    ) async throws -> String? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if let line = traceLines(event).first { return line }
            try await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    override func tearDown() {
        reader.stop()
        reader = nil
        UserDefaults.standard.removePersistentDomain(forName: traceRoot.lastPathComponent)
        try? FileManager.default.removeItem(at: traceRoot)
        super.tearDown()
    }

    /// A book with no end to it.
    ///
    /// Endless on purpose: every claim in this file is about something *stopping* the
    /// voice, and over a book that runs out on its own each of them would pass without
    /// the rule under test existing at all.
    private func session(
        voices: [String: String] = [:],
        note: @escaping @MainActor (SpokenSentence) -> Void = { _ in }
    ) -> SpeechSession {
        SpeechSession(
            book: SpeechBook(id: "book", title: "渡口", cover: nil),
            chapterIndex: 0,
            anchor: .start,
            script: .off,
            pace: .standard,
            voices: voices,
            supply: { index in
                SpeechScript.sentences(
                    chapterIndex: index, siteChapterId: "c\(index)", title: "第\(index)章",
                    paragraphs: ["他推開門。雪落在渡口的燈上。船還沒有來。"],
                    script: .off
                )
            },
            note: note
        )
    }

    // MARK: - The system taking the audio away

    func testAPhoneCallPausesTheVoiceAndHangingUpCarriesItOn() {
        reader.start(session())
        XCTAssertEqual(reader.state, .speaking)

        reader.interrupted(began: true, mayResume: false)
        XCTAssertEqual(reader.state, .paused, "a call has to stop the book being read over it")

        reader.interrupted(began: false, mayResume: true)
        XCTAssertEqual(reader.state, .speaking, "and hanging up has to give the book back")
    }

    /// The one that matters on a train. A reader who pressed pause has stopped listening;
    /// an interruption that ends afterwards is the system offering the audio back, not the
    /// reader asking for their book.
    func testAVoiceTheReaderPausedIsNotStartedAgainByTheSystem() {
        reader.start(session())
        reader.pause()
        XCTAssertEqual(reader.state, .paused)

        reader.interrupted(began: false, mayResume: true)
        XCTAssertEqual(reader.state, .paused, "only the system's own pause may be undone")
    }

    /// An interruption that ends without permission to resume leaves the book where it is:
    /// the system is saying the audio is free, not that this app should take it.
    func testAnInterruptionThatMayNotResumeLeavesTheBookPaused() {
        reader.start(session())
        reader.interrupted(began: true, mayResume: false)
        reader.interrupted(began: false, mayResume: false)
        XCTAssertEqual(reader.state, .paused)
    }

    /// Headphones out means the speaker, and the speaker means everyone in the carriage.
    /// Nothing hands this back, so nothing starts it again either.
    func testHeadphonesComingOutStopTheVoiceAndDoNotHandItBack() {
        reader.start(session())
        reader.unplugged()
        XCTAssertEqual(reader.state, .paused)

        reader.interrupted(began: false, mayResume: true)
        XCTAssertEqual(reader.state, .paused)
    }

    // MARK: - Ending it

    func testLeavingTheBookForgetsEverythingAboutIt() {
        reader.start(session())
        reader.sleepsAt = Date().addingTimeInterval(900)
        XCTAssertEqual(reader.book?.id, "book")
        reader.stop()

        XCTAssertEqual(reader.state, .idle)
        XCTAssertNil(reader.book, "another book must not find this one's sentence picked out")
        XCTAssertNil(reader.current)
        XCTAssertNil(reader.sleepsAt, "a timer set for one book is not a timer for the next")
    }

    /// The timer stops a book that would otherwise go on for ever — and it stops it by
    /// refusing the next sentence rather than by cutting off the one being said, which is
    /// what wakes a reader up instead of letting them go.
    func testASleepTimerThatHasRungStopsTheVoiceRatherThanReadingOn() async throws {
        reader.start(session())
        reader.sleepsAt = Date().addingTimeInterval(-1)

        // Long enough for the two sentences already handed to the synthesiser to be
        // finished, which is the whole point: they are, and then it stops.
        let deadline = ContinuousClock.now.advanced(by: .seconds(40))
        while reader.state != .idle {
            guard ContinuousClock.now < deadline else {
                return XCTFail("the timer had rung and the voice took another sentence anyway")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - What the lock screen is told

    /// A lock screen cannot be looked at from a test, but what was published to it can be
    /// asked for. A book that reads aloud behind a control centre showing nothing is the
    /// failure this catches — and so is one that goes on showing a book after the reader
    /// has closed it.
    func testTheLockScreenIsToldWhatIsPlayingAndThenThatItStopped() {
        reader.start(session())
        let playing = MPNowPlayingInfoCenter.default().nowPlayingInfo
        XCTAssertEqual(playing?[MPMediaItemPropertyArtist] as? String, "渡口")
        XCTAssertNotNil(playing?[MPMediaItemPropertyTitle])
        XCTAssertEqual(MPNowPlayingInfoCenter.default().playbackState, .playing)

        // A pause from outside the page — here, headphones coming out — which the lock
        // screen is where the reader carries on from.
        reader.unplugged()
        XCTAssertEqual(
            MPNowPlayingInfoCenter.default().playbackState, .paused,
            "a book paused from outside the app has to show a play button, not vanish"
        )
        XCTAssertNotNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)

        reader.stop()
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
    }

    /// Reported from a device: paused with the page open, then locked, and the lock screen
    /// still offered the book. A reader who pressed pause on the book in front of them has
    /// put it down, and a player left behind is the app claiming otherwise — and sitting on
    /// the audio over whatever they play next. The strip on the page stays, which is how
    /// they pick it up again, and picking it up puts the book back on the lock screen.
    func testTheReadersOwnPauseTakesTheBookOffTheLockScreenUntilTheyCarryOn() {
        reader.start(session())
        XCTAssertNotNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)

        reader.pause()
        XCTAssertEqual(reader.state, .paused, "paused, not stopped: the strip stays on the page")
        XCTAssertEqual(reader.book?.id, "book")
        XCTAssertNil(
            MPNowPlayingInfoCenter.default().nowPlayingInfo,
            "nothing left on the lock screen for a book put down on the page"
        )

        reader.resume()
        XCTAssertEqual(
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtist] as? String,
            "渡口", "carrying on puts the book back where a locked phone can reach it"
        )
        XCTAssertEqual(MPNowPlayingInfoCenter.default().playbackState, .playing)
    }

    /// The other half of putting the book down: the synthesiser was emptied rather than
    /// paused, so carrying on has to say something again. A resume that only asked the
    /// synthesiser to continue would leave a strip showing "playing" over total silence.
    /// And while it is down it has to be silent — a paragraph arriving late from a chapter
    /// load must not start the voice under a reader who stopped it.
    func testAfterTheReadersOwnPauseTheVoiceIsSilentAndCarryingOnReadsOn() async throws {
        var said: [SpokenSentence] = []
        reader.start(session { said.append($0) })
        try await waitUntil("the voice never began") { !said.isEmpty }

        reader.pause()
        // Callbacks already on their way from the synthesiser are let land first.
        try await Task.sleep(for: .milliseconds(500))
        let whilePaused = said.count
        try await Task.sleep(for: .seconds(3))
        XCTAssertEqual(said.count, whilePaused, "a paused voice moved on to another sentence")

        reader.resume()
        try await waitUntil("carrying on said nothing") { said.count > whilePaused }
    }

    /// Polls, because every sentence arrives when the synthesiser gets round to it.
    private func waitUntil(
        _ failure: String, within seconds: Double = 20, _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail(failure) }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Choosing a voice

    /// A voice is a download, and downloads get deleted. The choice outlives the voice, so
    /// the one thing this must never do is hand the synthesiser nothing and leave a reader
    /// pressing play on a book that says absolutely nothing — with no way to connect the
    /// silence to the storage they cleared out last week.
    func testAVoiceTheDeviceNoLongerHasIsReadInAnotherRatherThanNotAtAll() throws {
        let language = "zh-TW"
        try XCTSkipIf(
            AVSpeechSynthesisVoice(language: language) == nil,
            "this device has no \(language) voice at all, so there is no fallback to check"
        )

        let resolved = SpeechReader.voice(
            for: language,
            chosen: [SpeechReader.voiceKey(for: language): "com.example.voice.deleted.last.week"]
        )
        XCTAssertNotNil(resolved, "a deleted voice has to fall back, not go silent")
        XCTAssertEqual(
            resolved?.language, language,
            "and it has to fall back within the language — any other is unintelligible"
        )
    }

    /// The choice is honoured when the device does have it.
    ///
    /// Against a voice that is deliberately *not* the one its language resolves to on its
    /// own. The first version of this took the device's first installed voice, which turns
    /// out to be exactly what the fallback answers with — so it passed just as loudly with
    /// the reader's choice ignored altogether, which a red-light check caught and which is
    /// the entire behaviour this file was added for.
    ///
    /// The voices come off this device rather than being named outright: a hard-coded
    /// identifier is a test that agrees with whatever iOS happened to ship that year.
    func testAVoiceTheReaderChoseIsPreferredToTheOneItsLanguageWouldPick() throws {
        let alternative = AVSpeechSynthesisVoice.speechVoices().first { voice in
            AVSpeechSynthesisVoice(language: voice.language)?.identifier != voice.identifier
        }
        let choice = try XCTUnwrap(
            alternative,
            "every language here has one voice, so there is no choice to honour"
        )

        let resolved = SpeechReader.voice(
            for: choice.language,
            chosen: [SpeechReader.voiceKey(for: choice.language): choice.identifier]
        )
        XCTAssertEqual(
            resolved?.identifier, choice.identifier,
            "the reader's choice has to beat what the language resolves to by itself"
        )
    }

    /// A voice from another region of the same language is the reader's to choose: a
    /// Traditional-script book read by a Mainland voice. And the choice holds whichever
    /// Mandarin a book resolves to — a book with a script setting of its own is read in a
    /// different one from the global setting the choice was made under, and filing the
    /// choice by region is what made choosing a voice quietly do nothing there.
    func testAVoiceFromAnotherRegionOfTheLanguageIsHonoured() throws {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let pair = voices.lazy.compactMap { voice -> (AVSpeechSynthesisVoice, String)? in
            guard let other = voices.first(where: {
                $0.language != voice.language
                    && SpeechReader.voiceKey(for: $0.language)
                        == SpeechReader.voiceKey(for: voice.language)
            }) else { return nil }
            return (voice, other.language)
        }.first
        let (choice, readIn) = try XCTUnwrap(
            pair, "no language here has voices in two regions, so there is nothing to cross"
        )

        let resolved = SpeechReader.voice(
            for: readIn, chosen: [SpeechReader.voiceKey(for: choice.language): choice.identifier]
        )
        XCTAssertEqual(
            resolved?.identifier, choice.identifier,
            "\(choice.language) chosen, \(readIn) being read: the choice has to hold"
        )
    }

    /// Only the languages a book can actually be read in — the reader's own Mandarin and
    /// the device's own language. A picker that listed every language iOS has a voice for
    /// would be offering seventy choices, sixty-eight of which nothing will ever consult.
    func testTheVoicesOfferedAreOnlyTheOnesABookCanBeReadIn() {
        let traditional = SpeechReader.spokenLanguages(
            script: ChineseScript(depth: .characters, target: .traditional)
        )
        XCTAssertEqual(traditional.first, "zh-TW", "the reader's script settles the Mandarin")

        let simplified = SpeechReader.spokenLanguages(
            script: ChineseScript(depth: .characters, target: .simplified)
        )
        XCTAssertEqual(simplified.first, "zh-CN")

        XCTAssertEqual(
            Set(simplified.map(SpeechReader.voiceKey(for:))).count, simplified.count,
            "a device whose own language is Chinese has one Chinese list, not one per script"
        )
        XCTAssertLessThanOrEqual(simplified.count, 2)
    }

    /// The rule `setPace` already holds, now that a second control shares its machinery:
    /// re-saying what is queued is how a voice changes mid-sentence, and doing it to a book
    /// the reader stopped is a book that starts talking out of a pocket. Same failure as the
    /// sleep-timer one above, reached through a different control.
    func testChoosingAVoiceDoesNotStartABookTheReaderPaused() {
        reader.start(session())
        reader.pause()
        XCTAssertEqual(reader.state, .paused)

        reader.setVoices(["zh": "com.apple.voice.compact.zh-TW.Meijia"])
        XCTAssertEqual(
            reader.state, .paused,
            "choosing a voice is not asking for the book to be read"
        )
    }

    /// A voice is a download and downloads get deleted, so a reader can come back to a
    /// book being read in a voice they did not choose. Nothing on screen connects that to
    /// the storage they cleared last week, and the fallback is *correct* behaviour — the
    /// alternative is silence — so there is no bug report to file and nothing to see.
    /// This line is the only trace such a device leaves.
    ///
    /// The language is read back out of the trace rather than assumed: which one a
    /// sentence is said in is settled per sentence and depends on the device, so a test
    /// that named one would be testing this machine's locale.
    func testAChosenVoiceTheDeviceNoLongerHasIsWrittenDownRatherThanOnlySoundingWrong()
        async throws {
        trace.isOn = true
        reader.start(session())

        let utterance = try await waitForTrace("say n=")
        let said = try XCTUnwrap(
            utterance, "nothing was said, so there is nothing to record"
        )
        let language = try XCTUnwrap(
            said.split(separator: " ").first { $0.hasPrefix("lang=") }?.dropFirst(5),
            "the utterance line has to name the language it chose: \(said)"
        )

        // Nothing recorded yet, and the assertion is load-bearing rather than tidy: this
        // test waits for a line to appear, so a line written earlier for some other
        // reason would satisfy that wait and the test would pass with the rule gone. A
        // red-light check found exactly that.
        XCTAssertTrue(
            traceLines("voice gone").isEmpty,
            "nothing has been chosen yet, so nothing can have been missed yet"
        )

        // Through the reader's own control, which is what a reader choosing a voice goes
        // through — and it clears the resolved cache, so the choice is looked up again.
        reader.setVoices(
            [SpeechReader.voiceKey(for: String(language)): "com.example.voice.deleted.last.week"]
        )

        let missing = try await waitForTrace("voice gone")
        let gone = try XCTUnwrap(
            missing,
            "a choice the device cannot honour has to leave a line, or the silence is "
                + "the only evidence there will ever be"
        )
        XCTAssertTrue(gone.contains("lang=\(language)"), gone)
    }

    /// The other half, and the reason the condition is what it is: a reader who never
    /// chose a voice, or whose choice is still installed, must not have this written down
    /// once per utterance. The file leaves the phone, and nine lines a minute of "nothing
    /// is wrong" is the whole file by morning.
    func testAVoiceThatResolvedAsAskedIsNotWorthALine() async throws {
        trace.isOn = true
        reader.start(session())

        let spoke = try await waitForTrace("say n=")
        _ = try XCTUnwrap(spoke)
        XCTAssertTrue(
            traceLines("voice gone").isEmpty,
            "nothing was chosen, so nothing was missed: \(traceLines("voice gone"))"
        )
    }

    // MARK: - Where the reader got to

    /// The only record a locked phone keeps. Nothing is drawn while the screen is off, so
    /// without this an hour of listening is written down as the paragraph the eye last saw.
    func testEverySentenceSaidIsReportedWithSomewhereToWriteItDown() async throws {
        var said: [SpokenSentence] = []
        reader.start(session { said.append($0) })

        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while said.isEmpty {
            guard ContinuousClock.now < deadline else {
                return XCTFail("the voice read a sentence and told the book nothing about it")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(said.first?.chapterIndex, 0)
        XCTAssertEqual(said.first?.anchor, TextAnchor(paragraph: 0, characterOffset: 0))
    }
}
