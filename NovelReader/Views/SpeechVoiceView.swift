import AVFoundation
import SwiftUI

/// Which voice reads a book out loud.
///
/// One list per language rather than one voice for the app, because the language is settled
/// per sentence — see `SpeechReader.spokenLanguages(script:)`, which is where the short list
/// of languages this device can be read in comes from.
///
/// Picking a row is the audition. Nothing here is a separate preview button: with the book
/// stopped, choosing plays a line in that voice, and with the book being read, choosing
/// changes the voice in the sentence the reader is standing in — see `SpeechReader.setVoices`.
/// A row that both chooses and demonstrates is one decision where a preview button beside
/// every row would be two, and the second one would be the one nobody presses.
struct SpeechVoiceView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var settings = ReaderSettings.shared
    @State private var audition = VoiceAudition()

    /// The one or two languages a book on this device is actually read in.
    private var languages: [String] {
        SpeechReader.spokenLanguages(script: settings.chineseScript)
    }

    var body: some View {
        Form {
            ForEach(languages, id: \.self) { section(for: $0) }
        }
        .navigationTitle("settings.speech")
        .navigationBarTitleDisplayMode(.inline)
        // A voice auditioned on the way out would go on talking over the shelf.
        .onDisappear { audition.stop() }
    }

    private func section(for language: String) -> some View {
        let key = SpeechReader.voiceKey(for: language)
        return Section {
            // The system's own answer, and first: it is what every device starts on, and a
            // reader who has tried three voices needs the way back to be a row rather than
            // a guess at which of them it was.
            row(named: Text("speech.voice.system"), voice: nil, key: key, language: language)
            ForEach(Self.voices(for: language), id: \.identifier) { voice in
                row(named: Text(verbatim: voice.name), voice: voice, key: key, language: language)
            }
        } header: {
            // The language alone, because the list is every region of it — see
            // `SpeechReader.voiceKey(for:)`. Each row says which region it is.
            Text(verbatim: Locale.current.localizedString(forLanguageCode: key) ?? key)
        } footer: {
            // Said once, under the last list: iOS ships two or three voices per language and
            // keeps the good ones behind a download, so a reader looking at a short list is
            // usually looking at a list that is short for a reason they can fix.
            if language == languages.last {
                Text("speech.voice.footer")
            }
        }
    }

    private func row(
        named name: Text, voice: AVSpeechSynthesisVoice?, key: String, language: String
    ) -> some View {
        Button {
            choose(voice, key: key, language: language)
        } label: {
            LabeledContent {
                if settings.speechVoices[key] == voice?.identifier {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            } label: {
                // Stacked explicitly rather than left as two views in a `ViewBuilder`:
                // how `LabeledContent` arranges a label of several views is its own
                // business, and a name and what is said under it have to read as one thing.
                VStack(alignment: .leading, spacing: 1) {
                    name
                    if let voice {
                        HStack(spacing: 4) {
                            // Which region, because the list mixes them: a Mainland voice
                            // reads Traditional text in Mainland pronunciation, and that is
                            // the reader's call to make knowingly.
                            Text(verbatim: Self.regionName(of: voice))
                            // The same voice is shipped at two qualities under one name,
                            // so without this the list reads as the same row twice and the
                            // better one is a coin toss.
                            if let quality = Self.qualityKey(of: voice) {
                                Text(verbatim: "·")
                                Text(quality)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            // On the label alone, not as a `tint` on the button: tinting the button
            // would take the accent colour off the checkmark too, which is the one
            // thing in the row that has to keep it.
            .foregroundStyle(.primary)
        }
        // The way back to the system's answer is the row worth being able to address.
        .accessibilityIdentifier(voice == nil ? "speech.voice.system" : "speech.voice.row")
    }

    /// Chooses a voice, and says something in it.
    ///
    /// The setting is written first and handed on in the same breath: a reader listening
    /// while they choose hears the book itself change voice, which is a better audition
    /// than any sample line — so the sample is only for a reader who has no book running.
    private func choose(_ voice: AVSpeechSynthesisVoice?, key: String, language: String) {
        settings.speechVoices[key] = voice?.identifier
        env.speech.setVoices(settings.speechVoices)
        guard env.speech.state == .idle else { return }
        audition.say(in: voice, language: language, at: settings.speechPace)
    }

    /// Every voice of the language, whatever its region: the reader's own region first,
    /// then the others region by region.
    private static func voices(for language: String) -> [AVSpeechSynthesisVoice] {
        let key = SpeechReader.voiceKey(for: language)
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { SpeechReader.voiceKey(for: $0.language) == key }
            .sorted {
                ($0.language == language ? 0 : 1, $0.language, $0.name, $0.quality.rawValue)
                    < ($1.language == language ? 0 : 1, $1.language, $1.name, $1.quality.rawValue)
            }
    }

    /// "台灣", "香港" — the region alone, since the section heading already names the
    /// language. The code itself where the system has no name for it.
    private static func regionName(of voice: AVSpeechSynthesisVoice) -> String {
        guard let region = Locale(identifier: voice.language).region?.identifier else {
            return voice.language
        }
        return Locale.current.localizedString(forRegionCode: region) ?? region
    }

    /// What to say about a voice that is not the plain one. Nil for `.default`, which is
    /// the majority and would be a badge on almost every row.
    private static func qualityKey(of voice: AVSpeechSynthesisVoice?) -> LocalizedStringKey? {
        switch voice?.quality {
        case .enhanced: return "speech.voice.enhanced"
        case .premium: return "speech.voice.premium"
        default: return nil
        }
    }
}

/// A line said in a voice the reader is trying out.
///
/// Its own synthesiser, never `SpeechReader`'s: that one is in the middle of a book, holds
/// a queue of paragraphs and a position to write down, and borrowing it to say four words
/// would lose the reader's place.
@MainActor
final class VoiceAudition {
    private let synthesiser = AVSpeechSynthesizer()

    /// A line of prose per language, written out rather than localised.
    ///
    /// These are not interface text: they are what the voice says, so they have to be in the
    /// voice's language and not in the one the app happens to be running in. A Mandarin
    /// voice handed the English line reads it letter by letter, which auditions nothing.
    /// Chinese is written in the traditional script for both Mandarins — a synthesiser says
    /// the sound, and the two scripts do not differ in one.
    private static let chinese = "他推開門。雪落在渡口的燈上。"
    private static let english = "He pushed the door open. Snow was falling on the lamp."

    /// - Parameter pace: the reader's own reading speed, so a voice is auditioned at the
    ///   speed they will actually hear it at. A sample said at the system default would
    ///   have them choosing between voices on a quality they have already overridden.
    func say(in voice: AVSpeechSynthesisVoice?, language: String, at pace: SpeechPace) {
        // The one before it is cut off rather than queued: a reader trying four voices in a
        // row wants the fourth one now, not after the other three have finished.
        synthesiser.stopSpeaking(at: .immediate)
        // The same category the book itself is read under, and for exactly the reason
        // `SpeechReader.beginSession` gives: a phone is usually held on silent, and the
        // default `.soloAmbient` is silenced by the ring switch. Without this the sample
        // plays nothing on most phones — and a reader hearing nothing concludes the voice
        // is broken, not that their ring switch is down.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
        let utterance = AVSpeechUtterance(
            string: language.hasPrefix("zh") ? Self.chinese : Self.english
        )
        // Resolved here rather than taken on trust: `nil` is the system's own answer for
        // this language, which is exactly what the row it came from promises.
        utterance.voice = voice ?? AVSpeechSynthesisVoice(language: language)
        utterance.rate = Float(pace.rate)
        synthesiser.speak(utterance)
    }

    func stop() {
        synthesiser.stopSpeaking(at: .immediate)
        // Handed back on the way out rather than held: leaving this screen must not sit on
        // the audio over whatever the reader had playing before they walked in. Only ever
        // called from `onDisappear`, and only this screen ever took the session — a book
        // being read holds its own, and choosing a voice while one is running never gets
        // as far as `say`.
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
    }
}
