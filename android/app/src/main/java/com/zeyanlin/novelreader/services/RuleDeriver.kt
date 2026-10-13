package com.zeyanlin.novelreader.services

import com.zeyanlin.novelreader.network.WebFetcher
import com.zeyanlin.novelreader.siterules.ExtractorScript
import com.zeyanlin.novelreader.siterules.SiteRule
import com.zeyanlin.novelreader.siterules.URLPatternInference
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import java.net.URI

/**
 * Builds a [SiteRule] for a site nobody has written one for, from one pasted book URL — the
 * iOS `RuleDeriver`, whose comments carry the reasoning behind every step. The probes it runs
 * in the page are generated from that file (`scripts/extract_js.py`).
 *
 * The derivation is a guess, so it ends by running the derived rule against a real chapter
 * and handing back what it read as the preview.
 */
class RuleDeriver(private val fetcher: WebFetcher, private val installed: List<SiteRule>) {
    sealed class DeriveError(message: String) : Exception(message) {
        class BadURL : DeriveError("這不是一個可用的網址。")
        class AlreadyCovered(val name: String) :
            DeriveError("這個網站已經有來源「$name」。請直接從書櫃加書，或先移除那個來源。")
        class NoChapterLinks : DeriveError("在這一頁找不到章節清單。請改貼書籍頁或目錄頁的網址。")
        class NoTitle : DeriveError("讀不出書名，這一頁可能不是書籍頁。")
        class EmptyChapter : DeriveError("章節內容抓不到文字，這個站台目前無法自動建立規則。")
    }

    /** What the reader is asked to confirm, in terms they can check against the page. */
    data class Preview(
        val bookTitle: String,
        val author: String?,
        val chapterCount: Int,
        val firstChapterTitle: String?,
        val evidence: Evidence,
        val warnings: List<String>,
    ) {
        sealed interface Evidence {
            data class Text(val excerpt: String) : Evidence
            data class Pages(val count: Int, val first: String) : Evidence
        }
    }

    data class Draft(val rule: SiteRule, val preview: Preview)

    suspend fun derive(pastedURL: String): Draft {
        val uri = runCatching { URI(pastedURL) }.getOrNull()
        val host = uri?.host
        if (host == null || uri.scheme?.startsWith("http") != true) throw DeriveError.BadURL()
        // Before anything is fetched: a second rule for a site that has one splits it in two.
        installed.firstOrNull { it.matches(pastedURL) }?.let { throw DeriveError.AlreadyCovered(it.name) }

        val bookToken = URLPatternInference.identifierTokens(pastedURL).firstOrNull() ?: ""
        val probe = pageProbe(bookToken)
        val bookPage = fetcher.fetch(pastedURL, probe, PageProbe.serializer())

        // The catalog is rarely the page pasted, so the pages it points at are tried too and
        // the cluster listing the most chapters wins.
        var best = bestCandidate(bookPage, pastedURL, pastedURL)
        if ((best?.chapters?.size ?: 0) < COMPLETE_CATALOG_THRESHOLD) {
            for (followed in followUps(bookPage, pastedURL).take(2)) {
                val page = try {
                    fetcher.fetch(followed, probe, PageProbe.serializer())
                } catch (e: WebFetcher.FetchError) {
                    // A challenge must reach the reader; a dead link must not end the search.
                    if (e is WebFetcher.FetchError.ChallengePresented) throw e
                    continue
                }
                val candidate = bestCandidate(page, pastedURL, followed)
                if (candidate != null && candidate.chapters.size > (best?.chapters?.size ?: 0)) best = candidate
                if ((best?.chapters?.size ?: 0) >= COMPLETE_CATALOG_THRESHOLD) break
            }
        }
        val found = best ?: throw DeriveError.NoChapterLinks()
        val chapters = found.chapters
        val order = order(chapters.map { it.second })
        val reading = if (order == SiteRule.Catalog.Order.DESCENDING) chapters.asReversed() else chapters
        val firstChapter = reading.firstOrNull() ?: throw DeriveError.NoChapterLinks()

        val title = title(bookPage) ?: throw DeriveError.NoTitle()
        val catalogTemplate = URLPatternInference.template(found.catalogURL, found.inferred.bookId)
        val catalogContainer = found.group.container ?: "body"
        val author = bookPage.metas["og:novel:author"]
        val firstTitle = firstChapter.second.ifEmpty { null }

        // A catalog can open on a notice with no text (czbooks put a 「錯誤章」 first in 2026-10),
        // so the next chapters get their turn before the site is given up on, as on iOS.
        for ((sampleURL, _) in reading.take(SAMPLE_CHAPTERS)) {
            val chapterProbe = fetcher.fetch(sampleURL, CHAPTER_PROBE, ChapterProbe.serializer())

            // Comics first, and the run of page images is the whole test (see iOS).
            val images = chapterProbe.images
            if (images != null && images.count >= COMIC_PAGE_FLOOR) {
                val rule = assemble(host, found.inferred, catalogTemplate, catalogContainer, order, bookPage, title.second, null, images)
                val pages = fetcher.fetch(
                    sampleURL, ExtractorScript.comicImages(rule), ExtractorScript.ComicImagesPayload.serializer(),
                ).imageURLs
                if (pages.size < COMIC_PAGE_FLOOR) continue
                return Draft(
                    rule,
                    Preview(title.first, author, chapters.size, firstTitle, Preview.Evidence.Pages(pages.size, pages.first()), listOf(NO_SEARCH)),
                )
            }

            var rule = assemble(host, found.inferred, catalogTemplate, catalogContainer, order, bookPage, title.second, chapterProbe, null)
            // Confirmation: run the rule that will be saved against a real chapter.
            var paragraphs = extractChapter(rule, sampleURL)
            if (paragraphs.joinToString("").length < 100 && rule.chapter?.contentSelectors?.firstOrNull() != null) {
                // The named selector matched a near-empty node; the heuristic found the text.
                rule = rule.copy(chapter = rule.chapter!!.copy(contentSelectors = emptyList()))
                paragraphs = extractChapter(rule, sampleURL)
            }
            val text = paragraphs.joinToString("")
            if (text.length < 100) continue

            val warnings = buildList {
                if (rule.chapter?.contentSelectors?.firstOrNull() == null) add("正文靠版面判斷尋找，站台改版後可能需要重新建立。")
                add(NO_SEARCH)
            }
            return Draft(
                rule,
                Preview(title.first, author, chapters.size, firstTitle, Preview.Evidence.Text(text.take(160)), warnings),
            )
        }
        throw DeriveError.EmptyChapter()
    }

