package com.zeyanlin.novelreader.services

import com.zeyanlin.novelreader.network.WebFetcher
import com.zeyanlin.novelreader.siterules.ExtractorScript
import com.zeyanlin.novelreader.siterules.SiteRule
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import java.net.URLEncoder

/**
 * Works out how to search a site from the site's own search box — the iOS `SearchDeriver`,
 * whose comments carry the reasoning; its three probes are extracted from that file. A real
 * form is submitted with a real query rather than a URL template guessed: the browser encodes
 * the field in the document's own charset, and for a GET form the address it lands on *is* the
 * template, with the query substituted back out.
 */
class SearchDeriver(private val fetcher: WebFetcher) {
    sealed class DeriveError(message: String) : Exception(message) {
        class NoSearchForm : DeriveError("在這個站找不到可用的搜尋表單。")
        class NoResults : DeriveError("搜尋跑得起來，但結果頁裡認不出任何書。換一個確實存在的書名再試。")
    }

    /** The search, and the titles it actually returned: the reader confirms against results, not a configuration. */
    data class Derived(val search: SiteRule.Search, val sampleTitles: List<String>)

    @Serializable
    data class FormsPayload(val forms: List<Form>, val searchLink: String? = null) {
        /** [inputSelector] is set for a search box outside any form: typed into and clicked, as a person would. */
        @Serializable
        data class Form(val method: String, val action: String, val field: String, val inputSelector: String? = null)
    }

    @Serializable
    data class ResultsPayload(
        val href: String,
        val container: String? = null,
        val count: Int,
        val inContainer: Int = 0,
        val hasCover: Boolean,
        val titles: List<String> = emptyList(),
    )

    suspend fun derive(rule: SiteRule, query: String): Derived {
        var page = "https://${rule.host}/"
        var forms = fetcher.fetch(page, FORM_PROBE, FormsPayload.serializer())
        // One page and no further: where a site keeps its box off the homepage, it is a tap away.
        val link = forms.searchLink
        if (forms.forms.isEmpty() && link != null) {
            page = link
            forms = fetcher.fetch(page, FORM_PROBE, FormsPayload.serializer())
        }
        if (forms.forms.isEmpty()) throw DeriveError.NoSearchForm()

        for (form in forms.forms) {
            // A typed-into box can only ever produce GET: whatever its script does ends at an address.
            val method = if (form.inputSelector == null && form.method == "POST") SiteRule.Search.Method.POST else SiteRule.Search.Method.GET
            val submit = form.inputSelector?.let { typeAndSubmit(it, query) }
                ?: ExtractorScript.submitForm(form.action, form.field, query, method)
            val landing = try {
                // Shorter for the typed path: a click that opens an overlay never lands, and the
                // next candidate deserves its turn without a 30 s wait.
                fetcher.fetchSubmitting(page, submit, resultsProbe(rule), ResultsPayload.serializer(), timeoutMs = if (form.inputSelector == null) 30_000 else 15_000)
            } catch (e: WebFetcher.FetchError.ChallengePresented) {
                throw e
            } catch (e: WebFetcher.FetchError) {
                continue
            }
            if (landing.count == 0) continue
            val endpoint = when (method) {
                // A field encoded in GBK lands as bytes no other query can be rebuilt into: dropped, not saved broken.
                SiteRule.Search.Method.GET -> template(landing.href, query) ?: continue
                SiteRule.Search.Method.POST -> form.action
            }
            // A container that loses rows is worse than none: it holds every result or is left out.
            val container = landing.container.takeIf { landing.inContainer == landing.count }
            // Not re-run to double-check: some sites answer a second identical query within
            // seconds with an empty page, which made a working rule look broken.
            return Derived(
                SiteRule.Search(
                    method, endpoint, form.field, resultContainer = container, resultLinkSelector = "a",
                    resultCoverSelector = if (landing.hasCover) "img" else null,
                ),
                landing.titles,
            )
        }
        // A box was found and tried; "no form" would send the reader looking for the wrong thing.
        throw DeriveError.NoResults()
    }

    companion object {
        private val FORM_PROBE by lazy { ExtractorScript.fill("formProbe") }

        private fun typeAndSubmit(selector: String, query: String) =
            ExtractorScript.fill("typeAndSubmit", "__CFG__" to Json.encodeToString(ListSerializer(String.serializer()), listOf(selector, query)))

        private fun resultsProbe(rule: SiteRule) = ExtractorScript.fill(
            "resultsProbe",
            "__BOOKPATTERN__" to Json.encodeToString(String.serializer(), rule.idPatterns.bookId),
            "__CHAPTERPATTERN__" to Json.encodeToString(String.serializer(), rule.idPatterns.chapterId),
        )

        /**
         * The address a GET search landed on, turned back into a `{query}` template. Encoded the
         * way a form encodes it (space as `+`) first, then with `%20` and raw, as iOS does.
         */
        fun template(href: String, query: String): String? {
            val form = URLEncoder.encode(query, "UTF-8")
            return listOf(form, form.replace("+", "%20"), query).firstOrNull { it.isNotEmpty() && it in href }
                ?.let { href.replace(it, "{query}") }
        }
    }
}
