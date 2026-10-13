package com.zeyanlin.novelreader.services

import com.zeyanlin.novelreader.data.Chapter
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import org.w3c.dom.Element
import org.w3c.dom.Node
import java.io.ByteArrayInputStream
import java.net.URL
import java.security.MessageDigest
import java.text.ParsePosition
import java.text.SimpleDateFormat
import java.time.LocalDate
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Locale
import java.util.TimeZone
import javax.xml.parsers.DocumentBuilderFactory

internal fun String?.nonBlank(): String? = this?.trim()?.takeIf { it.isNotEmpty() }

/**
 * A minimal read-only XML tree — the iOS `XMLTree`. Names and attribute keys lose their namespace
 * prefix (`content:encoded` is `encoded`): producers disagree about which prefix goes on what, and
 * nothing looked up here is ambiguous without one. Text and children stay interleaved, so [text]
 * reads `<a>Chapter <b>1</b> begins</a>` in the order it was written.
 */
class XmlTree(val name: String, val attributes: Map<String, String>) {
    private val contents = mutableListOf<Any>()

    val children: List<XmlTree> get() = contents.filterIsInstance<XmlTree>()

    /** All text under this element, concatenated. */
    val text: String get() = contents.joinToString("") { if (it is XmlTree) it.text else it as String }

    /** The first direct child with this name: a channel's `<title>` is not its first item's. */
    fun child(name: String) = children.firstOrNull { it.name == name }

    fun childText(name: String) = child(name)?.text.nonBlank()

    /** Every descendant with this name, in document order. */
    fun all(name: String): List<XmlTree> = children.flatMap { if (it.name == name) listOf(it) + it.all(name) else it.all(name) }

    /** The children written back out as HTML, for Atom's `type="xhtml"`, which holds elements rather than text. */
    val innerHTML: String
        get() = contents.joinToString("") { if (it is XmlTree) it.outerHTML else escaping(it as String) }

    private val outerHTML: String
        get() {
            // In name order: markup that differs between two runs is markup no test can pin.
            val written = attributes.toSortedMap().entries.joinToString("") { " ${it.key}=\"${escaping(it.value, quotes = true)}\"" }
            // `<br></br>` is two line breaks to an HTML parser and `<p/>` a paragraph that never closes.
            return if (name.lowercase() in VOID) "<$name$written />" else "<$name$written>$innerHTML</$name>"
        }

    companion object {
        private val VOID = setOf("area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr")

        /** Ampersand first, or the `&` just written becomes `&amp;lt;`. OPML's writer uses this too: two escapers is how one forgets `&`. */
        fun escaping(raw: String, quotes: Boolean = false): String {
            val escaped = raw.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            return if (quotes) escaped.replace("\"", "&quot;") else escaped
        }

        /** Null for anything that is not well-formed XML; every caller decides what that means for it. */
        fun parse(data: ByteArray): XmlTree? = try {
            val factory = DocumentBuilderFactory.newInstance()
            // A feed's DOCTYPE must not send the parser to the network for a DTD. Not every
            // platform parser knows the feature; Android's never loads one anyway.
            runCatching { factory.setFeature("http://apache.org/xml/features/nonvalidating/load-external-dtd", false) }
            val document = factory.newDocumentBuilder().apply { setErrorHandler(Quiet) }.parse(ByteArrayInputStream(data))
            build(document.documentElement)
        } catch (e: Exception) {
            null
        }

        private fun build(element: Element): XmlTree {
            val attributes = HashMap<String, String>()
            val map = element.attributes
            for (i in 0 until map.length) map.item(i).let { attributes[local(it.nodeName)] = it.nodeValue }
            val tree = XmlTree(local(element.nodeName), attributes)
            var node = element.firstChild
            while (node != null) {
                when (node.nodeType) {
                    Node.ELEMENT_NODE -> tree.contents += build(node as Element)
                    // CDATA is how nearly every RSS feed carries its bodies; it is text like any other.
                    Node.TEXT_NODE, Node.CDATA_SECTION_NODE -> tree.contents += node.nodeValue
                    Node.ENTITY_REFERENCE_NODE -> tree.contents += node.textContent.orEmpty()
                }
                node = node.nextSibling
            }
            return tree
        }

        private fun local(raw: String) = raw.substringAfterLast(':')

        /** A failed parse is an answer (null), not something to print: the default handler writes every one to stderr. */
        private object Quiet : org.xml.sax.ErrorHandler {
            override fun warning(e: org.xml.sax.SAXParseException) = Unit

            override fun error(e: org.xml.sax.SAXParseException) = Unit

            override fun fatalError(e: org.xml.sax.SAXParseException) = throw e
        }
    }
}

