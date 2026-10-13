package com.zeyanlin.novelreader.services

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.charset.Charset

/**
 * The iOS `TextBookParserTests`. Two guesses decide whether an imported `.txt` is readable, and
 * each fails unmistakably: the wrong encoding is mojibake, a missed heading is one wall of text.
 */
class TextBookParserTest {
    private val sample = "第一章 起風\n山上的雪還沒融。"

    @Test
    fun utf8IsDecoded() = assertEquals(sample, TextBookParser.decode(sample.toByteArray()))

    /** GB18030 maps almost any bytes; tried before Big5 it would read Traditional as Simplified nonsense. */
    @Test
    fun big5FileIsNotDecodedAsSimplified() {
        val data = sample.toByteArray(Charset.forName("Big5"))
        assertTrue("fixture must not be valid UTF-8", data.toString(Charsets.UTF_8) != sample)
        assertEquals(sample, TextBookParser.decode(data))
    }

    @Test
    fun byteOrderMarksAreObeyed() {
        val utf16 = byteArrayOf(0xff.toByte(), 0xfe.toByte()) + sample.toByteArray(Charsets.UTF_16LE)
        assertEquals(sample, TextBookParser.decode(utf16))
        val utf8 = byteArrayOf(0xef.toByte(), 0xbb.toByte(), 0xbf.toByte()) + sample.toByteArray()
        assertEquals("the mark itself must not survive", sample, TextBookParser.decode(utf8))
    }

    /** A lone 0xff starts a sequence in none of the three, so there is no honest answer. */
    @Test
    fun undecodableBytesAreReportedRatherThanGuessed() =
        assertNull(TextBookParser.decode(byteArrayOf(0xff.toByte(), 0x41, 0xff.toByte(), 0x42)))

    @Test
    fun headingLinesBecomeChapters() {
        val chapters = TextBookParser.chapters("第一章 下山\n雪停了。\n風也停了。\n\n第二卷 入城\n城門在傍晚關上。\n第３回 夜行\n他沒有回頭。")
        assertEquals(listOf("第一章 下山", "第二卷 入城", "第３回 夜行"), chapters.map { it.title })
        assertEquals(listOf("雪停了。", "風也停了。"), chapters[0].paragraphs)
        assertEquals(listOf("他沒有回頭。"), chapters[2].paragraphs)
    }

    @Test
    fun textBeforeTheFirstHeadingIsKept() {
        val chapters = TextBookParser.chapters("本書由某人整理，僅供試閱。\n第一章 下山\n雪停了。")
        assertEquals(2, chapters.size)
        assertEquals(listOf("本書由某人整理，僅供試閱。"), chapters[0].paragraphs)
        assertEquals("第一章 下山", chapters[1].title)
    }

    /** The length cap is the whole guard: prose that references a chapter runs on, headings stop. */
    @Test
    fun aLongLineThatOnlyLooksLikeAHeadingStaysProse() {
        val long = "第三章的內容其實是後來才補寫的，作者在後記裡提過這件事，說是為了補上一段回憶，" +
            "而那段回憶又牽出另一個人，於是整章就這樣長了出來。"
        assertTrue(long.length > 60)
        val chapters = TextBookParser.chapters("第一章 下山\n雪停了。\n$long")
        assertEquals(1, chapters.size)
        assertEquals(listOf("雪停了。", long), chapters[0].paragraphs)
    }

    /** Why the cap is 60, not 30: a missed subtitled heading stays in the body and the chapter never starts. */
    @Test
    fun aLongSubtitledHeadingIsStillAHeading() {
        val heading = "第一百二十三章 龍城之戰（上）——他終於明白什麼叫做代價，也明白了得付出多少"
        assertTrue(heading.length > 30)
        val chapters = TextBookParser.chapters("$heading\n雪停了。")
        assertEquals(listOf(heading), chapters.map { it.title })
        assertEquals(listOf("雪停了。"), chapters.first().paragraphs)
    }

    @Test
    fun aHeadingKeepsItsPunctuation() {
        val chapters = TextBookParser.chapters("第一章 上京：雪夜。\n雪停了。")
        assertEquals(listOf("第一章 上京：雪夜。"), chapters.map { it.title })
    }

