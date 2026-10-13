package com.zeyanlin.novelreader.services

import android.content.Context
import com.zeyanlin.novelreader.data.Book
import com.zeyanlin.novelreader.data.Chapter
import com.zeyanlin.novelreader.data.LibraryDao
import com.zeyanlin.novelreader.network.ImportView
import com.zeyanlin.novelreader.siterules.ExtractorScript
import com.zeyanlin.novelreader.siterules.SiteRule
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.security.DigestInputStream
import java.security.MessageDigest
import java.util.UUID

/** Why an import failed, in the reader's words. */
sealed class LocalBookError(message: String) : Exception(message) {
    class Unreadable : LocalBookError("讀不到這個檔案。")

    /** The detail on a second line is what makes a report about someone else's EPUB actionable. */
    class Malformed(detail: String) : LocalBookError("這個 EPUB 檔無法解析。\n$detail")
    class BadArchive(detail: String) : LocalBookError("這個 ZIP 檔無法解析。\n$detail")
    class UnknownEncoding : LocalBookError("判斷不出這個文字檔的編碼，請另存成 UTF-8 後再試。")
    class Empty : LocalBookError("這個檔案裡沒有可以閱讀的內容。")

    /** The book was imported, but its text is no longer on the device. */
    class ContentDeleted : LocalBookError("這本書的內容已從裝置刪除，請重新匯入檔案。")
}

/**
 * Turns a `.txt` or `.epub` the reader picked into a book — the iOS `LocalBookImporter`. An
 * imported book is a bookmark under [SiteStore.LOCAL_SITE_ID] whose every chapter is already
 * downloaded: not a new kind of book, so the storage screen, the delete scopes and the reader's
 * kept-text-first read all work on it without knowing.
 *
 * Cancellation is checked per unit of work — per spine document, per chapter written — so a
 * cancel lands while it is watched; anything already written is undone before it escapes.
 */
class LocalBookImporter(private val context: Context, private val library: LibraryDao) {
    /**
     * [progress] is a 0…1 fraction: an EPUB is extracted and then written, two passes over the
     * same book, and a fraction is the only way to show that as one bar that never runs back.
     */
    suspend fun import(open: () -> InputStream?, name: String, progress: (Double) -> Unit): Book {
        val file = File(context.cacheDir, "import-${UUID.randomUUID()}")
        try {
            val siteBookId = withContext(Dispatchers.IO) { copy(open, file) }
            currentCoroutineContext().ensureActive()
            val isEpub = name.endsWith(".epub", ignoreCase = true)
            val parsed = if (isEpub) epub(file, progress) else withContext(Dispatchers.Default) {
                val text = TextBookParser.decode(file.readBytes()) ?: throw LocalBookError.UnknownEncoding()
                ensureActive()
                Parsed(null, null, TextBookParser.chapters(text))
            }
            if (parsed.chapters.isEmpty()) throw LocalBookError.Empty()
            return store(
                // The filename is what the reader recognises: a `.txt` has no metadata, and
                // plenty of EPUBs carry a placeholder title from whatever made them.
                parsed.title?.trim()?.takeIf { it.isNotEmpty() } ?: name.substringBeforeLast('.'),
                parsed.author?.trim()?.takeIf { it.isNotEmpty() },
                siteBookId, parsed.chapters, if (isEpub) EXTRACTION_SHARE else 0.0, progress,
            )
        } finally {
            file.delete()
        }
    }

    private class Parsed(val title: String?, val author: String?, val chapters: List<ImportedChapter>)

