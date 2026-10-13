package com.zeyanlin.novelreader.services

/**
 * Where one sentence ends and the next begins — the iOS `SentenceRules`, which is the voice's
 * rule alone: what it reads by, and what the band under the spoken words covers. Stated over a
 * string and a paragraph's range, because the voice is handed loose paragraphs before anything
 * has been laid out.
 */
object SentenceRules {
    /** `.` splits "Mr. Smith" wrongly: one breath too many costs less than a paragraph read out whole. */
    private const val TERMINATORS = "。．！？!?；;…⋯."

    /** Punctuation that belongs to the sentence it closes, so 「…。」 ends after the bracket. */
    private const val CLOSERS = "」』〉》】）)］]｝}”’\"'"

    private val PUNCTUATION = setOf(
        CharCategory.CONNECTOR_PUNCTUATION, CharCategory.DASH_PUNCTUATION, CharCategory.START_PUNCTUATION,
        CharCategory.END_PUNCTUATION, CharCategory.INITIAL_QUOTE_PUNCTUATION, CharCategory.FINAL_QUOTE_PUNCTUATION,
        CharCategory.OTHER_PUNCTUATION,
    )

    /**
     * Every sentence of the paragraph [from, to) of [text], in reading order. Sentences with no
     * words are left out: a silent utterance finishes the instant it starts, which at the foot of
     * a chapter sounds like the voice skipping ahead.
     */
    fun sentences(text: String, from: Int = 0, to: Int = text.length): List<Span> {
        val result = mutableListOf<Span>()
        var index = from
        while (index < to) {
            val finish = end(text, index, from, to)
            // `end` always steps past what it was given. Stated anyway: this walks text off the network.
            if (finish <= index) break
            // The space after the last full stop belongs to nothing; left in, the band and the
            // anchor would start on the indent 「　　他推開門。」 is how these chapters begin.
            var start = index
            while (start < finish && text[start].isWhitespace()) start++
            if (finish > start && (start until finish).any { text[it].isWord() }) result += Span(start, finish)
            index = finish
        }
        return result
    }

    /** The boundary after [offset], never leaving the paragraph; one past it, so a walk always advances. */
    private fun end(text: String, offset: Int, from: Int, to: Int): Int {
        var index = minOf(offset.coerceIn(from, to) + 1, to)
        while (index < to && !endsBefore(text, index, from, to)) index++
        return index
    }

    private fun endsBefore(text: String, index: Int, from: Int, to: Int): Boolean {
        if (index <= from || index > to) return false
        // A closer here still belongs to the sentence being closed.
        if (index < to && text[index] in CLOSERS) return false
        var scan = index - 1
        while (scan >= from && text[scan] in CLOSERS) scan--
        return scan >= from && text[scan] in TERMINATORS
    }

    private fun Char.isWord() = !isWhitespace() && category !in PUNCTUATION
}

/**
 * One sentence, as something to say and as a place in the book — the iOS `SpokenSentence`.
 * Everything that follows the voice (the band, the page that keeps up, the position written
 * down while the phone is locked) is [anchor] and nothing else.
 */
data class SpokenSentence(
    val chapterIndex: Int,
    val siteChapterId: String,
    /** Carried by every sentence, for the lock screen: nothing else there can be asked. */
    val chapterTitle: String,
    val paragraph: Int,
    /** Where it sits in its paragraph; empty for a chapter's heading, which belongs to none. */
    val range: Span,
    /** In the script the page is drawn in. */
    val text: String,
    val isTitle: Boolean,
) {
    val anchor get() = TextAnchor(paragraph, range.start)
}

/** One chapter as the sentences a voice reads, and how they are handed over — the iOS `SpeechScript`. */
object SpeechScript {
    /**
     * Heading first, then every sentence. Rendered in the reader's script, as the page is: the
     * voice should say what the reader sees, and a conversion never changes a length, so the
     * offsets are the stored text's.
     */
    fun sentences(chapterIndex: Int, siteChapterId: String, title: String, paragraphs: List<String>, script: ChineseScript): List<SpokenSentence> {
        val heading = ChineseText.rendered(title, script).trim()
        val result = mutableListOf<SpokenSentence>()
        // Anchored at the top of the chapter, where a reader being told its name is standing.
        if (heading.isNotEmpty()) result += SpokenSentence(chapterIndex, siteChapterId, heading, 0, Span(0, 0), heading, true)
        paragraphs.forEachIndexed { i, paragraph ->
            val rendered = ChineseText.rendered(paragraph, script)
            for (range in SentenceRules.sentences(rendered)) {
                result += SpokenSentence(chapterIndex, siteChapterId, heading, i, range, rendered.substring(range.start, range.end), false)
            }
        }
        return result
    }

    /**
     * How long a run may grow before the next paragraph starts its own, in UTF-16 units: about
     * thirty seconds of voice. Every utterance boundary restarts the audio, and in dialogue — a
     * line a paragraph — one per paragraph was nine restarts a minute.
     */
    const val RUN_BUDGET = 120

