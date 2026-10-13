package com.zeyanlin.novelreader.services

import com.zeyanlin.novelreader.data.Book
import com.zeyanlin.novelreader.data.Chapter
import com.zeyanlin.novelreader.data.ReadingBookmark
import com.zeyanlin.novelreader.data.TextHighlight
import java.time.LocalDate

/**
 * The iOS `MarksExport`: one book's marks as Markdown, for a notes app — chapters become an
 * outline, highlights quotations. A mark is placed by its chapter and by where it falls in a
 * document in reading order, never by paragraph number: that coordinate means nothing off
 * this device.
 */
class MarksExport(
    private val book: Book,
    /** The stored catalog in reading order, which is what orders the sections. */
    private val chapters: List<Chapter>,
    private val bookmarks: List<ReadingBookmark>,
    private val highlights: List<TextHighlight>,
) {
    /** A title with nothing under it looks like an export that went wrong. */
    val isEmpty get() = bookmarks.isEmpty() && highlights.isEmpty()

    /** The suffix after the cleaner, so a title at its length cap cannot eat what the file is. */
    val filename get() = "${BookExporter.filename(book.shownName)} 標記.md"

    /**
     * [today] stamps the summary as a dash-separated day in the reader's zone: a file that
     * outlives the device must not carry a date that reads differently by country.
     */
    fun text(today: LocalDate = LocalDate.now()): String {
        val blocks = mutableListOf("# ${book.shownName}")
        book.author?.trim()?.takeIf { it.isNotEmpty() }?.let { blocks += it }
        blocks += "劃線：${highlights.size} · 書籤：${bookmarks.size} · 匯出於 $today"
        for ((title, marks) in sections()) {
            blocks += "## $title"
            blocks += marks
        }
        return blocks.joinToString("\n\n") + "\n"
    }

    /**
     * Chapters with marks in catalog order, each as its finished blocks; a chapter the site
     * dropped keeps its own section at the end, in id order, since the catalog that knew its
     * place no longer lists it.
     */
    private fun sections(): List<Pair<String, List<String>>> {
        val bookmarksOf = bookmarks.groupBy { it.siteChapterId }
        val highlightsOf = highlights.groupBy { it.siteChapterId }
        fun marks(chapterId: String) = blocks(bookmarksOf[chapterId].orEmpty(), highlightsOf[chapterId].orEmpty())
        val listed = chapters.map { it.siteChapterId }.toSet()
        val dropped = (bookmarksOf.keys + highlightsOf.keys - listed).sorted()
        return chapters.map { it.title to marks(it.siteChapterId) }.filter { it.second.isNotEmpty() } +
            dropped.map { "章節已不在目錄中" to marks(it) }
    }

    /**
     * Both kinds in one run, as they meet a reader going down the chapter, in a total order —
     * start, end, then kind with the highlight first — so two exports never shuffle a pair.
     *
     * A highlight is quoted, every line, so a passage across paragraphs stays inside the quote;
     * a bookmark is labelled, because its excerpt was taken from the paragraph, not chosen. One
     * with no excerpt still goes in: dropping it would lose a mark the reader asked to take.
     */
    private fun blocks(bookmarks: List<ReadingBookmark>, highlights: List<TextHighlight>): List<String> {
        val quoted = highlights.map { h ->
            listOf(h.startParagraph, h.startCharacterOffset, h.endParagraph, h.endCharacterOffset, 0) to
                h.excerpt.split("\n").joinToString("\n") { if (it.isEmpty()) ">" else "> $it" }
        }
        val labelled = bookmarks.map { b ->
            listOf(b.paragraph, b.characterOffset, b.paragraph, b.characterOffset, 1) to
                (b.excerpt?.trim()?.takeIf { it.isNotEmpty() }?.let { "- 書籤：$it" } ?: "- 書籤")
        }
        val lexicographic = Comparator<List<Int>> { a, b -> a.zip(b).map { (x, y) -> x.compareTo(y) }.firstOrNull { it != 0 } ?: 0 }
        return (quoted + labelled).sortedWith(compareBy(lexicographic) { it.first }).map { it.second }
    }
}