/** One feed's bytes in the shape the rest of the app works in — the iOS `ParsedFeed`. An empty feed is not an error. */
data class ParsedFeed(
    val title: String? = null,
    /** The site the feed is about, not the feed's own address. */
    val homePageURL: String? = null,
    /** The feed's own picture, which becomes the shelf cover. */
    val iconURL: String? = null,
    val items: List<ParsedItem> = emptyList(),
)

/** One article as the feed publishes it — the iOS `ParsedItem`. */
data class ParsedItem(
    val guid: String? = null,
    val url: String? = null,
    val title: String? = null,
    /** `content:encoded`, `description`, Atom `content`/`summary`, JSON Feed `content_html`: one body by the time it gets here. */
    val contentHTML: String? = null,
    /** Epoch milliseconds, or null for a date no reader recognised. */
    val datePublished: Long? = null,
    val author: String? = null,
) {
    /**
     * A stable name: the publisher's id, then the permalink, then a hash of title and date — the
     * same bytes iOS hashes, so an article's marks survive a backup crossing platforms. Never the
     * body: a publisher fixing a typo has not published a new article.
     */
    val identity: String
        get() {
            guid.nonBlank()?.let { return it }
            url.nonBlank()?.let { return it }
            // Swift's `String(describing: Date)`.
            val date = datePublished?.let { DESCRIBED.format(java.time.Instant.ofEpochMilli(it).atOffset(ZoneOffset.UTC)) }
            val material = listOfNotNull(title.nonBlank(), date).joinToString("|")
            val digest = MessageDigest.getInstance("SHA-256").digest(material.toByteArray())
            return "sha256-" + digest.take(12).joinToString("") { "%02x".format(it) }
        }

    private companion object {
        val DESCRIBED: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss '+0000'", Locale.US)
    }
}

/** RSS 2.0, RSS 1.0/RDF, Atom and JSON Feed, decided from the bytes — the iOS `FeedParser`. */
object FeedParser {
    /** Overwhelmingly an HTML page: the address pasted is a website, not its feed. */
    class NotAFeed : Exception("這個網址不是訂閱源，該頁面也沒有標示自己的訂閱源。")

    private val json = Json { ignoreUnknownKeys = true }

    /** @param url what the document was fetched from, which relative links resolve against. */
    fun parse(data: ByteArray, url: String): ParsedFeed {
        if (opensWithBrace(data)) return jsonFeed(data, url)
        val root = tree(data) ?: throw NotAFeed()
        return when (root.name.lowercase()) {
            // One reader for both RSS: items are collected from the document rather than the
            // channel, and both `<pubDate>` and `<dc:date>` are consulted.
            "rss", "rdf" -> rss(root, url)
            "feed" -> atom(root, url)
            else -> throw NotAFeed()
        }
    }

    /** The opening character, not the `Content-Type`, which hosts get wrong for JSON Feed in every way there is. */
    private fun opensWithBrace(data: ByteArray): Boolean {
        for (byte in data.take(64)) {
            when (byte.toInt() and 0xFF) {
                0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF -> continue
                else -> return byte == '{'.code.toByte()
            }
        }
        return false
    }

    /** One em dash in one headline must not cost the feed: HTML's named entities are healed, only after a parse failed. */
    private fun tree(data: ByteArray): XmlTree? = XmlTree.parse(data) ?: healingEntities(data)?.let(XmlTree::parse)

