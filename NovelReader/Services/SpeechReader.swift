import AVFoundation
import Foundation
import MediaPlayer
import UIKit

/// How fast the voice reads.
///
/// `AVSpeechUtterance`'s own scale, kept rather than converted into words a minute: the
/// scale is not linear and it is not the same curve for every voice, so a number in
/// words a minute would be a promise this cannot keep. What the reader adjusts is a
/// slider between a slow voice and a fast one, which is the only thing the number means.
struct SpeechPace: Equatable {
    var rate: Double

    /// Narrower than what the synthesiser accepts at both ends. Below this the voice
    /// stops sounding like speech and starts sounding like a fault; above it a Mandarin
    /// voice runs its tones together and stops being followable at all, which is the
    /// whole point of listening to a book rather than skimming one.
    static let range: ClosedRange<Double> = 0.3...0.8
    static let standard = SpeechPace(rate: Double(AVSpeechUtteranceDefaultSpeechRate))
}

/// The sentences still to be said, in reading order, across chapter boundaries.
///
/// The one piece of listening that has nothing to do with audio: where the words come
/// from, what happens when a chapter runs out, and where to pick up from a position the
/// reader was already standing at. Separate from `SpeechReader` so it can be driven in a
/// test without a voice — a synthesiser has to be listened to to be observed.
@MainActor
final class SpeechSequence {
    /// The chapter at a reading-order index, loading it if that is what it takes. Nil
    /// when the book has no such chapter, or cannot fetch it — which is what ends the
    /// listening.
    typealias Supply = @MainActor (Int) async -> [SpokenSentence]?

    private let supply: Supply
    private var buffer: [SpokenSentence] = []
    private var next = 0
    /// The chapter `buffer` holds, so running out of it knows what to ask for next.
    private var chapterIndex: Int?

    init(supply: @escaping Supply) {
        self.supply = supply
    }

    /// Loads one chapter and stands the voice where the reader is.
    ///
    /// - Returns: whether there is a book here to read at all.
    func begin(chapterIndex: Int, anchor: TextAnchor) async -> Bool {
        guard let sentences = await supply(chapterIndex) else { return false }
        buffer = sentences
        self.chapterIndex = chapterIndex
        next = SpeechScript.index(forAnchor: anchor, in: sentences)
        return true
    }

    /// The next sentence to say, crossing into the chapter below when this one is spent.
    ///
    /// Chapters with nothing in them are stepped over rather than treated as the end of
    /// the book: a subscription can hold an article that is a headline and a link, and
    /// one of those in the middle of the list must not stop the voice for good.
    func take() async -> SpokenSentence? {
        while true {
            if next < buffer.count {
                defer { next += 1 }
                return buffer[next]
            }
            guard let chapterIndex, let sentences = await supply(chapterIndex + 1) else {
                return nil
            }
            buffer = sentences
            self.chapterIndex = chapterIndex + 1
            next = 0
        }
    }

    /// The next run of sentences to say as one: a paragraph, or a heading on its own.
    ///
    /// A paragraph rather than a sentence, because a sentence is not the right size to
    /// hand a synthesiser — every utterance boundary is the audio pipeline starting over,
    /// and at one per sentence that was fifteen restarts a minute. See `SpeechReader.say`.
    ///
    /// Empty only where `take` answers nil: the end of the book.
    func takeParagraph() async -> [SpokenSentence] {
        guard let first = await take() else { return [] }
        var run = [first]
        // Only out of the buffer already in hand. Reaching past it would mean loading the
        // next chapter to find out whether its opening continues this paragraph — and it
        // never does, because a chapter starts with its own name.
        while next < buffer.count, SpeechScript.belongTogether(first, buffer[next]) {
            run.append(buffer[next])
            next += 1
        }
        return run
    }
}

/// What is being listened to, as everything outside the app has to describe it.
///
/// The lock screen, the control centre, a car's dashboard and a watch all ask the same
/// three questions — what is playing, whose is it, what does it look like — and none of
/// them can be answered from a sentence.
struct SpeechBook: Equatable {
    let id: String
    let title: String
    /// The cover as it sits on disk. Nil for a book that has none, which is a lock
    /// screen with the app's own icon on it rather than a missing picture.
    let cover: URL?
}

