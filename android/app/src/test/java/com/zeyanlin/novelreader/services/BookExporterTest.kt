package com.zeyanlin.novelreader.services

import com.zeyanlin.novelreader.data.Book
import com.zeyanlin.novelreader.data.Chapter
import com.zeyanlin.novelreader.siterules.SiteRule
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import javax.xml.parsers.DocumentBuilderFactory
import org.w3c.dom.Element

/**
 * The iOS `BookExportTests`. The failures worth catching are the ones the reader cannot see:
 * half a novel passed off as whole, a file this app cannot read back, a stray character that
 * makes a whole EPUB unopenable.
 */
class BookExporterTest {
    private val book = Book("alpha|1", "alpha", "1", SiteRule.Kind.NOVEL, "山月記", null, "中島敦", null, 1_700_000_000_000, 0, null, null, null, null, null, null)
    private val texts = mapOf(
        "1" to listOf("隴西的李徵。", "博學才穎。"),
        "2" to listOf("月光落在草上。"),
        "3" to listOf("天亮了。"),
    )
    private val directory = Files.createTempDirectory("exports").toFile().also { it.deleteOnExit() }

    private fun chapter(id: String, title: String, downloaded: Boolean = true) =
        Chapter(Chapter.makeId(book.id, id), book.id, id, id.toInt() - 1, title, "https://x/$id", null, if (downloaded) 1L else null)

    private val chapters = listOf(chapter("1", "第一章 回鄉"), chapter("2", "第二章 虎嘯"), chapter("3", "第三章 天明"))

    private fun export(
        format: BookExporter.Format,
        list: List<Chapter> = chapters,
        text: (Chapter) -> List<String>? = { texts[it.siteChapterId] },
        progress: (Double) -> Unit = {},
    ) = runBlocking { BookExporter { text(it) }.export(book, list, format, directory, progress) }

    @Test
    fun theTextFileReadsBackThroughTheTextParser() {
        val export = export(BookExporter.Format.TEXT)
        val parsed = TextBookParser.chapters(export.file.readText())
        assertEquals(chapters.map { it.title }, parsed.map { it.title })
        assertEquals(chapters.map { texts[it.siteChapterId] }, parsed.map { it.paragraphs })
        assertTrue("no seam between streamed chapters", export.file.readText().endsWith("天亮了。\n"))
    }

    // Our own importer reads the spine and the nav: chapters in order, under their own names,
    // and the title page kept out of the reading order so it never comes back as chapter one.
    @Test
    fun theEpubReadsBackThroughOurOwnReader() {
        val document = EpubDocument.parse(export(BookExporter.Format.EPUB).file)
        assertEquals("山月記", document.title)
        assertEquals("中島敦", document.author)
        assertEquals(chapters.map { it.title }, document.items.map { it.tocTitle })
    }

    @Test
    fun mimetypeIsTheFirstEntryAndStored() {
        ZipFile(export(BookExporter.Format.EPUB).file).use { zip ->
            val first = zip.entries().nextElement()
            assertEquals("mimetype", first.name)
            assertEquals(ZipEntry.STORED, first.method)
            assertEquals("application/epub+zip", zip.getInputStream(first).readBytes().decodeToString())
        }
    }

