package com.zeyanlin.novelreader.data

import android.content.SharedPreferences
import com.zeyanlin.novelreader.siterules.SiteRule
import java.text.Collator

/** The shelf's settings, per device as on iOS: view preferences, not content. Keys are iOS's. */
const val LIBRARY_SORT = "library.sort"
const val LIBRARY_GROUPING = "library.grouping"
const val ONLY_WITH_NEW_CHAPTERS = "library.onlyWithNewChapters"
const val HOME_SCREEN = "library.home"
const val DEFAULT_MEDIA_MODE = "library.defaultMediaMode"
const val RECENT_READING_COUNT = "library.recentReadingCount"

/** A medium as iOS stores one: `SiteRule.Kind`'s raw value. */
val SiteRule.Kind.raw get() = name.lowercase()

/**
 * Which shelf a launch opens on — the iOS `defaultMediaMode`. The default rather than the last one
 * used: the switch is a tap away on the shelf, and remembering it would leave this nothing to do.
 */
fun SharedPreferences.defaultMediaMode() = SiteRule.Kind.entries.firstOrNull { it.raw == getString(DEFAULT_MEDIA_MODE, null) } ?: SiteRule.Kind.NOVEL

/** Which screen a launch opens on — the iOS `HomeScreen`. [raw] is the storage key both apps write. */
enum class HomeScreen(val raw: String, val label: String) {
    /** What the app did before there was anything to choose: recent reading while it holds something unfinished. */
    AUTOMATIC("automatic", "自動"),
    RECENT("recent", "近期閱讀"),
    LIBRARY("library", "書櫃"),
    ;

    companion object {
        fun from(raw: String?) = entries.firstOrNull { it.raw == raw } ?: AUTOMATIC
    }
}

/** How many books recent reading shows, as iOS bounds it: a longer list stops answering "what was I reading". */
val RECENT_READING_RANGE = 1..15

/** Clamped on the way in: a restored backup is free to say anything, and this is a list length. */
fun SharedPreferences.recentReadingCount() = getInt(RECENT_READING_COUNT, 5).coerceIn(RECENT_READING_RANGE)

/** How the shelf orders books — the iOS `LibrarySort`. [raw] is the storage key both apps write. */
enum class LibrarySort(val raw: String, val label: String) {
    /** Newest addition first: the order the shelf had before there was anything to choose. */
    ADDED("added", "最近加入"),
    TITLE("title", "書名"),
    RECENTLY_READ("recentlyRead", "最近閱讀"),
    ;

    /** A total order, ties included: one that leaves two books equal lets a reload reshuffle them. */
    fun comparator(): Comparator<Book> = when (this) {
        ADDED -> compareByDescending<Book> { it.addedAt }.thenByDescending { it.id }
        // Digit runs padded so the collation reads them by value, as `localizedStandardCompare` does:
        // by code point 第10章 files before 第2章, and Han comes out in an order nobody reads by.
        // The same name twice is common — one novel on two sites is why the shelf groups at all.
        TITLE -> compareBy<Book, String>(Collator.getInstance()) { DIGITS.replace(it.shownName) { m -> m.value.padStart(20, '0') } }
            .thenBy { it.id }
        // A book never read has nothing to be recent about: below every one that has, in the default order.
        RECENTLY_READ -> compareBy<Book> { it.lastReadAt == null }.thenByDescending { it.lastReadAt ?: it.addedAt }.thenByDescending { it.id }
    }

    companion object {
        fun from(raw: String?) = entries.firstOrNull { it.raw == raw } ?: ADDED
    }
}

private val DIGITS = Regex("[0-9]+")

/** How the shelf divides its books — the iOS `LibraryGrouping`. [raw] is the storage key both apps write. */
enum class LibraryGrouping(val raw: String, val label: String) {
    NONE("none", "不分組"),
    /** The default, and what the shelf did before there was anything to choose. */
    SOURCE("source", "來源"),
    AUTHOR("author", "作者"),
    SOURCE_THEN_AUTHOR("sourceThenAuthor", "來源，再作者"),
    ;

