package com.zeyanlin.novelreader.services

import com.zeyanlin.novelreader.network.WebFetcher
import com.zeyanlin.novelreader.siterules.ExtractorScript
import com.zeyanlin.novelreader.siterules.SiteRule
import java.net.URI

/**
 * Fetches book metadata, catalogs and chapter text through the rule engine — the iOS
 * `BookService`, ported. Everything site-specific arrives as a [SiteRule]; this only drives
 * the fetcher and post-processes what comes back. Storage is the caller's (see `App`).
 */
class BookService(private val fetcher: WebFetcher) {
    data class Info(
        val title: String,
        val author: String?,
        val cover: String?,
        val category: String?,
        val status: String?,
        val intro: String?,
        val latestChapter: String?,
    )

    sealed class ServiceError(message: String) : Exception(message) {
        class NoTitle : ServiceError("no title")
        class EmptyCatalog : ServiceError("empty catalog")
        class EmptyChapter : ServiceError("empty chapter")
    }

    /** One row of the chapter index, as the catalog says it. */
    data class CatalogEntry(val siteChapterId: String, val title: String, val url: String)

    /** A chapter page's text, and the chapter's name as the page gives it. */
    data class ChapterText(val title: String?, val paragraphs: List<String>)

    suspend fun info(rule: SiteRule, siteBookId: String): Info {
        val payload = fetcher.fetch(
            rule.bookUrl(siteBookId), ExtractorScript.book(rule), ExtractorScript.BookPayload.serializer(),
            signIn = rule.signIn,
        )
        val title = payload.title?.takeIf { it.isNotEmpty() } ?: throw ServiceError.NoTitle()
        return Info(
            title, payload.author, payload.cover, payload.category, payload.status, payload.intro,
            payload.latestChapter,
        )
    }

    suspend fun catalog(rule: SiteRule, siteBookId: String): List<CatalogEntry> {
        val payload = fetcher.fetch(
            rule.catalogUrl(siteBookId), ExtractorScript.catalog(rule), ExtractorScript.CatalogPayload.serializer(),
            waitFor = rule.catalog.waitFor, signIn = rule.signIn,
        )
        return entries(payload, rule, siteBookId).ifEmpty { throw ServiceError.EmptyCatalog() }
    }

    /**
     * One chapter's paragraphs, retried once when the page yields nothing: on ad-heavy sites
     * an ad script can navigate the page out from under the extractor. Once only — a chapter
     * that is genuinely empty must surface as an error, not as a loop against the site.
     */
    suspend fun chapterParagraphs(rule: SiteRule, url: String): ChapterText =
        try {
            fetchParagraphs(rule, url)
        } catch (e: ServiceError.EmptyChapter) {
            fetchParagraphs(rule, url)
        }

    /**
     * A comic chapter's picture addresses — only the addresses: the bytes come over plain HTTP,
     * because holding the one web view for fifty pictures would stop everything else. Never to
     * be stored: on these CDNs an address carries an expiry and a signature.
     */
    suspend fun chapterImages(rule: SiteRule, url: String): ExtractorScript.ComicImagesPayload {
        val payload = fetcher.fetch(
            url, ExtractorScript.comicImages(rule), ExtractorScript.ComicImagesPayload.serializer(), signIn = rule.signIn,
        )
        if (payload.imageURLs.isEmpty()) throw ServiceError.EmptyChapter()
        return payload
    }

    private suspend fun fetchParagraphs(rule: SiteRule, url: String): ChapterText {
        val payload = fetcher.fetch(
            url, ExtractorScript.chapter(rule), ExtractorScript.ChapterPayload.serializer(),
            waitFor = rule.chapter?.waitFor, signIn = rule.signIn,
        )
        val paragraphs = dropping(
            rule.chapter?.dropParagraphPatterns,
            replacing(rule.chapter?.replacements, payload.paragraphs),
        )
        if (paragraphs.isEmpty()) throw ServiceError.EmptyChapter()
        return ChapterText(payload.title, paragraphs)
    }

    companion object {
        /**
         * Turns what the extractor found on a catalog page into chapter index rows. Links go
         * through `idPatterns.chapterId` rather than being trusted wholesale: a selector broad
         * enough to catch every chapter also catches navigation, teasers and other books.
         */
        fun entries(payload: ExtractorScript.CatalogPayload, rule: SiteRule, siteBookId: String): List<CatalogEntry> {
            val seen = HashSet<String>()
            val carriesIds = rule.catalog.carriesChapterIds
            return payload.entries.mapNotNull { entry ->
                val chapterId = (if (carriesIds) entry.url else rule.chapterId(entry.url)) ?: return@mapNotNull null
                // Another book's chapter; a link with no book id at all is accepted.
                val owner = rule.bookId(entry.url)
                if (owner != null && owner != siteBookId) return@mapNotNull null
                // The site's own link wins where there is one; some templates do not round-trip.
                val url = if (rule.catalog.linkAttribute == null && !carriesIds) {
                    if (runCatching { URI(entry.url) }.isFailure) return@mapNotNull null
                    entry.url
                } else {
                    rule.chapterUrl(siteBookId, chapterId)
                }
                if (!seen.add(chapterId)) return@mapNotNull null
                CatalogEntry(chapterId, replacing(rule.chapter?.replacements, listOf(entry.title))[0], url)
            }
        }

        /**
         * Applies a rule's `dropParagraphPatterns`. An unparseable pattern is skipped: a typo in
         * one line of a user-imported rule must not make the whole chapter unreadable.
         */
        fun dropping(patterns: List<String>?, paragraphs: List<String>): List<String> {
            val regexes = patterns.orEmpty().mapNotNull { runCatching { Regex(it) }.getOrNull() }
            if (regexes.isEmpty()) return paragraphs
            return paragraphs.filter { p -> regexes.none { it.containsMatchIn(p) } }
        }

        /** Applies a rule's `replacements` in key order, so the result never depends on map order. */
        fun replacing(replacements: Map<String, String>?, paragraphs: List<String>): List<String> {
            val pairs = replacements.orEmpty().filterKeys { it.isNotEmpty() }.toSortedMap()
            if (pairs.isEmpty()) return paragraphs
            return paragraphs.map { p -> pairs.entries.fold(p) { acc, (k, v) -> acc.replace(k, v) } }
        }
    }
}
