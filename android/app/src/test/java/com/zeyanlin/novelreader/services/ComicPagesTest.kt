package com.zeyanlin.novelreader.services

import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class ComicPagesTest {
    @get:Rule
    val folder = TemporaryFolder()

    private val pages by lazy { ComicPages(File(folder.root, "downloads"), File(folder.root, "cache")) { "agent" } }

    /** What the reader sees: page numbers in order, `gap` where the download has a marker. */
    private fun shape(directory: File) = ComicPages.stored(directory).map { if (ComicPages.isGap(it)) "gap" else it.readText() }

    // A page the site would not give up keeps its place: dropped, every page after it would
    // shift up one and the chapter would read as whole while being short.
    @Test
    fun aMissingPageHoldsItsPlaceAndIsFilledInPlace() {
        val chapter = File(folder.root, "chapter")
        pages.write(listOf("a".toByteArray(), null, "c".toByteArray()), chapter)
        assertEquals(listOf("a", "gap", "c"), shape(chapter))

        pages.store("b".toByteArray(), ComicPages.Page(1, File(chapter, ComicPages.name(1)), "https://example.com/2.jpg"))
        assertEquals(listOf("a", "b", "c"), shape(chapter))
    }

    // A crash between a filled page landing and its marker going leaves both: the page wins,
    // or page 2 would be counted twice and every page after it read one off.
    @Test
    fun aPageWinsOverItsLeftoverMarker() {
        val chapter = File(folder.root, "chapter").apply { mkdirs() }
        File(chapter, "000").writeText("a")
        File(chapter, "001").writeText("b")
        File(chapter, "001${ComicPages.GAP}").writeText("")
        File(chapter, ".002.part").writeText("half")
        assertEquals(listOf("a", "b"), shape(chapter))
    }

    // By number, not by name: a chapter of a thousand pages must not read page 1000 between 100 and 101.
    @Test
    fun pagesReadInNumberOrder() {
        val chapter = File(folder.root, "chapter").apply { mkdirs() }
        for (n in listOf(1000, 101, 99, 100)) File(chapter, ComicPages.name(n)).writeText("$n")
        assertEquals(listOf("99", "100", "101", "1000"), shape(chapter))
    }
}
