package com.zeyanlin.novelreader.siterules

import java.net.URI

/**
 * Works out a site's URL templates and id regexes from one book URL plus the chapter links
 * found on it — the iOS `URLPatternInference`, which documents why each rule is the way it
 * is. A pure function over strings, pinned against real sites' URL shapes in the tests.
 */
object URLPatternInference {
    data class Inferred(
        val bookId: String,
        val bookTemplate: String,
        val chapterTemplate: String,
        val bookIdPattern: String,
        val chapterIdPattern: String,
    )

    const val BOOK_ID = "{bookId}"
    const val CHAPTER_ID = "{chapterId}"

    private const val SLUG_CLASS = "[0-9A-Za-z_-]"

    private val structuralWords = setOf(
        "book", "books", "novel", "novels", "n", "txt", "read", "chapter",
        "chapters", "list", "info", "index", "html", "htm", "php", "shtml",
        "xiaoshuo", "content", "view", "page", "comic", "comics", "manga",
    )

    fun infer(bookURL: String, chapterURLs: List<String>): Inferred? {
        val chapters = chapterURLs.map(::stripQuery).distinct()
        if (chapters.isEmpty()) return null
        val bookId = inferBookId(bookURL, chapters) ?: return null
        val bookTemplate = substituting(bookId, BOOK_ID, bookURL)
        // Only this book's links may shape the chapter template; see iOS.
        val owned = chapters.filter { bookId in it }
        if (owned.isEmpty()) return null
        val bodies = owned.map { substituting(bookId, BOOK_ID, it) }
        val chapterId = inferChapterId(bodies, bookId) ?: return null
        val chapterTemplate = substituting(chapterId, CHAPTER_ID, bodies.first())
        return Inferred(
            bookId = bookId,
            bookTemplate = bookTemplate,
            chapterTemplate = chapterTemplate,
            bookIdPattern = bookIdPattern(bookTemplate, bookId),
            chapterIdPattern = chapterIdPattern(chapterTemplate, chapterId),
        )
    }

    /** Path tokens that look like identifiers rather than structure, best first. */
    fun identifierTokens(url: String): List<String> =
        tokens(pathOf(url))
            .filter { it.length >= 2 && it.lowercase() !in structuralWords }
            .sortedByDescending(::score)

    /** A URL rewritten into a template by putting the placeholder where a known book id is. */
    fun template(url: String, bookId: String): String = substituting(bookId, BOOK_ID, url)

    private fun inferBookId(bookURL: String, chapterURLs: List<String>): String? {
        val needed = Math.ceil(chapterURLs.size * 0.3).toInt()
        return identifierTokens(bookURL).firstOrNull { candidate ->
            chapterURLs.count { candidate in it } >= maxOf(needed, 1)
        }
    }

    private fun score(token: String): Int {
        var value = token.length
        if (token.any { it.isDigit() }) value += 2
        if (token.lowercase() in structuralWords) value -= 5
        return value
    }

    private fun inferChapterId(bodies: List<String>, bookId: String): String? {
        if (bodies.size >= 2) {
            val a = tokens(bodies[0])
            for (other in bodies.drop(1)) {
                val b = tokens(other)
                if (a.size != b.size) continue
                val index = a.indices.lastOrNull { a[it] != b[it] }
                if (index != null) return a[index]
            }
        }
        return tokens(pathPortion(bodies[0]))
            .filter { it.length >= 2 && it != bookId && it != "bookId" }
            .maxByOrNull(::score)
    }

    private fun bookIdPattern(bookTemplate: String, bookId: String): String {
        val path = pathPortion(bookTemplate)
        val at = path.indexOf(BOOK_ID)
        if (at < 0) return path
        val suffix = if (path.getOrNull(at + BOOK_ID.length) == '/') "/" else ""
        return escaped(path.substring(0, at)) + "(" + characterClass(bookId) + "+)" + escaped(suffix)
    }

    private fun chapterIdPattern(chapterTemplate: String, chapterId: String): String {
        val out = StringBuilder()
        var rest = pathPortion(chapterTemplate)
        while (true) {
            val hit = listOf(BOOK_ID, CHAPTER_ID)
                .map { it to rest.indexOf(it) }
                .filter { it.second >= 0 }
                .minByOrNull { it.second } ?: break
            out.append(escaped(rest.substring(0, hit.second)))
            out.append(if (hit.first == BOOK_ID) "$SLUG_CLASS+" else "(" + characterClass(chapterId) + "+)")
            rest = rest.substring(hit.second + hit.first.length)
        }
        return out.append(escaped(rest)).toString()
    }

    private fun characterClass(id: String): String = if (id.all { it.isDigit() }) "\\d" else SLUG_CLASS

    /**
     * `NSRegularExpression.escapedPattern(for:)`, character for character (measured), so a
     * rule derived here reads the same as one derived on iOS — the file moves between them.
     */
    private fun escaped(literal: String): String = buildString {
        for (c in literal) {
            if (c in "$()*+./?[\\^{|}") append('\\')
            append(c)
        }
    }

    /** Runs of identifier characters; `_` and `-` are inside a token (twking's `216_216497`). */
    fun tokens(string: String): List<String> {
        val out = mutableListOf<String>()
        val current = StringBuilder()
        for (c in string) {
            if (c.isLetterOrDigit() || c == '_' || c == '-') {
                current.append(c)
            } else if (current.isNotEmpty()) {
                out += current.toString()
                current.clear()
            }
        }
        if (current.isNotEmpty()) out += current.toString()
        return out
    }

    /** Replaces the id in the path, never in the host. */
    private fun substituting(id: String, placeholder: String, url: String): String {
        val hostEnd = hostEnd(url) ?: return url.replace(id, placeholder)
        val tail = url.substring(hostEnd)
        val at = tail.indexOf(id)
        if (at < 0) return url
        return url.substring(0, hostEnd) + tail.substring(0, at) + placeholder + tail.substring(at + id.length)
    }

    private fun hostEnd(url: String): Int? {
        val schemeEnd = url.indexOf("://").takeIf { it >= 0 }?.plus(3) ?: return null
        return url.indexOf('/', schemeEnd).takeIf { it >= 0 } ?: url.length
    }

    private fun pathPortion(template: String): String = hostEnd(template)?.let { template.substring(it) } ?: template

    private fun stripQuery(url: String): String = url.substringBefore('#').substringBefore('?')

    /** Swift's `URL.path`: decoded, without query or fragment. */
    fun pathOf(url: String): String =
        runCatching { URI(url).path }.getOrNull()
            ?: stripQuery(pathPortion(url))
}
