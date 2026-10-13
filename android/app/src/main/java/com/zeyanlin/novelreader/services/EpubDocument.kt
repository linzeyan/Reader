package com.zeyanlin.novelreader.services

import org.w3c.dom.Element
import org.xml.sax.InputSource
import java.io.File
import java.io.StringReader
import java.net.URLDecoder
import java.util.zip.ZipFile
import javax.xml.parsers.DocumentBuilderFactory

/**
 * The parts of an EPUB the importer needs: the book's metadata, and the reading order with each
 * document's markup and its table-of-contents title — the iOS `EpubDocument`. The chapter text
 * is not read here: that is `ExtractorScript`'s job, so an imported book and a fetched page go
 * through the same normalisation.
 */
class EpubDocument(val title: String?, val author: String?, val items: List<Item>) {
    /** [path] is kept for diagnosis when chapters come out in an order nobody expected. */
    class Item(val path: String, val tocTitle: String?, val xhtml: String)

    companion object {
        /** A random-access archive rather than a stream: the spine names entries in any order. */
        fun parse(file: File): EpubDocument = ZipFile(file).use { zip ->
            fun text(path: String) = zip.getEntry(path)?.let { entry -> zip.getInputStream(entry).use { it.readBytes() } }
                ?.toString(Charsets.UTF_8)?.removePrefix("\uFEFF")

            val opfPath = text("META-INF/container.xml")?.let(::xml)?.first("rootfile")?.attr("full-path")
                ?: throw LocalBookError.Malformed("no readable META-INF/container.xml")
            val opf = text(opfPath)?.let(::xml)
                ?: throw LocalBookError.Malformed("package document $opfPath is missing or unreadable")
            val opfDirectory = directory(opfPath)

            val manifest = opf.first("manifest")?.all("item").orEmpty().mapNotNull { item ->
                val id = item.attr("id") ?: return@mapNotNull null
                val href = item.attr("href") ?: return@mapNotNull null
                id to Manifest(href, item.attr("media-type").orEmpty(), item.attr("properties").orEmpty())
            }.toMap()

            // `linear="no"` is the attribute saying a document is not part of the reading
            // order — copyright plates, footnote collections, sometimes the nav itself.
            val spine = opf.first("spine")?.all("itemref").orEmpty().mapNotNull { reference ->
                if (reference.attr("linear")?.lowercase() == "no") return@mapNotNull null
                manifest[reference.attr("idref")]?.let { resolve(it.href, opfDirectory) }
            }

            // EPUB 3's nav first, the ncx second — the order a reading system must prefer them
            // in. One that will not parse costs the titles, not the import.
            val navTitles = manifest.values.firstOrNull { "nav" in it.properties }?.let { nav ->
                val path = resolve(nav.href, opfDirectory)
                val document = text(path)?.let(::xml) ?: return@let null
                // A nav holds several lists — toc, landmarks, page-list — and only `toc` names chapters.
                val navs = document.all("nav")
                val toc = navs.firstOrNull { it.attr("type")?.contains("toc") == true } ?: navs.firstOrNull()
                toc?.all("a")?.mapNotNull { a -> a.attr("href")?.let { resolve(it, directory(path)) to a.textContent } }
            }?.let(::titles)?.takeIf { it.isNotEmpty() }
            val tocTitles = navTitles ?: run {
                val ncxHref = opf.first("spine")?.attr("toc")?.let { manifest[it]?.href }
                    ?: manifest.values.firstOrNull { it.mediaType == "application/x-dtbncx+xml" }?.href
                    ?: return@run emptyMap()
                val path = resolve(ncxHref, opfDirectory)
                val document = text(path)?.let(::xml) ?: return@run emptyMap()
                titles(
                    document.all("navPoint").mapNotNull { point ->
                        val target = point.first("content")?.attr("src") ?: return@mapNotNull null
                        val label = point.first("text")?.textContent ?: return@mapNotNull null
                        resolve(target, directory(path)) to label
                    },
                )
            }

            // A spine entry the archive lacks is skipped: the rest is still worth reading,
            // and the chapter count on screen says something is off.
            val items = spine.mapNotNull { path -> text(path)?.let { Item(path, tocTitles[path], it) } }
            if (items.isEmpty()) throw LocalBookError.Empty()
            val metadata = opf.first("metadata")
            EpubDocument(metadata?.first("title")?.textContent, metadata?.first("creator")?.textContent, items)
        }

        /**
         * An href as an archive path: fragment dropped, percent-decoded (hrefs are URLs, ZIP
         * entry names are not), `.` and `..` resolved against [directory].
         */
        fun resolve(href: String, directory: String): String {
            val path = href.substringBefore('#')
            // `+` survives: URLDecoder is a form decoder, and in a path a plus is a plus.
            val decoded = runCatching { URLDecoder.decode(path.replace("+", "%2B"), "UTF-8") }.getOrDefault(path)
            val parts = directory.split('/').filter { it.isNotEmpty() }.toMutableList()
            for (part in decoded.split('/').filter { it.isNotEmpty() }) {
                when (part) {
                    "." -> Unit
                    ".." -> parts.removeLastOrNull()
                    else -> parts += part
                }
            }
            return parts.joinToString("/")
        }

        fun directory(path: String) = path.substringBeforeLast('/', "")

        private class Manifest(val href: String, val mediaType: String, val properties: String)

        /** First title wins: a toc points at one document once per section, and the first names the chapter. */
        private fun titles(links: List<Pair<String, String>>): Map<String, String> {
            val titles = LinkedHashMap<String, String>()
            for ((path, title) in links) title.trim().takeIf { it.isNotEmpty() }?.let { titles.putIfAbsent(path, it) }
            return titles
        }

        /**
         * Null rather than throwing, so each caller decides what an unreadable document costs.
         * Namespaces off and prefixes stripped by hand, as iOS does: producers disagree about
         * which prefix goes on what (`dc:title` or `title`, `epub:type`). External entities and
         * DTDs resolve to nothing — XHTML routinely names the W3C's, and a file must not make
         * the app fetch anything.
         */
        private fun xml(text: String): Element? = runCatching {
            val builder = DocumentBuilderFactory.newInstance().newDocumentBuilder()
            builder.setEntityResolver { _, _ -> InputSource(StringReader("")) }
            builder.setErrorHandler(null)
            builder.parse(InputSource(StringReader(text))).documentElement
        }.getOrNull()

        private val Element.bareName get() = tagName.substringAfterLast(':')

        /** Every descendant called [name], in document order. Descendants, because producers nest differently. */
        private fun Element.all(name: String): List<Element> {
            val nodes = getElementsByTagName("*")
            return (0 until nodes.length).map { nodes.item(it) as Element }.filter { it.bareName == name }
        }

        private fun Element.first(name: String) = all(name).firstOrNull()

        private fun Element.attr(name: String): String? {
            for (i in 0 until attributes.length) {
                val attribute = attributes.item(i)
                if (attribute.nodeName.substringAfterLast(':') == name) return attribute.nodeValue
            }
            return null
        }
    }
}