/// One stretch of listening: what to read, in what voice, where the words come from and
/// who to tell about them.
///
/// One value rather than seven arguments because it is one decision — the reader pressed
/// the headphones on this book, at this place, in the script and at the pace they have
/// chosen — and because everything in it is wanted again the moment any of it changes.
struct SpeechSession {
    let book: SpeechBook
    let chapterIndex: Int
    let anchor: TextAnchor
    let script: ChineseScript
    let pace: SpeechPace
    let supply: SpeechSequence.Supply
    /// Called as each sentence begins.
    ///
    /// The book's own way of remembering where the voice got to. Nothing is drawn while
    /// a phone is locked, so nothing reports a position — and without this an hour of
    /// listening would be written down as the paragraph the eye last saw.
    let note: @MainActor (SpokenSentence) -> Void
}

/// Reading the book out loud.
///
/// Owned by `AppEnvironment` rather than by the reader's view, because listening outlives
/// looking: a reader who starts a chapter and puts the phone in their pocket has left
/// every view that could have held this. The view tree tells it what to read and follows
/// what it says; it holds nothing about how a page is drawn.
///
/// What a locked phone can be read is what is already on disk. The app stays alive while
/// it is speaking, but a chapter that has not been downloaded still has to come through
/// the one `WKWebView` that carries the site's clearance cookie, and that needs a window
/// — so listening online stops at the edge of what has been loaded. See SPEC 五、不做.
@MainActor
@Observable
final class SpeechReader {
    enum State: Equatable {
        case idle
        case speaking
        /// Stopped mid-sentence, with the sentence still in the synthesiser's mouth —
        /// which is what lets resuming carry on rather than start the sentence again.
        case paused
    }

    private(set) var state = State.idle
    /// What is being said right now. The band on the page and the page that follows the
    /// voice are both this and nothing else.
    private(set) var current: SpokenSentence?
    /// Which book is being read, so a reader who opens a different one is not shown
    /// another book's sentence picked out under their words.
    private(set) var book: SpeechBook?
    /// When the voice should stop of its own accord. Nil for no timer.
    ///
    /// A moment rather than a number of minutes, because that is what it has to be to
    /// survive being asked twice: a reader who sets thirty minutes and then changes the
    /// speed has not asked for another thirty. The current sentence is always finished —
    /// cutting a voice off mid-clause is how a reader wakes up rather than falls asleep.
    var sleepsAt: Date?

    var isSpeaking: Bool { state == .speaking }

    /// How many paragraphs are handed to the synthesiser ahead of the one being said.
    ///
    /// One, which is enough for a seam nobody hears — `AVSpeechSynthesizer` speaks its
    /// queue without a gap. Deeper costs nothing to say and everything to un-say: a change
    /// of pace has to hand every queued paragraph back at the new rate.
    private static let readAhead = 1

    /// One utterance and the sentences it says.
    ///
    /// The synthesiser reports by utterance and by character offset inside it. Neither
    /// says anything about where in the book the words came from, and where in the book
    /// the voice is is the whole of what the page, the band and the stored position need.
    private struct Chunk {
        let utterance: AVSpeechUtterance
        let sentences: [SpokenSentence]
        /// Where each sentence starts inside the utterance's string, in the UTF-16 units
        /// `willSpeakRangeOfSpeechString` reports in.
        let starts: [Int]

        /// Which sentence the voice is in the middle of.
        func sentence(at offset: Int) -> SpokenSentence? {
            // The last one starting at or before the offset: the synthesiser reports a
            // word, which lands inside a sentence rather than on its head.
            guard let index = starts.lastIndex(where: { $0 <= offset }) else { return nil }
            return sentences[index]
        }
    }