    @Test
    fun aChineseHeadingToleratesSpacesAroundItsNumber() {
        val chapters = TextBookParser.chapters("第 3 部分\n雪停了。\n第三部分\n風也停了。\n第 一 章\n他沒有回頭。")
        assertEquals(listOf("第 3 部分", "第三部分", "第 一 章"), chapters.map { it.title })
        assertEquals(listOf(listOf("雪停了。"), listOf("風也停了。"), listOf("他沒有回頭。")), chapters.map { it.paragraphs })
    }

    /** This app's own `.txt` export writes titles as plain lines; a shape it cannot read back is lost each round trip. */
    @Test
    fun englishHeadingsBecomeChapters() {
        val chapters = TextBookParser.chapters(
            "Chapter 12\nHe went down the mountain.\nCHAPTER XIII — THE CITY\nThe gate closed at dusk.\n" +
                "Chapter Twenty-One\nHe did not look back.\nPart 3\nSnow, again.\nBook II\nThen spring.",
        )
        assertEquals(
            listOf("Chapter 12", "CHAPTER XIII — THE CITY", "Chapter Twenty-One", "Part 3", "Book II"),
            chapters.map { it.title },
        )
        assertEquals(listOf("He went down the mountain."), chapters[0].paragraphs)
        assertEquals(listOf("Then spring."), chapters[4].paragraphs)
    }

    @Test
    fun unnumberedEnglishSectionNamesBecomeChapters() {
        val chapters = TextBookParser.chapters(
            "Prologue\nBefore all of it.\nFOREWORD\nA note from the translator.\n" +
                "Epilogue: Ten Years Later\nAfter all of it.\nAfterword\nA second note.",
        )
        assertEquals(listOf("Prologue", "FOREWORD", "Epilogue: Ten Years Later", "Afterword"), chapters.map { it.title })
    }

    /** Also what pins the regex to Unicode on the JVM: an ASCII `\b` finds no boundary after `１２`. */
    @Test
    fun englishHeadingsSurviveCaseDigitWidthAndStrayWhitespace() {
        val chapters = TextBookParser.chapters("  chapter 4 \t\nRain.\n\u3000Chapter １２\u3000\nSnow.\nepilogue\nDone.")
        assertEquals(listOf("chapter 4", "Chapter １２", "epilogue"), chapters.map { it.title })
        assertEquals(listOf(listOf("Rain."), listOf("Snow."), listOf("Done.")), chapters.map { it.paragraphs })
    }

    /** The cap counts characters, a dozen English words; the lower-case guard is what stops these. */
    @Test
    fun englishProseThatOpensLikeAHeadingStaysProse() {
        val prose = listOf(
            "Chapter 12 was the one he remembered for years afterwards.",
            "Chapter 12 was his favourite.",
            "Chapter 12 — the end of it",
            "Book two of the series.",
            "Part 3 of the plan failed.",
            "Prologues are rarely read.",
        )
        assertTrue("the length cap alone would not stop these", prose.all { it.length <= 60 })
        val chapters = TextBookParser.chapters((listOf("Chapter 1") + prose).joinToString("\n"))
        assertEquals(listOf("Chapter 1"), chapters.map { it.title })
        assertEquals(prose, chapters[0].paragraphs)
    }

    /** Years, list items and OCR page numbers look exactly like a bare number. */
    @Test
    fun bareNumberLinesStayProse() {
        val chapters = TextBookParser.chapters("Chapter 1\n12.\n1995\nHe was born that year.")
        assertEquals(listOf("Chapter 1"), chapters.map { it.title })
        assertEquals(listOf("12.", "1995", "He was born that year."), chapters[0].paragraphs)
    }

    @Test
    fun headinglessFileIsSplitIntoParts() {
        val paragraph = "夜色漸深，燈火未熄。".repeat(20)
        val chapters = TextBookParser.chapters(List(60) { paragraph }.joinToString("\n"), partLength = 1_000)
        assertTrue(chapters.size > 5)
        assertEquals("part titles must differ", chapters.size, chapters.map { it.title }.toSet().size)
        // Every line survives, and none is cut in the middle.
        assertEquals(60, chapters.flatMap { it.paragraphs }.size)
        assertTrue(chapters.all { c -> c.paragraphs.all { it == paragraph } })
    }

    @Test
    fun shortSingleChapterFileKeepsItsTitle() =
        assertEquals(listOf("第一章 下山"), TextBookParser.chapters("第一章 下山\n雪停了。").map { it.title })

    @Test
    fun emptyFileYieldsNothing() = assertTrue(TextBookParser.chapters("\n  \n\n").isEmpty())
}
