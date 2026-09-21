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
    /// Which voice says each language, keyed by `SpeechReader.voiceKey(for:)` — see
    /// `ReaderSettings.speechVoices`. Empty for the system's own answer, which is what
    /// every device starts on.
    let voices: [String: String]
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
    /// Which voice the reader picked for each language, keyed by `voiceKey(for:)` — see
    /// `ReaderSettings.speechVoices`. An identifier rather than a voice, because it is
    /// stored across launches and a voice is a download that can be deleted between two of
    /// them; resolving it is `voice(for:)`'s job, and failing to is not an error.
    private var chosen: [String: String] = [:]
    private var note: (@MainActor (SpokenSentence) -> Void)?
    /// The cover, decoded once for the lock screen.
    private var artwork: MPMediaItemArtwork?
    /// Whether the system took the audio away rather than the reader. Only a pause this
    /// flag is set for may be undone by the system handing it back — a reader who pressed
    /// pause and then took a phone call must not find the book reading itself afterwards.
    private var pausedBySystem = false
    /// Whether the reader paused from the page itself — see `pause()`. The synthesiser
    /// holds nothing and the lock screen shows nothing, so resuming has to say the
    /// sentence again rather than continue it.
    private var putDown = false

    // What the trace counts between roll-ups — see `speechFields`.
    private var countedSince = Date()
    private var utterances = 0
    private var characters = 0
    private var voiceMisses = 0
    private var pauses = 0
    private var interruptions = 0

    /// The diagnostics trace, held because this is the one part of the app whose
    /// behaviour cannot be observed where it matters: a locked phone in a pocket draws no
    /// frames, answers no test, and is the only place the heat question is real.
    private let trace: TraceLog

    init(trace: TraceLog) {
        self.trace = trace
        let listener = Delegate(
            started: { [weak self] in self?.began($0) },
            saying: { [weak self] in self?.saying($0, at: $1) },
            finished: { [weak self] in self?.finished($0) }
        )
        self.listener = listener
        synthesiser.delegate = listener
        watchTheAudioSession()
        // Fields for the trace's five-second sample, plus a rate once a minute. See
        // `speechFields`.
        trace.watch("voice") { [weak self] in self?.speechFields() }
    }

    /// What the sample says about the voice, and once a minute what it has been costing.
    ///
    /// The rate is the whole of the heat question and five seconds is too short a window
    /// to state one — a paragraph takes twenty. So the counts accumulate and a minute's
    /// worth is handed over at a time, measured by the clock rather than by counting
    /// calls, so that changing the sample interval cannot silently change what `/min`
    /// means.
    ///
    /// Read the two rate fields together, never `utt` alone. Their product is characters
    /// read per minute, which the pace sets and which no change on this side can move:
    /// measured 9.0/min × 32 ≈ 290 chars/min over an eight-minute listen at pace 0.8. So
    /// the regression shape is the two of them moving *apart* at a constant product — the
    /// same prose cut into more pieces, which is what a sentence per utterance was, and
    /// what every utterance boundary starving the audio queue is made of. `utt` on its own
    /// says nothing, because a book of long paragraphs reads at a lower `utt` than a book
    /// of short ones with nothing wrong with either.
    ///
    /// `miss` is absolute: anything but 0 after the first minute is the voice being looked
    /// up per utterance rather than once.
    private func speechFields() -> String? {
        guard state != .idle else { return nil }
        var fields = "speak=\(state == .speaking ? 1 : 0)"
        let window = Date().timeIntervalSince(countedSince)
        guard window >= 60 else { return fields }
        let minutes = window / 60
        fields += String(format: " utt=%.1f/min", Double(utterances) / minutes)
        fields += " chars=\(utterances > 0 ? characters / utterances : 0)/utt"
        fields += " miss=\(voiceMisses) pause=\(pauses) intr=\(interruptions)"
        countedSince = Date()
        utterances = 0
        characters = 0
        voiceMisses = 0
        pauses = 0
        interruptions = 0
        return fields
    }

    /// Starts reading where the reader is standing.
    func start(_ session: SpeechSession) {
        stop()
        book = session.book
        script = session.script
        pace = session.pace
        chosen = session.voices
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

    /// The reader's own pause, pressed on the book in front of them.
    ///
    /// Puts the book down rather than holding it mid-word: the synthesiser is emptied, the
    /// lock screen is let go of and the audio handed back. A reader who stopped listening
    /// with the page open has not asked to be offered the book again from outside it, and
    /// a player left on the lock screen — reported from a device — is this app claiming a
    /// book is playing that they put down. The price is that resuming says the interrupted
    /// sentence again from its head; it also means a voice or pace chosen in between is
    /// the one that resumes.
    ///
    /// A pause from anywhere else — the lock screen, headphones, a phone call — is
    /// `holdMidWord`, because there the lock screen is where the reader resumes from.
    func pause() {
        guard state == .speaking else { return }
        pauses += 1
        pausedBySystem = false
        state = .paused
        putDown = true
        // Immediate rather than at the end of the word: the sentence is said again from
        // its head anyway, and a word still sounding is audio the session cannot be
        // handed back over.
        synthesiser.stopSpeaking(at: .immediate)
        releaseTheAudio(by: "pause")
    }

    /// Stops at the end of the word being said, so a sentence resumes rather than
    /// restarts, and leaves the book on the lock screen with a play button — which is
    /// where a pause from the lock screen, a pair of headphones or a phone call is
    /// resumed from.
    private func holdMidWord() {
        guard state == .speaking else { return }
        pauses += 1
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
        if putDown {
            putDown = false
            takeRemoteControl()
            publishNowPlaying()
            resayFromCurrent()
        } else {
            synthesiser.continueSpeaking()
            publishNowPlaying()
        }
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
        chosen = [:]
        sleepsAt = nil
        pausedBySystem = false
        let wasPutDown = putDown
        putDown = false
        synthesiser.stopSpeaking(at: .immediate)
        // A book already put down has handed everything back.
        guard wasReading, !wasPutDown else { return }
        releaseTheAudio(by: "stop")
    }

    /// Takes the book off the lock screen and hands the audio back.
    ///
    /// Handed back rather than held: an app that keeps the session active is one that
    /// stays paused over the music somebody put on after they stopped listening.
    ///
    /// Only `stop` and the reader's own `pause` get here. A trace showing `aud idle` after
    /// a pause from the lock screen would mean that changed; a trace never showing one at
    /// all means this app is sitting on the audio over somebody's music. Both are worth
    /// seeing, and neither is visible from inside the app — and a failed hand-back is the
    /// one that leaves a player on the lock screen, so it is written down too.
    private func releaseTheAudio(by reason: String) {
        let centre = MPNowPlayingInfoCenter.default()
        centre.nowPlayingInfo = nil
        centre.playbackState = .stopped
        releaseRemoteControl()
        do {
            try AVAudioSession.sharedInstance().setActive(
                false, options: .notifyOthersOnDeactivation
            )
            trace.note("aud idle by=\(reason)")
        } catch {
            trace.note("aud idle failed by=\(reason) err=\((error as NSError).code)")
        }
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
        resayFromCurrent()
    }

    /// New voices, applied to the paragraph being said as well as to the ones after it.
    ///
    /// `setPace`'s reason and `setPace`'s method: an utterance's voice, like its rate, is
    /// fixed when it is handed to the synthesiser, so the only way to say the rest of it in
    /// another voice is to hand it over again. Which also makes choosing a voice its own
    /// audition for a reader who is listening as they choose — the book itself changes
    /// voice under them, in the sentence they are on.
    func setVoices(_ voices: [String: String]) {
        guard voices != chosen else { return }
        chosen = voices
        // The resolved cache is keyed by language and not by what it was resolved from, so
        // leaving it would go on answering with the voice that was just replaced.
        self.voices = [:]
        resayFromCurrent()
    }

    /// Hands what is queued back to the synthesiser, starting at the sentence being said.
    ///
    /// The only way to change anything about how the words come out, and it starts from
    /// `current` rather than from the head of the paragraph that sentence is inside: a
    /// touch of a control must not take the reader back several sentences.
    private func resayFromCurrent() {
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
        let language = language(of: text)
        let missesBefore = voiceMisses
        utterance.voice = voice(for: language)
        utterances += 1
        characters += text.count
        // One line per utterance, which is nine a minute rather than the fifteen it used
        // to be — and the difference between those two numbers is the whole finding. The
        // roll-up states the rate; these say when, which is what tells a voice that went
        // quiet at `phase bg` from one that carried on.
        trace.note(
            "say n=\(run.count) chars=\(text.count) lang=\(language) "
                + "voice=\(voiceMisses > missesBefore ? "miss" : "hit")"
        )
        // A breath between paragraphs, which is where one belongs — inside a paragraph
        // the punctuation being read is already doing it. Prose read with no gap at all
        // is the one thing that makes a synthesised voice tiring to follow for an hour.
        utterance.postUtteranceDelay = 0.15
        queue.append(Chunk(utterance: utterance, sentences: run, starts: starts))
        // A paragraph whose chapter finished loading after the reader put the book down:
        // kept for `resume` to say, and not said now. The synthesiser is empty rather than
        // paused, so handing it this would start the voice under a reader who stopped it.
        guard !putDown else { return }
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
        // Counted, not logged here: this is the miss the cache exists to prevent, and one
        // or two of them per book is the cache working. It is the *rate* that is the
        // finding, so it belongs in the roll-up.
        voiceMisses += 1
        let found = Self.voice(for: language, chosen: chosen)
        // A line rather than a count, because unlike the miss above this is not a rate —
        // it is one fact about one device, and it is the only trace of the failure this
        // feature can actually have. A voice is a download and downloads get deleted, so
        // a reader can come back to a book that is read in a voice they did not choose,
        // with nothing on screen connecting it to the storage they cleared last week.
        // `none` is the worse half: no voice at all for this language means silence.
        if let wanted = chosen[Self.voiceKey(for: language)], found?.identifier != wanted {
            trace.note("voice gone lang=\(language) using=\(found == nil ? "none" : "other")")
        }
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
        // Reported rather than swallowed. A failure here is "pressed play, nothing
        // happened" — the one speech bug with no visible symptom to describe, because
        // everything on screen says the book is being read.
        do {
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            trace.note("aud active cat=playback mode=spokenAudio")
        } catch {
            trace.note("aud active failed err=\((error as NSError).code)")
        }
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
        // A book the reader put down is off the lock screen until they pick it up again,
        // however late its cover arrives.
        guard let book, !putDown else {
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
            Task { @MainActor in self?.holdMidWord() }
            return .success
        }
        // What a pair of headphones sends, and what a steering wheel sends. Handled
        // separately from the two above because the system does not promise which of
        // them a given accessory will use.
        centre.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.state == .speaking { self.holdMidWord() } else { self.resume() }
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
        trace.note(
            began
                ? "aud interrupt began"
                : "aud interrupt ended resume=\(pausedBySystem && mayResume ? 1 : 0)"
        )
        guard began else {
            // Only a voice the system itself stopped may be started again by the system
            // handing the audio back. A reader who pressed pause and then took a call did
            // not ask for their book to carry on when they hung up.
            guard pausedBySystem, mayResume else { return }
            resume()
            return
        }
        interruptions += 1
        guard state == .speaking else { return }
        holdMidWord()
        pausedBySystem = true
    }

    /// The headphones came out.
    ///
    /// Reading the rest of the chapter aloud to a carriage full of strangers is the one
    /// behaviour nobody wants, and it is what happens by default. Not marked as the
    /// system's pause: nothing is going to hand this back, and going on is a tap.
    func unplugged() {
        trace.note("aud route reason=oldDeviceUnavailable speaking=\(state == .speaking ? 1 : 0)")
        guard state == .speaking else { return }
        holdMidWord()
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

extension SpeechReader {
    /// Which voice says a language: the reader's own, for as long as the device still has
    /// it, and the system's answer otherwise.
    ///
    /// A voice is a download, and one removed in iOS Settings resolves to nil — so without
    /// the fallback a reader who tidied up their storage would press play on a book that
    /// says nothing, with no way to connect the silence to what they deleted. The fallback
    /// is what this app did before anybody could choose, so the worst case is the voice
    /// they used to have.
    ///
    /// Nothing is written back when a choice fails to resolve: the setting stays on disk,
    /// because the voice is usually a re-download away, and forgetting it would make
    /// deleting a voice for the afternoon cost the reader the choice for good.
    ///
    /// Separate from the cache that calls it because it is the *decision* — the cache is
    /// keyed by language and cannot tell a resolved choice from a resolved fallback, which
    /// is exactly the difference worth asserting.
    static func voice(for language: String, chosen: [String: String])
        -> AVSpeechSynthesisVoice? {
        chosen[voiceKey(for: language)].flatMap(AVSpeechSynthesisVoice.init(identifier:))
            ?? AVSpeechSynthesisVoice(language: language)
    }

    /// What a chosen voice is filed under: the language, not the region — `zh` for every
    /// Mandarin and Cantonese, `en` for every English.
    ///
    /// Not the region, for two reasons. Filed by region, a reader of Traditional text was
    /// only ever offered `zh-TW` voices — on most phones one voice at two qualities — when
    /// a Mainland voice reads the same characters. And the choice was filed under whichever
    /// Mandarin the *global* script setting named, while a book with a script setting of
    /// its own can be read in the other one, where the choice was looked up under a key it
    /// had never been written to and quietly did nothing.
    static func voiceKey(for language: String) -> String {
        String(language.prefix { $0 != "-" && $0 != "_" })
    }

    /// Every language a book on this device can be read out in, in the order a reader
    /// meets them.
    ///
    /// Two at the most, and it is the whole list a voice can usefully be chosen for — which
    /// is why the picker does not offer the seventy languages iOS has voices for. A sentence
    /// resolves to the reader's own Mandarin or, with no Han character in it, to the
    /// device's language; see `language(of:)`, whose two answers these are. One per
    /// `voiceKey`, since that is what a choice is filed under: a device whose own language
    /// is Chinese has one Chinese list, not one per script.
    ///
    /// Here rather than in the picker because `spokenLanguage` is private to this file, and
    /// a second copy of "which Mandarin" is a picker whose system row auditions a voice the
    /// reader will never hear.
    static func spokenLanguages(script: ChineseScript) -> [String] {
        var languages: [String] = []
        for language in [script.spokenLanguage, AVSpeechSynthesisVoice.currentLanguageCode()]
        where !languages.contains(where: { voiceKey(for: $0) == voiceKey(for: language) }) {
            languages.append(language)
        }
        return languages
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
