package com.zeyanlin.novelreader.services

import com.zeyanlin.novelreader.services.RuleDeriver.PageProbe
import com.zeyanlin.novelreader.siterules.SiteRule
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The decisions derivation makes over what the page probe found, before any rule is run. */
class RuleDeriverTest {
    private fun page(
        groups: List<PageProbe.Group> = emptyList(),
        metas: Map<String, String> = emptyMap(),
        docTitle: String = "",
        titles: List<PageProbe.TitleCandidate> = emptyList(),
        catalogLinks: List<String> = emptyList(),
        sameBookLinks: List<String> = emptyList(),
    ) = PageProbe("https://www.hetubook.com/book/5763/index.html", docTitle, metas, groups, catalogLinks, sameBookLinks, titles)

    private val book = "https://www.hetubook.com/book/5763/index.html"

    /**
     * Size alone does not decide: a book page's "you may also like" grid outnumbers the
     * chapters beside it, and choosing it would derive a rule whose catalog is other books.
     */
    @Test
    fun theClusterHoldingThisBooksChaptersWinsOverABiggerOne() {
        val related = PageProbe.Group(
            container = "div.related",
            hrefs = (1..12).map { "https://www.hetubook.com/book/${9000 + it}/index.html" },
            texts = (1..12).map { "別的書 $it" },
        )
        val chapters = PageProbe.Group(
            container = "#dir",
            hrefs = (1..6).map { "https://www.hetubook.com/book/5763/${4327465 + it}.html" } +
                // A site-wide "recently updated" link inside the same container.
                "https://www.hetubook.com/book/7777/1234567.html",
            texts = (1..6).map { "第${it}章" } + "別人的新章",
        )
        val best = RuleDeriver.bestCandidate(page(listOf(related, chapters)), book, book)!!
        assertEquals("#dir", best.group.container)
        // The foreign link is dropped here too, or the preview would count a chapter the
        // catalog will never reproduce.
        assertEquals(6, best.chapters.size)
        assertEquals("5763", best.inferred.bookId)
    }

    /** Taking the first title in the document title bookmarked one site's books as "和圖書". */
    @Test
    fun theBookTitleIsTheLongestCandidateInTheDocumentTitle() {
        val found = RuleDeriver.title(
            page(
                docTitle = "大奉打更人最新章節 - 和圖書",
                titles = listOf(
                    PageProbe.TitleCandidate("div.logo", "和圖書"),
                    PageProbe.TitleCandidate("h2.book_name", "大奉打更人"),
                ),
            ),
        )
        assertEquals("大奉打更人" to "h2.book_name", found)
        // og:novel:book_name means one thing and wins outright.
        val tagged = RuleDeriver.title(
            page(metas = mapOf("og:novel:book_name" to "青山", "og:title" to "青山最新章節免費閱讀"), docTitle = "x"),
        )
        assertEquals("青山" to null, tagged)
    }

    /** Getting the direction wrong makes chapter 1 the last entry. */
    @Test
    fun aCatalogListedNewestFirstIsReadAsDescending() {
        assertEquals(SiteRule.Catalog.Order.DESCENDING, RuleDeriver.order(listOf("第 120 章 終", "第119章", "第 3 回")))
        assertEquals(SiteRule.Catalog.Order.ASCENDING, RuleDeriver.order(listOf("1. 開端", "2. 相遇")))
        assertEquals(SiteRule.Catalog.Order.ASCENDING, RuleDeriver.order(listOf("楔子", "後記")))
    }

    @Test
    fun theShortNameDropsDeviceLabelsAndTheTopLevelDomain() {
        assertEquals("hetubook", RuleDeriver.shortName("www.hetubook.com"))
        assertEquals("quanben5", RuleDeriver.shortName("big5.quanben5.com"))
        assertEquals("czbooks", RuleDeriver.shortName("czbooks.net"))
    }

    /** Labelled catalog links first, then named pages, which are lists; numbered ones are chapters. */
    @Test
    fun followUpsTryTheCatalogBeforeTheChapters() {
        val pasted = "https://www.hetubook.com/book/5763/index.html"
        val followed = RuleDeriver.followUps(
            page(
                catalogLinks = listOf("https://www.hetubook.com/book/5763/catalog.html"),
                sameBookLinks = listOf(
                    "https://www.hetubook.com/book/5763/4327466.html",
                    "https://www.hetubook.com/book/5763/xiaoshuo.html",
                    pasted,
                    "https://www.hetubook.com/book/5763/catalog.html",
                ),
            ),
            pasted,
        )
        assertEquals(
            listOf(
                "https://www.hetubook.com/book/5763/catalog.html",
                "https://www.hetubook.com/book/5763/xiaoshuo.html",
                "https://www.hetubook.com/book/5763/4327466.html",
            ),
            followed,
        )
    }

    @Test
    fun aPageWithNoUsableClusterHasNoCandidate() {
        val small = PageProbe.Group("nav", listOf("https://www.hetubook.com/a", "https://www.hetubook.com/b"), listOf("a", "b"))
        assertNull(RuleDeriver.bestCandidate(page(listOf(small)), book, book))
    }
}
