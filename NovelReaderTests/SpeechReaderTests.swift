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

    override func setUp() {
        super.setUp()
        reader = SpeechReader()
    }

    override func tearDown() {
        reader.stop()
        reader = nil
        super.tearDown()
    }

    /// A book with no end to it.
    ///
    /// Endless on purpose: every claim in this file is about something *stopping* the
    /// voice, and over a book that runs out on its own each of them would pass without
    /// the rule under test existing at all.
    private func session(
        note: @escaping @MainActor (SpokenSentence) -> Void = { _ in }
    ) -> SpeechSession {
        SpeechSession(
            book: SpeechBook(id: "book", title: "渡口", cover: nil),
            chapterIndex: 0,
            anchor: .start,
            script: .off,
            pace: .standard,
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

        reader.pause()
        XCTAssertEqual(
            MPNowPlayingInfoCenter.default().playbackState, .paused,
            "a paused book has to show a play button rather than a pause one"
        )

        reader.stop()
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
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
