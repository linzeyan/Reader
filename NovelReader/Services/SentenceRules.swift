import Foundation

/// Where one sentence ends and the next begins.
///
/// Two things in this app read the same text a sentence at a time and ask opposite
/// questions of it: a press-and-drag grows a selection outwards from a point — "which
/// sentence is this offset inside" — while the voice works forwards through a paragraph
/// — "give me every sentence in order". Both are the same rule about punctuation, and
/// two sets of punctuation marks is how a highlight ends up covering a passage the voice
/// read out as two.
///
/// Stated over an `NSString` and a paragraph range rather than over any type that owns
/// text, because the callers own different ones: `ChapterText` holds a composed chapter,
/// and the voice is handed loose paragraphs before anything has been laid out.
enum SentenceRules {
    /// What ends a sentence.
    ///
    /// The CJK terminators this app mostly reads, plus the Latin ones. `.` is included
    /// knowing it splits "Mr. Smith" wrongly: over-splitting is recoverable — by sliding
    /// the finger further, or by one more breath in the voice — whereas a paragraph with
    /// no terminator at all can only be marked, or read out, whole.
    static let terminators = Set("。．！？!?；;…⋯.".unicodeScalars.map { UInt16($0.value) })

    /// Punctuation that belongs to the sentence it closes, so 「…。」 ends after the
    /// bracket rather than between the two marks.
    static let closers = Set("」』〉》】）)］]｝}”’\"'".unicodeScalars.map { UInt16($0.value) })

    /// The sentence boundary at or before `offset`, never leaving the paragraph.
    static func start(at offset: Int, in paragraph: NSRange, of text: NSString) -> Int {
        var index = clamp(offset, to: paragraph)
        while index > paragraph.location, !endsSentence(before: index, in: paragraph, of: text) {
            index -= 1
        }
        return index
    }

    /// The sentence boundary after `offset`, never leaving the paragraph.
    ///
    /// Starts one past the offset so that pressing *on* a full stop selects the
    /// sentence it ends rather than the one after it.
    static func end(at offset: Int, in paragraph: NSRange, of text: NSString) -> Int {
        let end = NSMaxRange(paragraph)
        var index = min(clamp(offset, to: paragraph) + 1, end)
        while index < end, !endsSentence(before: index, in: paragraph, of: text) {
            index += 1
        }
        return index
    }

    /// Every sentence of one paragraph, in reading order.
    ///
    /// Sentences with no words in them are left out. A line of 「——」 or a run of spaces
    /// between two terminators is nothing to the eye and silence to the voice, and a
    /// silent utterance is one the synthesiser finishes instantly — which at the end of a
    /// chapter reads as the voice skipping ahead.
    static func sentences(in paragraph: NSRange, of text: NSString) -> [NSRange] {
        var result: [NSRange] = []
        var index = paragraph.location
        while index < NSMaxRange(paragraph) {
            let finish = end(at: index, in: paragraph, of: text)
            // `end` always steps at least one character past what it was given, so the
            // loop cannot stand still. Stated anyway: this walks text off the network.
            guard finish > index else { break }
            // The space after the last full stop belongs to nothing. Left in, it would put
            // the head of the band a character to the left of the first word and make the
            // anchor a sentence starts at point at whitespace — 「　　他推開門。」 is how a
            // great many of these chapters are indented.
            let start = firstWord(from: index, through: finish, of: text)
            let range = NSRange(location: start, length: finish - start)
            if range.length > 0, hasWords(range, of: text) { result.append(range) }
            index = finish
        }
        return result
    }

    /// Whether a sentence finishes immediately before `index`.
    private static func endsSentence(
        before index: Int, in paragraph: NSRange, of text: NSString
    ) -> Bool {
        let end = NSMaxRange(paragraph)
        guard index > paragraph.location, index <= end else { return false }
        // A closer sitting at this position still belongs to the sentence being closed,
        // so the boundary is on the far side of it.
        if index < end, closers.contains(text.character(at: index)) { return false }
        var scan = index - 1
        while scan >= paragraph.location, closers.contains(text.character(at: scan)) {
            scan -= 1
        }
        guard scan >= paragraph.location else { return false }
        return terminators.contains(text.character(at: scan))
    }

    /// The first position in a range that is not whitespace.
    private static func firstWord(from: Int, through: Int, of text: NSString) -> Int {
        var index = from
        let blank = CharacterSet.whitespacesAndNewlines
        while index < through,
              let scalar = Unicode.Scalar(text.character(at: index)), blank.contains(scalar) {
            index += 1
        }
        return index
    }

    private static func hasWords(_ range: NSRange, of text: NSString) -> Bool {
        text.rangeOfCharacter(
            from: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).inverted,
            options: [], range: range
        ).location != NSNotFound
    }

    private static func clamp(_ offset: Int, to paragraph: NSRange) -> Int {
        min(max(offset, paragraph.location), NSMaxRange(paragraph))
    }
}
