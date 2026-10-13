package com.zeyanlin.novelreader.siterules

import com.zeyanlin.novelreader.services.BookService
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class SiteRuleTest {
    /** The rule files the iOS app was built against, from the notes repo beside this one. */
    private val rules: Map<String, SiteRule> by lazy {
        val dir = File(System.getProperty("user.dir"), "../../../dev_docs/novel_reader/sites").canonicalFile
        assertTrue("rule files expected at $dir", dir.isDirectory)
        dir.listFiles { f -> f.extension == "json" }!!.associate { it.nameWithoutExtension to SiteRule.decode(it.readText()) }
    }

    private fun rule(id: String) = checkNotNull(rules[id]) { "no rule $id" }

    // A rule file written for iOS has to work here unchanged, or the two apps cannot share one.
    @Test
    fun everyIosRuleFileDecodesWithTheBlockItsKindNeeds() {
        assertTrue(rules.size >= 19)
        for ((file, rule) in rules) {
            assertEquals("$file: id matches its file name", file, rule.id)
            when (rule.kind) {
                SiteRule.Kind.NOVEL -> assertNotNull("$file: a novel rule reads chapters", rule.chapter)
                SiteRule.Kind.COMIC -> assertNotNull("$file: a comic rule reads images", rule.images)
                SiteRule.Kind.FEED -> error("$file: no rule file may declare a feed")
            }
        }
    }

    /**
     * A gated 8comic book bounces to the members page from a `<head>` script, so the landed address
     * is all that is left to tell a sign-in wall from a broken page — and a wrong yes puts a
     * password form in front of a reader no site asked to sign in.
     */
    @Test
    fun aSignInWallIsRecognisedFromWhereTheFetchLanded() {
        val signIn = rule("8comic").signIn!!
        assertTrue(signIn.turnsAway("https://www.8comic.com/member/404.html"))
        assertTrue(signIn.turnsAway("https://www.8comic.com/member/404.html?r=103"))
        assertFalse(signIn.turnsAway("https://www.8comic.com/html/5946.html"))
        // The form the reader is sent to is not the locked door.
        assertFalse(signIn.turnsAway("https://www.8comic.com/member/login"))
        // Landing nowhere failed for some other reason.
        assertFalse(signIn.turnsAway(null))
    }

    @Test
    fun kindDefaultsToNovelForRulesWrittenBeforeComics() {
        assertEquals(SiteRule.Kind.NOVEL, rule("69shuba").kind)
        assertEquals(SiteRule.Kind.COMIC, rule("8comic").kind)
    }

    // The id patterns were written and verified against ICU (NSRegularExpression); these are
    // the captures the notes recorded, re-run on Java's engine.
    @Test
    fun idPatternsCaptureWhatTheIosNotesRecorded() {
        val czbooks = rule("czbooks")
        assertEquals("s6ojkc", czbooks.bookId("https://czbooks.net/n/s6ojkc"))
        assertEquals("s6ojkc", czbooks.bookId("https://czbooks.net/n/s6ojkc/s6675fe9"))
        assertEquals("s6675fe9", czbooks.chapterId("https://czbooks.net/n/s6ojkc/s6675fe9"))
        assertNull("a book URL is not a chapter", czbooks.chapterId("https://czbooks.net/n/s6ojkc"))

        val comic = rule("8comic")
        assertEquals("103", comic.bookId("https://www.8comic.com/html/103.html"))
        assertEquals("471", comic.chapterId("https://www.8comic.com/online/new-103.html?ch=471"))
        // The catalog hands over an onclick handler's text, never parsed as a URL.
        assertEquals("103", comic.bookId("cview('103-471.html',6,1);return false;"))
        assertEquals("471", comic.chapterId("cview('103-471.html',6,1);return false;"))
        assertNull(comic.chapterId("https://www.8comic.com/html/103.html"))

        val manhuaren = rule("manhuaren")
        assertEquals("huoyingrenzhe-naruto", manhuaren.bookId("https://www.manhuaren.com/manhua-huoyingrenzhe-naruto/"))
        assertNull(manhuaren.bookId("https://www.manhuaren.com/m208255/"))
    }

    @Test
    fun matchingDropsOnlyDeviceLabels() {
        val cxyqw = rule("cxyqw") // host m.cxyqw.com
        assertTrue(cxyqw.matches("https://www.cxyqw.com/cxyqw/12600.html"))
        assertTrue(cxyqw.matches("https://cxyqw.com/"))
        assertFalse(cxyqw.matches("https://img.cxyqw.com/"))
        assertFalse(cxyqw.matches("not a url"))
    }

    // A placeholder left in a script is a ReferenceError inside the page, which reads as
    // "the site returned nothing" — the worst kind of failure to debug from a reader's report.
    @Test
    fun everyScriptBuiltFromEveryRuleIsFullyFilledIn() {
        for ((id, rule) in rules) {
            val scripts = buildList {
                add(ExtractorScript.book(rule))
                add(ExtractorScript.catalog(rule))
                if (rule.chapter != null) add(ExtractorScript.chapter(rule))
                if (rule.images != null) add(ExtractorScript.comicImages(rule))
                if (rule.search != null) {
                    add(ExtractorScript.searchResults(rule))
                    add(ExtractorScript.submitSearch(rule, "劍來"))
                }
            }
            for (script in scripts) {
                assertFalse("$id: unfilled placeholder", Regex("__[A-Z]+__").containsMatchIn(script))
            }
        }
    }

    @Test
    fun scriptsCarryTheRuleButNotItsAbsentFields() {
        val script = ExtractorScript.chapter(rule("czbooks"))
        assertTrue(script.contains("\"contentSelectors\":[\"div.content\"]"))
        // explicitNulls = false: an absent optional must not reach the page as null.
        assertFalse(script.contains("\"waitFor\":null"))
    }

    @Test
    fun catalogKeepsOnlyThisBooksChaptersOnce() {
        val czbooks = rule("czbooks")
        val payload = ExtractorScript.CatalogPayload(
            listOf(
                ExtractorScript.CatalogPayload.Entry("第1章", "https://czbooks.net/n/s6ojkc/aaa"),
                ExtractorScript.CatalogPayload.Entry("第1章 again", "https://czbooks.net/n/s6ojkc/aaa"),
                ExtractorScript.CatalogPayload.Entry("another book", "https://czbooks.net/n/zzzzzz/bbb"),
                ExtractorScript.CatalogPayload.Entry("首頁", "https://czbooks.net/"),
                ExtractorScript.CatalogPayload.Entry("第2章", "https://czbooks.net/n/s6ojkc/ccc"),
            ),
        )
        val entries = BookService.entries(payload, czbooks, "s6ojkc")
        assertEquals(listOf("aaa", "ccc"), entries.map { it.siteChapterId })
    }

    @Test
    fun paragraphFiltersMatchTheRuleNotTheWholeChapter() {
        // czbooks ends some chapters with a literal "(本章完)" line, and only that line goes.
        val kept = BookService.dropping(rule("czbooks").chapter!!.dropParagraphPatterns, listOf("正文(本章完)", "(本章完)"))
        assertEquals(listOf("正文(本章完)"), kept)
        assertEquals(listOf("a"), BookService.dropping(listOf("(unclosed"), listOf("a")))
        assertEquals(listOf("「x」"), BookService.replacing(mapOf("﹁" to "「", "﹂" to "」"), listOf("﹁x﹂")))
    }
}