    val reachesAuthors get() = this == AUTHOR || this == SOURCE_THEN_AUTHOR

    /**
     * What a shelf of [kind] is divided by — the iOS `shelfGrouping`. A subscription has no author, so
     * dividing feeds by one leaves them all undivided, which looks like the choice was never made: the
     * half of it that still means something is kept. One choice for every shelf, so it can be made on
     * a shelf that has authors.
     */
    fun on(kind: SiteRule.Kind) = when {
        kind != SiteRule.Kind.FEED || !reachesAuthors -> this
        this == SOURCE_THEN_AUTHOR -> SOURCE
        else -> NONE
    }

    companion object {
        fun from(raw: String?) = entries.firstOrNull { it.raw == raw } ?: SOURCE
    }
}

/** Books by one author inside a section — the iOS `LibraryGroup`. The same author on two sites is two groups. */
data class ShelfGroup(val id: String, val author: String, val rows: List<ShelfRow>)

/**
 * One block of the shelf — the iOS `LibrarySection`. [id] is what folding is remembered against; a
 * null [name] is the books under no heading, which cannot fold: there would be nothing to tap.
 */
data class ShelfSection(val id: String, val name: String?, val groups: List<ShelfGroup>, val rows: List<ShelfRow>) {
    /** Both levels: what the heading says it is holding. */
    val count get() = groups.sumOf { it.rows.size } + rows.size
}

const val FLAT_SECTION = "__flat__"

/**
 * The iOS `LibraryShelf.sections`. Sorted once, before dividing: groupBy keeps first appearance, so
 * every section and group stands for its first book and the reader's order reaches the headings too —
 * with 最近閱讀 chosen, the book read this morning must not sit three folded headings down. Filtered
 * first, so a source with nothing left loses its heading as well.
 */
fun shelfSections(
    rows: List<ShelfRow>, sort: LibrarySort, grouping: LibraryGrouping, onlyUnread: Boolean, sourceName: (String) -> String,
): List<ShelfSection> {
    val order = sort.comparator()
    val books = rows.filter { !onlyUnread || it.unread > 0 }.sortedWith { a, b -> order.compare(a.book, b.book) }
    return when (grouping) {
        LibraryGrouping.NONE -> loose(books)
        LibraryGrouping.SOURCE -> books.groupBy { it.book.siteId }.map { (site, rows) -> ShelfSection(site, sourceName(site), emptyList(), rows) }
        // The authors become the headings, so the top of the shelf reads the same whether it is divided by who published or who wrote.
        LibraryGrouping.AUTHOR -> divide(books, FLAT_SECTION).let { (groups, rest) ->
            groups.map { ShelfSection(it.id, it.author, emptyList(), it.rows) } + loose(rest)
        }
        LibraryGrouping.SOURCE_THEN_AUTHOR -> books.groupBy { it.book.siteId }.map { (site, rows) ->
            divide(rows, site).let { (groups, rest) -> ShelfSection(site, sourceName(site), groups, rest) }
        }
    }
}

private fun loose(rows: List<ShelfRow>) = if (rows.isEmpty()) emptyList() else listOf(ShelfSection(FLAT_SECTION, null, emptyList(), rows))

private val ShelfRow.author get() = book.author?.trim()?.takeIf { it.isNotEmpty() }

/**
 * Rows already in the reader's order, split into author groups and the rest, that order kept in both.
 * Only an author with more than one book gets a group: forty books by forty people would be forty
 * triangles with one book behind each. A book with no author is in the rest — not a cohort.
 */
private fun divide(rows: List<ShelfRow>, sectionId: String): Pair<List<ShelfGroup>, List<ShelfRow>> {
    val counts = rows.groupingBy { it.author }.eachCount()
    val (grouped, rest) = rows.partition { it.author != null && counts.getValue(it.author) > 1 }
    // Joined with '|', as a book id joins its site to its own: no section id holds one, so two sections cannot run together.
    return grouped.groupBy { it.author!! }.map { (author, books) -> ShelfGroup("$sectionId|$author", author, books) } to rest
}