    private fun healingEntities(data: ByteArray): ByteArray? {
        // Not UTF-8: the parser decoded it from its own prologue, and there is nothing here to repair it with.
        if (!data.isUtf8()) return null
        return ENTITY.replace(data.decodeToString()) { match ->
            val name = match.groupValues[1]
            when {
                name in XML_ENTITIES -> match.value
                name in HTML_ENTITIES -> "&#${HTML_ENTITIES.getValue(name)};"
                // Escaped, so the literal shows: one wrong word rather than a lost feed or silently eaten text.
                else -> "&amp;$name;"
            }
        }.toByteArray()
    }

    private fun ByteArray.isUtf8() = runCatching {
        Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(this))
    }.isSuccess

    private val ENTITY = Regex("&([A-Za-z][A-Za-z0-9]{1,30});")
    private val XML_ENTITIES = setOf("amp", "lt", "gt", "quot", "apos")

    /** The ones feed prose actually uses; the long tail degrades to a visible literal, not a lost feed. */
    private val HTML_ENTITIES = mapOf(
        "nbsp" to 160, "iexcl" to 161, "cent" to 162, "pound" to 163, "curren" to 164, "yen" to 165,
        "sect" to 167, "copy" to 169, "laquo" to 171, "not" to 172, "shy" to 173, "reg" to 174,
        "deg" to 176, "plusmn" to 177, "micro" to 181, "para" to 182, "middot" to 183,
        "raquo" to 187, "frac14" to 188, "frac12" to 189, "frac34" to 190, "iquest" to 191,
        "times" to 215, "divide" to 247, "ndash" to 8211, "mdash" to 8212, "lsquo" to 8216,
        "rsquo" to 8217, "sbquo" to 8218, "ldquo" to 8220, "rdquo" to 8221, "bdquo" to 8222,
        "dagger" to 8224, "Dagger" to 8225, "bull" to 8226, "hellip" to 8230, "permil" to 8240,
        "prime" to 8242, "Prime" to 8243, "lsaquo" to 8249, "rsaquo" to 8250, "euro" to 8364,
        "trade" to 8482, "larr" to 8592, "uarr" to 8593, "rarr" to 8594, "darr" to 8595,
        "minus" to 8722, "ne" to 8800, "le" to 8804, "ge" to 8805,
    )

    private fun rss(root: XmlTree, feedURL: String): ParsedFeed {
        // The root where a document has lost its `<channel>`: its items are still wanted.
        val channel = root.child("channel") ?: root
        return ParsedFeed(
            title = channel.childText("title"),
            homePageURL = absolute(siteLink(channel), feedURL),
            iconURL = absolute(channel.child("image")?.childText("url"), feedURL),
            items = root.all("item").map { item ->
                ParsedItem(
                    guid = item.childText("guid"),
                    url = absolute(siteLink(item), feedURL),
                    title = item.childText("title"),
                    // `content:encoded` first: `<description>` is a summary, and read first every
                    // article would end at "read more".
                    contentHTML = item.childText("encoded") ?: item.childText("description"),
                    datePublished = FeedDate.parse(item.childText("pubDate") ?: item.childText("date")),
                    // `<dc:creator>` first: RSS's `<author>` is meant to be an email address.
                    author = item.childText("creator") ?: item.childText("author"),
                )
            },
        )
    }

    private fun atom(root: XmlTree, feedURL: String) = ParsedFeed(
        title = root.childText("title"),
        homePageURL = absolute(siteLink(root), feedURL),
        iconURL = absolute(root.childText("icon") ?: root.childText("logo"), feedURL),
        items = root.all("entry").map { entry ->
            ParsedItem(
                guid = entry.childText("id"),
                url = absolute(siteLink(entry), feedURL),
                title = entry.childText("title"),
                contentHTML = body(entry.child("content")) ?: body(entry.child("summary")),
                // When it appeared; `updated` only where `published` is missing, which Atom allows.
                datePublished = FeedDate.parse(entry.childText("published") ?: entry.childText("updated")),
                author = entry.child("author")?.childText("name"),
            )
        },
    )

    /**
     * `xhtml` holds elements and is written back out; `text` is escaped into markup; anything
     * else — including a missing `type`, against the spec — is taken as the markup it appears to
     * be, or every forgetful publisher's article would show its `<p>` tags.
     */
    private fun body(element: XmlTree?): String? = when (element?.attributes?.get("type")?.lowercase()) {
        null -> element?.text.nonBlank()
        "xhtml" -> element.innerHTML.nonBlank()
        "text" -> element.text.nonBlank()?.let(::html)
        else -> element.text.nonBlank()
    }

    @Serializable
    private data class JsonFeedDocument(
        val version: String? = null,
        val title: String? = null,
        @SerialName("home_page_url") val homePageUrl: String? = null,
        val icon: String? = null,
        val favicon: String? = null,
        val items: List<Item>? = null,
    ) {
        @Serializable
        data class Author(val name: String? = null)

        @Serializable
        data class Item(
            val id: String? = null,
            val url: String? = null,
            @SerialName("external_url") val externalUrl: String? = null,
            val title: String? = null,
            @SerialName("content_html") val contentHtml: String? = null,
            @SerialName("content_text") val contentText: String? = null,
            val summary: String? = null,
            @SerialName("date_published") val datePublished: String? = null,
            val author: Author? = null,
            val authors: List<Author>? = null,
        )
    }

    private fun jsonFeed(data: ByteArray, feedURL: String): ParsedFeed {
        val document = runCatching { json.decodeFromString(JsonFeedDocument.serializer(), data.decodeToString()) }.getOrNull()
        // `version` is what says it is a feed: everything else is optional, and a host's JSON
        // error page would otherwise subscribe the reader to nothing and report success.
        if (document == null || document.version.nonBlank() == null) throw NotAFeed()
        return ParsedFeed(
            title = document.title.nonBlank(),
            homePageURL = absolute(document.homePageUrl, feedURL),
            iconURL = absolute(document.icon ?: document.favicon, feedURL),
            items = document.items.orEmpty().map { item ->
                ParsedItem(
                    guid = item.id.nonBlank(),
                    // A link blog's `external_url` is what it points at; the item's own page comes first.
                    url = absolute(item.url ?: item.externalUrl, feedURL),
                    title = item.title.nonBlank(),
                    contentHTML = item.contentHtml.nonBlank() ?: item.contentText.nonBlank()?.let(::html) ?: item.summary.nonBlank(),
                    datePublished = FeedDate.parse(item.datePublished),
                    // 1.1 says `authors`, 1.0 said `author`.
                    author = item.authors?.firstNotNullOfOrNull { it.name.nonBlank() } ?: item.author?.name.nonBlank(),
                )
            },
        )
    }

    /** Text first (RSS), then an `href` that is not `rel="self"` — that one is the feed document itself. */
    private fun siteLink(element: XmlTree): String? {
        val links = element.children.filter { it.name == "link" }
        links.firstNotNullOfOrNull { it.text.nonBlank() }?.let { return it }
        return links.firstOrNull { val rel = it.attributes["rel"]?.lowercase(); rel == null || rel == "alternate" }
            ?.attributes?.get("href").nonBlank()
    }

    /** Resolved against the feed: by the time anything opens a relative link, its document is long gone. */
    internal fun absolute(raw: String?, base: String): String? {
        val text = raw.nonBlank() ?: return null
        return runCatching { URL(URL(base), text).toString() }.getOrNull()
    }

    /** Escaped, then split at its line breaks into `<p>`s, which is what the extractor splits on. */
    private fun html(text: String) = text.lines().mapNotNull { it.nonBlank() }
        .joinToString("") { "<p>${it.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")}</p>" }
}

