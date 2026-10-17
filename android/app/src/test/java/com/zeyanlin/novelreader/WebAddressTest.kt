package com.zeyanlin.novelreader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Finding the page in what another app shared. The address goes straight into a run that adds it, so
 * one taken with a stray character on its end is a book that fails to add — blamed on the site.
 */
class WebAddressTest {
    @Test
    fun theAddressIsFoundInTheShapesBrowsersAndChatsShareItIn() {
        // A browser: the address alone, or after the page's title.
        assertEquals("https://a.example/book/1", webAddress("https://a.example/book/1"))
        assertEquals("https://a.example/book/1", webAddress("斗羅大陸 - 某某小說網\nhttps://a.example/book/1"))
        // A chat: inside a sentence, closed by Chinese or English punctuation.
        assertEquals("https://a.example/book/1", webAddress("這本不錯 https://a.example/book/1。快看"))
        assertEquals("https://a.example/book/1", webAddress("Try https://a.example/book/1, it's good."))
        // A page's own query survives whole.
        assertEquals("http://a.example/read.php?id=12&page=3#top", webAddress("http://a.example/read.php?id=12&page=3#top"))
    }

    @Test
    fun textWithNoWebAddressHasNone() {
        assertNull(webAddress("只是一段筆記"))
        assertNull(webAddress("ftp://a.example/book/1"))
    }
}