    private suspend fun extractChapter(rule: SiteRule, url: String): List<String> =
        fetcher.fetch(url, ExtractorScript.chapter(rule), ExtractorScript.ChapterPayload.serializer()).paragraphs

    /** A link cluster shown to describe this book's chapters. */
    data class Candidate(
        val group: PageProbe.Group,
        val inferred: URLPatternInference.Inferred,
        val catalogURL: String,
        /** (href, text) of the links surviving the derived patterns. */
        val chapters: List<Pair<String, String>>,
    )

    @Serializable
    data class PageProbe(
        val href: String,
        val docTitle: String,
        val metas: Map<String, String>,
        val groups: List<Group>,
        val catalogLinks: List<String>,
        val sameBookLinks: List<String>,
        val titleCandidates: List<TitleCandidate>,
    ) {
        @Serializable
        data class Group(val container: String? = null, val hrefs: List<String>, val texts: List<String>)

        @Serializable
        data class TitleCandidate(val selector: String, val text: String)
    }

    @Serializable
    data class ChapterProbe(
        val contentSelector: String? = null,
        val unique: Boolean,
        val title: String? = null,
        val titleSelector: String? = null,
        val images: Images? = null,
    ) {
        @Serializable
        data class Images(val selector: String, val attributes: List<String>, val count: Int, val first: String)
    }

