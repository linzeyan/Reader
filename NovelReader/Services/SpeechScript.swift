import Foundation

/// One sentence, as something to say out loud and as a place in the book.
///
/// Both halves matter and they are the same value on purpose: a voice that knows what it
/// is saying but not where it is cannot be followed on the page, and everything that
/// follows the voice — the band under the words, the page that scrolls itself, the
/// position written to disk when the app is taken away — is `anchor` and nothing else.
struct SpokenSentence: Equatable, Identifiable {
    /// Reading order, which is how the reader's controls and the loaded window count.
    let chapterIndex: Int
    /// What is written down, which outlives the catalog being renumbered — see
    /// `ReadingPosition`.
    let siteChapterId: String
    let paragraph: Int
    /// Where the sentence sits inside its paragraph, in the UTF-16 offsets a
    /// `TextAnchor` stores. Empty for a chapter's heading, which belongs to no paragraph.
    let range: NSRange
    /// The words, in the script the page is drawn in — see `SpeechScript.sentences`.
    let text: String
    /// A chapter's own title, announced as the voice arrives in it.
    let isTitle: Bool

    /// Where this sentence begins, in the terms everything else in the reader stores.
    var anchor: TextAnchor {
        TextAnchor(paragraph: paragraph, characterOffset: range.location)
    }

    var id: String { "\(siteChapterId)#\(paragraph)@\(range.location)#\(isTitle)" }
}

/// One chapter turned into the sentences a voice can read out.
///
/// Built from the loose paragraphs the reader model holds rather than from a laid-out
/// column, because listening must not wait for anything to be drawn: the chapter after
/// this one is asked for while the reader is still on this one, and it has no column yet.
enum SpeechScript {
    /// The chapter's sentences, in reading order, heading first.
    ///
    /// - Parameter script: the Chinese script the page is drawn in. Rendered here for
    ///   the same reason the columns are: the voice should say what the reader can see,
    ///   and at phrase depth the two scripts are not only different characters but
    ///   different words — 「鼠標」 against 「滑鼠」. The offsets survive it, because
    ///   `ChineseText.rendered` will not return a conversion that changes the length.
    static func sentences(
        chapterIndex: Int,
        siteChapterId: String,
        title: String,
        paragraphs: [String],
        script: ChineseScript
    ) -> [SpokenSentence] {
        var result: [SpokenSentence] = []
        let heading = ChineseText.rendered(title, in: script)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !heading.isEmpty {
            result.append(SpokenSentence(
                chapterIndex: chapterIndex, siteChapterId: siteChapterId,
                // Anchored at the top of the chapter, which is where a reader who is
                // being told its name is standing. An empty range marks nothing, which
                // is right: the heading is not a sentence of the text.
                paragraph: 0, range: NSRange(location: 0, length: 0),
                text: heading, isTitle: true
            ))
        }
        for (index, paragraph) in paragraphs.enumerated() {
            let rendered = ChineseText.rendered(paragraph, in: script) as NSString
            let whole = NSRange(location: 0, length: rendered.length)
            for range in SentenceRules.sentences(in: whole, of: rendered) {
                result.append(SpokenSentence(
                    chapterIndex: chapterIndex, siteChapterId: siteChapterId,
                    paragraph: index, range: range,
                    text: rendered.substring(with: range), isTitle: false
                ))
            }
        }
        return result
    }

    /// Which sentence to pick up at for a reader standing at `anchor`.
    ///
    /// The first sentence they have not read to the end of, so starting the voice never
    /// skips text — the same direction `ChapterText.anchor(atOffset:)` errs in, and for
    /// the same reason: re-hearing half a sentence is forgivable, missing one is not.
    ///
    /// Returns one past the end when the anchor sits after every sentence, which is what
    /// a chapter the reader has already finished should answer — the voice rolls on into
    /// the next one rather than reading this one again.
    static func index(forAnchor anchor: TextAnchor, in sentences: [SpokenSentence]) -> Int {
        // A reader anywhere but the very top of a chapter has long since passed its
        // heading, and being told the chapter's name in the middle of it would be the
        // voice announcing an arrival that happened ten minutes ago.
        let atChapterStart = anchor.paragraph <= 0 && anchor.characterOffset <= 0
        let found = sentences.firstIndex { sentence in
            guard !sentence.isTitle else { return atChapterStart }
            guard sentence.paragraph == anchor.paragraph else {
                return sentence.paragraph > anchor.paragraph
            }
            return NSMaxRange(sentence.range) > anchor.characterOffset
        }
        return found ?? sentences.count
    }
}