    /**
     * Whether [next] is said in the same utterance as [run]. The rest of a paragraph always;
     * another paragraph only while the run is short and in the same language, since the voice is
     * chosen once per utterance. A heading joins nothing.
     */
    fun continues(run: List<SpokenSentence>, next: SpokenSentence): Boolean {
        val last = run.lastOrNull() ?: return false
        if (last.isTitle || next.isTitle || last.chapterIndex != next.chapterIndex) return false
        if (last.paragraph == next.paragraph) return true
        val said = spoken(run).text
        return said.length < RUN_BUDGET && hasHan(said) == hasHan(next.text)
    }

    fun hasHan(text: String) = text.any(ChineseText::isHan)

    /** The one statement of what goes into one utterance, so taking runs and re-saying the rest agree. */
    fun runs(sentences: List<SpokenSentence>): List<List<SpokenSentence>> {
        val result = mutableListOf<MutableList<SpokenSentence>>()
        for (sentence in sentences) {
            val last = result.lastOrNull()
            if (last != null && continues(last, sentence)) last += sentence else result += mutableListOf(sentence)
        }
        return result
    }

    /** A run as the string it is said in, and where each sentence starts inside it (UTF-16). */
    data class Spoken(val text: String, val starts: List<Int>)

    /**
     * Concatenated rather than cut from the paragraph: the indent and silent punctuation between
     * sentences are not said. Paragraphs meet at a line break, which the voice takes as a pause.
     */
    fun spoken(run: List<SpokenSentence>): Spoken {
        val text = StringBuilder()
        val starts = mutableListOf<Int>()
        var previous: SpokenSentence? = null
        for (sentence in run) {
            if (previous != null && previous.paragraph != sentence.paragraph) text.append('\n')
            starts += text.length
            text.append(sentence.text)
            previous = sentence
        }
        return Spoken(text.toString(), starts)
    }

    /**
     * A run cut at sentence boundaries into pieces of at most [limit] units — Android's engines
     * refuse longer input, where iOS takes a paragraph of any length. A single sentence over the
     * limit stays whole and is the engine's to refuse.
     */
    fun pieces(run: List<SpokenSentence>, limit: Int): List<List<SpokenSentence>> {
        if (spoken(run).text.length <= limit) return listOf(run)
        val result = mutableListOf<MutableList<SpokenSentence>>()
        for (sentence in run) {
            val last = result.lastOrNull()
            if (last != null && spoken(last + sentence).text.length <= limit) last += sentence else result += mutableListOf(sentence)
        }
        return result
    }

    /**
     * Which sentence to pick up at for a reader standing at [anchor]: the first they have not read
     * to the end of — re-hearing half a sentence is forgivable, missing one is not. One past the
     * end for a chapter already finished, so the voice rolls on into the next.
     */
    fun index(anchor: TextAnchor, sentences: List<SpokenSentence>): Int {
        // Anywhere but the very top, the reader arrived long ago; announcing the chapter would say otherwise.
        val atChapterStart = anchor.paragraph <= 0 && anchor.offset <= 0
        val found = sentences.indexOfFirst { s ->
            when {
                s.isTitle -> atChapterStart
                s.paragraph != anchor.paragraph -> s.paragraph > anchor.paragraph
                else -> s.range.end > anchor.offset
            }
        }
        return if (found < 0) sentences.size else found
    }
}

/**
 * The sentences still to be said, across chapter boundaries — the iOS `SpeechSequence`, the part
 * of listening with nothing to do with audio, so it can be driven in a test without a voice.
 *
 * @param supply a chapter by reading-order index; null where the book has none or it will not
 * load, which is what ends the listening.
 */
class SpeechSequence(private val supply: suspend (Int) -> List<SpokenSentence>?) {
    private var buffer = emptyList<SpokenSentence>()
    private var next = 0
    private var chapterIndex: Int? = null

    /** Loads a chapter and stands the voice where the reader is; false when there is nothing to read. */
    suspend fun begin(chapterIndex: Int, anchor: TextAnchor): Boolean {
        val sentences = supply(chapterIndex) ?: return false
        buffer = sentences
        this.chapterIndex = chapterIndex
        next = SpeechScript.index(anchor, sentences)
        return true
    }

    /** The next sentence, crossing into the chapter below; an empty chapter is stepped over, not the end. */
    suspend fun take(): SpokenSentence? {
        while (true) {
            if (next < buffer.size) return buffer[next++]
            val index = chapterIndex ?: return null
            buffer = supply(index + 1) ?: return null
            chapterIndex = index + 1
            next = 0
        }
    }

    /**
     * The next run to say as one — see [SpeechScript.continues]. Only out of the chapter in hand:
     * a chapter starts with its own name, so the next one never continues this run.
     */
    suspend fun takeRun(): List<SpokenSentence> {
        val first = take() ?: return emptyList()
        val run = mutableListOf(first)
        while (next < buffer.size && SpeechScript.continues(run, buffer[next])) run += buffer[next++]
        return run
    }
}
