package com.zeyanlin.novelreader.services

import com.zeyanlin.novelreader.services.CacheLimit.Companion.victims
import com.zeyanlin.novelreader.services.CacheLimit.Held
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class CacheLimitTest {
    @get:Rule
    val folder = TemporaryFolder()

    private fun chapter(name: String, bytes: Long, usedAt: Long) = Held(bytes, usedAt, text = name)

    // The book someone keeps coming back to outlives the one abandoned in an evening: what goes
    // is what was read longest ago, whatever was written first, and only until the rest fits.
    @Test
    fun theLeastRecentlyReadGoFirstAndOnlyUntilTheRestFits() {
        val held = listOf(chapter("kept", 40, usedAt = 30), chapter("abandoned", 30, usedAt = 10), chapter("older", 30, usedAt = 20))
        assertEquals(listOf("abandoned"), victims(held, limit = 70).map { it.text })
        assertEquals(listOf("abandoned", "older"), victims(held, limit = 69).map { it.text })
    }

    @Test
    fun nothingGoesWhileItFits() {
        assertEquals(emptyList<Held>(), victims(listOf(chapter("a", 50, 1), chapter("b", 50, 2)), limit = 100))
    }

    // The cache screen shows the web's number under a button that cannot clear the chapter
    // cache's pages: counted there too, they would be counted twice and never go. A cache whose
    // name nobody told it — the covers' — still counts, or that button would hide what it frees.
    @Test
    fun theWebsShareIsEverythingButTheChaptersPagesAndOutgoingFiles() {
        fun write(path: String, bytes: Int) = File(folder.root, path).apply { parentFile!!.mkdirs() }.writeBytes(ByteArray(bytes))
        write("WebView/Default/HTTP Cache/entry", 100)
        write("Covers/book", 20)
        write("loose.lck", 3)
        write("${CacheLimit.PAGES}/book/chapter/000", 1_000)
        write("${CacheLimit.EXPORTS}/book.txt", 10_000)
        assertEquals(123L, CacheLimit.webBytes(folder.root))
    }
}
