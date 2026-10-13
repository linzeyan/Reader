package com.zeyanlin.novelreader.services

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The iOS `SentenceRulesTests` and `SpeechTests`. What a listener sees — the band, the page that
 * keeps up, the position written down with the phone locked — is a sentence's anchor, so the
 * script is a claim about where each sentence is, and one character out puts all of that in the
 * wrong place. And walking a paragraph must say every word once: a rule that drops a clause is a
 * book that skips a line out loud with nothing on screen to say so.
 */
class SpeechTest {
    private val off = ChineseScript(ChineseScript.Depth.OFF, ChineseScript.Target.TRADITIONAL)
    private val paragraphs = listOf("他推開門。雪落在渡口的燈上。", "船還沒有來。")

    private fun split(paragraph: String) = SentenceRules.sentences(paragraph).map { paragraph.substring(it.start, it.end) }

    private fun script(paragraphs: List<String>, chapter: Int = 0, title: String = "第一章　渡口", chinese: ChineseScript = off) =
        SpeechScript.sentences(chapter, "c$chapter", title, paragraphs, chinese)

    private suspend fun drain(sequence: SpeechSequence) = buildList { while (true) add(sequence.take()?.text ?: break) }

    @Test
    fun sentencesEndAfterTheirStopAndTheBracketThatClosesThem() {
        assertEquals(listOf("他推開門。", "雪落在渡口的燈上。", "船還沒有來。"), split("他推開門。雪落在渡口的燈上。船還沒有來。"))
        assertEquals(listOf("她說：「船要來了。」", "他沒有回答。"), split("她說：「船要來了。」他沒有回答。"))
        assertEquals(listOf("渡口的燈還亮著"), split("渡口的燈還亮著"))
        // Silence is not a sentence, and an indent is not part of one.
        assertEquals(listOf("好。", "他走了。"), split("好。……！？　他走了。"))
        assertEquals(emptyList<String>(), split("　 \n "))
        assertEquals(listOf("他推開門。"), split("　　他推開門。"))
    }

    @Test
    fun walkingAParagraphSaysEveryWordOnceAndInOrder() {
        val text = "「你真的要走？」她問。他點頭，說：「明天。」雪還在下……渡口沒有人"
        var reach = 0
        for (range in SentenceRules.sentences(text)) {
            assertTrue("ran back over the sentence before", range.start >= reach)
            val skipped = text.substring(reach, range.start)
            assertTrue("never said: $skipped", skipped.all { it.isWhitespace() || it.category.name.endsWith("PUNCTUATION") })
            reach = range.end
        }
        assertEquals("stopped short of the paragraph", text.length, reach)
        // Inside the paragraph asked about, never reaching into its neighbour.
        val chapter = "第一段。還有一句。\n第二段。"
        assertEquals(listOf(Span(10, 14)), SentenceRules.sentences(chapter, 9, chapter.length))
    }

    @Test
    fun aChapterIsItsTitleThenItsSentencesEachAtItsAnchor() {
        val sentences = script(paragraphs)
        assertEquals(listOf("第一章　渡口", "他推開門。", "雪落在渡口的燈上。", "船還沒有來。"), sentences.map { it.text })
        assertEquals(listOf(true, false, false, false), sentences.map { it.isTitle })
        assertEquals(listOf(TextAnchor(0, 0), TextAnchor(0, 0), TextAnchor(0, 5), TextAnchor(1, 0)), sentences.map { it.anchor })
        assertEquals("the heading marks no text", 0, sentences.first().range.let { it.end - it.start })
        assertEquals(listOf("第一章　渡口"), script(listOf("", "   ")).map { it.text })
    }

    // ChineseText keeps every length; the day it stops, every band and stored position in the
    // other script lands characters away from the words it names.
    @Test
    fun theOtherScriptSaysOtherCharactersInTheSamePlaces() {
        val text = listOf("他讀鬥羅大陸。書還沒有翻開。")
        val hant = script(text, chinese = ChineseScript(ChineseScript.Depth.CHARACTERS, ChineseScript.Target.TRADITIONAL))
        val hans = script(text, chinese = ChineseScript(ChineseScript.Depth.CHARACTERS, ChineseScript.Target.SIMPLIFIED))
        assertEquals(hant.map { it.range }, hans.map { it.range })
        assertNotEquals("the conversion really happened", hant.map { it.text }, hans.map { it.text })
    }

