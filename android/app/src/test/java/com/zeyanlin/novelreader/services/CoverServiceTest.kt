package com.zeyanlin.novelreader.services

import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class CoverServiceTest {
    @get:Rule
    val folder = TemporaryFolder()

    private val jpeg = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 1, 2, 3)

    // The shelf and 近期閱讀 draw the same book at the same moment, and a hotlinked cover is
    // refused as often as not: one request per book however many rows ask, and none again for an
    // address that said no — not one per row scrolled past, forever.
    @Test
    fun aCoverIsAskedForOnceAndARefusalIsRemembered() = runBlocking<Unit> {
        val asked = mutableListOf<String>()
        val covers = CoverService(File(folder.root, "kept"), File(folder.root, "cache"), this) { address, _, _ ->
            asked += address
            delay(100)
            if (address.endsWith("ok.jpg")) jpeg else null
        }
        val rows = List(2) { async { covers.cover("s|1", "s", "1", "https://x/ok.jpg") } }.awaitAll()
        assertEquals(rows[0], rows[1])
        assertArrayEquals(jpeg, rows[0]!!.readBytes())

        repeat(2) { assertNull(covers.cover("s|2", "s", "2", "https://x/gone.jpg")) }
        // Drawn again from the file, without asking.
        assertEquals(rows[0], covers.cover("s|1", "s", "1", "https://x/ok.jpg"))
        assertEquals(listOf("https://x/ok.jpg", "https://x/gone.jpg"), asked)
    }

    // A fetched cover comes back on the next drawing; an imported comic's has no site to come back
    // from, so clearing the cache must not take it, or the placeholder is that comic's for good.
    @Test
    fun clearingTheCacheKeepsAnImportedCover() = runBlocking<Unit> {
        val covers = CoverService(File(folder.root, "kept"), File(folder.root, "cache"), this) { _, _, _ -> jpeg }
        assertNotNull(covers.cover("s|1", "s", "1", "https://x/ok.jpg"))
        covers.keep(jpeg, "local|1")
        covers.clearCache()
        assertNull(covers.stored("s|1"))
        assertNotNull(covers.stored("local|1"))
    }
}
