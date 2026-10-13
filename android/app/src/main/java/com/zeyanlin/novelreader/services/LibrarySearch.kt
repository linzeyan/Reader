package com.zeyanlin.novelreader.services

import com.zeyanlin.novelreader.data.Book
import com.zeyanlin.novelreader.data.Chapter
import com.zeyanlin.novelreader.data.LibraryDao
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json

/** One chapter of one book that holds what the reader searched for — the iOS `LibraryTextHit`. */
data class LibraryTextHit(
    val book: Book,
    /** Read from the catalog, so a title the site has since corrected reads correctly here too. */
    val chapterTitle: String,
    val siteChapterId: String,
    val excerpt: FullTextExcerpt,
) {
    val id get() = Chapter.makeId(book.id, siteChapterId)
}

/**
 * Searching the text of the chapters this device has downloaded — the iOS `LibrarySearch`.
 * Two passes, as there: the database narrows the library to candidates, then each candidate's
 * text is opened to find the passage, quote it in its own script and say which paragraph it
 * is in. A candidate whose text no longer holds the words is dropped, not offered as a row
 * that opens onto nothing.
 *
 * Where iOS asks an FTS5 trigram index, this scans a folded copy kept beside each text: the
 * platform SQLite has no trigram tokenizer before Android 14, and FTS3/4's tokenizers cannot
 * see inside a Chinese sentence.
 * ponytail: a linear scan of every downloaded chapter (11 ms for 1,242 chapters, 8 MB, by
 * sqlite3 on a Mac; a phone is several times slower); a bundled SQLite with FTS5 trigram if
 * libraries grow to where that shows.
 */
class LibrarySearch(private val library: LibraryDao) {
    suspend fun hits(query: String): List<LibraryTextHit> = withContext(Dispatchers.Default) {
        val trimmed = query.trim()
        if (trimmed.codePointCount(0, trimmed.length) < MINIMUM_QUERY_LENGTH) return@withContext emptyList()
        val candidates = library.textCandidates(needle(trimmed), CANDIDATE_LIMIT)
        if (candidates.isEmpty()) return@withContext emptyList()
        val books = library.allBooksNow().associateBy { it.id }
        val hits = ArrayList<LibraryTextHit>()
        for (candidate in candidates) {
            if (hits.size >= MAXIMUM_RESULTS) break
            val book = books[candidate.bookId] ?: continue
            val paragraphs = library.cachedParagraphs(candidate.chapterId)?.let { Json.decodeFromString<List<String>>(it) } ?: continue
            val excerpt = FullTextExcerpt.first(trimmed, paragraphs) ?: continue
            hits += LibraryTextHit(book, candidate.title, candidate.siteChapterId, excerpt)
        }
        hits
    }

    companion object {
        /** One character matches most chapters of most books: a slow way to list the library. */
        const val MINIMUM_QUERY_LENGTH = 2

        /** A reader scanning results is looking for one passage; six hundred rows narrow nothing. */
        const val MAXIMUM_RESULTS = 50

        /** The ceiling on chapters opened for one search, for when the scan proposes many. */
        const val CANDIDATE_LIMIT = 400

        private val FOLD = ChineseScript(ChineseScript.Depth.CHARACTERS, ChineseScript.Target.SIMPLIFIED)

        /**
         * The one form both scripts are written down as — the iOS `FullTextQuery.folded`. A
         * reader in Taiwan typing 「鬥破蒼穹」 must find the chapter a simplified site served, and
         * 「裡」 the chapter that spells it 「裏」. Character by character, so a query and a chapter
         * fold alike without seeing each other, and offsets found in the folded text name the
         * same characters in the original; toward simplified, because simplifying merges.
         */
        fun folded(text: String) = ChineseText.rendered(text, FOLD)

        /**
         * The query as it appears inside a folded, JSON-encoded chapter: folded, then escaped the
         * way the encoder escaped the paragraphs, so a quote or a backslash in what the reader
         * typed is looked for as itself. Can match across an escape — a false candidate the
         * second pass drops — but never misses a run inside one paragraph.
         */
        fun needle(query: String): String = Json.encodeToString(folded(query)).let { it.substring(1, it.length - 1) }
    }
}

/**
 * Where in a chapter a hit sits, and enough of the text around it to recognise — the iOS
 * `FullTextExcerpt`. Found again in the chapter's own paragraphs, the array the reader loads,
 * so the quotation is in the script the reader would see and the paragraph number is the one
 * the reader's anchor means.
 */
data class FullTextExcerpt(
    val paragraph: Int,
    /** In UTF-16 units, the reader anchor's unit. */
    val characterOffset: Int,
    /** The quotation, elided at each end that was cut. */
    val text: String,
    /** Where the searched-for run sits in [text]: it need not be in the query's script. */
    val matchStart: Int,
    val matchEnd: Int,
) {
    companion object {
        /** Code points either side: enough to place the hit in its sentence, not to wrap past two lines. */
        const val CONTEXT = 24

        /** The first place [query] occurs, both sides folded; first, as one chapter is one row. */
        fun first(query: String, paragraphs: List<String>): FullTextExcerpt? {
            val needle = LibrarySearch.folded(query)
            if (needle.isEmpty()) return null
            paragraphs.forEachIndexed { index, original ->
                val folded = LibrarySearch.folded(original)
                // A fold that moved a length cannot place anything; another paragraph may.
                if (folded.length != original.length) return@forEachIndexed
                val lower = folded.indexOf(needle)
                if (lower < 0) return@forEachIndexed
                val upper = lower + needle.length
                // Offsets inside a surrogate pair would quote half a character.
                if (Character.isLowSurrogate(original[lower]) || (upper < original.length && Character.isLowSurrogate(original[upper]))) {
                    return@forEachIndexed
                }
                val head = runCatching { original.offsetByCodePoints(lower, -CONTEXT) }.getOrDefault(0)
                val tail = runCatching { original.offsetByCodePoints(upper, CONTEXT) }.getOrDefault(original.length)
                val leading = if (head > 0) "…" else ""
                val trailing = if (tail < original.length) "…" else ""
                val start = leading.length + lower - head
                return FullTextExcerpt(index, lower, leading + original.substring(head, tail) + trailing, start, start + upper - lower)
            }
            return null
        }
    }
}
