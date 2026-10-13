package com.zeyanlin.novelreader.services

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.webkit.WebSettings
import com.zeyanlin.novelreader.Refusal
import com.zeyanlin.novelreader.data.Book
import com.zeyanlin.novelreader.data.Chapter
import com.zeyanlin.novelreader.data.FeedEntry
import com.zeyanlin.novelreader.data.FeedFetchState
import com.zeyanlin.novelreader.data.LibraryDao
import com.zeyanlin.novelreader.network.ImportView
import com.zeyanlin.novelreader.siterules.ExtractorScript
import com.zeyanlin.novelreader.siterules.SiteRule
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.nio.charset.Charset
import java.util.Locale
import kotlin.math.roundToInt

/**
 * Subscriptions: reading a feed document, and keeping a book of chapters in step with it — the
 * iOS `FeedService`. Over plain HTTP rather than [com.zeyanlin.novelreader.network.WebFetcher]: a
 * feed is a static document on whoever's host, and routing it through the one web view would evict
 * whatever page the reader or a download is part way through. Only turning an article's markup into
 * blocks borrows a web view — the isolated [ImportView] an EPUB's documents go through.
 */
class FeedService(private val context: Context, private val library: LibraryDao) {
    /** An article the feed listed with no readable body. Thrown at opening, the only moment it matters. */
    class EmptyArticle : Exception("這篇沒有內文——訂閱源只給了標題和連結。")

    /**
     * How far the first read of a subscription has got, in articles stored — "3 / 27" says both how
     * long is left and that something is happening. [total] is zero for a headlines-only feed.
     */
    data class Progress(val stored: Int, val total: Int)

    /** An article's own page, read but not yet illustrated; [page] is where it landed, the pictures' Referer. */
    class FullText(val blocks: List<ArticleBlock>, val page: String)

    private val images = ArticleImages(File(context.filesDir, "Articles")) { userAgent() }

    // Subscribing

    /**
     * Subscribes and pulls the first batch of articles in the same breath: a subscription that
     * lands on the shelf as an empty screen is the one moment it has to feel like it worked.
     * What is pasted is usually the site, so a page is asked what feed it declares first.
     */
    suspend fun subscribe(address: String, progress: (Progress) -> Unit = {}): Book {
        val url = url(address) ?: throw badAddress()
        var response = read(url, null, FEED_TYPES)
        val parsed = try {
            FeedParser.parse(response.body ?: throw http(304), response.landed)
        } catch (e: FeedParser.NotAFeed) {
            // The original error when the page names no feed: "none was declared" would be a
            // sentence about a page the reader did not know they had fetched.
            val declared = FeedDiscovery.feedURL(response.body!!, response.landed) ?: throw e
            response = read(declared, null, FEED_TYPES)
            FeedParser.parse(response.body ?: throw http(304), response.landed)
        }
        // The address it landed on: an http feed redirected to https would otherwise be two books
        // holding the same articles — the book's id is built from this string.
        val book = library.bookmark(FEED_SITE_ID, response.landed, SiteRule.Kind.FEED, name(parsed, response.landed), null, parsed.iconURL)
        library.saveFeedFetchState(response.state(book.id, null))
        store(parsed, book, progress)
        return book
    }

    /** Reads a subscription again and takes in whatever is new. */
    suspend fun refresh(book: Book) {
        val url = url(book.siteBookId) ?: throw badAddress()
        val previous = library.feedFetchState(book.id)
        val response = read(url, previous, FEED_TYPES)
        // The window's line carried over, unlike iOS: a 304 re-draws nothing, and dropping it
        // would hold retention off until the publisher next posts.
        library.saveFeedFetchState(response.state(book.id, previous?.windowOldestAt))
        val body = response.body
        if (body == null) {
            // A 304 is a read of the index that found nothing new: as fresh as a full one.
            library.touchCatalog(book.id)
        } else {
            // No discovery here: a page from a subscription's address means the publisher moved
            // or lost the feed, and following it would repoint the book at another feed.
            store(FeedParser.parse(body, response.landed), book)
        }
    }

    // Full text

