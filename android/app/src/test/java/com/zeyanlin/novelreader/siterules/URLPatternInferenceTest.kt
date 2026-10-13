package com.zeyanlin.novelreader.siterules

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The iOS `URLPatternInferenceTests`, case for case: the URL shapes of six sites whose
 * hand-written rules were verified live. If inference reproduces their behaviour here it
 * produces a working rule for a site nobody has looked at. Assertions are on behaviour (the
 * derived regexes recover the right ids), since more than one regex is correct.
 */
class URLPatternInferenceTest {
    private data class Case(
        val name: String,
        val book: String,
        val chapters: List<String>,
        val bookId: String,
        val chapterId: String,
        val bookTemplate: String,
        val chapterTemplate: String,
        /** False where chapters live under a different path prefix than book pages. */
        val bookIdReadableFromChapterURL: Boolean,
    )

    private val cases = listOf(
        Case(
            "69shuba", "https://www.69shuba.com/book/90442.htm",
            listOf("https://www.69shuba.com/txt/90442/41051913", "https://www.69shuba.com/txt/90442/41051914"),
            "90442", "41051913",
            "https://www.69shuba.com/book/{bookId}.htm", "https://www.69shuba.com/txt/{bookId}/{chapterId}", false,
        ),
        Case(
            // Real czbooks links carry a query string that must not read as the chapter id.
            "czbooks", "https://czbooks.net/n/s6ojkc",
            listOf("https://czbooks.net/n/s6ojkc/s6675fe9?chapterNumber=1", "https://czbooks.net/n/s6ojkc/z51cc7l?chapterNumber=2"),
            "s6ojkc", "s6675fe9",
            "https://czbooks.net/n/{bookId}", "https://czbooks.net/n/{bookId}/{chapterId}", true,
        ),
        Case(
            "hetubook", "https://www.hetubook.com/book/5763/index.html",
            listOf("https://www.hetubook.com/book/5763/4327466.html", "https://www.hetubook.com/book/5763/4327467.html"),
            "5763", "4327466",
            "https://www.hetubook.com/book/{bookId}/index.html", "https://www.hetubook.com/book/{bookId}/{chapterId}.html", true,
        ),
        Case(
            "hjwzw", "https://tw.hjwzw.com/Book/1889",
            listOf("https://tw.hjwzw.com/Book/Read/1889,41051", "https://tw.hjwzw.com/Book/Read/1889,41052"),
            "1889", "41051",
            "https://tw.hjwzw.com/Book/{bookId}", "https://tw.hjwzw.com/Book/Read/{bookId},{chapterId}", false,
        ),
        Case(
            "quanben5", "https://big5.quanben5.com/n/xinghedadi/",
            listOf("https://big5.quanben5.com/n/xinghedadi/29881.html", "https://big5.quanben5.com/n/xinghedadi/29882.html"),
            "xinghedadi", "29881",
            "https://big5.quanben5.com/n/{bookId}/", "https://big5.quanben5.com/n/{bookId}/{chapterId}.html", true,
        ),
        Case(
            // The underscore is part of the id, not a separator.
            "twking", "https://www.twking.org/216_216497/",
            listOf("https://www.twking.org/216_216497/12345.html", "https://www.twking.org/216_216497/12346.html"),
            "216_216497", "12345",
            "https://www.twking.org/{bookId}/", "https://www.twking.org/{bookId}/{chapterId}.html", true,
        ),
    )

    private fun inferred(case: Case) = checkNotNull(URLPatternInference.infer(case.book, case.chapters)) { case.name }

    @Test
    fun templatesMatchTheHandWrittenRules() {
        for (case in cases) {
            val inferred = inferred(case)
            assertEquals(case.name, case.bookId, inferred.bookId)
            assertEquals(case.name, case.bookTemplate, inferred.bookTemplate)
            assertEquals(case.name, case.chapterTemplate, inferred.chapterTemplate)
        }
    }

