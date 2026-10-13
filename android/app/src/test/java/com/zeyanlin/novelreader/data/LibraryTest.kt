package com.zeyanlin.novelreader.data

import com.zeyanlin.novelreader.services.BookService.CatalogEntry
import com.zeyanlin.novelreader.siterules.SiteRule
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LibraryTest {
    private val book = "site|1"

    private fun stored(id: String, index: Int, title: String = "第${id}章", addedAt: Long? = null, downloadedAt: Long? = null) =
        Chapter(Chapter.makeId(book, id), book, id, index, title, "https://x/$id", addedAt, downloadedAt)

    private fun entry(id: String, title: String = "第${id}章") = CatalogEntry(id, title, "https://x/$id")

    // The first catalog flags nothing: a book whose every chapter is new has no news in it.
    @Test
    fun onlyChaptersAfterTheFirstCatalogAreNew() {
        val first = catalogChanges(book, emptyList(), listOf(entry("1"), entry("2")), isFirstCatalog = true, now = 100)
        assertTrue(first.added.all { it.addedAt == null })

        val later = catalogChanges(book, first.added, listOf(entry("1"), entry("2"), entry("3")), isFirstCatalog = false, now = 200)
        assertEquals(listOf("3"), later.added.map { it.siteChapterId })
        assertEquals(200L, later.added.single().addedAt)
        assertTrue("unchanged chapters are not rewritten", later.changed.isEmpty())
    }

    // A refresh that finds a chapter inserted and one withdrawn must keep what the reader has:
    // the downloaded text, the new marker, and the place of every chapter that stayed.
    @Test
    fun aRefreshReindexesWithoutLosingWhatWasKept() {
        val current = listOf(stored("1", 0, downloadedAt = 5), stored("2", 1, addedAt = 7), stored("3", 2))
        val changes = catalogChanges(book, current, listOf(entry("1"), entry("9"), entry("2")), isFirstCatalog = false, now = 300)
        assertEquals(listOf("3"), changes.removed.map { it.siteChapterId })
        assertEquals(listOf("9"), changes.added.map { it.siteChapterId })
        val moved = changes.changed.single()
        assertEquals("2", moved.siteChapterId)
        assertEquals(2, moved.index)
        assertEquals(7L, moved.addedAt)
    }

    // A day, to the millisecond: "new" is a claim about recency, and a chapter that arrived
    // yesterday is simply one not reached yet. One from the first catalog was never news at all.
    @Test
    fun aChapterIsNewForADayAfterItArrives() {
        val day = Chapter.NEW_WINDOW_MS
        assertTrue(stored("1", 0, addedAt = 1_000).isMarked(SiteRule.Kind.NOVEL, null, now = 1_000 + day - 1))
        assertFalse(stored("1", 0, addedAt = 1_000).isMarked(SiteRule.Kind.NOVEL, null, now = 1_000 + day))
        assertFalse(stored("1", 0, addedAt = null).isMarked(SiteRule.Kind.COMIC, null, now = 1_000))
    }

    // Only ahead of the reader: a new chapter they have already read past is not one they are missing.
    @Test
    fun onlyChaptersPastTheReadingPositionAreNew() {
        val now = 10_000L
        fun marked(index: Int, lastRead: Int?) = stored("$index", index, addedAt = now).isMarked(SiteRule.Kind.NOVEL, lastRead, now)
        assertTrue(marked(6, lastRead = 5))
        assertFalse(marked(5, lastRead = 5))
        assertFalse(marked(4, lastRead = 5))
        // Never opened, or left in a chapter the site has dropped: everything recent is ahead.
        assertTrue(marked(0, lastRead = null))
        // A subscription asks only whether the article was read — at any age, on either side of the position.
        assertTrue(stored("a", 0).isMarked(SiteRule.Kind.FEED, lastReadIndex = 5, now))
        assertFalse(stored("b", 9, addedAt = now).copy(readAt = now).isMarked(SiteRule.Kind.FEED, null, now))
    }

    // A refresh stamps what arrived and nothing else, however the catalog moved: stamping a chapter
    // again because it shifted place would raise the badge on chapters the reader has long had.
    @Test
    fun aRefreshDoesNotMarkChaptersItAlreadyHad() {
        val day = Chapter.NEW_WINDOW_MS
        fun newIn(chapters: List<Chapter>, now: Long) = chapters.filter { it.isMarked(SiteRule.Kind.NOVEL, null, now) }.map { it.siteChapterId }
        val first = catalogChanges(book, emptyList(), listOf(entry("1"), entry("2")), isFirstCatalog = true, now = 0).added
        val second = catalogChanges(book, first, listOf(entry("1"), entry("2"), entry("3")), isFirstCatalog = false, now = day)
        val kept = first + second.added
        assertEquals(listOf("3"), newIn(kept, now = day + 1))

        // A day on, a chapter inserted near the front moves every one after it.
        val third = catalogChanges(book, kept, listOf(entry("1"), entry("9"), entry("2"), entry("3")), isFirstCatalog = false, now = 2 * day)
        val moved = third.changed.map { it.siteChapterId }.toSet()
        assertEquals(setOf("2", "3"), moved)
        val after = kept.filter { it.siteChapterId !in moved } + third.changed + third.added
        assertEquals(listOf("9"), newIn(after, now = 2 * day + 1))
    }

    // A chapter page that named the chapter in full must not be undone by the catalog's truncation.
    @Test
    fun aFullerStoredTitleSurvivesTheCatalog() {
        val current = listOf(stored("1", 0, title = "第一章 重生拒當皇家人(1)"))
        val changes = catalogChanges(book, current, listOf(entry("1", "第一章 重生")), isFirstCatalog = false, now = 1)
        assertTrue(changes.changed.isEmpty())

        val renamed = catalogChanges(book, current, listOf(entry("1", "第一章 改名了")), isFirstCatalog = false, now = 1)
        assertEquals("第一章 改名了", renamed.changed.single().title)
        assertNull(Chapter.fullerTitle("第一章", "第一章"))
    }

    // A blank name is none, so the shelf shows the site's title again rather than an empty row — the
    // full-width space a Chinese keyboard types included.
    @Test
    fun aBlankNameGivesTheTitleBack() {
        assertEquals("我的山海", Book.customName("  我的山海 "))
        assertNull(Book.customName("\u3000 "))
        val renamed = Book("s|1", "s", "1", SiteRule.Kind.NOVEL, "原名", Book.customName("\u3000"), null, null, 0, 0, null, null, null, null, null, null)
        assertEquals("原名", renamed.shownName)
    }

    @Test
    fun theShareCountsTheTitleAndNewlinesAsTheIosReaderDoes() {
        // "T\nab\ncd" is 7 characters; the start of "cd" is offset 5.
        assertEquals(0.71, chapterShare("T", listOf("ab", "cd"), paragraph = 1, offset = 0), 1e-9)
        assertEquals(1.0, chapterShare("T", listOf("ab", "cd"), paragraph = 5, offset = 99), 1e-9)
        assertEquals(0.28, chapterShare("T", listOf("ab", "cd"), paragraph = 0, offset = 0), 1e-9)
    }
}
