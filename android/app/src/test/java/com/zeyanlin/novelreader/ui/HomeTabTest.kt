package com.zeyanlin.novelreader.ui

import com.zeyanlin.novelreader.data.Book
import com.zeyanlin.novelreader.data.HomeScreen
import com.zeyanlin.novelreader.data.ShelfRow
import com.zeyanlin.novelreader.siterules.SiteRule
import org.junit.Assert.assertEquals
import org.junit.Test

class HomeTabTest {
    private fun read(id: String, fraction: Double) = ShelfRow(
        Book("s|$id", "s", id, SiteRule.Kind.NOVEL, id, null, null, null, 0, 0, "c", 0, 0, fraction, 1, null),
        chapterTitle = "c", chapterIndex = 0, chapterCount = 1,
    )

    // Automatic decides on the history as its screen shows it: an unfinished book pushed off the end of
    // a short list cannot be tapped, so it must not be why the app opens there. A choice is where the
    // reader wants to land, whatever is waiting.
    @Test
    fun automaticOpensOnWhatTheListShows() {
        val history = listOf(read("done", 1.0), read("alsoDone", 1.0), read("open", 0.4))
        assertEquals(Tab.RECENT, homeTab(history, shown = 3, HomeScreen.AUTOMATIC))
        assertEquals(Tab.LIBRARY, homeTab(history, shown = 2, HomeScreen.AUTOMATIC))
        assertEquals(Tab.RECENT, homeTab(emptyList(), shown = 5, HomeScreen.RECENT))
        assertEquals(Tab.LIBRARY, homeTab(history, shown = 3, HomeScreen.LIBRARY))
    }
}