    companion object {
        /** Past this many chapters a cluster is the complete catalog. */
        const val COMPLETE_CATALOG_THRESHOLD = 100
        private const val COMIC_PAGE_FLOOR = 3

        /** Chapters tried for text, in reading order: enough to step past a notice or two, not a site with none. */
        private const val SAMPLE_CHAPTERS = 3
        private const val NO_SEARCH = "這個來源不支援搜尋，只能貼網址加書。"

        internal val CHAPTER_PROBE by lazy { ExtractorScript.fill("chapterProbe") }

        fun pageProbe(bookToken: String): String =
            ExtractorScript.fill("pageProbe", "__TOKEN__" to Json.encodeToString(String.serializer(), bookToken))

        /** The cluster on [page] yielding the most readable chapters for this book. */
        fun bestCandidate(page: PageProbe, bookURL: String, pageURL: String): Candidate? {
            val catalogURL = page.href.ifEmpty { pageURL }
            var best: Candidate? = null
            for (group in page.groups) {
                if (group.hrefs.size < 5) continue
                val inferred = URLPatternInference.infer(bookURL, group.hrefs) ?: continue
                val chapters = group.hrefs.zip(group.texts).filter { (href, _) ->
                    if (capture(inferred.chapterIdPattern, href) == null) return@filter false
                    val owner = capture(inferred.bookIdPattern, href) ?: return@filter true
                    owner == inferred.bookId
                }
                if (chapters.isNotEmpty() && chapters.size > (best?.chapters?.size ?: 0)) {
                    best = Candidate(group, inferred, catalogURL, chapters)
                }
            }
            return best
        }

        /** Labelled catalog links, then named same-book pages, then numbered ones. */
        fun followUps(page: PageProbe, pasted: String): List<String> {
            val named = page.sameBookLinks.filter { link ->
                URLPatternInference.pathOf(link).trimEnd('/').substringAfterLast('/').none { it.isDigit() }
            }
            val seen = mutableSetOf(pasted)
            return (page.catalogLinks + named + page.sameBookLinks).filter { seen.add(it) }
        }

        /** `www.hetubook.com` → `hetubook`. Display only; the id stays the full host. */
        fun shortName(host: String): String {
            val parts = host.lowercase().split('.').toMutableList()
            val prefixes = setOf("www", "m", "big5", "gb", "tw", "hk", "cn", "www1", "www2")
            while (parts.size > 2 && parts.first() in prefixes) parts.removeAt(0)
            if (parts.size > 1) parts.removeAt(parts.lastIndex)
            return parts.joinToString(".").ifEmpty { host }
        }

        /** (text, selector) of the book's title. */
        fun title(page: PageProbe): Pair<String, String?>? {
            page.metas["og:novel:book_name"]?.takeIf { it.isNotEmpty() }?.let { name ->
                val agreeing = page.titleCandidates.firstOrNull { name.contains(it.text) || it.text.contains(name) }
                return name to agreeing?.selector
            }
            // Longest candidate inside the document title: the site's own name is the shorter.
            page.titleCandidates
                .filter { it.text.isNotEmpty() && page.docTitle.contains(it.text) }
                .maxByOrNull { it.text.length }
                ?.let { return it.text to it.selector }
            page.metas["og:title"]?.takeIf { it.isNotEmpty() }?.let { return it to null }
            return page.titleCandidates.firstOrNull()?.let { it.text to it.selector }
        }

        fun order(texts: List<String>): SiteRule.Catalog.Order {
            val numbers = texts.mapNotNull(::chapterNumber)
            if (numbers.size < 2) return SiteRule.Catalog.Order.ASCENDING
            return if (numbers.first() > numbers.last()) SiteRule.Catalog.Order.DESCENDING else SiteRule.Catalog.Order.ASCENDING
        }

        private fun chapterNumber(text: String): Int? =
            listOf("第\\s*(\\d+)\\s*[章回节節卷]", "^\\s*(\\d+)").firstNotNullOfOrNull { capture(it, text)?.toIntOrNull() }

        private fun capture(pattern: String, string: String): String? =
            runCatching { Regex(pattern).find(string)?.groups?.get(1)?.value }.getOrNull()

        private fun assemble(
            host: String,
            inferred: URLPatternInference.Inferred,
            catalogTemplate: String,
            catalogContainer: String,
            order: SiteRule.Catalog.Order,
            bookPage: PageProbe,
            titleSelector: String?,
            chapterProbe: ChapterProbe?,
            images: ChapterProbe.Images?,
        ): SiteRule {
            val contentSelectors = if (chapterProbe?.unique == true) listOfNotNull(chapterProbe.contentSelector) else emptyList()
            val titleSelectors = listOfNotNull(chapterProbe?.titleSelector, "h1", "h2").distinct()
            val orderName = if (order == SiteRule.Catalog.Order.DESCENDING) "descending" else "ascending"
            return SiteRule(
                // The host is the id: a prettier name could let two sites share a file.
                id = host,
                name = shortName(host),
                host = host,
                kind = if (images == null) SiteRule.Kind.NOVEL else SiteRule.Kind.COMIC,
                urls = SiteRule.UrlTemplates(inferred.bookTemplate, catalogTemplate, inferred.chapterTemplate),
                idPatterns = SiteRule.IdPatterns(inferred.bookIdPattern, inferred.chapterIdPattern),
                // Search cannot be derived from a book page; absent is honest.
                search = null,
                book = bookFields(bookPage, titleSelector),
                catalog = SiteRule.Catalog(container = catalogContainer, linkSelector = "a", order = order),
                chapter = chapterProbe?.let {
                    SiteRule.Chapter(
                        titleSelectors = titleSelectors,
                        contentSelectors = contentSelectors,
                        stripSelectors = listOf("script", "style", "ins", ".ads"),
                    )
                },
                images = images?.let {
                    SiteRule.Images(listOf(SiteRule.Images.Strategy(SiteRule.Images.Strategy.Type.DOM, it.selector, it.attributes)))
                },
                notes = listOf(
                    "Auto-derived from ${inferred.bookTemplate}",
                    images?.let {
                        "Image selector: ${it.selector} via ${it.attributes.joinToString(", ")} " +
                            "— ${it.count} pages on the chapter that was probed"
                    } ?: "Content selector: ${contentSelectors.firstOrNull() ?: "(largest text block heuristic)"}",
                    "Catalog container: $catalogContainer, order: $orderName",
                ),
            )
        }

        /** `og:` meta tags wherever the page publishes them: they survive layout changes. */
        private fun bookFields(page: PageProbe, titleSelector: String?): SiteRule.BookFields {
            fun field(meta: String): SiteRule.Field? = if (page.metas[meta] != null) SiteRule.Field(meta = meta) else null
            val titleMeta = if (page.metas["og:novel:book_name"] != null) "og:novel:book_name" else "og:title"
            return SiteRule.BookFields(
                title = SiteRule.Field(meta = titleMeta.takeIf { page.metas[it] != null }, selector = titleSelector),
                author = field("og:novel:author"),
                cover = field("og:image"),
                category = field("og:novel:category"),
                status = field("og:novel:status"),
                intro = field("og:description"),
                latestChapter = field("og:novel:latest_chapter_name"),
            )
        }
    }
}
