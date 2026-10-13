package com.zeyanlin.novelreader.services

import android.content.Context
import com.zeyanlin.novelreader.data.Book
import com.zeyanlin.novelreader.data.Chapter
import com.zeyanlin.novelreader.data.LibraryDao
import com.zeyanlin.novelreader.siterules.SiteRule
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.net.URLDecoder
import java.net.URLEncoder
import java.security.MessageDigest
import java.util.UUID
import java.util.zip.ZipFile

/**
 * Turns a ZIP of folders into a comic on the shelf — the iOS `ComicArchiveImporter`. It reads the
 * shape [BookExporter] writes and the one anybody would build by hand: a folder for the comic, a
 * folder per chapter, the pages inside. Anything else in the archive is ignored, not refused.
 *
 * An imported comic is a bookmark under [SiteStore.LOCAL_SITE_ID] whose chapters land through
 * [ComicPages.write], the call a download makes: the reader, the storage screen and the delete
 * scopes work on it without knowing it came from a file.
 */
class ComicArchiveImporter(private val context: Context, private val library: LibraryDao, private val comics: ComicPages, private val covers: CoverService) {
    suspend fun import(open: () -> InputStream?, name: String, progress: (Double) -> Unit): Book {
        // ponytail: a copy the archive's size sits in the cache for the import, because ZipFile
        // wants a file it can seek in and a picked document is a stream; read the descriptor in
        // place if large archives run the cache dry.
        val file = File(context.cacheDir, "import-${UUID.randomUUID()}.zip")
        try {
            return withContext(Dispatchers.IO) {
                copy(open, file)
                ensureActive()
                zip(file).use { zip ->
                    val names = zip.entries().asSequence().filterNot { it.isDirectory }.map { it.name }.toList()
                    val found = structure(names, name.substringBeforeLast('.'))
                    if (found.chapters.isEmpty()) throw LocalBookError.Empty()
                    store(found, zip, progress)
                }
            }
        } finally {
            file.delete()
        }
    }

    private fun copy(open: () -> InputStream?, to: File) {
        try {
            val input = open() ?: throw LocalBookError.Unreadable()
            input.use { stream -> to.outputStream().use { stream.copyTo(it) } }
        } catch (e: IOException) {
            throw LocalBookError.Unreadable()
        } catch (e: SecurityException) {
            throw LocalBookError.Unreadable()
        }
    }

    /**
     * Android reads a name that is not UTF-8 with replacement characters rather than refusing the
     * archive — what iOS's Latin-1 fallback is for: a garbled chapter name beats a refused comic.
     * ponytail: names from GBK/Big5 tools read as `��1��`; decode them through
     * [TextBookParser]'s encoding guess if such archives turn up.
     */
    private fun zip(file: File): ZipFile = try {
        ZipFile(file)
    } catch (e: IOException) {
        throw LocalBookError.BadArchive(e.message ?: e.javaClass.simpleName)
    }