    /**
     * The piece read off the page it lives on, for the feed that published a headline and a link.
     * Returns once the words are stored; [fetchImages] follows with the article on screen, as a
     * browser shows the words first and fills the pictures in behind them.
     */
    suspend fun fetchFullText(chapter: Chapter): FullText {
        if (!isWeb(chapter.url)) throw EmptyArticle()
        val response = read(chapter.url, null, PAGE_TYPES)
        val html = decode(response.body ?: throw http(304), response.contentType)
        val blocks = withImportView {
            it.extract(html, ExtractorScript.article(response.landed, chapter.title, wholePage = true), ExtractorScript.ArticlePayload.serializer())
        }.blocks
        // A paywall, a consent wall, or an article built in script the import view will not run.
        if (blocks.none { it.hasContent }) throw EmptyArticle()
        save(chapter.id, blocks)
        return FullText(blocks, response.landed)
    }

    /** @return whether a picture reached the disk, so the reader knows a re-layout is worth it. */
    suspend fun fetchImages(text: FullText, chapter: Chapter): Boolean {
        if (text.blocks.none { it.type == ArticleBlock.Kind.IMAGE }) return false
        val illustrated = images.stored(text.blocks, chapter.id, text.page)
        if (illustrated.none { it.image?.file != null }) return false
        save(chapter.id, illustrated)
        return true
    }

    /** Where an article's picture is stored, for the reader to draw. */
    fun imageFile(chapterId: String, name: String) = File(images.directory(chapterId), name)

    // Retention

    /**
     * Deletes the articles this subscription no longer keeps; the rules are [FeedRetention]'s.
     * Files first, rows second: a crash between leaves a row whose text is gone, where the other
     * order leaves files nothing can find.
     */
    suspend fun purge(book: Book, policy: FeedRetention.Policy, now: Long = System.currentTimeMillis()): Int {
        if (book.kind != SiteRule.Kind.FEED || policy.keepCount <= 0) return 0
        val chapters = library.chaptersNow(book.id)
        val doomed = FeedRetention.purgeable(
            chapters,
            chapters.firstOrNull { it.siteChapterId == book.lastReadSiteChapterId }?.index,
            library.markedChapters(book.id).toSet(),
            library.feedFetchState(book.id)?.windowOldestAt,
            policy, now,
        )
        if (doomed.isEmpty()) return 0
        withContext(Dispatchers.IO) { doomed.forEach { images.directory(it.id).deleteRecursively() } }
        doomed.map { it.id }.chunked(500).forEach { library.removeChapters(it) }
        return doomed.size
    }

    /**
     * Picture directories whose article no longer has stored structure — a deleted book, deleted
     * downloads, a store cut short. Swept at launch rather than at each delete.
     * ponytail: deleted books keep their pictures until the next launch; delete at each scope if disk matters sooner.
     */
    suspend fun sweepImages() {
        val kept = library.articleIds().mapTo(HashSet()) { images.directory(it).name }
        withContext(Dispatchers.IO) { images.root.listFiles()?.filter { it.name !in kept }?.forEach { it.deleteRecursively() } }
    }

    // Storing

