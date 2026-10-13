package com.zeyanlin.novelreader.services

import com.zeyanlin.novelreader.data.Book
import com.zeyanlin.novelreader.data.Chapter
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import java.io.File
import java.time.Instant
import java.util.zip.CRC32
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/**
 * The iOS `BookExporter`: a book written back out as a file the reader owns. It only ever writes
 * text that is on this device — a chapter without a downloaded copy is left out, never written
 * as a heading over nothing — and the counts it returns say how much of the book made it.
 * Nothing here reaches the network, cover included: [cover] is the one the shelf has drawn, and a
 * book whose cover never arrived gets a text title page rather than an export waiting on a site.
 *
 * [text] is a downloaded chapter's paragraphs, or null for one this file cannot contain; [pages]
 * a downloaded comic chapter's page files, gap markers included.
 */
class BookExporter(
    private val pages: (Chapter) -> List<File> = { emptyList() },
    private val cover: ByteArray? = null,
    private val text: suspend (Chapter) -> List<String>?,
) {
    enum class Format(val extension: String, val mime: String) {
        TEXT("txt", "text/plain"),
        EPUB("epub", "application/epub+zip"),
        COMIC("zip", "application/zip"),
    }

    /** A finished file. [isPartial] has to be said: half a novel handed over as whole is invisible. */
    data class Export(val format: Format, val file: File, val filename: String, val chapterCount: Int, val catalogCount: Int) {
        val isPartial get() = chapterCount < catalogCount
    }

    class NothingOnDevice : Exception("這本書還沒有任何內容存在裝置上，沒有東西可以匯出。")

    /**
     * Writes the book into [directory], emptied first: the file must outlive this call for the
     * save screen to copy it, and the next export is the first moment nobody needs the last one.
     * Cancellation is checked per chapter; a cancelled or failed export leaves no file behind.
     */
    suspend fun export(
        book: Book,
        chapters: List<Chapter>,
        format: Format,
        directory: File,
        progress: (Double) -> Unit,
    ): Export {
        val filename = filename(book.shownName)
        directory.deleteRecursively()
        directory.mkdirs()
        val file = File(directory, "$filename.${format.extension}")
        try {
            val count = when (format) {
                Format.TEXT -> writeText(file, chapters, progress)
                Format.EPUB -> writeEpub(file, book, chapters, progress)
                Format.COMIC -> writeComic(file, filename, chapters, progress)
            }
            if (count == 0) throw NothingOnDevice()
            progress(1.0)
            return Export(format, file, filename, count, chapters.size)
        } catch (e: Throwable) {
            file.delete()
            throw e
        }
    }

    private suspend fun paragraphs(chapter: Chapter): List<String>? =
        if (chapter.downloadedAt == null) null else text(chapter)?.takeIf { it.isNotEmpty() }

    /**
     * Heading, blank line, one paragraph per line with blank lines between — the shape
     * `TextBookParser` reads back. The separator goes before every chapter but the first, so the
     * file is exactly the chapters joined by it.
     */
    private suspend fun writeText(file: File, chapters: List<Chapter>, progress: (Double) -> Unit): Int {
        var count = 0
        file.bufferedWriter().use { out ->
            chapters.forEachIndexed { i, chapter ->
                currentCoroutineContext().ensureActive()
                paragraphs(chapter)?.let {
                    if (count > 0) out.write("\n\n")
                    out.write((listOf(chapter.title) + it).joinToString("\n\n"))
                    count++
                }
                progress((i + 1).toDouble() / chapters.size)
            }
            // So the last line is a line, not a fragment.
            if (count > 0) out.write("\n")
        }
        return count
    }

    /**
     * A minimal EPUB 3. `mimetype` first and stored, as OCF requires; the package document and
     * table of contents last, since they name exactly the chapters that made it in.
     */
    private suspend fun writeEpub(file: File, book: Book, chapters: List<Chapter>, progress: (Double) -> Unit): Int {
        val titles = mutableListOf<String>()
        ZipOutputStream(file.outputStream().buffered()).use { zip ->
            val mimetype = "application/epub+zip".toByteArray()
            zip.putNextEntry(
                entry("mimetype").apply {
                    method = ZipEntry.STORED
                    size = mimetype.size.toLong()
                    crc = CRC32().apply { update(mimetype) }.value
                },
            )
            zip.write(mimetype)
            zip.add("META-INF/container.xml", CONTAINER)
            zip.add("OEBPS/$STYLE", STYLESHEET)
            chapters.forEachIndexed { i, chapter ->
                currentCoroutineContext().ensureActive()
                paragraphs(chapter)?.let {
                    zip.add("OEBPS/${chapterHref(titles.size)}", document(chapter.title, it))
                    titles += chapter.title
                }
                progress((i + 1).toDouble() / chapters.size)
            }
            // `export` deletes the file anyway; a valid but empty EPUB is a book with nothing in it.
            if (titles.isEmpty()) return 0
            val author = book.author?.trim()?.takeIf { it.isNotEmpty() }
            val format = cover?.let { ImageFormat.sniff(it) }?.takeIf { it in EPUB_COVER_TYPES }
            if (cover != null && format != null) zip.add("OEBPS/cover.${format.extension}", cover)
            zip.add("OEBPS/$TITLE_PAGE", titlePage(book.shownName, author, format))
            zip.add("OEBPS/$NAV", navigation(book.shownName, titles))
            zip.add(OPF, packageDocument(book.shownName, author, book.id, book.addedAt, titles, format))
        }
        return titles.size
    }

    /**
     * A comic the way iOS's `ComicExporter` writes it: a folder named after the comic, a folder
     * per chapter numbered in catalog order, the pages inside — the shape a person makes by hand,
     * which anything can open. Stored, not deflated: a JPEG does not compress twice, and the pages
     * come out as the site served them. Gap markers stay behind: they are notes to this app, and
     * the numbering keeps the gap. One file at any size, where iOS splits at 3 GiB:
     * [ZipOutputStream] writes ZIP64 when it has to.
     */
    private suspend fun writeComic(file: File, root: String, chapters: List<Chapter>, progress: (Double) -> Unit): Int {
        var count = 0
        // Wide enough to sort as text: a 1300-chapter comic needs four digits.
        val width = maxOf(3, chapters.size.toString().length)
        ZipOutputStream(file.outputStream().buffered()).use { zip ->
            // Named `cover`, which is what the importer looks for: unzipped, the folder shows what it is.
            val format = cover?.let { ImageFormat.sniff(it) }
            if (cover != null && format != null) zip.store("$root/cover.${format.extension}", cover)
            chapters.forEachIndexed { i, chapter ->
                currentCoroutineContext().ensureActive()
                val stored = if (chapter.downloadedAt == null) emptyList() else pages(chapter).filterNot(ComicPages::isGap)
                if (stored.isNotEmpty()) {
                    val folder = "$root/${"%0${width}d".format(i + 1)} ${filename(chapter.title)}"
                    for (page in stored) {
                        val bytes = page.readBytes()
                        // The extension from the bytes, for whoever opens the folder: pages are kept without one.
                        val name = page.name + (ImageFormat.sniff(bytes)?.let { "." + it.extension } ?: "")
                        zip.store("$folder/$name", bytes)
                    }
                    count++
                }
                progress((i + 1).toDouble() / chapters.size)
            }
        }
        return count
    }

    private fun ZipOutputStream.add(name: String, text: String) = add(name, text.toByteArray())

    private fun ZipOutputStream.add(name: String, bytes: ByteArray) {
        putNextEntry(entry(name))
        write(bytes)
        closeEntry()
    }

    private fun ZipOutputStream.store(name: String, bytes: ByteArray) {
        putNextEntry(
            entry(name).apply {
                method = ZipEntry.STORED
                size = bytes.size.toLong()
                crc = CRC32().apply { update(bytes) }.value
            },
        )
        write(bytes)
        closeEntry()
    }

    companion object {
        private const val OPF = "OEBPS/content.opf"
        private const val NAV = "nav.xhtml"
        private const val STYLE = "style.css"
        private const val TITLE_PAGE = "titlepage.xhtml"

        /** A fixed time rather than the clock: two exports of one book are the same bytes. */
        private fun entry(name: String) = ZipEntry(name).apply { time = 315_532_800_000L }

        /** Zero-padded so the documents sort in reading order for anyone who unzips the file. */
        private fun chapterHref(index: Int) = "text/chapter-%05d.xhtml".format(index + 1)

        private fun chapterId(index: Int) = "c${index + 1}"

        /**
         * EPUB 3.0's core image types, by the bytes: a WebP — what manhuagui serves — only became
         * core in 3.3, and would trade the file's validity for a picture.
         */
        private val EPUB_COVER_TYPES = mapOf(ImageFormat.JPEG to "image/jpeg", ImageFormat.PNG to "image/png", ImageFormat.GIF to "image/gif")

        private val CONTAINER = """
            |<?xml version="1.0" encoding="UTF-8"?>
            |<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            |  <rootfiles>
            |    <rootfile full-path="$OPF" media-type="application/oebps-package+xml"/>
            |  </rootfiles>
            |</container>
        """.trimMargin()

        /**
         * Another reader's defaults and nothing more: no fonts and no colour, so a reading
         * system's night mode can recolour it. Chinese-aware: justified, never hyphenated, and
         * strict line breaking so a line cannot begin with 」 or 。.
         */
        private val STYLESHEET = """
            |html {
            |  hyphens: none;
            |  -epub-hyphens: none;
            |}
            |
            |body {
            |  margin: 4% 5%;
            |  line-height: 1.75;
            |  text-align: justify;
            |  line-break: strict;
            |  word-break: normal;
            |  overflow-wrap: break-word;
            |}
            |
            |h1 {
            |  font-size: 1.2em;
            |  line-height: 1.4;
            |  margin: 0 0 1.6em;
            |  text-align: left;
            |}
            |
            |p {
            |  margin: 0 0 0.9em;
            |  text-indent: 0;
            |}
            |
            |.titlepage {
            |  margin-top: 20%;
            |  text-align: center;
            |}
            |
            |.titlepage h1 {
            |  font-size: 1.8em;
            |  margin: 0 0 0.8em;
            |  text-align: center;
            |}
            |
            |.titlepage img {
            |  max-width: 80%;
            |  margin: 0 0 1.5em;
            |}
            |
            |.titlepage .author {
            |  font-size: 1.05em;
            |  margin: 0;
            |}
        """.trimMargin()

        /** Kept out of the reading order (`linear="no"`), so it never comes back in as chapter one. */
        private fun titlePage(title: String, author: String?, cover: ImageFormat?): String {
            val image = cover?.let { "\n    <img src=\"cover.${it.extension}\" alt=\"${escaped(title)}\"/>" }.orEmpty()
            val byline = author?.let { "\n    <p class=\"author\">${escaped(it)}</p>" }.orEmpty()
            return """
                |<?xml version="1.0" encoding="UTF-8"?>
                |<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="und">
                |  <head>
                |    <title>${escaped(title)}</title>
                |    <link rel="stylesheet" type="text/css" href="$STYLE"/>
                |  </head>
                |  <body>
                |    <section class="titlepage" epub:type="titlepage">$image
                |    <h1>${escaped(title)}</h1>$byline
                |    </section>
                |  </body>
                |</html>
            """.trimMargin()
        }

        /**
         * Language `und` because EPUB 3 wants exactly one and this app reads Chinese and English
         * alike; `dcterms:modified` from the book's `addedAt` so the file does not change per export.
         * `properties="cover-image"` is how a reading system knows which picture goes on its shelf.
         */
        private fun packageDocument(title: String, author: String?, identifier: String, modified: Long, chapters: List<String>, cover: ImageFormat?): String {
            val creator = author?.let { "\n    <dc:creator>${escaped(it)}</dc:creator>" }.orEmpty()
            val coverItem = cover?.let {
                "\n    <item id=\"cover-image\" href=\"cover.${it.extension}\" media-type=\"${EPUB_COVER_TYPES[it]}\" properties=\"cover-image\"/>"
            }.orEmpty()
            val manifest = chapters.indices.joinToString("\n") {
                "    <item id=\"${chapterId(it)}\" href=\"${chapterHref(it)}\" media-type=\"application/xhtml+xml\"/>"
            }
            val spine = chapters.indices.joinToString("\n") { "    <itemref idref=\"${chapterId(it)}\"/>" }
            return """
                |<?xml version="1.0" encoding="UTF-8"?>
                |<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id" xml:lang="und">
                |  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                |    <dc:identifier id="book-id">novelreader:${escaped(identifier)}</dc:identifier>
                |    <dc:title>${escaped(title)}</dc:title>$creator
                |    <dc:language>und</dc:language>
                |    <meta property="dcterms:modified">${Instant.ofEpochSecond(Math.floorDiv(modified, 1000L))}</meta>
                |  </metadata>
                |  <manifest>
                |    <item id="nav" href="$NAV" media-type="application/xhtml+xml" properties="nav"/>
                |    <item id="style" href="$STYLE" media-type="text/css"/>
                |    <item id="titlepage" href="$TITLE_PAGE" media-type="application/xhtml+xml"/>$coverItem
                |$manifest
                |  </manifest>
                |  <spine>
                |    <itemref idref="titlepage" linear="no"/>
                |$spine
                |  </spine>
                |</package>
            """.trimMargin()
        }

        /** The table of contents, out of the spine; the title page leads it under the book's own name. */
        private fun navigation(title: String, chapters: List<String>): String {
            val items = (listOf(TITLE_PAGE to title) + chapters.mapIndexed { i, t -> chapterHref(i) to t })
                .joinToString("\n") { (href, label) -> "      <li><a href=\"$href\">${escaped(label)}</a></li>" }
            return """
                |<?xml version="1.0" encoding="UTF-8"?>
                |<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="und">
                |  <head>
                |    <title>${escaped(title)}</title>
                |    <link rel="stylesheet" type="text/css" href="$STYLE"/>
                |  </head>
                |  <body>
                |    <nav epub:type="toc" id="toc">
                |      <h1>${escaped(title)}</h1>
                |      <ol>
                |$items
                |      </ol>
                |    </nav>
                |  </body>
                |</html>
            """.trimMargin()
        }

        /** Lines joined rather than a margin template: a paragraph's own line starting with `|` would lose it. */
        private fun document(title: String, paragraphs: List<String>): String = (
            listOf(
                """<?xml version="1.0" encoding="UTF-8"?>""",
                """<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="und">""",
                "  <head>",
                "    <title>${escaped(title)}</title>",
                """    <link rel="stylesheet" type="text/css" href="../$STYLE"/>""",
                "  </head>",
                "  <body>",
                "    <h1>${escaped(title)}</h1>",
            ) + paragraphs.map { "    <p>${escaped(it)}</p>" } + listOf("  </body>", "</html>")
            ).joinToString("\n")

        /**
         * Escapes for XML and drops what XML cannot carry: one stray control character from a
         * mis-decoded page makes the whole document unparseable, and nobody saw it on screen.
         */
        fun escaped(text: String): String = buildString(text.length) {
            for (c in text) when (c) {
                '&' -> append("&amp;")
                '<' -> append("&lt;")
                '>' -> append("&gt;")
                '"' -> append("&quot;")
                '\t', '\n', '\r' -> append(c)
                else -> if (c >= ' ') append(c)
            }
        }

        /**
         * A blacklist, not a whitelist: this name is the first thing the reader sees on the save
         * screen, so only what a filesystem or a share cannot take is replaced.
         */
        fun filename(title: String): String {
            val cleaned = title.map { if (it in ":/\\?%*|\"<>" || it < ' ') ' ' else it }.joinToString("")
            val collapsed = cleaned.split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")
            return collapsed.trimStart('.').take(80).trim().ifEmpty { "book" }
        }
    }
}