/**
 * The dates feeds publish — the iOS `FeedDate`. RFC 822 (RSS) and RFC 3339 (Atom, JSON Feed) and
 * the shapes publishers trim them to. Null is a real answer: "now" for an unreadable date would
 * sort it to the top on every refresh.
 */
object FeedDate {
    fun parse(raw: String?): Long? {
        val text = raw.nonBlank() ?: return null
        runCatching { return OffsetDateTime.parse(text).toInstant().toEpochMilli() }
        for (pattern in PATTERNS) {
            // Created per call: SimpleDateFormat is not thread-safe, and a feed is a few dozen dates.
            val format = SimpleDateFormat(pattern, Locale.US).apply { timeZone = TimeZone.getTimeZone("GMT") }
            val at = ParsePosition(0)
            format.parse(text, at)?.let { return it.time }
        }
        // Last, and load-bearing: every reader here matches a prefix, so a date-only one tried
        // earlier reads `2002-10-02 08:00:00` as midnight and an afternoon post sorts before a morning one.
        return runCatching { LocalDate.parse(text.take(10)).atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli() }.getOrNull()
    }

    // `en_US` because the month is matched as text, and GMT because a pattern with no zone falls
    // back to it — the device's own zone is not an answer the publisher gave.
    private val PATTERNS = listOf(
        "EEE, d MMM yyyy HH:mm:ss zzz",
        "EEE, d MMM yyyy HH:mm zzz",
        "d MMM yyyy HH:mm:ss zzz",
        "d MMM yyyy HH:mm zzz",
        "EEE, d MMM yyyy HH:mm:ss",
        "EEE, d MMM yyyy HH:mm",
        "d MMM yyyy HH:mm:ss",
        // Neither standard, and common: an ISO date with the `T` written as a space.
        "yyyy-MM-dd HH:mm:ss Z",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm:ss",
    )
}