    private let synthesiser = AVSpeechSynthesizer()
    /// Held strongly: `AVSpeechSynthesizer.delegate` is weak, and a delegate nobody owns
    /// is one that stops answering the moment this method returns.
    private var listener: Delegate?
    private var sequence: SpeechSequence?
    /// The paragraphs handed over and not yet finished, oldest first.
    private var queue: [Chunk] = []
    /// Whether a top-up is already in flight. Filling the queue has to await the next
    /// chapter, and every finished paragraph asks for one.
    private var filling = false
    private var pace = SpeechPace.standard
    private var script = ChineseScript.off
    /// The voice for each language, looked up once.
    ///
    /// Building one per sentence put a synchronous call into the text-to-speech stack on
    /// the main thread fifteen times a minute — measured, and the reason this exists; see
    /// `ReaderListeningProbeTests`. A book is read in two languages at the most.
    private var voices: [String: AVSpeechSynthesisVoice] = [:]
    private var note: (@MainActor (SpokenSentence) -> Void)?
    /// The cover, decoded once for the lock screen.
    private var artwork: MPMediaItemArtwork?
    /// Whether the system took the audio away rather than the reader. Only a pause this
    /// flag is set for may be undone by the system handing it back — a reader who pressed
    /// pause and then took a phone call must not find the book reading itself afterwards.
    private var pausedBySystem = false

    init() {
        let listener = Delegate(
            started: { [weak self] in self?.began($0) },
            saying: { [weak self] in self?.saying($0, at: $1) },
            finished: { [weak self] in self?.finished($0) }
        )
        self.listener = listener
        synthesiser.delegate = listener
        watchTheAudioSession()
    }

    /// Starts reading where the reader is standing.
    func start(_ session: SpeechSession) {
        stop()
        book = session.book
        script = session.script
        pace = session.pace
        note = session.note
        let sequence = SpeechSequence(supply: session.supply)
        self.sequence = sequence
        // Before the first chapter has been read off disk: the control the reader just
        // pressed has to answer for the press, and loading a chapter can take a fetch.
        state = .speaking
        beginSession()
        takeRemoteControl()
        loadArtwork(session.book.cover)
        publishNowPlaying()
        Task { @MainActor in
            // Only the book having nothing to read stops it here. A reader who pressed
            // pause while the first chapter was still being read off disk has paused —
            // stopping them instead would take the strip off the screen under their hand,
            // and `fill` is a no-op for everything but a voice that is still speaking.
            guard await sequence.begin(
                chapterIndex: session.chapterIndex, anchor: session.anchor
            ) else {
                stop()
                return
            }
            fill()
        }
    }

    /// Stops at the end of the word being said, so a sentence resumes rather than
    /// restarts. The reader pressed pause, not rewind.
    func pause() {
        guard state == .speaking else { return }
        pausedBySystem = false
        state = .paused
        synthesiser.pauseSpeaking(at: .word)
        publishNowPlaying()
    }

    func resume() {
        guard state == .paused else { return }
        pausedBySystem = false
        state = .speaking
        // Asked for again rather than assumed: an interruption that took the audio away
        // handed the session back with it, and continuing into a session this app no
        // longer holds is a voice nobody can hear.
        beginSession()
        synthesiser.continueSpeaking()
        publishNowPlaying()
        fill()
    }

    func stop() {
        let wasReading = state != .idle
        state = .idle
        current = nil
        book = nil
        note = nil
        artwork = nil
        sequence = nil
        queue = []
        // Dropped with everything else about the book: the voice a language resolves to is
        // the reader's own setting, and leaving is the moment they could have changed it.
        voices = [:]
        sleepsAt = nil
        pausedBySystem = false
        synthesiser.stopSpeaking(at: .immediate)
        guard wasReading else { return }
        publishNowPlaying()
        releaseRemoteControl()
        // Handed back rather than held: an app that keeps the session active is one that
        // stays paused over the music somebody put on after they stopped listening.
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
    }

