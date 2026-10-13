package com.zeyanlin.novelreader.services

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/**
 * The iOS `EpubDocumentTests`. Four indirections — container, package, spine, document — and
 * each can silently shuffle the reading order, which is worse than a failed import because
 * nothing on screen says so.
 */
class EpubDocumentTest {
    /** The manifest lists `c2` before `c1`, so trusting it instead of the spine fails visibly. */
    private fun epub(vararg extra: Pair<String, String>): File {
        val entries = listOf(
            "mimetype" to "application/epub+zip",
            "META-INF/container.xml" to """
                <?xml version="1.0"?>
                <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
                  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
                </container>
            """.trimIndent(),
            "OEBPS/content.opf" to """
                <?xml version="1.0"?>
                <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
                  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                    <dc:title>山月記</dc:title>
                    <dc:creator>中島敦</dc:creator>
                  </metadata>
                  <manifest>
                    <item id="cover" href="text/cover.xhtml" media-type="application/xhtml+xml"/>
                    <item id="c2" href="text/c2.xhtml" media-type="application/xhtml+xml"/>
                    <item id="c1" href="text/c1.xhtml" media-type="application/xhtml+xml"/>
                    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
                    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                  </manifest>
                  <spine toc="ncx">
                    <itemref idref="cover" linear="no"/>
                    <itemref idref="c1"/>
                    <itemref idref="c2"/>
                  </spine>
                </package>
            """.trimIndent(),
            "OEBPS/text/cover.xhtml" to "<html><body><img/></body></html>",
            "OEBPS/text/c1.xhtml" to "<html><body><h1>回鄉</h1><p>隴西的李徵。</p></body></html>",
            "OEBPS/text/c2.xhtml" to "<html><body><h1>虎嘯</h1><p>月光落在草上。</p></body></html>",
        ) + extra
        return zip(entries)
    }

    private val ncx = "OEBPS/toc.ncx" to """
        <?xml version="1.0"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <navMap>
            <navPoint id="p1" playOrder="1"><navLabel><text>第一章 回鄉</text></navLabel><content src="text/c1.xhtml"/></navPoint>
            <navPoint id="p2" playOrder="2"><navLabel><text>第二章 虎嘯</text></navLabel><content src="text/c2.xhtml#top"/></navPoint>
          </navMap>
        </ncx>
    """.trimIndent()

    /** With a DOCTYPE naming the W3C's DTD, which a parser left to itself would go and fetch. */
    private val nav = "OEBPS/nav.xhtml" to """
        <?xml version="1.0"?>
        <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
        <html xmlns:epub="http://www.idpf.org/2007/ops">
          <body>
            <nav epub:type="landmarks"><ol><li><a href="text/c1.xhtml">封面</a></li></ol></nav>
            <nav epub:type="toc">
              <ol>
                <li><a href="text/c1.xhtml">上卷 回鄉</a></li>
                <li><a href="text/c2.xhtml">下卷 虎嘯</a></li>
              </ol>
            </nav>
          </body>
        </html>
    """.trimIndent()

    @Test
    fun metadataComesFromThePackageDocument() {
        val document = EpubDocument.parse(epub(ncx))
        assertEquals("山月記", document.title)
        assertEquals("中島敦", document.author)
    }

    @Test
    fun readingOrderFollowsTheSpine() =
        assertEquals(listOf("OEBPS/text/c1.xhtml", "OEBPS/text/c2.xhtml"), EpubDocument.parse(epub(ncx)).items.map { it.path })

    /** `text/c2.xhtml#top` names the same document as `text/c2.xhtml`. */
    @Test
    fun chapterTitlesComeFromTheNcx() =
        assertEquals(listOf("第一章 回鄉", "第二章 虎嘯"), EpubDocument.parse(epub(ncx)).items.map { it.tocTitle })

    /** The landmarks nav must be ignored, or chapter one would be titled 「封面」. */
    @Test
    fun navDocumentWinsOverTheNcx() =
        assertEquals(listOf("上卷 回鄉", "下卷 虎嘯"), EpubDocument.parse(epub(ncx, nav)).items.map { it.tocTitle })

    /** The manifest promises a nav the archive lacks, and there is no ncx: the import still goes on. */
    @Test
    fun missingTableOfContentsIsNotFatal() {
        val document = EpubDocument.parse(epub())
        assertEquals(2, document.items.size)
        assertEquals(listOf(null, null), document.items.map { it.tocTitle })
    }

    @Test
    fun archiveWithoutAContainerIsRejected() {
        assertThrows(LocalBookError.Malformed::class.java) { EpubDocument.parse(zip(listOf("book.txt" to "not an epub"))) }
    }

    @Test
    fun hrefsAreResolvedAgainstTheirDocumentAndPercentDecoded() {
        assertEquals("OEBPS/text/chapter 1.xhtml", EpubDocument.resolve("text/chapter%201.xhtml", "OEBPS"))
        assertEquals("OEBPS/text/c1.xhtml", EpubDocument.resolve("../images/../text/c1.xhtml#part2", "OEBPS/nav"))
        assertEquals("content.opf", EpubDocument.resolve("content.opf", ""))
        assertEquals("a+b.xhtml", EpubDocument.resolve("a+b.xhtml", ""))
    }

    private fun zip(entries: List<Pair<String, String>>): File {
        val file = File.createTempFile("epub", ".epub").apply { deleteOnExit() }
        ZipOutputStream(file.outputStream()).use { out ->
            for ((name, text) in entries) {
                out.putNextEntry(ZipEntry(name))
                out.write(text.toByteArray())
                out.closeEntry()
            }
        }
        return file
    }
}
