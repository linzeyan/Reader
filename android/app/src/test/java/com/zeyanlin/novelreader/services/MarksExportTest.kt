package com.zeyanlin.novelreader.services

import com.zeyanlin.novelreader.data.Book
import com.zeyanlin.novelreader.data.Chapter
import com.zeyanlin.novelreader.data.ReadingBookmark
import com.zeyanlin.novelreader.data.TextHighlight
import com.zeyanlin.novelreader.siterules.SiteRule
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate

/**
 * The iOS `MarksExportTests`: the document is the only copy of these passages that leaves the
 * app, so what matters is reading order, no mark silently missing, and no words put in the
 * reader's mouth.
 */
class MarksExportTest {
    private val book = Book("alpha|1", "alpha", "1", SiteRule.Kind.NOVEL, "山月記", null, "中島敦", null, 0, 0, null, null, null, null, null, null)
    private val titles = listOf("第一章 下山", "第二章 入城", "第三章 夜行")
    private val catalog = titles.mapIndexed { i, t -> Chapter(Chapter.makeId(book.id, "c$i"), book.id, "c$i", i, t, "https://e/$i", null, null) }
    private val day = LocalDate.of(2026, 9, 21)

    private fun highlight(chapter: Int, paragraph: Int, text: String, at: Long) =
        TextHighlight.make(book.id, "c$chapter", paragraph to 0, paragraph to text.length, text, at)

    private fun bookmark(chapter: Int, paragraph: Int, excerpt: String?, at: Long) =
        ReadingBookmark.make(book.id, "c$chapter", paragraph, 0, excerpt, at)

    private fun assertInOrder(parts: List<String>, text: String) {
        var from = 0
        for (part in parts) {
            val at = text.indexOf(part, from)
            assertTrue("'$part' missing or out of order in:\n$text", at >= 0)
            from = at + part.length
        }
    }

    // Made in one order, stamped in another, read in a third; a bookmark sits between two
    // highlights, which fails a document that walks the two kinds one after the other.
    @Test
    fun marksRunInReadingOrderRatherThanTheOrderTheyWereMade() {
        val marks = MarksExport(
            book, catalog,
            listOf(bookmark(0, 3, "山路很長。", 50), bookmark(1, 4, "城門在傍晚關上。", 40)),
            listOf(highlight(2, 0, "夜裡的燈。", 20), highlight(0, 5, "風也停了。", 10), highlight(0, 1, "雪停了。", 30)),
        )
        assertInOrder(
            listOf("## 第一章 下山", "雪停了。", "山路很長。", "風也停了。", "## 第二章 入城", "城門在傍晚關上。", "## 第三章 夜行", "夜裡的燈。"),
            marks.text(day),
        )
    }

    @Test
    fun theDocumentNamesTheBookTheChapterAndThePassage() {
        val text = MarksExport(book, catalog, emptyList(), listOf(highlight(1, 2, "城門在傍晚關上。", 10))).text(day)
        assertTrue(text.startsWith("# 山月記\n"))
        assertTrue(text.contains("\n中島敦\n"))
        assertInOrder(listOf("## 第二章 入城", "> 城門在傍晚關上。"), text)
        assertFalse("no heading over nothing", text.contains("第一章 下山"))
        assertTrue(text.contains("劃線：1 · 書籤：0 · 匯出於 2026-09-21"))
    }

    @Test
    fun aPassageAcrossParagraphsStaysInsideTheQuote() {
        val text = MarksExport(book, catalog, emptyList(), listOf(highlight(0, 1, "雪停了。\n風也停了。", 10))).text(day)
        assertTrue(text, text.contains("> 雪停了。\n> 風也停了。"))
    }

    // The reader chose the place, not the words taken from its paragraph.
    @Test
    fun aBookmarkIsLabelledNotQuoted() {
        val text = MarksExport(book, catalog, listOf(bookmark(0, 3, "山路很長。", 10), bookmark(0, 4, null, 11)), emptyList()).text(day)
        assertTrue(text, text.contains("\n- 書籤：山路很長。\n"))
        assertTrue("one with no excerpt still goes in", text.contains("\n- 書籤\n"))
        assertFalse(text.contains("> 山路很長。"))
    }

    @Test
    fun aMarkWhoseChapterWasDroppedIsStillCarriedLast() {
        val marks = MarksExport(book, catalog.take(2), emptyList(), listOf(highlight(2, 0, "夜裡的燈。", 20), highlight(0, 0, "雪停了。", 10)))
        assertInOrder(listOf("## 第一章 下山", "> 雪停了。", "## 章節已不在目錄中", "> 夜裡的燈。"), marks.text(day))
    }

    @Test
    fun nothingMarkedIsNothingToExport() {
        assertTrue(MarksExport(book, catalog, emptyList(), emptyList()).isEmpty)
        assertFalse(MarksExport(book, catalog, listOf(bookmark(0, 0, null, 1)), emptyList()).isEmpty)
    }

    @Test
    fun theFileIsNamedAfterTheBook() = assertEquals("山月記 標記.md", MarksExport(book, catalog, emptyList(), emptyList()).filename)
}