    /// A new pace, applied to what is in the voice's mouth as well as to what follows it.
    ///
    /// An utterance's rate is fixed when it is handed to the synthesiser, so the only way
    /// to say the rest faster is to hand it over again. From the sentence being said and
    /// not from the head of the paragraph it is in the middle of — a touch of the slider
    /// must not take the reader back several sentences. That is also why the slider calls
    /// this when it is let go and not as it moves: a rate applied per drag frame would be
    /// one paragraph restarting sixty times a second.
    func setPace(_ pace: SpeechPace) {
        guard pace != self.pace else { return }
        self.pace = pace
        // Nothing to re-say while paused, and re-saying it would start the voice up
        // under a reader who has stopped it.
        guard state == .speaking else { return }
        let owed = queue.flatMap(\.sentences)
        let from = current.flatMap { owed.firstIndex(of: $0) } ?? 0
        queue = []
        synthesiser.stopSpeaking(at: .immediate)
        for run in SpeechScript.runs(of: Array(owed[from...])) { say(run) }
    }

    // MARK: - The queue

    /// Tops the synthesiser up to `readAhead` paragraphs, loading chapters as needed.
    private func fill() {
        guard state == .speaking, !filling else { return }
        filling = true
        Task { @MainActor in
            defer { filling = false }
            while state == .speaking, !hasSleptIn, queue.count <= Self.readAhead,
                  let run = await sequence?.takeParagraph(), !run.isEmpty {
                say(run)
            }
            // The book ran out under the voice. Nothing is queued, nothing is coming,
            // and a reader whose phone is in their pocket is owed the session back.
            if state == .speaking, queue.isEmpty { stop() }
        }
    }

    /// Hands one paragraph to the synthesiser as a single utterance.
    ///
    /// Not one per sentence, which is what this was. Measured over two eight-minute
    /// listening sessions with nobody touching the phone: every utterance boundary
    /// starved the audio queue, which padded it with silence and began again — fifteen
    /// times a minute at a sentence, which is the shape of a phone that will not cool
    /// down rather than of a phone that is working hard. See `ReaderListeningProbeTests`.
    private func say(_ run: [SpokenSentence]) {
        guard !run.isEmpty else { return }
        let (text, starts) = SpeechScript.spoken(run)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = Float(pace.rate)
        utterance.voice = voice(for: language(of: text))
        // A breath between paragraphs, which is where one belongs — inside a paragraph
        // the punctuation being read is already doing it. Prose read with no gap at all
        // is the one thing that makes a synthesised voice tiring to follow for an hour.
        utterance.postUtteranceDelay = 0.15
        queue.append(Chunk(utterance: utterance, sentences: run, starts: starts))
        synthesiser.speak(utterance)
    }

    /// Which language to say a sentence in.
    ///
    /// Per sentence rather than per book, because this app is read in both: a novel from
    /// a Chinese site and an English feed sit on the same shelf, and one voice reading
    /// the other's text is not a slight accent, it is unintelligible. A Han character
    /// anywhere in the sentence settles it — a Mandarin voice reads an English word
    /// inside a Chinese sentence far better than the reverse.
    private func language(of text: String) -> String {
        guard text.unicodeScalars.contains(where: ChineseText.isHan) else {
            return AVSpeechSynthesisVoice.currentLanguageCode()
        }
        return script.spokenLanguage
    }

    private func voice(for language: String) -> AVSpeechSynthesisVoice? {
        if let held = voices[language] { return held }
        let found = AVSpeechSynthesisVoice(language: language)
        voices[language] = found
        return found
    }

    private func beginSession() {
        let session = AVAudioSession.sharedInstance()
        // `.playback`, which is what makes the ring switch not silence it: a phone is
        // usually held on silent, and an audiobook that plays nothing there would be
        // reported as a feature that does not work. `.spokenAudio` is what tells the
        // system this is a book rather than music — it is the difference between other
        // audio ducking under it and being stopped by it.
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
    }

    /// Whether the sleep timer has rung.
    ///
    /// Read where the next sentence would be taken rather than driven by a timer of its
    /// own: the sentence being said is always finished, and a voice that stopped in the
    /// middle of a clause is what wakes a reader up rather than letting them go.
    private var hasSleptIn: Bool {
        guard let sleepsAt else { return false }
        return sleepsAt <= Date()
    }

    // MARK: - Every screen that is not this app's