    /**
     * The row, the merged catalog and every page — the only phase that writes, so the only one
     * that undoes itself. A first import that fails leaves no trace; a second part that fails
     * leaves the first exactly as it was.
     */
    private suspend fun store(found: Structure, zip: ZipFile, progress: (Double) -> Unit): Book {
        val siteBookId = identifier(found.title)
        val bookId = Book.makeId(SiteStore.LOCAL_SITE_ID, siteBookId)
        // Both read before anything is written: they are what a rollback puts back.
        val previous = library.chaptersNow(bookId).map { BookService.CatalogEntry(it.siteChapterId, it.title, it.url) }
        val wasOnShelf = library.bookNow(bookId) != null
        val incoming = identify(found.chapters)
        val book = library.bookmark(SiteStore.LOCAL_SITE_ID, siteBookId, SiteRule.Kind.COMIC, found.title, null, null)
        val written = mutableListOf<String>()
        var firstPage: ByteArray? = null
        try {
            library.replaceCatalog(book.id, merge(incoming, previous, siteBookId))
            val skipped = HashSet<String>()
            incoming.forEachIndexed { offset, (id, chapter) ->
                currentCoroutineContext().ensureActive()
                // The bytes decide: a `.jpg` that is really an error page is a page nothing can draw.
                val pages = chapter.pages.mapNotNull { entry ->
                    zip.getInputStream(zip.getEntry(entry)).use { it.readBytes() }.takeIf { ImageFormat.sniff(it) != null }
                }
                if (pages.isEmpty()) {
                    skipped += id
                } else {
                    firstPage = firstPage ?: pages.first()
                    comics.write(pages, comics.downloaded(book.id, id))
                    written += id
                    library.markDownloaded(Chapter.makeId(book.id, id))
                }
                progress((offset + 1).toDouble() / incoming.size)
            }
            // A folder with no readable picture is not a chapter: a row for it would open onto an error forever.
            if (skipped.isNotEmpty()) {
                val kept = incoming.filter { it.first !in skipped }
                if (kept.isEmpty()) throw LocalBookError.Empty()
                library.replaceCatalog(book.id, merge(kept, previous, siteBookId))
            }
            // An imported comic has no site to fetch a cover from. The archive's own wins over what is
            // there — someone put it in the file on purpose; else the first page, which is what the
            // comic looks like, unless an earlier part already gave it one.
            val archived = found.cover?.let { name -> zip.getInputStream(zip.getEntry(name)).use { it.readBytes() } }?.takeIf { ImageFormat.sniff(it) != null }
            (archived ?: firstPage?.takeIf { covers.stored(book.id) == null })?.let { covers.keep(it, book.id) }
        } catch (e: Throwable) {
            // A chapter that was already here is left alone even if this import wrote over it:
            // pages land all at once, so it is whole either way, and deleting it would make a
            // failed import cost the reader a chapter they had.
            withContext(NonCancellable) {
                val had = previous.map { it.siteChapterId }.toSet()
                written.filter { it !in had }.forEach { comics.downloaded(book.id, it).deleteRecursively() }
                if (wasOnShelf) {
                    runCatching { library.replaceCatalog(book.id, previous) }
                } else {
                    comics.deleteBook(book.id)
                    covers.delete(book.id)
                    runCatching { library.deleteBook(book.id) }
                }
            }
            throw e
        }
        return library.bookNow(book.id) ?: book
    }

    /** One chapter as the archive has it: the folder that orders it, the name it shows, its pages' entry names in order. */
    data class Found(val folder: String, val title: String, val pages: List<String>)

    /** [cover] is the entry name of a picture called `cover…` beside the chapter folders. */
    data class Structure(val title: String, val chapters: List<Found>, val cover: String? = null)

