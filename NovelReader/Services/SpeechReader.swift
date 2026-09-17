import AVFoundation
import Foundation

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
}

/// Reading the book out loud.
///
/// Owned by `AppEnvironment` rather than by the reader's view, because listening outlives
/// looking: a reader who starts a chapter and puts the phone in their pocket has left
/// every view that could have held this. The view tree tells it what to read and follows
/// what it says; it holds nothing about how a page is drawn.
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
    private(set) var bookId: String?

    var isSpeaking: Bool { state == .speaking }

    /// How many sentences are handed to the synthesiser ahead of the one being said.
    ///
    /// Two, and not because one would leave a gap — `AVSpeechSynthesizer` speaks its
    /// queue without a seam. It is what a change of pace costs: the queued sentences
    /// carry the old rate and have to be said again, so the deeper the queue the more of
    /// the book jumps backwards when the slider is let go.
    private static let readAhead = 2

    private let synthesiser = AVSpeechSynthesizer()
    /// Held strongly: `AVSpeechSynthesizer.delegate` is weak, and a delegate nobody owns
    /// is one that stops answering the moment this method returns.
    private var listener: Delegate?
    private var sequence: SpeechSequence?
    /// The utterances handed over and not yet finished, oldest first, each with the
    /// sentence it says. The synthesiser reports by utterance, and an utterance on its
    /// own says nothing about where in the book it came from.
    private var queue: [(utterance: AVSpeechUtterance, sentence: SpokenSentence)] = []
    /// Whether a top-up is already in flight. Filling the queue has to await the next
    /// chapter, and every finished sentence asks for one.
    private var filling = false
    private var pace = SpeechPace.standard
    private var script = ChineseScript.off

    init() {
        let listener = Delegate()
        listener.reader = self
        self.listener = listener
        synthesiser.delegate = listener
    }

    /// Starts reading where the reader is standing.
    func start(
        bookId: String,
        chapterIndex: Int,
        anchor: TextAnchor,
        script: ChineseScript,
        pace: SpeechPace,
        supply: @escaping SpeechSequence.Supply
    ) {
        stop()
        self.bookId = bookId
        self.script = script
        self.pace = pace
        let sequence = SpeechSequence(supply: supply)
        self.sequence = sequence
        // Before the first chapter has been read off disk: the control the reader just
        // pressed has to answer for the press, and loading a chapter can take a fetch.
        state = .speaking
        beginSession()
        Task { @MainActor in
            // Only the book having nothing to read stops it here. A reader who pressed
            // pause while the first chapter was still being read off disk has paused —
            // stopping them instead would take the strip off the screen under their hand,
            // and `fill` is a no-op for everything but a voice that is still speaking.
            guard await sequence.begin(chapterIndex: chapterIndex, anchor: anchor) else {
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
        state = .paused
        synthesiser.pauseSpeaking(at: .word)
    }

    func resume() {
        guard state == .paused else { return }
        state = .speaking
        synthesiser.continueSpeaking()
        fill()
    }

    func stop() {
        let wasReading = state != .idle
        state = .idle
        current = nil
        bookId = nil
        sequence = nil
        queue = []
        synthesiser.stopSpeaking(at: .immediate)
        guard wasReading else { return }
        // Handed back rather than held: an app that keeps the session active is one that
        // stays paused over the music somebody put on after they stopped listening.
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
    }

    /// A new pace, applied to the sentence in the voice's mouth as well as to what
    /// follows it.
    ///
    /// An utterance's rate is fixed when it is handed to the synthesiser, so the only way
    /// to say the current sentence faster is to say it again. That is why the reader's
    /// slider calls this when it is let go and not as it moves: a rate applied per drag
    /// frame would be one sentence restarting sixty times a second.
    func setPace(_ pace: SpeechPace) {
        guard pace != self.pace else { return }
        self.pace = pace
        // Nothing to re-say while paused, and re-saying it would start the voice up
        // under a reader who has stopped it.
        guard state == .speaking else { return }
        let again = queue.map(\.sentence)
        queue = []
        synthesiser.stopSpeaking(at: .immediate)
        for sentence in again { say(sentence) }
    }

    // MARK: - The queue

    /// Tops the synthesiser up to `readAhead` sentences, loading chapters as needed.
    private func fill() {
        guard state == .speaking, !filling else { return }
        filling = true
        Task { @MainActor in
            defer { filling = false }
            while state == .speaking, queue.count <= Self.readAhead,
                  let sentence = await sequence?.take() {
                say(sentence)
            }
            // The book ran out under the voice. Nothing is queued, nothing is coming,
            // and a reader whose phone is in their pocket is owed the session back.
            if state == .speaking, queue.isEmpty { stop() }
        }
    }

    private func say(_ sentence: SpokenSentence) {
        let utterance = AVSpeechUtterance(string: sentence.text)
        utterance.rate = Float(pace.rate)
        utterance.voice = AVSpeechSynthesisVoice(language: language(of: sentence.text))
        // A breath between sentences. Prose read with no gap at all is the one thing
        // that makes a synthesised voice tiring to follow for an hour.
        utterance.postUtteranceDelay = 0.15
        queue.append((utterance, sentence))
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

    // MARK: - What the synthesiser says back

    fileprivate func began(_ utterance: AVSpeechUtterance) {
        guard let match = queue.first(where: { $0.utterance === utterance }) else { return }
        current = match.sentence
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
    private final class Delegate: NSObject, AVSpeechSynthesizerDelegate {
        weak var reader: SpeechReader?

        func speechSynthesizer(
            _ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance
        ) {
            Task { @MainActor in reader?.began(utterance) }
        }

        func speechSynthesizer(
            _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
        ) {
            Task { @MainActor in reader?.finished(utterance) }
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
