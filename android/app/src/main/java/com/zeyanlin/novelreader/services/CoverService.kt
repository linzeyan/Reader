package com.zeyanlin.novelreader.services

import android.webkit.CookieManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException

/**
 * A book's cover on the device, fetched the first time it is drawn — the iOS `CoverService` and
 * `CoverStore`. By hand rather than from the address, because most comic sites refuse a picture
 * asked for without the page it sits on: the book's page as referer, the web view's agent and its
 * cookies, as [ComicPages] asks for a page. At first drawing rather than when the book is added, so
 * a restored shelf and a cover the site published later get theirs too.
 *
 * Two places where iOS keeps one: what came from a site sits in [cache], which 「清除網頁與封面快取」
 * empties and the next drawing fetches again; what came out of an imported archive sits in [kept],
 * since there is no site to fetch it from again.
 *
 * Not paced, as on iOS: a list composes only the rows on screen, so the burst is a screenful — the
 * shape a browser makes of a page of thumbnails.
 */
class CoverService(
    private val kept: File,
    private val cache: File,
    /** Outlives the row that asked: a row scrolled away stops waiting, not the fetch, so the cover is there when it comes back. */
    private val scope: CoroutineScope,
    /** A cover's bytes, or null when they will not come — [request] in the app. */
    private val fetch: suspend (address: String, siteId: String, siteBookId: String) -> ByteArray?,
) {
    /** One fetch per book however many rows ask: the shelf and 近期閱讀 draw the same book at once. */
    private val inFlight = HashMap<String, Deferred<File?>>()

    /**
     * Addresses that would not give a cover up. Hotlinked covers 403 or are missing as often as not,
     * so this is the expected state, and asking again whenever a row scrolls past would be a request
     * per flick. By address, not book: a search hit and the book it becomes share an id, not always a cover.
     */
    private val refused = HashSet<String>()

    fun keptFile(bookId: String) = File(kept, SiteStore.safeComponent(bookId))

    fun cachedFile(bookId: String) = File(cache, SiteStore.safeComponent(bookId))

    /** The cover this device has, an imported one first. Blocking. */
    fun stored(bookId: String): File? = listOf(keptFile(bookId), cachedFile(bookId)).firstOrNull { it.exists() }

    /** The cover's file, fetched first if need be; null for a book without one. Main thread only: nothing here is locked. */
    suspend fun cover(bookId: String, siteId: String, siteBookId: String, address: String?): File? {
        withContext(Dispatchers.IO) { stored(bookId) }?.let { return it }
        if (address == null || address in refused) return null
        return inFlight.getOrPut(bookId) {
            scope.async {
                val file = fetch(address, siteId, siteBookId)?.let { bytes ->
                    withContext(Dispatchers.IO) { runCatching { write(bytes, cachedFile(bookId)) }.getOrNull() }
                }
                inFlight.remove(bookId)
                if (file == null) refused += address
                file
            }
        }.await()
    }

    /** An imported comic's cover, for good. */
    fun keep(bytes: ByteArray, bookId: String) {
        write(bytes, keptFile(bookId))
    }

    /** What 「清除網頁與封面快取」 takes: every fetched cover, no imported one. */
    fun clearCache() = cache.deleteRecursively()

    fun delete(bookId: String) {
        keptFile(bookId).delete()
        cachedFile(bookId).delete()
    }

    /** Through a side file: the shelf draws this file the moment it appears, and half a cover draws as a broken one. */
    private fun write(bytes: ByteArray, file: File): File {
        file.parentFile!!.mkdirs()
        val part = File(file.path + ".part")
        part.writeBytes(bytes)
        if (!part.renameTo(file)) throw IOException("cannot move $part")
        return file
    }

    companion object {
        /** URLSession's default, which is what iOS asks for a cover with. */
        private const val TIMEOUT_MS = 60_000

        /**
         * One cover asked for as the book's page would ask: that page as referer when its source
         * is still installed, the web view's agent, its cookies for this address only. Null on any
         * failure: nothing shows it, and there is nothing the reader would do about it.
         */
        suspend fun request(address: String, referer: String?, userAgent: String): ByteArray? = withContext(Dispatchers.IO) {
            try {
                val headers = buildMap {
                    put("User-Agent", userAgent)
                    referer?.let { put("Referer", it) }
                    CookieManager.getInstance().getCookie(address)?.let { put("Cookie", it) }
                }
                // A 200 that is not a picture: a hotlink stub, a login page, a WAF interstitial.
                get(address, headers, TIMEOUT_MS).body?.takeIf { ImageFormat.sniff(it) != null }
            } catch (e: Exception) {
                null
            }
        }
    }
}
