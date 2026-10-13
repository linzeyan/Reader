package com.zeyanlin.novelreader.services

import android.webkit.CookieManager
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.util.Locale
import java.util.TreeMap

/**
 * A comic's pages on the device and off the site — iOS's `ChapterFileStore` page half,
 * `ChapterCache`'s pages and `ImageFetcher` in one. Every page is a file before it is a picture:
 * a downloaded chapter's under [downloads], one read online under [cache] — which the system
 * clears when space runs short, the job iOS's cache budget does by hand.
 */
class ComicPages(
    private val downloads: File,
    private val cache: File,
    /** Told how many bytes a page read online added to [cache], for the cache limit. */
    private val cached: suspend (Long) -> Unit = {},
    private val userAgent: suspend () -> String,
) {
    /** One page: where its bytes are or are to be put, and the address to fetch them from when they are not there yet. */
    data class Page(val index: Int, val file: File, val url: String?)

    class PageError(message: String) : Exception(message)

    fun downloaded(bookId: String, siteChapterId: String) = File(File(downloads, SiteStore.safeComponent(bookId)), SiteStore.safeComponent(siteChapterId))

    fun cached(bookId: String, siteChapterId: String) = File(File(cache, SiteStore.safeComponent(bookId)), SiteStore.safeComponent(siteChapterId))

    /**
     * Writes a chapter for keeps, all at once: into a side directory, then renamed in, so a
     * chapter is never half there. A page the site would not give up is written as an empty
     * marker in its place, so the numbering stays the site's and the reader can say which page
     * is absent instead of reading a short chapter as whole.
     */
    fun write(pages: List<ByteArray?>, directory: File) {
        val partial = File(directory.path + ".partial")
        partial.deleteRecursively()
        if (!partial.mkdirs()) throw IOException("cannot create $partial")
        pages.forEachIndexed { i, bytes -> File(partial, name(i) + if (bytes == null) GAP else "").writeBytes(bytes ?: ByteArray(0)) }
        directory.deleteRecursively()
        if (!partial.renameTo(directory)) throw IOException("cannot move $partial")
    }

    /**
     * Puts a fetched page where [page] says it belongs. The page lands before its gap marker
     * goes, so a crash between leaves both — which [stored] resolves in the page's favour.
     */
    fun store(bytes: ByteArray, page: Page) {
        val directory = page.file.parentFile!!
        directory.mkdirs()
        // Named so it never reads as a page: [stored] takes only names that start with a number.
        val part = File(directory, ".${page.file.name}.part")
        part.writeBytes(bytes)
        if (!part.renameTo(page.file)) throw IOException("cannot move $part")
        File(page.file.path + GAP).delete()
    }

    /** One page's bytes, asked for as the chapter's own page would: its address as referer, the site's cookies, a browser's agent. */
    suspend fun fetch(url: String, referer: String, index: Int, timeoutMs: Int): ByteArray {
        val headers = buildMap {
            put("User-Agent", userAgent())
            put("Referer", referer)
            // The web view's jar, so a page behind the site's verification comes with it; per address, so no host gets another's.
            CookieManager.getInstance().getCookie(url)?.let { put("Cookie", it) }
        }
        val reply = withContext(Dispatchers.IO) { get(url, headers, timeoutMs) }
        if (reply.status !in 200..299) throw PageError("第 ${index + 1} 頁下載失敗（HTTP ${reply.status}）。")
        // A 200 that is not a picture: a hotlink stub, a login page, a WAF interstitial.
        return reply.body?.takeIf { ImageFormat.sniff(it) != null } ?: throw PageError("第 ${index + 1} 頁回傳的不是圖片。")
    }

    private val reading = Semaphore(4)

    /**
     * A page onto the device for reading, unless it is there already. Four at a time across the
     * app, the handful a browser opens per host: a flick through a chapter composes every page it
     * passes, and fifty requests at once is the shape a CDN answers with a 429. Waiting is
     * cancellable; a request on the wire is finished even when nobody waits for it any more, so
     * a page flicked past is on disk when the reader comes back to it.
     */
    suspend fun bring(page: Page, referer: String) {
        suspend fun there() = withContext(Dispatchers.IO) { page.file.exists() }
        if (there()) return
        val url = page.url ?: throw PageError("第 ${page.index + 1} 頁當初沒有下載到，本話缺這一頁。")
        reading.withPermit {
            if (there()) return
            withContext(NonCancellable) {
                val bytes = fetch(url, referer, page.index, READ_TIMEOUT_MS)
                withContext(Dispatchers.IO) { store(bytes, page) }
                if (page.file.startsWith(cache)) cached(bytes.size.toLong())
            }
        }
    }

    /**
     * A chapter's pages for keeps, three at a time as iOS's window does. A page that will not
     * come is a gap rather than a failed chapter; only a chapter with no page at all fails.
     */
    suspend fun fetchAll(urls: List<String>, referer: String): List<ByteArray?> = coroutineScope {
        val gate = Semaphore(3)
        val results = urls.mapIndexed { i, url ->
            async {
                gate.withPermit {
                    try {
                        Result.success(fetch(url, referer, i, DOWNLOAD_TIMEOUT_MS))
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        Result.failure(e)
                    }
                }
            }
        }.awaitAll()
        if (results.none { it.isSuccess }) throw results.first().exceptionOrNull()!!
        results.map { it.getOrNull() }
    }

    fun downloadedBytes(bookId: String) = bytes(File(downloads, SiteStore.safeComponent(bookId)))

    fun cachedBytes(bookId: String) = bytes(File(cache, SiteStore.safeComponent(bookId)))

    /** One book's pages read online, or every book's when [bookId] is null. */
    fun clearCache(bookId: String?) = (if (bookId == null) cache else File(cache, SiteStore.safeComponent(bookId))).deleteRecursively()

    /** One book's downloads, or every book's when [bookId] is null. */
    fun deleteDownloads(bookId: String?) = (if (bookId == null) downloads else File(downloads, SiteStore.safeComponent(bookId))).deleteRecursively()

    /** Everything a book has here, kept or cached: what deleting it from the shelf takes. */
    fun deleteBook(bookId: String) {
        deleteDownloads(bookId)
        File(cache, SiteStore.safeComponent(bookId)).deleteRecursively()
    }

    private fun bytes(root: File) = root.walk().filter { it.isFile }.sumOf { it.length() }

    companion object {
        /** A page the site would not give up: `012.missing`, empty, holding page 12's place. */
        const val GAP = ".missing"

        /** Ten seconds of silence with a reader looking at the gap: the retry is theirs to press. */
        private const val READ_TIMEOUT_MS = 10_000

        /** A slow page is slow, not failed, when nobody is waiting on it. */
        private const val DOWNLOAD_TIMEOUT_MS = 30_000

        fun name(index: Int) = String.format(Locale.ROOT, "%03d", index)

        fun isGap(file: File) = file.name.endsWith(GAP)

        /**
         * A downloaded chapter's pages in reading order, empty when it is not downloaded. By the
         * number in the name, not the name, so page 1000 does not sort between 099 and 100; one
         * file per number, a real page winning over its marker.
         */
        fun stored(directory: File): List<File> {
            val byNumber = TreeMap<Int, File>()
            for (name in directory.list().orEmpty()) {
                val number = name.takeWhile { it.isDigit() }.toIntOrNull() ?: continue
                val existing = byNumber[number]
                if (existing == null || isGap(existing)) byNumber[number] = File(directory, name)
            }
            return byNumber.values.toList()
        }
    }
}