/**
 * The feed a web page declares in its head — the iOS `FeedDiscovery`. Only the declaration:
 * guessing at `/feed` and a dozen other paths would aim a dozen requests at a site that never
 * asked for them.
 */
object FeedDiscovery {
    /** In declaration order, a comments feed last rather than dropped: a site may publish nothing else. */
    fun feedURLs(html: ByteArray, pageURL: String): List<String> {
        // Lossy where nothing recognises the encoding: tag syntax is ASCII either way.
        val text = TextBookParser.decode(html) ?: html.decodeToString()
        val head = text.indexOf("</head", ignoreCase = true).let { if (it >= 0) text.substring(0, it) else text.take(64_000) }
        val found = mutableListOf<Pair<String, Boolean>>()
        val seen = HashSet<String>()
        for (tag in LINK.findAll(head)) {
            val attributes = attributes(tag.value)
            val rel = attributes["rel"]?.lowercase() ?: continue
            if ("alternate" !in rel.split(' ')) continue
            if (attributes["type"]?.lowercase() !in TYPES) continue
            val href = attributes["href"].nonBlank() ?: continue
            val url = FeedParser.absolute(unescaped(href), pageURL) ?: continue
            if (!seen.add(url)) continue
            found += url to isAside(attributes["title"], url)
        }
        return found.filter { !it.second }.map { it.first } + found.filter { it.second }.map { it.first }
    }

    fun feedURL(html: ByteArray, pageURL: String) = feedURLs(html, pageURL).firstOrNull()

    /** WordPress's comments feed: the path is generated and the same in every language, the title is not. */
    private fun isAside(title: String?, url: String): Boolean =
        runCatching { URL(url).path.lowercase() }.getOrDefault("").contains("comment") || title?.lowercase()?.contains("comment") == true

    private val LINK = Regex("<link\\b[^>]*>", RegexOption.IGNORE_CASE)
    private val PAIR = Regex("([a-zA-Z][a-zA-Z0-9:-]*)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+))")

    private fun attributes(tag: String): Map<String, String> {
        val result = HashMap<String, String>()
        for (match in PAIR.findAll(tag)) {
            val (name, double, single, bare) = match.destructured
            // First wins, as a browser reads a repeated attribute.
            result.putIfAbsent(name.lowercase(), double.ifEmpty { single.ifEmpty { bare } })
        }
        return result
    }

    /** `application/json` deliberately absent: pages advertise APIs under it. */
    private val TYPES = setOf("application/rss+xml", "application/atom+xml", "application/rdf+xml", "application/feed+json")

    /** `&amp;` last: `&amp;lt;` in a URL means the text `&lt;`. */
    private fun unescaped(value: String) = if ('&' !in value) value else value
        .replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&#39;", "'").replace("&apos;", "'")
        .replace("&amp;", "&")
}

/** The subscription list as a file, in the format every feed reader agrees on — the iOS `OPML`. */
object OPML {
    data class Subscription(val title: String?, val address: String)

