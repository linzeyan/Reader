package com.zeyanlin.novelreader.services

import com.zeyanlin.novelreader.services.ComicArchiveImporter.Companion.chapterTitle
import com.zeyanlin.novelreader.services.ComicArchiveImporter.Companion.identify
import com.zeyanlin.novelreader.services.ComicArchiveImporter.Companion.merge
import com.zeyanlin.novelreader.services.ComicArchiveImporter.Companion.structure
import org.junit.Assert.assertEquals
import org.junit.Test

class ComicArchiveImporterTest {
    private fun titles(found: ComicArchiveImporter.Structure) = found.chapters.map { it.title }

    // What the exporter writes must come back as it went: the comic's name, the chapters without
    // the numbers that ordered them, the pages in their order.
    @Test
    fun anExportComesBackAsItWent() {
        val found = structure(listOf("山月記/001 第一話/000.jpg", "山月記/001 第一話/002.jpg", "山月記/003 第三話/000.jpg"), "export")
        assertEquals("山月記", found.title)
        assertEquals(listOf("第一話", "第三話"), titles(found))
        assertEquals(listOf("山月記/001 第一話/000.jpg", "山月記/001 第一話/002.jpg"), found.chapters[0].pages)
    }

    // The exporter puts the shelf's cover beside the chapter folders. Coming back it is the comic's
    // cover — not a chapter named after the comic with the cover as its one page, under the file's name.
    @Test
    fun anExportsCoverComesBackAsTheCover() {
        val found = structure(listOf("山月記/cover.jpg", "山月記/001 第一話/000.jpg", "山月記/002 第二話/000.jpg"), "export")
        assertEquals("山月記", found.title)
        assertEquals(listOf("第一話", "第二話"), titles(found))
        assertEquals("山月記/cover.jpg", found.cover)
    }

    // An archive made by hand: no outer folder, so the file names the comic; chapter 2 before
    // chapter 10 and page 9 before page 10, which is not what text order says.
    @Test
    fun aHandMadeArchiveReadsInTheOrderAPersonReadsIt() {
        val found = structure(listOf("第10話/1.png", "第2話/10.png", "第2話/9.png", "第2話/1.png"), "夜行紀錄")
        assertEquals("夜行紀錄", found.title)
        assertEquals(listOf("第2話", "第10話"), titles(found))
        assertEquals(listOf("第2話/1.png", "第2話/9.png", "第2話/10.png"), found.chapters[0].pages)
    }

    // Everything a real archive carries besides the comic: the Mac's resource forks, a hidden
    // index, a readme. Counted as pages, they would be pages nothing can draw.
    @Test
    fun theArchivesOwnRubbishIsNotPages() {
        val found = structure(
            listOf("名/第1話/001.png", "名/第1話/.DS_Store", "名/__MACOSX/第1話/._001.png", "名/.thumbs/第1話/001.png", "名/readme.txt"),
            "名",
        )
        assertEquals(listOf("第1話"), titles(found))
        assertEquals(listOf("名/第1話/001.png"), found.chapters[0].pages)
    }

    // Someone who zipped one chapter's pictures meant one chapter.
    @Test
    fun aBagOfPicturesIsOneChapter() {
        val found = structure(listOf("002.png", "001.png"), "單話")
        assertEquals(listOf("單話"), titles(found))
        assertEquals(listOf("001.png", "002.png"), found.chapters[0].pages)
    }

    // A number set off from the name ordered the folder; one that is part of the name stays.
    @Test
    fun onlyAnOrderingNumberComesOff() {
        assertEquals("第01話", chapterTitle("001 第01話"))
        assertEquals("1話", chapterTitle("1話"))
        assertEquals("一騎當千", chapterTitle("一騎當千"))
        assertEquals("007", chapterTitle("007"))
    }

    // An export too large for one file comes in parts, which may arrive in either order; a comic
    // that gained a prologue renumbers every folder after it. Either way: one comic, every
    // chapter once, in the comic's order.
    @Test
    fun partsAndReImportsMergeIntoOneComic() {
        fun part(vararg folders: String) = identify(structure(folders.map { "長篇/$it/1.png" }, "x").chapters)
        val second = merge(part("003 第3話", "004 第4話"), emptyList(), "book")
        val both = merge(part("001 第1話", "002 第2話"), second, "book")
        assertEquals(listOf("第1話", "第2話", "第3話", "第4話"), both.map { it.title })

        val again = merge(part("001 序章", "002 第1話", "003 第2話", "004 第3話", "005 第4話"), both, "book")
        assertEquals(listOf("序章", "第1話", "第2話", "第3話", "第4話"), again.map { it.title })

        // Volumes: the whole path is the order, or volume two's first chapter sorts beside volume one's.
        val volumes = merge(part("卷一/001 序", "卷二/001 終"), emptyList(), "book")
        assertEquals(listOf("序", "中", "終"), merge(part("卷一/002 中"), volumes, "book").map { it.title })
    }
}
