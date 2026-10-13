package com.zeyanlin.novelreader.services

import android.content.SharedPreferences
import com.zeyanlin.novelreader.data.LibraryDao
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File

/**
 * The iOS `ChapterCache`'s ceiling over what was read online: texts in the database, a comic's
 * pages under [pages]. A download is the reader's to take away; this appears by itself, so it
 * makes room for itself — whole chapters, least recently read first, because half a comic
 * chapter is a page the reader scrolls into and waits for.
 */
class CacheLimit(private val library: LibraryDao, private val pages: File, private val prefs: SharedPreferences) {
    /** One chapter held: a text row, or a directory of pages. */
    data class Held(val bytes: Long, val usedAt: Long, val text: String? = null, val pages: File? = null)

    val limit: Long get() = prefs.getLong(KEY, DEFAULT)

    private val lock = Mutex()

    /**
     * Bytes held as of the last count plus the writes since — an estimate, so a page write
     * does not walk the whole cache. Nothing is deleted on it alone: pruning counts afresh.
     * Null until something is written.
     */
    private var used: Long? = null

    /** Lowering it takes effect at once: a setting that only applies to future reading did not do what it said. */
    suspend fun set(limit: Long) {
        prefs.edit().putLong(KEY, limit).apply()
        lock.withLock { used = prune() }
    }

    /** A chapter's text or a page read online just landed, [bytes] of it. */
    suspend fun added(bytes: Long) = lock.withLock {
        val now = used?.plus(bytes) ?: held().sumOf { it.bytes }
        used = if (now > limit) prune() else now
    }

    /** After a clear: the next write counts from the disk rather than from a total that is gone. */
    suspend fun forget() = lock.withLock { used = null }

    private suspend fun held(): List<Held> = withContext(Dispatchers.IO) {
        library.cachedTexts().map { Held(it.bytes, it.usedAt, text = it.id) } +
            // Two levels down, book then chapter: the layout ComicPages writes.
            pages.listFiles().orEmpty().flatMap { it.listFiles().orEmpty().asList() }.map { chapter ->
                Held(chapter.walk().filter { it.isFile }.sumOf { it.length() }, chapter.lastModified(), pages = chapter)
            }
    }

    private suspend fun prune(): Long = withContext(Dispatchers.IO) {
        val held = held()
        val dropped = victims(held, limit)
        // Chunked under SQLite's limit on bound variables: lowering the limit far can drop thousands.
        dropped.mapNotNull { it.text }.chunked(500).forEach { library.evictTexts(it) }
        dropped.forEach { it.pages?.deleteRecursively() }
        held.sumOf { it.bytes } - dropped.sumOf { it.bytes }
    }

    companion object {
        private const val KEY = "cache.limit"

        /** Under the app's cache directory: the pages read online, which this cache holds. */
        const val PAGES = "Pages"

        /** Under the app's cache directory: files on their way out of the app, which no cache holds. */
        const val EXPORTS = "Exports"

        /**
         * What the web view and the covers keep in [cacheDir]: all of it but [PAGES] and [EXPORTS].
         * By exclusion, so a cache put beside them is counted without this learning its name.
         */
        fun webBytes(cacheDir: File): Long = cacheDir.listFiles().orEmpty().filter { it.name != PAGES && it.name != EXPORTS }
            .sumOf { top -> top.walk().filter { it.isFile }.sumOf { it.length() } }

        // Decimal, as iOS has them: these are shown to a person, and a gibibyte drawn as
        // "1.07 GB" reads as a bug rather than as a unit nobody chose.
        const val DEFAULT = 1_000_000_000L

        /** Below this a comic chapter and its neighbour do not both fit, and the cache evicts what it just wrote. */
        const val MINIMUM = 250_000_000L

        /** Past this it has stopped being a cache and become a download nobody asked for. */
        const val MAXIMUM = 20_000_000_000L
        const val STEP = 250_000_000L

        /** The top of the slider: what the disk can spare, but never so little there is nothing to drag. */
        fun ceiling(free: Long) = minOf(MAXIMUM, maxOf(MINIMUM * 2, free))

        /** What goes to bring [held] under [limit]: least recently used first, whole, and no more than that. */
        fun victims(held: List<Held>, limit: Long): List<Held> {
            var total = held.sumOf { it.bytes }
            return held.sortedBy { it.usedAt }.takeWhile { chapter ->
                (total > limit).also { if (it) total -= chapter.bytes }
            }
        }
    }
}