    /**
     * The catalog first, then a body for every article that just arrived — not every article with
     * no text: that also means one the reader deleted, or one the extractor could not read, and
     * neither should come back on every refresh.
     */
    private suspend fun store(parsed: ParsedFeed, book: Book, progress: (Progress) -> Unit = {}) {
        val arrived = library.mergeCatalog(
            book.id,
            parsed.items.map {
                // Empty for an article with no address of its own: the feed's would send "open the
                // original" to a document instead of a page.
                FeedEntry(it.identity, it.title.nonBlank() ?: UNTITLED, it.url.orEmpty(), it.datePublished)
            },
        )
        // Where the publisher's window starts, retention's line. Off the rows: an undated item was
        // stamped with its arrival on the way in, and that stamp is what everything compares.
        val listed = parsed.items.mapTo(HashSet()) { it.identity }
        library.chaptersNow(book.id).filter { it.siteChapterId in listed }.mapNotNull { it.publishedAt }.minOrNull()?.let { oldest ->
            library.feedFetchState(book.id)?.let { library.saveFeedFetchState(it.copy(windowOldestAt = oldest)) }
        }
        val pending = parsed.items.filter { it.identity in arrived }
        if (pending.isEmpty()) return
        progress(Progress(0, pending.size))
        withImportView { view ->
            pending.forEachIndexed { index, item ->
                currentCoroutineContext().ensureActive()
                // On every way out, the two that store nothing included: a count stalled on an
                // article with no body reports a subscription as stuck.
                try {
                    val html = item.contentHTML.nonBlank() ?: return@forEachIndexed
                    val chapterId = Chapter.makeId(book.id, item.identity)
                    // The article's address as the base: the markup loads with none, and every
                    // relative link and picture in it would resolve to nothing.
                    val script = ExtractorScript.article(item.url.nonBlank() ?: book.siteBookId, item.title, wholePage = false)
                    // One article that will not read must not cost the refresh the other forty-nine.
                    val blocks = try {
                        view.extract(html, script, ExtractorScript.ArticlePayload.serializer()).blocks
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        return@forEachIndexed
                    }
                    if (blocks.none { it.hasContent }) return@forEachIndexed
                    save(chapterId, images.stored(blocks, chapterId, item.url))
                } finally {
                    progress(Progress(index + 1, pending.size))
                }
            }
        }
    }

    /** The plain text block for block, empty ones too, so a paragraph index names the same place as a block index. */
    private suspend fun save(chapterId: String, blocks: List<ArticleBlock>) =
        library.storeArticle(chapterId, ArticleBlock.encode(blocks), Json.encodeToString(blocks.map { it.plainText }))

    private suspend fun <T> withImportView(work: suspend (ImportView) -> T): T {
        val view = withContext(Dispatchers.Main) { ImportView(context) }
        try {
            return work(view)
        } finally {
            withContext(NonCancellable + Dispatchers.Main) { view.close() }
        }
    }

    // Fetching

    /** One response before anything about it reaches the database; [body] is null exactly on a 304. */
    private class Response(val landed: String, val etag: String?, val lastModified: String?, val body: ByteArray?, val contentType: String?) {
        fun state(bookId: String, windowOldestAt: Long?) =
            FeedFetchState(bookId, etag, lastModified, System.currentTimeMillis(), windowOldestAt)
    }

    private suspend fun read(address: String, validators: FeedFetchState?, accept: String): Response {
        val headers = buildMap {
            put("User-Agent", userAgent())
            put("Accept", accept)
            validators?.etag?.let { put("If-None-Match", it) }
            validators?.lastModified?.let { put("If-Modified-Since", it) }
        }
        val reply = withContext(Dispatchers.IO) { get(address, headers, TIMEOUT_MS) }
        // A 304 carries no validators of its own; keeping the ones that produced it keeps the next
        // request conditional rather than a full download every other check.
        val etag = reply.etag ?: validators?.etag
        val lastModified = reply.lastModified ?: validators?.lastModified
        if (reply.status == 304) return Response(reply.landed, etag, lastModified, null, null)
        if (reply.status !in 200..299) throw http(reply.status)
        return Response(reply.landed, etag, lastModified, reply.body, reply.contentType)
    }

    private var agent: String? = null

    /** The web view's own agent: some hosts answer a library's default one with a 403. */
    private suspend fun userAgent(): String =
        agent ?: withContext(Dispatchers.Main) { WebSettings.getDefaultUserAgent(context) }.also { agent = it }