    /**
     * Copies the picked document out and names it by a digest of its bytes, not a fresh id:
     * importing the same file twice must land on the same book, so a re-import after a storage
     * cleanup restores the text under the reading position the reader already has. The whole
     * digest — it is a primary key, and a collision would serve one book's text as another's.
     */
    private fun copy(open: () -> InputStream?, to: File): String {
        val digest = MessageDigest.getInstance("SHA-512")
        try {
            val input = open() ?: throw LocalBookError.Unreadable()
            DigestInputStream(input, digest).use { stream -> to.outputStream().use { stream.copyTo(it) } }
        } catch (e: IOException) {
            throw LocalBookError.Unreadable()
        } catch (e: SecurityException) {
            throw LocalBookError.Unreadable()
        }
        if (to.length() == 0L) throw LocalBookError.Unreadable()
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    /**
     * Every spine document through the extractor the site rules use: it already turns `<br>`,
     * `<p>` and `<div>` into paragraphs and drops the heading a document repeats over its own
     * body. A second HTML reader here would be a worse copy of that, and would drift.
     */
    private suspend fun epub(file: File, progress: (Double) -> Unit): Parsed {
        val document = withContext(Dispatchers.IO) {
            try {
                EpubDocument.parse(file)
            } catch (e: IOException) {
                throw LocalBookError.Malformed(e.message ?: e.javaClass.simpleName)
            }
        }
        val script = ExtractorScript.chapter(EMBEDDED_DOCUMENT)
        val chapters = mutableListOf<ImportedChapter>()
        val view = withContext(Dispatchers.Main) { ImportView(context) }
        try {
            document.items.forEachIndexed { offset, item ->
                currentCoroutineContext().ensureActive()
                val payload = view.extract(item.xhtml, script, ExtractorScript.ChapterPayload.serializer())
                // Documents that read as nothing are covers and heading plates — rows that
                // would open onto a blank page.
                if (payload.paragraphs.isNotEmpty()) {
                    val title = item.tocTitle ?: payload.title?.trim()?.takeIf { it.isNotEmpty() }
                    chapters += ImportedChapter(title ?: "第 ${chapters.size + 1} 部分", payload.paragraphs)
                }
                progress((offset + 1).toDouble() / document.items.size * EXTRACTION_SHARE)
            }
        } finally {
            withContext(NonCancellable + Dispatchers.Main) { view.close() }
        }
        return Parsed(document.title, document.author, chapters)
    }

    /**
     * The row, its catalog, and every chapter's text, through the calls a real download makes.
     * The only phase that writes, so the only one that undoes itself.
     */
    private suspend fun store(
        title: String, author: String?, siteBookId: String, chapters: List<ImportedChapter>,
        progressBase: Double, progress: (Double) -> Unit,
    ): Book {
        currentCoroutineContext().ensureActive()
        // Asked first, because it decides how far a rollback may go: re-importing a file the
        // shelf already holds must not take the existing book down with it.
        val wasOnShelf = library.bookNow(Book.makeId(SiteStore.LOCAL_SITE_ID, siteBookId)) != null
        val book = library.bookmark(SiteStore.LOCAL_SITE_ID, siteBookId, SiteRule.Kind.NOVEL, title, author, null)
        try {
            library.replaceCatalog(
                book.id,
                chapters.mapIndexed { offset, chapter ->
                    // Not nullable, and meaningless for a file: a scheme nothing can fetch, so a
                    // path that ever tries fails loudly instead of quietly reaching some site.
                    BookService.CatalogEntry(chapterId(offset), chapter.title, "${SiteStore.LOCAL_SITE_ID}://$siteBookId/$offset")
                },
            )
            chapters.forEachIndexed { offset, chapter ->
                currentCoroutineContext().ensureActive()
                library.storeDownload(
                    Chapter.makeId(book.id, chapterId(offset)),
                    Json.encodeToString(chapter.paragraphs),
                )
                progress(progressBase + (offset + 1).toDouble() / chapters.size * (1 - progressBase))
            }
        } catch (e: Throwable) {
            // A book left here would claim a full catalog while holding its first few chapters,
            // and the reader would find out by running off the end. A re-import keeps the row:
            // its position and custom name predate this import and belong to the reader.
            withContext(NonCancellable) {
                runCatching { library.deleteBookDownloads(book.id) }
                if (!wasOnShelf) runCatching { library.deleteBook(book.id) }
            }
            throw e
        }
        return library.bookNow(book.id) ?: book
    }

    private companion object {
        /** The share of the bar an EPUB's extraction gets; writing the chapters costs about the same. */
        const val EXTRACTION_SHARE = 0.5

        /**
         * `body` as the content, because an EPUB document *is* one chapter. The heading
         * selectors name a chapter when the book has no toc, and let the extractor drop the
         * heading repeated at the top of the body.
         */
        val EMBEDDED_DOCUMENT = SiteRule.Chapter(
            titleSelectors = listOf("h1", "h2", "h3", "title"),
            contentSelectors = listOf("body"),
            stripSelectors = listOf("script", "style", "svg"),
        )

        /** Zero-padded, so anything listing them sorts them in reading order. */
        fun chapterId(index: Int) = "%05d".format(index)
    }
}