    /// What is playing, for the lock screen, the control centre and a car's dashboard.
    private func publishNowPlaying() {
        let centre = MPNowPlayingInfoCenter.default()
        guard let book else {
            centre.nowPlayingInfo = nil
            centre.playbackState = .stopped
            return
        }
        var playing: [String: Any] = [
            MPMediaItemPropertyTitle: current?.chapterTitle ?? book.title,
            MPMediaItemPropertyArtist: book.title,
            // Said to be live, which is what keeps a scrubber off the lock screen: speech
            // has no duration to seek inside, and a progress bar that cannot be dragged is
            // a control promising something it will not do.
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: state == .speaking ? 1.0 : 0.0
        ]
        if let artwork { playing[MPMediaItemPropertyArtwork] = artwork }
        centre.nowPlayingInfo = playing
        centre.playbackState = state == .speaking ? .playing : .paused
    }

    /// The cover, decoded off the main thread and published when it arrives.
    private func loadArtwork(_ file: URL?) {
        artwork = nil
        guard let file else { return }
        Task.detached(priority: .utility) {
            guard let image = UIImage(contentsOfFile: file.path) else { return }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            await MainActor.run { [weak self] in
                // A cover that arrives after the reader has closed the book belongs to
                // nothing, and publishing it would put a stopped book back on the lock
                // screen.
                guard let self, book != nil else { return }
                self.artwork = artwork
                publishNowPlaying()
            }
        }
    }

