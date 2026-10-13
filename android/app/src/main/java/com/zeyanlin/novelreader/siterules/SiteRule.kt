package com.zeyanlin.novelreader.siterules

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.net.URI

/**
 * A declarative description of how to read one site — the iOS `SiteRule`, field for field,
 * so a rule file moves between the two apps unchanged. The reasons behind each field are
 * documented there (NovelReader/SiteRules/SiteRule.swift); only what differs is noted here.
 *
 * Everything site-specific has to be expressible as data: any `if (site == …)` in Kotlin
 * is a bug, not a shortcut.
 */
@Serializable
data class SiteRule(
    val id: String,
    val name: String,
    val host: String,
    /** Absent in every rule written before comics existed, all of which are novels. */
    val kind: Kind = Kind.NOVEL,
    val urls: UrlTemplates,
    val idPatterns: IdPatterns,
    val search: Search? = null,
    val book: BookFields,
    val catalog: Catalog,
    val chapter: Chapter? = null,
    val images: Images? = null,
    val signIn: SignIn? = null,
    val notes: List<String>? = null,
) {
    @Serializable
    enum class Kind {
        @SerialName("novel") NOVEL,
        @SerialName("comic") COMIC,
        @SerialName("feed") FEED,
    }

    @Serializable
    data class UrlTemplates(val book: String, val catalog: String, val chapter: String)

    @Serializable
    data class IdPatterns(val bookId: String, val chapterId: String)

    @Serializable
    data class Search(
        val method: Method,
        val url: String,
        val queryField: String,
        val resultContainer: String? = null,
        val resultLinkSelector: String,
        val resultTitleSelector: String? = null,
        val resultAuthorSelector: String? = null,
        val resultCoverSelector: String? = null,
        val waitFor: String? = null,
    ) {
        @Serializable
        enum class Method {
            @SerialName("GET") GET,
            @SerialName("POST") POST,
        }
    }

    @Serializable
    data class Field(
        val meta: String? = null,
        val selector: String? = null,
        val attribute: String? = null,
    )

    @Serializable
    data class BookFields(
        val title: Field,
        val author: Field? = null,
        val cover: Field? = null,
        val category: Field? = null,
        val status: Field? = null,
        val intro: Field? = null,
        val latestChapter: Field? = null,
    )

    @Serializable
    data class Catalog(
        val container: String,
        val linkSelector: String,
        val order: Order,
        val linkAttribute: String? = null,
        val descendingWhen: Condition? = null,
        val waitFor: String? = null,
        val lines: Boolean? = null,
        val json: JsonList? = null,
    ) {
        @Serializable
        enum class Order {
            @SerialName("ascending") ASCENDING,
            @SerialName("descending") DESCENDING,
        }

        @Serializable
        data class JsonList(val arrayPath: String, val idKey: String, val titleKey: String)

        @Serializable
        data class Condition(val path: String, val equals: String)

        /** Whether the extractor hands back chapter ids rather than links to recover them from. */
        val carriesChapterIds: Boolean get() = lines == true || json != null
    }

    @Serializable
    data class Images(val strategies: List<Strategy>) {
        @Serializable
        data class Strategy(
            val type: Type,
            val selector: String? = null,
            val attributes: List<String>? = null,
            val unescape: Boolean? = null,
            val arrayPath: String? = null,
            val prefixPath: String? = null,
            val queryPath: String? = null,
            val baseURL: String? = null,
        ) {
            @Serializable
            enum class Type {
                @SerialName("dom") DOM,
                @SerialName("global") GLOBAL,
                @SerialName("packed") PACKED,
            }
        }
    }

    @Serializable
    data class SignIn(val landsOn: String, val url: String) {
        /** Nil is not a match: a fetch that landed nowhere failed for some other reason. */
        fun turnsAway(landed: String?): Boolean =
            landed != null && landsOn.isNotEmpty() && landed.contains(landsOn)
    }

    @Serializable
    data class Chapter(
        val titleSelectors: List<String>,
        val contentSelectors: List<String>,
        val stripSelectors: List<String>,
        val dropParagraphPatterns: List<String>? = null,
        val prevSelector: String? = null,
        val nextSelector: String? = null,
        val waitFor: String? = null,
        val visibleOnly: Boolean? = null,
        val replacements: Map<String, String>? = null,
    )

    // URL building / parsing

    fun bookUrl(bookId: String): String = urls.book.replace("{bookId}", bookId)

    fun catalogUrl(bookId: String): String = urls.catalog.replace("{bookId}", bookId)

    fun chapterUrl(bookId: String, chapterId: String): String =
        urls.chapter.replace("{bookId}", bookId).replace("{chapterId}", chapterId)

    /** Works on a URL or on raw catalog link text (`cview('103-1.html', 3)`) alike. */
    fun bookId(linkText: String): String? = firstCapture(idPatterns.bookId, linkText)

    fun chapterId(linkText: String): String? = firstCapture(idPatterns.chapterId, linkText)

    /**
     * Whether this rule reads the site `url` is on. Only the device labels `www.`, `m.` and
     * `mobile.` are dropped before comparing: dropping any first label would let a rule for
     * one subdomain read unrelated properties on its siblings.
     */
    fun matches(url: String): Boolean {
        val pasted = runCatching { URI(url).host }.getOrNull() ?: return false
        return site(pasted).equals(site(host), ignoreCase = true)
    }

    companion object {
        /** Lenient where iOS's `Codable` is: unknown keys are ignored, absent optionals are null. */
        val json = Json {
            ignoreUnknownKeys = true
            explicitNulls = false
        }

        fun decode(text: String): SiteRule = json.decodeFromString(serializer(), text)

        private fun site(host: String): String {
            val lowered = host.lowercase()
            for (label in listOf("www.", "m.", "mobile.")) {
                if (lowered.length > label.length && lowered.startsWith(label)) {
                    return lowered.removePrefix(label)
                }
            }
            return lowered
        }

        private fun firstCapture(pattern: String, text: String): String? =
            runCatching { Regex(pattern).find(text)?.groups?.get(1)?.value }.getOrNull()
    }
}