    @Test
    fun runsGatherShortParagraphsButNeverAHeadingAnotherLanguageOrHalfAParagraph() {
        assertEquals(
            listOf(listOf("第一章　渡口"), listOf("他推開門。", "雪落在渡口的燈上。", "船還沒有來。")),
            SpeechScript.runs(script(paragraphs)).map { run -> run.map { it.text } },
        )
        val short = "雪".repeat(50) + "。"
        val long = "燈。".repeat(70)
        val runs = SpeechScript.runs(script(listOf(short, short, short, short, long, short)))
        assertEquals(listOf(emptySet(), setOf(0, 1, 2), setOf(3, 4), setOf(5)), runs.map { run -> run.filter { !it.isTitle }.map { it.paragraph }.toSet() })
        assertEquals("the long paragraph goes whole", 71, runs[2].size)
        assertEquals(
            listOf(listOf("第一章　渡口"), listOf("他推開門。"), listOf("The ferry is late.")),
            SpeechScript.runs(script(listOf("他推開門。", "The ferry is late."))).map { run -> run.map { it.text } },
        )
    }

    // What turns "the voice is at unit 15 of this utterance" back into a place in the book.
    @Test
    fun aRunIsSaidAsItsSentencesWithItsParagraphBreaksCounted() {
        assertEquals("他推開門。雪落在渡口的燈上。", SpeechScript.spoken(script(listOf("　　他推開門。　　雪落在渡口的燈上。")).drop(1)).text)
        val (text, starts) = SpeechScript.spoken(script(paragraphs).drop(1))
        assertEquals("他推開門。雪落在渡口的燈上。\n船還沒有來。", text)
        assertEquals(listOf(0, 5, 15), starts)
        assertEquals("船還沒有來。", text.substring(15))
    }

    // Android refuses input over its engine's limit; cutting must lose and repeat nothing.
    @Test
    fun aRunTooLongForTheEngineIsCutBetweenSentencesOnly() {
        val run = script(listOf("燈。".repeat(70))).drop(1)
        val pieces = SpeechScript.pieces(run, 25)
        assertEquals(run, pieces.flatten())
        assertTrue(pieces.size > 1)
        assertTrue(pieces.all { SpeechScript.spoken(it).text.length <= 25 })
        assertEquals(listOf(run), SpeechScript.pieces(run, 4000))
    }

    @Test
    fun listeningStartsWhereTheReaderStands() {
        val sentences = script(paragraphs)
        assertEquals(0, SpeechScript.index(TextAnchor(0, 0), sentences))
        assertEquals("船還沒有來。", sentences[SpeechScript.index(TextAnchor(1, 0), sentences)].text)
        assertEquals("a place inside a sentence hears all of it", "雪落在渡口的燈上。", sentences[SpeechScript.index(TextAnchor(0, 8), sentences)].text)
        assertEquals(sentences.size, SpeechScript.index(TextAnchor(9, 0), sentences))
    }

    @Test
    fun theVoiceReadsOnAcrossChaptersStepsOverEmptyOnesAndStopsAtTheEnd() = runBlocking {
        val book = SpeechSequence { i ->
            when (i) {
                0 -> script(listOf("第一章的話。"), 0, "第一章")
                1 -> emptyList()
                2 -> script(listOf("第三章的話。"), 2, "第三章")
                else -> null
            }
        }
        assertTrue(book.begin(0, TextAnchor(0, 0)))
        assertEquals(listOf("第一章", "第一章的話。", "第三章", "第三章的話。"), drain(book))
        assertNull("and stays stopped", book.take())
        assertFalse(SpeechSequence { null }.begin(0, TextAnchor(0, 0)))
    }

    // Taking runs out of the book and re-saying the rest at a new pace are two callers of one rule;
    // a disagreement is a paragraph said twice or skipped the moment the slider is touched.
    @Test
    fun takingRunsTakesWhatRunsWouldGroupAndStartsWhereTheReaderIs() = runBlocking {
        val short = "雪".repeat(50) + "。"
        val chapter = script(paragraphs + listOf(short, short, short, "The ferry is late."))
        val sequence = SpeechSequence { if (it == 0) chapter else null }
        sequence.begin(0, TextAnchor(0, 0))
        val said = buildList { while (true) add(sequence.takeRun().takeIf { it.isNotEmpty() } ?: break) }
        assertEquals(SpeechScript.runs(chapter), said)
        assertTrue(said.size > 3)
        val inside = SpeechSequence { if (it == 0) script(paragraphs) else null }
        inside.begin(0, TextAnchor(0, 5))
        assertEquals(listOf("雪落在渡口的燈上。", "船還沒有來。"), inside.takeRun().map { it.text })
    }
}
