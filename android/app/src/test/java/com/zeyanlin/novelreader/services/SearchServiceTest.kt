package com.zeyanlin.novelreader.services

import com.zeyanlin.novelreader.data.LibraryBackup
import com.zeyanlin.novelreader.siterules.ExtractorScript
import com.zeyanlin.novelreader.siterules.SiteRule
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.URI
import java.net.URLDecoder

/** The iOS `SearchTests`' pure half, and `ChineseVariants`'. */
class SearchServiceTest {
    private fun search(url: String, method: SiteRule.Search.Method = SiteRule.Search.Method.GET) =
        SiteRule.json.decodeFromString(
            SiteRule.Search.serializer(),
            """{"method":"${method.name}","url":"$url","queryField":"searchkey","resultLinkSelector":"a.book"}""",
        )

    @Test
    fun aChineseQueryIsPercentEncodedAndComesBackAsTyped() {
        val url = SearchService.getSearchURL(search("https://demo.test/search/?keyword={query}"), "武俠")
        assertFalse(url.contains("{query}"))
        assertTrue(url, url.contains("%E6%AD%A6%E4%BF%A0"))
        assertEquals("keyword=武俠", URLDecoder.decode(URI(url).rawQuery, Charsets.UTF_8))
    }

    // A raw space makes an invalid address; `+` would be read as a literal plus by a path template.
    @Test
    fun aSpaceBecomesPercentTwenty() {
        val url = SearchService.getSearchURL(search("https://demo.test/List/{query}"), "a b&c")
        assertEquals("https://demo.test/List/a%20b%26c", url)
        URI(url)
    }

    // An all-sites search has to say which sources it could not ask, not report "nothing found".
    @Test
    fun aRuleWithoutSearchIsRefused() {
        val rule = LibraryBackup.read(javaClass.getResource("/backup/ios-backup.json")!!.readBytes()).rules.first().copy(search = null)
        assertThrows(ExtractorScript.SearchUnsupported::class.java) { ExtractorScript.searchResults(rule) }
        assertThrows(ExtractorScript.SearchUnsupported::class.java) { ExtractorScript.submitSearch(rule, "x") }
    }

    // The query reaches the posted form intact, including quotes that would break out of the script.
    @Test
    fun theSubmitScriptEscapesTheQuery() {
        val script = ExtractorScript.submitForm("https://demo.test/search.php", "searchkey", "he said \"hi\"", SiteRule.Search.Method.POST)
        assertTrue(script.contains("searchkey"))
        assertFalse(script.contains("\"hi\""))
        assertTrue(script.contains("\\\"hi\\\""))
    }

    // As typed first, then the other script — and only when converting changes something.
    @Test
    fun theOtherScriptIsTriedOnlyWhenItDiffers() {
        assertEquals(listOf("劍來", "剑来"), SearchService.forms(" 劍來 "))
        assertEquals(listOf("剑来", "劍來"), SearchService.forms("剑来"))
        assertEquals(listOf("一二三"), SearchService.forms("一二三"))
        assertEquals(listOf("Harry Potter"), SearchService.forms("Harry Potter"))
        assertEquals(emptyList<String>(), SearchService.forms("  "))
    }
}
