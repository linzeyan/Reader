package com.zeyanlin.novelreader.services

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The iOS `FullTextFoldingTests` and `FullTextExcerptTests`, and the scan's half of the
 * trigram tests: a result row promises these words, in the book's own script, and a tap that
 * lands on them — and the first pass may waste a read but must never lose a hit.
 */
class LibrarySearchTest {
    private val chapter = listOf("第一段沒有東西。", "蕭炎握緊手中的玄重尺，向前走去。")

    private fun FullTextExcerpt.matched() = text.substring(matchStart, matchEnd)

    // One folded form is how one scan answers both scripts, and variant spellings within one.
    @Test
    fun bothScriptsAndVariantsFoldOntoOneString() {
        assertEquals(LibrarySearch.folded("鬥破蒼穹"), LibrarySearch.folded("斗破苍穹"))
        assertEquals(LibrarySearch.folded("這裡"), LibrarySearch.folded("这裏"))
        assertEquals("plain english", LibrarySearch.folded("plain english"))
    }

    // Every hit is sliced out of the original at an offset found in its folded twin.
    @Test
    fun foldingNeverMovesAnOffset() {
        for (sample in listOf("蕭炎握緊手中的玄重尺，向前走去。", "他读的是斗破苍穹这本书。", "頭髮 鼠標 軟體 這裡著實")) {
            assertEquals(sample, sample.length, LibrarySearch.folded(sample).length)
        }
    }

    // The stored copy is the folded JSON of the paragraphs; every run of a paragraph, typed in
    // either script, quotes and backslashes included, has to be found in it.
    @Test
    fun theScanNeverLosesARunOfAParagraph() {
        val paragraphs = listOf("他說：\"不要\" \\ 走", "蕭炎握緊手中的玄重尺，向前走去")
        val stored = LibrarySearch.folded(Json.encodeToString(paragraphs))
        for (paragraph in paragraphs) {
            for (length in 2..paragraph.length) {
                for (start in 0..paragraph.length - length) {
                    val run = paragraph.substring(start, start + length)
                    assertTrue("lost $run", stored.contains(LibrarySearch.needle(run)))
                }
            }
        }
        assertTrue(stored.contains(LibrarySearch.needle("萧炎握紧")))
    }

    @Test
    fun findsTheParagraphAndOffsetTheHitIsIn() {
        val found = FullTextExcerpt.first("玄重尺", chapter)!!
        assertEquals("a jump into paragraph 0 would land a page early", 1, found.paragraph)
        assertEquals(7, found.characterOffset)
        assertEquals("玄重尺", found.matched())
        assertEquals("a short paragraph is quoted whole", chapter[1], found.text)
        assertNull(FullTextExcerpt.first("根本沒有這句", chapter))
    }

    // The reader is shown their own book, not the scan's working copy.
    @Test
    fun theQuotationIsInTheScriptTheChapterWasStoredIn() {
        val fromTraditional = FullTextExcerpt.first("鬥破蒼穹", listOf("他读的是斗破苍穹这本书。"))!!
        assertEquals("斗破苍穹", fromTraditional.matched())
        assertFalse(fromTraditional.text.contains("鬥"))
        assertEquals("鬥破蒼穹", FullTextExcerpt.first("斗破苍穹", listOf("他讀的是鬥破蒼穹這本書。"))!!.matched())
    }

    // The anchor is UTF-16, so it counts the surrogate pairs ahead of the hit.
    @Test
    fun surrogatePairsAreCountedAndNeverSplit() {
        val paragraph = "𠀀𠀁 蕭炎握緊手中的玄重尺 🗡️ 向前走去"
        val found = FullTextExcerpt.first("玄重尺", listOf(paragraph))!!
        assertEquals(paragraph.indexOf("玄重尺"), found.characterOffset)
        val filler = "雲🗡️".repeat(30)
        val cut = FullTextExcerpt.first("玄重尺", listOf(filler + "玄重尺" + filler))!!
        assertEquals("玄重尺", cut.matched())
        assertTrue("a lone surrogate in ${cut.text}", cut.text.codePoints().noneMatch { it in 0xD800..0xDFFF })
    }

    // Cut down to the sentence around the hit, saying so at each end; the anchor still names the paragraph.
    @Test
    fun aLongParagraphIsCutAroundTheHitAndSaysSo() {
        val filler = "雲".repeat(60)
        val found = FullTextExcerpt.first("玄重尺", listOf(filler + "玄重尺" + filler))!!
        assertTrue(found.text.startsWith("…") && found.text.endsWith("…"))
        assertEquals("玄重尺", found.matched())
        assertEquals("the window grew", FullTextExcerpt.CONTEXT * 2 + 3 + 2, found.text.length)
        assertEquals(60, found.characterOffset)
        assertNotNull(FullTextExcerpt.first("雲雲", listOf(filler)))
    }
}
