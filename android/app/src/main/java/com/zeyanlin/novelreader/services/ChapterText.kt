package com.zeyanlin.novelreader.services

import com.zeyanlin.novelreader.data.TextHighlight
import java.text.BreakIterator
import java.util.Locale

/** A place in a chapter: a paragraph, and a UTF-16 offset in it — the iOS `TextAnchor`. */
data class TextAnchor(val paragraph: Int, val offset: Int)

/** Characters [start, end) of a [ChapterText]. */
data class Span(val start: Int, val end: Int)

/**
 * One chapter's paragraphs as one string, joined by line breaks — the layout-free half of the
 * iOS `ChapterText`. A passage is a span of it, so the scrolling column and the page, which
 * share no drawing code, pick out, mark and copy the same characters. Built from the text as
 * shown: a script conversion keeps every length, so its anchors are the stored text's anchors.
 */
class ChapterText(val paragraphs: List<String>) {
    val text = paragraphs.joinToString("\n")
    private val starts = IntArray(paragraphs.size).also { starts ->
        var at = 0
        paragraphs.forEachIndexed { i, p ->
            starts[i] = at
            at += p.length + 1
        }
    }

    fun start(paragraph: Int) = starts[paragraph]

    /** Clamped: a stored anchor can outlive the text it named, and the right chapter's end beats refusing to open it. */
    fun offset(anchor: TextAnchor): Int {
        if (paragraphs.isEmpty()) return 0
        val i = anchor.paragraph.coerceIn(0, paragraphs.lastIndex)
        return starts[i] + anchor.offset.coerceIn(0, paragraphs[i].length)
    }

    /** Never rounds forward into the next paragraph: the separator belongs to the end of the one before. */
    fun anchor(offset: Int): TextAnchor {
        if (paragraphs.isEmpty()) return TextAnchor(0, 0)
        val i = starts.indexOfLast { it <= offset }.coerceAtLeast(0)
        return TextAnchor(i, (offset - starts[i]).coerceIn(0, paragraphs[i].length))
    }

    fun text(span: Span) = text.substring(span.start, span.end)

    fun span(highlight: TextHighlight): Span? {
        val start = offset(TextAnchor(highlight.startParagraph, highlight.startCharacterOffset))
        val end = offset(TextAnchor(highlight.endParagraph, highlight.endCharacterOffset))
        return if (end > start) Span(start, end) else null
    }

    /** The part of [span] in one paragraph, in that paragraph's own offsets; the separators stay unpainted. */
    fun inParagraph(span: Span, paragraph: Int): Span? {
        val from = maxOf(span.start - starts[paragraph], 0)
        val to = minOf(span.end - starts[paragraph], paragraphs[paragraph].length)
        return if (to > from) Span(from, to) else null
    }

    /**
     * The word holding a position, or the one mark there when it belongs to no word — what a
     * press picks out, a finger being too wide to aim at less. The platform's own word breaks,
     * which segment Chinese by dictionary, found inside the paragraph so a word never crosses
     * into the next. Null on blank: an indent or an empty line is nothing to mark.
     */
    fun word(at: Int): Span? {
        if (paragraphs.isEmpty() || at < 0) return null
        val anchor = anchor(at)
        val paragraph = paragraphs[anchor.paragraph]
        if (paragraph.isEmpty()) return null
        val words = BreakIterator.getWordInstance(Locale.TRADITIONAL_CHINESE).apply { setText(paragraph) }
        // The caret after a paragraph's last character, or the separator after it, is that character's.
        val end = words.following(minOf(anchor.offset, paragraph.length - 1))
        val span = Span(starts[anchor.paragraph] + words.previous(), starts[anchor.paragraph] + end)
        return if (text(span).isBlank()) null else span
    }

    /** A press and a slide: from the word the press began in to the word under the finger, either way. */
    fun wordSelection(from: Int, to: Int): Span? {
        if (paragraphs.isEmpty()) return null
        val lower = minOf(from, to).coerceAtLeast(0)
        val upper = maxOf(from, to).coerceAtLeast(0)
        val head = word(lower)?.start ?: lower
        val tail = word(upper)?.end ?: upper
        return if (tail > head) Span(head, tail) else null
    }

    /**
     * A grip being dragged: exactly the characters between the end held still and the caret
     * under the finger, in either order. Null for nothing worth marking — the ends meeting, or
     * only the gap between two paragraphs — so the caller keeps the last real passage.
     */
    fun caretSelection(fixed: Int, moving: Int): Span? {
        if (paragraphs.isEmpty()) return null
        val a = fixed.coerceIn(0, text.length)
        val b = moving.coerceIn(0, text.length)
        if (a == b) return null
        val span = Span(minOf(a, b), maxOf(a, b))
        return if (text(span).isBlank()) null else span
    }
}

/**
 * The part of a stored highlight in one paragraph of [length] — the iOS `range(inParagraph:)`.
 * What both renderers paint, without composing the chapter; clamped, since a re-fetched
 * chapter can come back shorter than the mark.
 */
fun TextHighlight.range(paragraph: Int, length: Int): Span? {
    if (paragraph < startParagraph || paragraph > endParagraph || length <= 0) return null
    val from = if (paragraph == startParagraph) startCharacterOffset.coerceIn(0, length) else 0
    val to = if (paragraph == endParagraph) endCharacterOffset.coerceIn(0, length) else length
    return if (to > from) Span(from, to) else null
}