    /** Bookmarking, catalog filtering and download paths are all built on these two answers. */
    @Test
    fun derivedRegexesRecoverIdsFromRealLinks() {
        for (case in cases) {
            val rule = rule(inferred(case))
            assertEquals("${case.name}: book URL", case.bookId, rule.bookId(case.book))
            assertEquals("${case.name}: chapter URL", case.chapterId, rule.chapterId(case.chapters[0]))
            // A book page is not a chapter, or the catalog would list it as chapter one.
            assertNull("${case.name}: book URL must not read as a chapter", rule.chapterId(case.book))
            val owner = rule.bookId(case.chapters[0])
            // nil is the safe answer: the catalog only drops an entry whose owner is known and different.
            assertEquals("${case.name}: owner of chapter", if (case.bookIdReadableFromChapterURL) case.bookId else null, owner)
        }
    }

    @Test
    fun allChaptersOfABookSurviveCatalogFiltering() {
        for (case in cases) {
            val rule = rule(inferred(case))
            val ids = case.chapters.mapNotNull { rule.chapterId(it) }
            assertEquals("${case.name}: unreadable chapter links", case.chapters.size, ids.size)
            assertEquals("${case.name}: chapter ids collided", case.chapters.size, ids.toSet().size)
        }
    }

    /** The patterns are written into rule files that iOS reads, so they are escaped its way. */
    @Test
    fun patternsAreEscapedTheWayIOSEscapesThem() {
        val inferred = inferred(cases[0])
        assertEquals("\\/book\\/(\\d+)", inferred.bookIdPattern)
        assertEquals("\\/txt\\/[0-9A-Za-z_-]+\\/(\\d+)", inferred.chapterIdPattern)
    }

    @Test
    fun aSingleChapterLinkStillYieldsATemplate() {
        val inferred = assertNotNullAndGet(
            URLPatternInference.infer(
                "https://www.hetubook.com/book/5763/index.html", listOf("https://www.hetubook.com/book/5763/4327466.html"),
            ),
        )
        assertEquals("5763", inferred.bookId)
        assertEquals("https://www.hetubook.com/book/{bookId}/{chapterId}.html", inferred.chapterTemplate)
    }

    @Test
    fun noChapterLinksIsUndecidable() {
        assertNull(URLPatternInference.infer("https://example.com/book/1", emptyList()))
    }

    /** Other books' links carry none of this book's id; guessing would mix books together. */
    @Test
    fun unrelatedChapterLinksAreRejected() {
        assertNull(
            URLPatternInference.infer(
                "https://example.com/book/1234",
                listOf("https://example.com/txt/9999/1.html", "https://example.com/txt/8888/2.html"),
            ),
        )
    }

    /** mycomic's related strip is all `/comics/…`: "comics" must never become the book id. */
    @Test
    fun aStructuralWordIsNeverTheBookId() {
        assertNull(
            URLPatternInference.infer(
                "https://mycomic.com/comics/19799",
                listOf("https://mycomic.com/comics/45991", "https://mycomic.com/comics/8566", "https://mycomic.com/comics/8871"),
            ),
        )
    }

    private fun <T> assertNotNullAndGet(value: T?): T {
        assertNotNull(value)
        return value!!
    }

    private fun rule(inferred: URLPatternInference.Inferred) = SiteRule(
        id = "test", name = "test", host = "example.com",
        urls = SiteRule.UrlTemplates(inferred.bookTemplate, inferred.bookTemplate, inferred.chapterTemplate),
        idPatterns = SiteRule.IdPatterns(inferred.bookIdPattern, inferred.chapterIdPattern),
        book = SiteRule.BookFields(title = SiteRule.Field(meta = "og:title", selector = "h1")),
        catalog = SiteRule.Catalog(container = "body", linkSelector = "a", order = SiteRule.Catalog.Order.ASCENDING),
        chapter = SiteRule.Chapter(titleSelectors = listOf("h1"), contentSelectors = emptyList(), stripSelectors = emptyList()),
    )
}
