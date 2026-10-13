package com.zeyanlin.novelreader.services

import com.zeyanlin.novelreader.data.TextHighlight
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The iOS `HighlightTests`, layout-free half. A highlight is a pair of anchors drawn by two
 * renderers that share no drawing code, so what is worth catching is the two marking different
 * characters, a press picking out more or less than a word, and a mark pointing past the text.
 */
class ChapterTextTest {
    private val prose = listOf(
        "雪停了。他推開門，看見渡口的燈在雪裡亮著。像一句沒有說完的話。",
        "「你還是來了。」船夫沒有回頭。他把槳擱在膝上，等著。",
        "河面很靜",
        "第四段。第五句。第六句。",
    )
    private val text = ChapterText(prose)

    private fun highlight(text: ChapterText, span: Span): TextHighlight {
        val start = text.anchor(span.start)
        val end = text.anchor(span.end)
        return TextHighlight.make("demo|1", "1", start.paragraph to start.offset, end.paragraph to end.offset, text.text(span), 0)
    }

    /** What the scrolling column and the page each paint: the stored mark, paragraph by paragraph. */
    private fun painted(h: TextHighlight, paragraphs: List<String>) =
        paragraphs.mapIndexedNotNull { i, p -> h.range(i, p.length)?.let { p.substring(it.start, it.end) } }

    // From the end of one paragraph into the next: the tail, all between, the head, nothing outside.
    @Test
    fun aSelectionAcrossParagraphsMarksTheTailAndTheHead() {
        val h = highlight(text, text.caretSelection(text.start(0) + 21, text.start(2) + prose[2].length)!!)
        assertEquals(listOf("像一句沒有說完的話。", prose[1], prose[2]), painted(h, prose))
        assertNull("the paragraph after the passage", h.range(3, prose[3].length))
        // And a span made of a word selection round-trips through the stored anchors unchanged.
        val span = text.wordSelection(text.start(0) + 20, text.start(1) + 3)!!
        assertEquals(span, text.span(highlight(text, span)))
    }

    // A re-fetched chapter can come back shorter; the renderers take these ranges as they are.
    @Test
    fun aHighlightIsClampedToTextThatCameBackShorter() {
        val h = highlight(text, text.caretSelection(text.start(1), text.start(1) + 6)!!)
        assertTrue(h.range(1, 4)!!.end <= 4)
        assertNull("a paragraph that came back empty", h.range(1, 0))
        assertEquals(text.text.length, ChapterText(prose).offset(TextAnchor(99, 99)))
    }

    // Latin for the exact answer: its word boundaries are not a matter of dictionary.
    @Test
    fun aPressSelectsTheWordItLandsIn() {
        val latin = ChapterText(listOf("The ferryman did not look back."))
        val word = latin.word(6)!!
        assertEquals("ferryman", latin.text(word))
        assertEquals("a press that does not slide is exactly the word", word, latin.wordSelection(6, 6))
    }

    // Swept, not sampled: whatever the segmenter, a press picks something holding the finger,
    // inside its paragraph, and never runs over a full stop.
    @Test
    fun everyPositionPicksOutAWordThatContainsIt() {
        val misses = mutableListOf<String>()
        prose.forEachIndexed { i, p ->
            for (offset in text.start(i) until text.start(i) + p.length) {
                val word = text.word(offset)
                if (word == null) {
                    misses += "p$i+$offset: nothing"
                    continue
                }
                if (offset !in word.start until word.end) misses += "p$i+$offset: $word misses it"
                if (word.start < text.start(i) || word.end > text.start(i) + p.length) misses += "p$i+$offset: leaves the paragraph"
                if (text.text(word).contains("。") && word.end - word.start > 1) misses += "p$i+$offset: ${text.text(word)} runs over a full stop"
            }
        }
        assertEquals(emptyList<String>(), misses)
    }

    @Test
    fun pressingOnPunctuationOrBlankSpace() {
        assertEquals("。", text.text(text.word(text.start(3) + 3)!!))
        val blank = ChapterText(listOf("　　河面很靜", "   ", "有字"))
        assertNull("the indent", blank.word(0))
        assertNotNull("the first word after it", blank.word(2))
        assertNull("a paragraph of spaces", blank.word(blank.start(1) + 1))
        assertNull(blank.wordSelection(blank.start(1), blank.start(1)))
    }

    // Both ends of a slide are word boundaries, whichever way the finger went.
    @Test
    fun aSlideNeverSplitsAWord() {
        val first = text.start(0)
        val last = text.start(1) + prose[1].length
        for ((from, to) in listOf(first + 5 to first + 13, first + 13 to first + 5, first + 6 to last - 3)) {
            val span = text.wordSelection(from, to)!!
            assertEquals("$from→$to start", span.start, text.word(span.start)!!.start)
            assertEquals("$from→$to end", span.end, text.word(span.end - 1)!!.end)
            assertTrue(minOf(from, to) in span.start until span.end && maxOf(from, to) in span.start until span.end)
        }
    }

    // A grip moves one end a character at a time; past the other end it becomes the other end.
    @Test
    fun aGripPicksOutExactlyTheCharactersBetweenTheTwoEnds() {
        val fixed = text.start(0) + 9
        for (moving in text.start(0)..text.start(0) + prose[0].length) {
            if (moving == fixed) continue
            assertEquals(Span(minOf(fixed, moving), maxOf(fixed, moving)), text.caretSelection(fixed, moving))
        }
        val end = text.start(0) + prose[0].length
        assertNull(text.caretSelection(end, end))
        assertNull("only the separator", text.caretSelection(end, text.start(1)))
        assertEquals("past the end stops at the last character", text.text.length, text.caretSelection(text.start(3), 10_000)!!.end)
    }

    // Copying gives the whole passage with the paragraph break, which the capped excerpt is not.
    @Test
    fun copyingGivesTheWholeTextAcrossParagraphs() {
        val long = "字".repeat(400)
        val chapter = ChapterText(listOf(long, "下一段。"))
        val span = chapter.caretSelection(0, chapter.start(1) + 3)!!
        assertEquals(long + "\n下一段", chapter.text(span))
        assertTrue(highlight(chapter, span).excerpt.let { it.length < 400 && it.endsWith("…") })
    }
}