    companion object {
        /** The site id every subscription is filed under; its book id is the feed's address. */
        const val FEED_SITE_ID = "feed"
        const val UNTITLED = "（無標題）"
        private const val TIMEOUT_MS = 20_000

        /** Not a filter, but the sites that serve readers one document and browsers another key off it. */
        private const val FEED_TYPES =
            "application/atom+xml, application/rss+xml, application/feed+json, application/xml;q=0.9, text/xml;q=0.9, application/json;q=0.8, */*;q=0.5"

        /** A browser's, for a page: here the browser's copy of the page is the one wanted. */
        private const val PAGE_TYPES = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"

        private fun badAddress() = Refusal("這不是一個讀得到的網址。")

        private fun http(status: Int) = Refusal("訂閱源回應了 HTTP $status。")

        fun isWeb(address: String) = runCatching { URI(address).scheme?.lowercase() }.getOrNull().let { it == "http" || it == "https" }

        /**
         * The address to fetch from whatever was pasted. `feed://` is what a browser's subscribe
         * link carries — http in a costume, and `feed:https://…` the whole address behind a
         * prefix; a bare `example.com/feed.xml` is how an address read off a page arrives.
         */
        fun url(address: String): String? {
            val trimmed = address.nonBlank() ?: return null
            val url = when (runCatching { URI(trimmed).scheme?.lowercase() }.getOrNull()) {
                "http", "https" -> trimmed
                "feed" -> trimmed.drop("feed:".length).trim('/').let { if ("://" in it) it else "https://$it" }
                null -> "https://$trimmed"
                else -> return null
            }
            return url.takeIf { runCatching { URI(it).host }.getOrNull().nonBlank() != null }
        }

        /** The server an address asks, so two subscriptions on one host never ask at once. */
        fun host(address: String): String = url(address)?.let { runCatching { URI(it).host?.lowercase() }.getOrNull() } ?: address

        /** The host rather than the whole address: a shelf row is a thumbnail wide. */
        private fun name(feed: ParsedFeed, landed: String) =
            feed.title.nonBlank() ?: runCatching { URI(landed).host }.getOrNull().nonBlank() ?: landed

        private val CHARSET = Regex("""charset\s*=\s*["']?([\w.:-]+)""", RegexOption.IGNORE_CASE)

        /** A page in the charset it declares — the header, else its own meta tag — else UTF-8. */
        internal fun decode(body: ByteArray, contentType: String?): String {
            val declared = contentType?.let { CHARSET.find(it) }
                ?: CHARSET.find(String(body, 0, minOf(body.size, 4096), Charsets.ISO_8859_1))
            val charset = declared?.let { runCatching { Charset.forName(it.groupValues[1]) }.getOrNull() } ?: Charsets.UTF_8
            return String(body, charset)
        }
    }
}

/** One HTTP exchange, the body read only on success. */
internal class HttpReply(val landed: String, val status: Int, val etag: String?, val lastModified: String?, val contentType: String?, val body: ByteArray?)

/**
 * A blocking GET that follows redirects by hand: [HttpURLConnection] will not cross from http to
 * https, the commonest redirect a feed has, and the address it lands on is what a subscription is.
 * Never cached: a 200 rebuilt from a cache would hide the 304 the validators exist for.
 */
internal fun get(address: String, headers: Map<String, String>, timeoutMs: Int): HttpReply {
    var url = address
    repeat(MAX_REDIRECTS) {
        if (!FeedService.isWeb(url)) throw Refusal("這不是一個讀得到的網址。")
        val connection = URL(url).openConnection() as HttpURLConnection
        try {
            connection.instanceFollowRedirects = false
            connection.useCaches = false
            connection.connectTimeout = timeoutMs
            connection.readTimeout = timeoutMs
            headers.forEach { (name, value) -> connection.setRequestProperty(name, value) }
            val status = connection.responseCode
            val location = connection.getHeaderField("Location")
            if (status in 300..399 && status != 304 && location != null) {
                url = URL(URL(url), location).toString()
                return@repeat
            }
            val body = if (status in 200..299) connection.inputStream.use { it.readBytes() } else null
            return HttpReply(
                url, status, connection.getHeaderField("ETag"), connection.getHeaderField("Last-Modified"),
                connection.contentType, body,
            )
        } finally {
            connection.disconnect()
        }
    }
    throw Refusal("重新導向的次數太多。")
}

private const val MAX_REDIRECTS = 10

/**
 * An article's pictures onto the device with its words — the iOS `ArticleImages`. A subscription is
 * read the way a download is, offline, and a picture fetched at layout time is missing exactly when
 * the reading happens. One directory per article, so retention takes its pictures with it.
 */
internal class ArticleImages(val root: File, private val userAgent: suspend () -> String) {
    fun directory(chapterId: String) = File(root, SiteStore.safeComponent(chapterId))

