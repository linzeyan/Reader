package com.zeyanlin.novelreader.siterules

import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString

/**
 * Turns a [SiteRule] into the JavaScript that runs inside the page. All DOM work happens in
 * JS and only JSON crosses back, so adding a site stays a data change.
 *
 * The scripts are not written here: `scripts/extract_js.py` generates them from the iOS
 * `ExtractorScript.swift`, which remains their only copy. Two hand-kept copies would drift
 * apart silently, and a rule that reads a site one way on iOS and another on Android is a
 * rule nobody can debug. What this file adds is the filling-in of the placeholders.
 */
object ExtractorScript {
    class WrongKind(kind: SiteRule.Kind) : IllegalArgumentException("rule kind $kind cannot be read this way")

    class SearchUnsupported : IllegalArgumentException("rule has no search block")

    // Extracted shapes, mirrored by the scripts.

    @Serializable
    data class BookPayload(
        val title: String? = null,
        val author: String? = null,
        val cover: String? = null,
        val category: String? = null,
        val status: String? = null,
        val intro: String? = null,
        val latestChapter: String? = null,
    )

    @Serializable
    data class CatalogPayload(val entries: List<Entry>) {
        @Serializable
        data class Entry(val title: String, val url: String)
    }

    @Serializable
    data class ChapterPayload(
        val title: String? = null,
        val paragraphs: List<String>,
        val prevURL: String? = null,
        val nextURL: String? = null,
        val matchedSelector: String? = null,
    )

    @Serializable
    data class ComicImagesPayload(
        val imageURLs: List<String>,
        val title: String? = null,
        val matchedStrategy: String? = null,
    )

    @Serializable
    data class ArticlePayload(val blocks: List<com.zeyanlin.novelreader.services.ArticleBlock>)

    @Serializable
    data class SearchPayload(val rows: List<Row>) {
        @Serializable
        data class Row(val title: String, val url: String, val author: String? = null, val cover: String? = null)
    }

    // Builders

    fun book(rule: SiteRule): String = fill("book", "__FIELDS__" to encode(rule.book))

    fun catalog(rule: SiteRule): String = fill("catalog", "__CFG__" to encode(rule.catalog))

    fun chapter(rule: SiteRule): String = chapter(rule.chapter ?: throw WrongKind(rule.kind))

    /** From the config alone, for content with no site behind it (an imported EPUB). */
    fun chapter(config: SiteRule.Chapter): String = fill("chapter", "__CFG__" to encode(config))

    /**
     * A document's markup as article blocks — a feed's article, or the page it links to. [baseURL]
     * is what relative links and pictures resolve against: the markup is loaded with no base of its own.
     * [wholePage]: the publisher's page rather than a feed's body, read from its one `<article>`.
     */
    fun article(baseURL: String, title: String?, wholePage: Boolean): String =
        fill("article", "__BASE__" to encode(baseURL), "__HEADING__" to encode(title.orEmpty()), "__WHOLEPAGE__" to wholePage.toString())

    fun comicImages(rule: SiteRule): String =
        fill("comicImages", "__CFG__" to encode(rule.images ?: throw WrongKind(rule.kind)))

    fun searchResults(rule: SiteRule): String =
        fill("searchResults", "__CFG__" to encode(rule.search ?: throw SearchUnsupported()))

    fun submitSearch(rule: SiteRule, query: String): String {
        val search = rule.search ?: throw SearchUnsupported()
        return submitForm(search.url, search.queryField, query, search.method)
    }

    fun submitForm(url: String, field: String, query: String, method: SiteRule.Search.Method): String =
        fill("submitForm", "__CFG__" to encode(SubmitConfig(url, field, query, method.name)))

    @Serializable
    private data class SubmitConfig(val url: String, val field: String, val query: String, val method: String)

    private val helpers by lazy { template("helpers") }

    internal fun fill(name: String, vararg values: Pair<String, String>): String {
        var script = template(name).replace("__HELPERS__", helpers)
        for ((placeholder, value) in values) script = script.replace(placeholder, value)
        return script
    }

    /** Java resources rather than Android assets, so plain JVM unit tests can read them too. */
    private fun template(name: String): String =
        checkNotNull(javaClass.getResourceAsStream("/extractor/$name.js")) { "missing extractor/$name.js" }
            .bufferedReader().use { it.readText() }

    // Absent optionals stay out of the script entirely (`explicitNulls = false`), the same
    // as iOS's synthesized encoder, so `readField` never meets a null it has to defend against.
    private inline fun <reified T> encode(value: T): String = SiteRule.json.encodeToString(value)
}
