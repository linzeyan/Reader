package com.zeyanlin.novelreader.data

import com.zeyanlin.novelreader.siterules.SiteRule
import org.junit.Assert.assertEquals
import org.junit.Test

class LibraryShelfTest {
    private fun row(
        id: String, site: String, title: String = id, addedAt: Long = 0, lastReadAt: Long? = null, unread: Int = 0, author: String? = null,
    ) = ShelfRow(
        Book(
            id = "$site|$id", siteId = site, siteBookId = id, kind = SiteRule.Kind.FEED, title = title, displayName = null,
            author = author, coverURL = null, addedAt = addedAt, updatedAt = 0, lastReadSiteChapterId = null, lastReadParagraph = null,
            lastReadCharacterOffset = null, lastReadFraction = null, lastReadAt = lastReadAt, catalogUpdatedAt = null,
        ),
        chapterTitle = null, chapterIndex = null, chapterCount = 0, unread = unread,
    )

    private fun sections(rows: List<ShelfRow>, sort: LibrarySort, grouping: LibraryGrouping = LibraryGrouping.SOURCE, onlyUnread: Boolean = false) =
        shelfSections(rows, sort, grouping, onlyUnread) { it.uppercase() }

    private fun List<ShelfSection>.ids() = map { it.id to it.rows.map { row -> row.book.siteBookId } }

    /** A section as one line: id, heading, then its author groups in brackets and its loose books. */
    private fun List<ShelfSection>.shape() = map { s ->
        val groups = s.groups.joinToString("") { g -> "[${g.id} ${g.author}: ${g.rows.joinToString(" ") { it.book.siteBookId }}]" }
        "${s.id} ${s.name}: $groups${s.rows.joinToString(" ") { it.book.siteBookId }}"
    }

    // The order reaches the headings, not only the rows under them: the book read this morning
    // heads the shelf whichever source it is from, and a book never opened sorts below every one
    // that was, by when it was added.
    @Test
    fun recentlyReadOrdersTheSectionsByTheirFirstBook() {
        val rows = listOf(
            row("old", "a", addedAt = 1, lastReadAt = 10),
            row("never", "a", addedAt = 50),
            row("neverOlder", "a", addedAt = 40),
            row("today", "b", addedAt = 2, lastReadAt = 99),
        )
        assertEquals(
            listOf("b" to listOf("today"), "a" to listOf("old", "never", "neverOlder")),
            sections(rows, LibrarySort.RECENTLY_READ).ids(),
        )
        // The default, newest addition first, reorders the very same sections.
        assertEquals(listOf("a", "b"), sections(rows, LibrarySort.ADDED).map { it.id })
    }

    // As Finder files names: a number by its value, so a sequel's tenth volume does not jump its second.
    @Test
    fun titlesCountNumbersByValue() {
        val rows = listOf(row("10", "a", "第10部"), row("9", "a", "第9部"), row("2", "a", "第2部"))
        assertEquals(listOf("第2部", "第9部", "第10部"), sections(rows, LibrarySort.TITLE).single().rows.map { it.book.title })
    }

    // A filter that hides every subscription of a source hides its heading too: a named section with
    // nothing under it reads as subscriptions gone missing.
    @Test
    fun theUnreadFilterTakesEmptiedSourcesWithIt() {
        val rows = listOf(row("read", "a"), row("waiting", "b", unread = 3), row("done", "b"))
        assertEquals(listOf("b" to listOf("waiting")), sections(rows, LibrarySort.ADDED, onlyUnread = true).ids())
    }

    // Every arrangement keeps the reader's order at every level. Only an author with two books here is a
    // group — one book behind a triangle discloses nothing — and a book with no author is nobody's cohort.
    // The same author on two sites is two groups when the shelf keeps sources apart.
    @Test
    fun eachArrangementDividesTheShelfAsIosDoes() {
        val rows = listOf(
            row("A1", "a", addedAt = 5, author = "甲"),
            row("A2", "a", addedAt = 3, author = "甲 "),
            row("A3", "a", addedAt = 4, author = "乙"),
            row("A4", "a", addedAt = 1, author = "  "),
            row("B1", "b", addedAt = 6, author = "甲"),
            row("B2", "b", addedAt = 2, author = "丙"),
        )
        assertEquals(listOf("__flat__ null: B1 A1 A3 A2 B2 A4"), sections(rows, LibrarySort.ADDED, LibraryGrouping.NONE).shape())
        assertEquals(listOf("b B: B1 B2", "a A: A1 A3 A2 A4"), sections(rows, LibrarySort.ADDED, LibraryGrouping.SOURCE).shape())
        assertEquals(
            listOf("__flat__|甲 甲: B1 A1 A2", "__flat__ null: A3 B2 A4"),
            sections(rows, LibrarySort.ADDED, LibraryGrouping.AUTHOR).shape(),
        )
        val nested = sections(rows, LibrarySort.ADDED, LibraryGrouping.SOURCE_THEN_AUTHOR)
        assertEquals(listOf("b B: B1 B2", "a A: [a|甲 甲: A1 A2]A3 A4"), nested.shape())
        // The heading counts what is under it at both levels.
        assertEquals(4, nested[1].count)
    }

    // A subscription has no author: dividing feeds by one would leave them all undivided, so the half of
    // the choice that still means something is kept. Other shelves get the choice as made.
    @Test
    fun aFeedShelfKeepsTheHalfOfTheChoiceThatMeansSomething() {
        assertEquals(LibraryGrouping.NONE, LibraryGrouping.AUTHOR.on(SiteRule.Kind.FEED))
        assertEquals(LibraryGrouping.SOURCE, LibraryGrouping.SOURCE_THEN_AUTHOR.on(SiteRule.Kind.FEED))
        assertEquals(LibraryGrouping.AUTHOR, LibraryGrouping.AUTHOR.on(SiteRule.Kind.NOVEL))
    }
}