    private func takeRemoteControl() {
        let centre = MPRemoteCommandCenter.shared()
        centre.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        centre.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        // What a pair of headphones sends, and what a steering wheel sends. Handled
        // separately from the two above because the system does not promise which of
        // them a given accessory will use.
        centre.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.state == .speaking { self.pause() } else { self.resume() }
            }
            return .success
        }
        // Skipping is not offered rather than offered and ignored: a lock screen with
        // buttons that do nothing is worse than one without them, and "next" in a book
        // being read sentence by sentence has no obvious meaning to promise.
        centre.nextTrackCommand.isEnabled = false
        centre.previousTrackCommand.isEnabled = false
    }

    private func releaseRemoteControl() {
        let centre = MPRemoteCommandCenter.shared()
        centre.playCommand.removeTarget(nil)
        centre.pauseCommand.removeTarget(nil)
        centre.togglePlayPauseCommand.removeTarget(nil)
    }

    // MARK: - When the system takes the audio away

    private func watchTheAudioSession() {
        let centre = NotificationCenter.default
        centre.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] message in
            guard let raw = message.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let options = AVAudioSession.InterruptionOptions(
                rawValue: message.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            )
            Task { @MainActor in
                self?.interrupted(began: type == .began, mayResume: options.contains(.shouldResume))
            }
        }
        centre.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] message in
            guard let raw = message.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable
            else { return }
            Task { @MainActor in self?.unplugged() }
        }
    }

    /// A phone call, an alarm, another app taking the audio — and the moment it is given
    /// back.
    ///
    /// Internal rather than private, and stated as two flags rather than as a
    /// notification, so the rule can be asserted without an interruption to arrange.
    func interrupted(began: Bool, mayResume: Bool) {
        guard began else {
            // Only a voice the system itself stopped may be started again by the system
            // handing the audio back. A reader who pressed pause and then took a call did
            // not ask for their book to carry on when they hung up.
            guard pausedBySystem, mayResume else { return }
            resume()
            return
        }
        guard state == .speaking else { return }
        pause()
        pausedBySystem = true
    }

    /// The headphones came out.
    ///
    /// Reading the rest of the chapter aloud to a carriage full of strangers is the one
    /// behaviour nobody wants, and it is what happens by default. Not marked as the
    /// system's pause: nothing is going to hand this back, and going on is a tap.
    func unplugged() {
        guard state == .speaking else { return }
        pause()
    }

    // MARK: - What the synthesiser says back

    fileprivate func began(_ utterance: AVSpeechUtterance) {
        guard let chunk = queue.first(where: { $0.utterance === utterance }),
              let first = chunk.sentences.first else { return }
        // The head of the paragraph, refined to the sentence by `saying` as the voice
        // walks through it — where the voice reports one. `willSpeakRangeOfSpeechString`
        // is not promised for every voice, and a band that never moved at all would be a
        // worse answer than one that moves a paragraph at a time.
        arriveAt(first)
    }

    /// Which sentence of the paragraph is being said now.
    fileprivate func saying(_ utterance: AVSpeechUtterance, at range: NSRange) {
        guard let chunk = queue.first(where: { $0.utterance === utterance }),
              let sentence = chunk.sentence(at: range.location) else { return }
        arriveAt(sentence)
    }

    /// The voice has reached a sentence, and everything that follows it is told once.
    private func arriveAt(_ sentence: SpokenSentence) {
        // Every word of a sentence reports, and the sentence is the unit anything outside
        // here cares about.
        guard sentence != current else { return }
        let arrivedInAChapter = current?.chapterIndex != sentence.chapterIndex
        current = sentence
        // Every sentence, because this is the only record a locked phone keeps of where
        // the reader got to — `ProgressWriteRule` is what keeps it from being a database
        // write per sentence.
        note?(sentence)
        // Only per chapter: what the lock screen shows is the chapter's name, and
        // republishing it every few seconds would be a line of work per sentence for a
        // string that did not change.
        if arrivedInAChapter { publishNowPlaying() }
    }

    fileprivate func finished(_ utterance: AVSpeechUtterance) {
        guard let index = queue.firstIndex(where: { $0.utterance === utterance }) else { return }
        // Everything before it as well: a sentence can only finish after the ones handed
        // over ahead of it, and a queue that leaks entries would refuse to be topped up.
        queue.removeSubrange(0...index)
        fill()
    }

    /// The synthesiser's delegate, which is not this object.
    ///
    /// `AVSpeechSynthesizerDelegate` is an `NSObjectProtocol`, and its callbacks make no
    /// promise about which thread they arrive on. A separate object that hops onto the
    /// main actor keeps that promise in one place instead of on every observable property
    /// this class holds.
    ///
    /// Two closures rather than a reference back: the protocol is `Sendable`, so nothing
    /// stored here may be mutable, and a `weak var` pointing at the reader is exactly that.
    /// Each of them holds the reader weakly, which is the cycle the old reference was
    /// avoiding — the synthesiser is owned by the reader and holds this in its place.
    private final class Delegate: NSObject, AVSpeechSynthesizerDelegate {
        private let started: @MainActor (AVSpeechUtterance) -> Void
        private let saying: @MainActor (AVSpeechUtterance, NSRange) -> Void
        private let finished: @MainActor (AVSpeechUtterance) -> Void

        init(
            started: @escaping @MainActor (AVSpeechUtterance) -> Void,
            saying: @escaping @MainActor (AVSpeechUtterance, NSRange) -> Void,
            finished: @escaping @MainActor (AVSpeechUtterance) -> Void
        ) {
            self.started = started
            self.saying = saying
            self.finished = finished
        }

        func speechSynthesizer(
            _ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance
        ) {
            Task { @MainActor in started(utterance) }
        }

        /// Where in the utterance the voice has got to — which is what makes a paragraph
        /// safe to hand over whole. Without it the reader would be followed a paragraph
        /// at a time.
        func speechSynthesizer(
            _ synthesizer: AVSpeechSynthesizer,
            willSpeakRangeOfSpeechString characterRange: NSRange,
            utterance: AVSpeechUtterance
        ) {
            Task { @MainActor in saying(utterance, characterRange) }
        }

        func speechSynthesizer(
            _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
        ) {
            Task { @MainActor in finished(utterance) }
        }
    }
}

private extension ChineseScript {
    /// Which Mandarin to read this book in.
    ///
    /// The script the page is drawn in, because that is the text being handed to the
    /// voice. With conversion off the page is whatever the site served — mixed, often —
    /// and the device's own answer is the best guess available.
    var spokenLanguage: String {
        let spoken = depth == .off ? ChineseScript.deviceDefault : target
        return spoken == .simplified ? "zh-CN" : "zh-TW"
    }
}
