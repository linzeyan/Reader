package com.zeyanlin.novelreader.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Where page breaks fall and how a reading position finds its page. A position that maps to a
 * different page than the one it was taken from moves the reader on every re-layout, which is
 * the bug a paginated reader can least afford: nothing on screen says it happened.
 */
class PageMapTest {
    /** Lines 10 tall, [perParagraph] to a paragraph, a [gap] between paragraphs, after a one-line title. */
    private fun column(paragraphs: Int, perParagraph: Int, gap: Float = 6f, titleLines: Int = 1): List<PageLine> {
        val lines = ArrayList<PageLine>()
        var y = 0f
        repeat(titleLines) { lines += PageLine(-1, it * 4, y, y + 10f).also { y += 10f } }
        y += gap
        for (p in 0 until paragraphs) {
            repeat(perParagraph) { lines += PageLine(p, it * 20, y, y + 10f).also { y += 10f } }
            y += gap
        }
        return lines
    }

    @Test
    fun aPageEndsAtTheFirstLineThatWouldNotFit() {
        // Title 0–10, paragraph 0 at 16–46, paragraph 1 at 52–82: a 50-tall page holds the
        // title and paragraph 0, and paragraph 1's first line (bottom 62) starts page two.
        val map = PageMap(column(paragraphs = 3, perParagraph = 3), height = 50f)
        assertEquals(1 to 0, map.anchor(1))
        assertEquals(52f, map.top(1))
        // Drawn no further than the page, nor than where the next one starts.
        assertEquals(50f, map.bottom(0))
    }

    /** Breaks fall between lines, not only between paragraphs, or a long paragraph leaves a one-line page. */
    @Test
    fun aLongParagraphIsSplitAcrossPages() {
        val map = PageMap(column(paragraphs = 1, perParagraph = 12), height = 50f)
        assertEquals(0 to 60, map.anchor(1)) // title + gap + 3 lines fit; line 4 of the paragraph opens page two
        assertEquals(3, map.count)
    }

    @Test
    fun aLineTallerThanThePageStillGetsAPageAndTheRestFollows() {
        val lines = listOf(PageLine(-1, 0, 0f, 10f), PageLine(0, 0, 10f, 200f), PageLine(1, 0, 200f, 210f))
        val map = PageMap(lines, height = 50f)
        assertEquals(3, map.count)
        assertEquals(listOf(-1 to 0, 0 to 0, 1 to 0), (0 until map.count).map { map.anchor(it) })
    }

    /** Every page's own anchor must lead back to it — including a page of nothing but title. */
    @Test
    fun everyPagesAnchorFindsThatPage() {
        for (lines in listOf(column(5, 7), column(1, 40), column(3, 2, titleLines = 6))) {
            val map = PageMap(lines, height = 45f)
            for (page in 0 until map.count) {
                val (p, o) = map.anchor(page)
                assertEquals("page $page of ${map.count}", page, map.pageOf(p, o))
            }
        }
    }

    @Test
    fun aPositionInsideAPageFindsThatPage() {
        val map = PageMap(column(paragraphs = 1, perParagraph = 12), height = 50f)
        // Offset 70 sits inside the line that starts at 60, the first line of page two.
        assertEquals(1, map.pageOf(0, 70))
        assertEquals(0, map.pageOf(0, 0))
        assertEquals("past the end is the last page", map.count - 1, map.pageOf(9, 0))
        assertEquals("the chapter's top is the first page", 0, map.pageOf(-1, 0))
    }

    /**
     * A page that turns itself waits as long as its text takes to read, so a chapter's last page —
     * usually a few lines — must be worth those lines, or the reader watches nothing happen for a page's time.
     */
    @Test
    fun theLastPageIsWorthOnlyTheTextOnIt() {
        // Title and gap, then 14 lines: pages of four or five lines, and a last page of one.
        val map = PageMap(column(paragraphs = 1, perParagraph = 14), height = 50f)
        assertEquals(10f, map.filled(map.count - 1))
        for (page in 0 until map.count - 1) assertEquals(map.bottom(page) - map.top(page), map.filled(page))
    }

    @Test
    fun onlyTheLastPageHasNoEnd() {
        val map = PageMap(column(paragraphs = 4, perParagraph = 4), height = 50f)
        for (page in 0 until map.count - 1) assertEquals(map.anchor(page + 1), map.end(page)!!.let { it.paragraph to it.offset })
        assertNull(map.end(map.count - 1))
    }
}
