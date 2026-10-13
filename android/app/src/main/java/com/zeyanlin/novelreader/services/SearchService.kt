package com.zeyanlin.novelreader.services

import com.zeyanlin.novelreader.data.Book
import com.zeyanlin.novelreader.describe
import com.zeyanlin.novelreader.network.WebFetcher
import com.zeyanlin.novelreader.siterules.ExtractorScript
import com.zeyanlin.novelreader.siterules.SiteRule
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.serialization.Serializable
import java.net.URI
import java.net.URLEncoder

/** One hit; [id] is the library's own `siteId|siteBookId`, so it can be checked against the shelf. */
@Serializable
data class SearchResult(
    val id: String,
    val siteId: String,
    val siteName: String,
    val siteBookId: String,
    val title: String,
    val author: String? = null,
    val coverURL: String? = null,
)

/**
 * What one site produced. Carries the failure rather than throwing it: a search across sites
 * reports "three answered, one needs a check, one cannot search" instead of collapsing on the
 * first that misbehaves. The failure is its message, so a screen can keep it across a restart.
 */
@Serializable
data class SiteSearchOutcome(
    val siteId: String,
    val siteName: String,
    val results: List<SearchResult>,
    val failure: String? = null,
    /** The page whose check stopped this site, so the failure row can hand it to the reader. */
    val challenge: String? = null,
    /** [challenge] is the site's sign-in form rather than a check. */
    val signIn: Boolean = false,
)

/** The iOS `SearchService`: one site, or every site in turn. */
class SearchService(private val fetcher: WebFetcher) {
    /**
     * Every script form of [query], merged. The typed form leads and its failure is the one
     * reported — it is the search that was asked for; the other form only adds books not
     * already found, and its failure is ignored, since it was a bonus.
     */
    suspend fun search(query: String, rule: SiteRule): List<SearchResult> {
        val merged = LinkedHashMap<String, SearchResult>()
        forms(query).forEachIndexed { i, form ->
            val hits = if (i == 0) {
                searchOnce(form, rule)
            } else {
                try {
                    searchOnce(form, rule)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    return@forEachIndexed
                }
            }
            for (hit in hits) merged.putIfAbsent(hit.id, hit)
        }
        return merged.values.toList()
    }

    private suspend fun searchOnce(query: String, rule: SiteRule): List<SearchResult> {
        val search = rule.search ?: throw ExtractorScript.SearchUnsupported()
        val extractor = ExtractorScript.searchResults(rule)
        val payload = when (search.method) {
            SiteRule.Search.Method.GET ->
                fetcher.fetch(
                    getSearchURL(search, query), extractor, ExtractorScript.SearchPayload.serializer(), search.waitFor,
                    signIn = rule.signIn,
                )
            // Land on the site first, so the form posted from inside the page inherits its
            // charset and cookies.
            SiteRule.Search.Method.POST -> fetcher.fetchSubmitting(
                URI(search.url).resolve("/").toString(), ExtractorScript.submitSearch(rule, query),
                extractor, ExtractorScript.SearchPayload.serializer(), search.waitFor, signIn = rule.signIn,
            )
        }
        return payload.rows.mapNotNull { row ->
            val bookId = rule.bookId(row.url) ?: return@mapNotNull null
            SearchResult(Book.makeId(rule.id, bookId), rule.id, rule.name, bookId, row.title, row.author, row.cover)
        }
    }

    /**
     * Every rule in turn, each outcome as it lands. One at a time by necessity — the fetcher has
     * one web view — and streamed so the screen fills in site by site instead of waiting on the
     * slowest.
     */
    fun searchAll(query: String, rules: List<SiteRule>): Flow<SiteSearchOutcome> = flow {
        for (rule in rules) {
            val outcome = try {
                SiteSearchOutcome(rule.id, rule.name, search(query, rule))
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                SiteSearchOutcome(
                    rule.id, rule.name, emptyList(), message(e), (e as? WebFetcher.FetchError.NeedsTheUser)?.url,
                    e is WebFetcher.FetchError.SignInRequired,
                )
            }
            emit(outcome)
        }
    }

    companion object {
        fun getSearchURL(search: SiteRule.Search, query: String): String =
            search.url.replace("{query}", URLEncoder.encode(query, "UTF-8").replace("+", "%20"))

        /**
         * The iOS `ChineseVariants.forms`: as typed, then the other script if that changes
         * anything — two at most, since a third request per site is a burst, not politeness.
         */
        fun forms(query: String): List<String> {
            val trimmed = query.trim()
            if (trimmed.isEmpty()) return emptyList()
            if (trimmed.none(ChineseText::isHan)) return listOf(trimmed)
            for (target in listOf(ChineseScript.Target.SIMPLIFIED, ChineseScript.Target.TRADITIONAL)) {
                val other = ChineseText.rendered(trimmed, ChineseScript(ChineseScript.Depth.CHARACTERS, target))
                if (other != trimmed) return listOf(trimmed, other)
            }
            return listOf(trimmed)
        }

        private fun message(error: Exception) = when (error) {
            is ExtractorScript.SearchUnsupported -> "這個來源不支援搜尋"
            else -> describe(error)
        }
    }
}