    companion object {
        private val RUNS = Regex("[0-9]+|[^0-9]+")

        /**
         * Finder's order, as iOS's `localizedStandardCompare` gives it: runs of digits by their
         * value, the rest without case — so `第2話` comes before `第10話`, and `9.jpg` before `10.jpg`.
         */
        val NATURAL = Comparator<String> { a, b ->
            val x = RUNS.findAll(a).map { it.value }.toList()
            val y = RUNS.findAll(b).map { it.value }.toList()
            for (i in 0 until minOf(x.size, y.size)) {
                val (p, q) = x[i] to y[i]
                val order = if (p[0] in '0'..'9' && q[0] in '0'..'9') {
                    // By length once the zeros are off, so a number of any size never overflows.
                    compareValuesBy(p.trimStart('0'), q.trimStart('0'), { it.length }, { it })
                } else {
                    p.compareTo(q, ignoreCase = true)
                }
                if (order != 0) return@Comparator order
            }
            // Equal to the eye (`01` and `1`): still one fixed order.
            compareValues(x.size, y.size).takeIf { it != 0 } ?: a.compareTo(b)
        }

        private val IMAGE_EXTENSIONS = setOf("jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "avif", "")

        private val SEPARATORS = charArrayOf(' ', '.', '-', '_')

        /**
         * The archive's files as a comic. Chapters are the folders that directly hold pages, at any
         * depth. The comic's own folder counts as one only when every file is inside it and it holds
         * chapter folders; without one, the file's name is the best title there is. Pictures beside
         * chapter folders are not pages, and one named `cover…` is the comic's cover; with no
         * chapter folders at all, a bag of pictures is one chapter — someone zipped a chapter.
         * iOS also wants every file two levels down, which reads the cover its own exporter puts
         * beside the chapters as a chapter named after the comic, and the comic as untitled.
         */
        fun structure(names: List<String>, fallbackTitle: String): Structure {
            val paths = names.mapNotNull { name ->
                val parts = name.split('/').filter { it.isNotEmpty() }
                val file = parts.lastOrNull() ?: return@mapNotNull null
                // By path, not name: the Mac's resource-fork tree and hidden folders, wherever they sit.
                if (file.startsWith(".") || parts.dropLast(1).any { it.startsWith(".") || it == "__MACOSX" }) return@mapNotNull null
                // By extension only to keep `Thumbs.db` and a readme out; none is kept, as a page whose
                // format went unrecognised is stored without one. The bytes decide later.
                if (file.substringAfterLast('.', "").lowercase() !in IMAGE_EXTENSIONS) return@mapNotNull null
                parts to name
            }
            val roots = paths.map { it.first.first() }.toSet()
            val wrapped = roots.size == 1 && paths.any { it.first.size >= 3 }
            val title = if (wrapped) roots.first() else fallbackTitle
            val byFolder = HashMap<String, MutableList<String>>()
            val loose = mutableListOf<String>()
            for ((parts, name) in paths) {
                val folder = parts.drop(if (wrapped) 1 else 0).dropLast(1).joinToString("/")
                if (folder.isEmpty()) loose += name else byFolder.getOrPut(folder) { mutableListOf() } += name
            }
            if (byFolder.isEmpty()) return Structure(title, if (loose.isEmpty()) emptyList() else listOf(Found(title, title, inOrder(loose))))
            return Structure(
                title,
                byFolder.keys.sortedWith(NATURAL).map { Found(it, chapterTitle(it), inOrder(byFolder.getValue(it))) },
                loose.firstOrNull { it.substringAfterLast('/').lowercase().startsWith("cover") },
            )
        }

        private fun inOrder(pages: List<String>) = pages.sortedWith(compareBy(NATURAL) { it.substringAfterLast('/') })

        /**
         * A folder's name without the number that ordered it: `001 第01話` → `第01話`. Only a number
         * set off by a separator is ordering, so `1話`, `3月のライオン` and `一騎當千` keep theirs, as
         * on iOS. Only a number stays one.
         */
        fun chapterTitle(folder: String): String {
            val name = folder.substringAfterLast('/')
            val digits = name.takeWhile { it.isDigit() }
            val rest = name.drop(digits.length)
            if (digits.isEmpty() || rest.firstOrNull()?.let { it in SEPARATORS } != true) return name
            return rest.trimStart(*SEPARATORS).trim().ifEmpty { name }
        }

        /**
         * Ids from titles, not positions: an export made after a chapter was added in the middle
         * renumbers every folder after it, and an id taken from `002 第01話` would land a second
         * copy of each. Titles that repeat fall back to their folders, all that tells them apart.
         */
        fun identify(chapters: List<Found>): List<Pair<String, Found>> {
            val counts = chapters.groupingBy { it.title }.eachCount()
            return chapters.map { identifier(if (counts[it.title] == 1) it.title else it.folder) to it }
        }

        /**
         * This import's chapters with those already on the shelf, in folder order: the catalog
         * write deletes what it is not given, so handing it only part two would take part one off
         * the shelf. The folder rides in the chapter's address — never fetched, a file has no site.
         */
        fun merge(incoming: List<Pair<String, Found>>, previous: List<BookService.CatalogEntry>, siteBookId: String): List<BookService.CatalogEntry> {
            val folders = LinkedHashMap<String, Pair<String, String>>()
            for (entry in previous) {
                val folder = URLDecoder.decode(entry.url.substringAfterLast('/'), "UTF-8").ifEmpty { entry.title }
                folders[entry.siteChapterId] = entry.title to folder
            }
            for ((id, found) in incoming) folders[id] = found.title to found.folder
            return folders.entries.sortedWith(compareBy(NATURAL) { it.value.second }).map { (id, place) ->
                // `/` encoded too, unlike iOS, so a nested folder comes back whole as the sort key.
                val encoded = URLEncoder.encode(place.second, "UTF-8").replace("+", "%20")
                BookService.CatalogEntry(id, place.first, "${SiteStore.LOCAL_SITE_ID}://$siteBookId/$encoded")
            }
        }

        /** A digest, as for a text import: a primary key and a path, which a comic called `../../x` must not choose. */
        fun identifier(name: String): String =
            MessageDigest.getInstance("SHA-512").digest(name.trim().toByteArray()).joinToString("") { "%02x".format(it) }
    }
}