    /** Every feed in the document, folders flattened (this app has none); an outline with no address is a folder or a note. */
    fun subscriptions(data: ByteArray): List<Subscription> {
        val root = XmlTree.parse(data) ?: return emptyList()
        val seen = HashSet<String>()
        return root.all("outline").mapNotNull { outline ->
            // `xmlUrl`, written every way twenty years of exporters could.
            val attributes = outline.attributes.mapKeys { it.key.lowercase() }
            val address = attributes["xmlurl"].nonBlank()?.takeIf { seen.add(it) } ?: return@mapNotNull null
            Subscription(attributes["title"].nonBlank() ?: attributes["text"].nonBlank(), address)
        }
    }

    /** `text` and `title` both, since importers disagree about which names a feed; `type="rss"` whatever it is, which every importer keys off. */
    fun document(title: String, subscriptions: List<Subscription>, now: Long = System.currentTimeMillis()): String {
        val outlines = subscriptions.joinToString("\n") { s ->
            val name = XmlTree.escaping(s.title ?: s.address, quotes = true)
            """    <outline text="$name" title="$name" type="rss" xmlUrl="${XmlTree.escaping(s.address, quotes = true)}"/>"""
        }
        val created = SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss 'GMT'", Locale.US).apply { timeZone = TimeZone.getTimeZone("GMT") }
            .format(java.util.Date(now))
        return """
            |<?xml version="1.0" encoding="UTF-8"?>
            |<opml version="1.0">
            |  <head>
            |    <title>${XmlTree.escaping(title)}</title>
            |    <dateCreated>$created</dateCreated>
            |  </head>
            |  <body>
            |$outlines
            |  </body>
            |</opml>
        """.trimMargin()
    }
}

/**
 * Which of a subscription's articles have outlived their welcome — the iOS `FeedRetention`. Pure,
 * apart from the deleting, because the rules are the substance: deleting a reader's archive is
 * not undoable, and keeping too much is the safe way to be wrong.
 */
object FeedRetention {
    /** [keepCount] 0 keeps everything; a null [unreadRetentionMs] keeps unread articles for ever. */
    data class Policy(val keepCount: Int, val graceMs: Long, val unreadRetentionMs: Long?)

    // The answers on offer, as iOS stores them — a count, and days — so a backup carries them across.
    // A short list rather than a free number: this is decided once, and 37 is nobody's reason.
    val KEEP_COUNTS = listOf(10, 25, 50, 100, 0)
    val GRACE_DAYS = listOf(1, 7, 30)
    val UNREAD_DAYS = listOf(7, 30, 90, 0)

    /**
     * @param chapters the whole catalog, oldest first.
     * @param stillPublished the oldest article the publisher's document still lists; nothing at
     * or after it goes, and nothing at all while it is unknown — a feed whose host has gone holds
     * articles that exist nowhere else.
     */
    fun purgeable(
        chapters: List<Chapter>,
        lastReadIndex: Int?,
        marked: Set<String>,
        stillPublished: Long?,
        policy: Policy,
        now: Long = System.currentTimeMillis(),
    ): List<Chapter> {
        if (policy.keepCount <= 0 || chapters.size <= policy.keepCount || stillPublished == null) return emptyList()
        return chapters.dropLast(policy.keepCount).filter { chapter ->
            when {
                // Where the reader stands: the stored position would name nothing.
                chapter.index == lastReadIndex -> false
                // A bookmark or a highlight, which would cascade away with the row.
                chapter.siteChapterId in marked -> false
                // Still in the publisher's window: it would come straight back, unread, every launch.
                (chapter.publishedAt ?: Long.MIN_VALUE) >= stillPublished -> false
                else -> {
                    val arrived = chapter.addedAt ?: chapter.publishedAt
                    when {
                        arrived == null || now - arrived < policy.graceMs -> false
                        // The reader has not had their turn with an unread one yet.
                        chapter.readAt == null -> policy.unreadRetentionMs?.let { now - arrived >= it } ?: false
                        else -> true
                    }
                }
            }
        }
    }
}