    // The archive iOS writes and its importer reads back: the shelf's cover as `cover`, a folder
    // per chapter numbered in catalog order, pages byte for byte, and neither a gap marker nor a
    // chapter never downloaded written as though it were content.
    @Test
    fun aComicIsAFolderPerChapterWithItsPagesAsServed() {
        val jpeg = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 1, 2, 3)
        val stored = Files.createTempDirectory("pages").toFile().also { it.deleteOnExit() }
        File(stored, "1").mkdirs()
        File(stored, "1/000").writeBytes(jpeg)
        File(stored, "1/001${ComicPages.GAP}").writeBytes(ByteArray(0))
        File(stored, "1/002").writeBytes(jpeg)
        // Pages with no flag: a deletion caught between its two halves, which is not a download.
        File(stored, "2").mkdirs()
        File(stored, "2/000").writeBytes(jpeg)
        File(stored, "3").mkdirs()
        File(stored, "3/000").writeBytes(jpeg)
        val list = listOf(chapter("1", "第一話"), chapter("2", "第二話", downloaded = false), chapter("3", "第三話"))
        val export = runBlocking {
            BookExporter({ ComicPages.stored(File(stored, it.siteChapterId)) }, jpeg) { null }.export(book, list, BookExporter.Format.COMIC, directory) {}
        }
        ZipFile(export.file).use { zip ->
            assertEquals(
                listOf("山月記/cover.jpg", "山月記/001 第一話/000.jpg", "山月記/001 第一話/002.jpg", "山月記/003 第三話/000.jpg"),
                zip.entries().toList().map { it.name },
            )
            assertArrayEquals(jpeg, zip.getInputStream(zip.getEntry("山月記/001 第一話/002.jpg")).readBytes())
            // Stored: a JPEG does not compress twice, and deflating gigabytes of them is minutes for nothing.
            assertTrue(zip.entries().toList().all { it.method == ZipEntry.STORED })
        }
        assertEquals(2, export.chapterCount)
        assertTrue(export.isPartial)
    }

    // A reading system shelves a book by the picture its package marks `cover-image`, and the
    // title page shows it. A WebP — what manhuagui serves — is no core type in EPUB 3.0, so it is
    // left out rather than making the whole file invalid.
    @Test
    fun theShelfsCoverIsTheEpubsCoverImage() {
        val png = byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 1, 2)
        fun epub(cover: ByteArray) = runBlocking {
            BookExporter(cover = cover) { texts[it.siteChapterId] }.export(book, chapters, BookExporter.Format.EPUB, directory) {}
        }
        val parser = DocumentBuilderFactory.newInstance().newDocumentBuilder()
        ZipFile(epub(png).file).use { zip ->
            assertArrayEquals(png, zip.getInputStream(zip.getEntry("OEBPS/cover.png")).readBytes())
            val items = parser.parse(zip.getInputStream(zip.getEntry("OEBPS/content.opf"))).getElementsByTagName("item")
            val cover = (0 until items.length).map { items.item(it) as Element }.single { it.getAttribute("properties") == "cover-image" }
            assertEquals("cover.png", cover.getAttribute("href"))
            assertEquals("image/png", cover.getAttribute("media-type"))
            val page = parser.parse(zip.getInputStream(zip.getEntry("OEBPS/titlepage.xhtml")))
            assertEquals("cover.png", (page.getElementsByTagName("img").item(0) as Element).getAttribute("src"))
        }
        ZipFile(epub("RIFF\u0000\u0000\u0000\u0000WEBP".toByteArray()).file).use { zip ->
            assertTrue(zip.entries().toList().none { it.name.contains("cover") })
            assertFalse(zip.getInputStream(zip.getEntry("OEBPS/content.opf")).readBytes().decodeToString().contains("cover-image"))
        }
    }

    // One stray control character from a mis-decoded page would make the document unparseable.
    @Test
    fun markupAndControlCharactersCannotBreakTheDocument() {
        val odd = "a < b & \"c\" > d\u000b"
        val export = export(BookExporter.Format.EPUB, listOf(chapter("1", "<第一章>")), { listOf(odd) })
        ZipFile(export.file).use { zip ->
            val xhtml = zip.getInputStream(zip.getEntry("OEBPS/text/chapter-00001.xhtml"))
            val dom = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(xhtml)
            assertEquals("a < b & \"c\" > d", dom.getElementsByTagName("p").item(0).textContent)
            assertEquals("<第一章>", dom.getElementsByTagName("h1").item(0).textContent)
        }
    }

    @Test
    fun twoExportsOfOneBookAreTheSameBytes() {
        val first = export(BookExporter.Format.EPUB).file.readBytes()
        Thread.sleep(2100) // past a DOS timestamp tick, so a clock in the file would show
        assertArrayEquals(first, export(BookExporter.Format.EPUB).file.readBytes())
    }

    // A chapter flagged but without its text counts as absent, so `isPartial` stays honest.
    @Test
    fun onlyWhatIsOnTheDeviceIsWrittenAndSaid() {
        val list = listOf(chapter("1", "第一章 回鄉"), chapter("2", "第二章 虎嘯", downloaded = false), chapter("3", "第三章 天明"))
        val export = export(BookExporter.Format.TEXT, list, { if (it.siteChapterId == "3") emptyList() else texts[it.siteChapterId] })
        assertEquals(1, export.chapterCount)
        assertEquals(3, export.catalogCount)
        assertTrue(export.isPartial)
        assertFalse(export.file.readText().contains("虎嘯"))
    }

    @Test
    fun nothingOnTheDeviceFailsAndLeavesNoFile() {
        for (format in BookExporter.Format.entries) {
            try {
                export(format, text = { null })
                fail("expected NothingOnDevice for $format")
            } catch (e: BookExporter.NothingOnDevice) {
                assertEquals(emptyList<File>(), directory.listFiles()!!.toList())
            }
        }
    }

    @Test
    fun aCancelLeavesNoFileBehind() {
        var calls = 0
        try {
            export(BookExporter.Format.EPUB, progress = { if (++calls == 1) throw CancellationException("stop") })
            fail("expected the cancel to propagate")
        } catch (e: CancellationException) {
            assertEquals(emptyList<File>(), directory.listFiles()!!.toList())
        }
    }

    @Test
    fun progressRunsForwardToOne() {
        val seen = mutableListOf<Double>()
        export(BookExporter.Format.TEXT, progress = { seen += it })
        assertEquals(seen.sorted(), seen)
        assertEquals(1.0, seen.last(), 0.0)
    }

    @Test
    fun theFilenameKeepsTheTitleAndDropsWhatAFilesystemCannotTake() {
        assertEquals("山月記 上 下", BookExporter.filename("山月記:上/下"))
        assertEquals("hidden", BookExporter.filename("..hidden"))
        assertEquals("book", BookExporter.filename("/?*"))
        assertEquals(80, BookExporter.filename("長".repeat(200)).length)
    }
}