    /**
     * The blocks again, every picture that arrived pointing at its file. One that will not come is
     * no error: the block keeps its address and alt text, which the reader draws in its place.
     */
    suspend fun stored(blocks: List<ArticleBlock>, chapterId: String, referer: String?): List<ArticleBlock> {
        val wanted = blocks.withIndex().filter { (_, block) ->
            block.type == ArticleBlock.Kind.IMAGE && block.image?.source?.let(FeedService::isWeb) == true
        }
        if (wanted.isEmpty()) return blocks
        val headers = buildMap {
            put("User-Agent", userAgent())
            // A host that serves its pictures only to its own pages answers 403 to one from nowhere.
            referer.nonBlank()?.let { put("Referer", it) }
        }
        // Six at once: what a browser opens per host, and a post's pictures are all one CDN —
        // twenty at once from one reader is the shape that gets answered with a 429.
        val gate = Semaphore(MAX_CONCURRENT)
        val fetched = coroutineScope {
            wanted.map { (position, block) ->
                async(Dispatchers.IO) { gate.withPermit { fetch(block.image!!.source, headers)?.let(::prepare)?.let { position to it } } }
            }.awaitAll()
        }
        val directory = directory(chapterId)
        val stored = blocks.toMutableList()
        withContext(Dispatchers.IO) {
            for ((position, picture) in fetched.filterNotNull()) {
                // Named after its block, unique without a counter; the extension from the bytes,
                // which an address is no evidence of.
                val name = String.format(Locale.ROOT, "%03d", position) + (ImageFormat.sniff(picture.data)?.let { "." + it.extension } ?: "")
                if (runCatching { directory.mkdirs(); File(directory, name).writeBytes(picture.data) }.isFailure) continue
                val block = stored[position]
                stored[position] = block.withImage(block.image!!.copy(file = name, width = picture.width, height = picture.height))
            }
        }
        return stored
    }

    private class Picture(val data: ByteArray, val width: Int, val height: Int)

    /** Ten seconds: a CDN that is going to answer answers quickly, and one that stalls stalls for as long as it is given. */
    private fun fetch(source: String, headers: Map<String, String>): ByteArray? = try {
        // A 200 that is not a picture: a hotlink stub, a login page, a WAF interstitial.
        get(source, headers, 10_000).body?.takeIf { ImageFormat.sniff(it) != null }
    } catch (e: Exception) {
        null
    }

    /**
     * Stored as it arrived when within the cap: re-encoding costs a generation for nothing, and
     * would lose a GIF's animation or a PNG's transparency. Above it, a 4000×3000 press photo is
     * forty-eight megabytes of bitmap inside a column of prose.
     * ponytail: EXIF orientation is not applied to a downscaled JPEG; read it with ExifInterface if sideways photos turn up.
     */
    private fun prepare(data: ByteArray): Picture? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(data, 0, data.size, bounds)
        val width = bounds.outWidth
        val height = bounds.outHeight
        if (width <= 0 || height <= 0) return null
        if (maxOf(width, height) <= MAX_PIXEL_SIZE) return Picture(data, width, height)
        var sample = 1
        while (maxOf(width, height) / (sample * 2) >= MAX_PIXEL_SIZE) sample *= 2
        val decoded = BitmapFactory.decodeByteArray(data, 0, data.size, BitmapFactory.Options().apply { inSampleSize = sample }) ?: return null
        val scale = MAX_PIXEL_SIZE.toFloat() / maxOf(decoded.width, decoded.height)
        val scaled = if (scale < 1) {
            Bitmap.createScaledBitmap(decoded, (decoded.width * scale).roundToInt().coerceAtLeast(1), (decoded.height * scale).roundToInt().coerceAtLeast(1), true)
        } else {
            decoded
        }
        // PNG where there is transparency — a logo, a diagram — or it becomes a black rectangle; JPEG for a photograph.
        val out = ByteArrayOutputStream()
        scaled.compress(if (scaled.hasAlpha()) Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG, 85, out)
        return Picture(out.toByteArray(), scaled.width, scaled.height)
    }

    private companion object {
        const val MAX_PIXEL_SIZE = 2048
        const val MAX_CONCURRENT = 6
    }
}
