package com.zeyanlin.novelreader.ui

import com.zeyanlin.novelreader.siterules.SiteRule
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * A stored arrangement must survive the builds after it: a reader who arranged their bar once
 * should never find a new control lost on the end, an old name breaking the bar, or a comic
 * offering a bookmark it cannot keep.
 */
class ReaderToolbarTest {
    @Test
    fun aControlTheReaderNeverArrangedSitsWhereItWasDesigned() {
        // Arranged before auto-scroll existed, with settings moved to the front.
        val layout = ReaderToolbarLayout(listOf("settings", "back", "catalog", "bookmark", "previousChapter", "nextChapter", "original", "speech"))
        assertEquals(
            listOf(
                ReaderButton.SETTINGS, ReaderButton.BACK, ReaderButton.CATALOG, ReaderButton.BOOKMARK, ReaderButton.PREVIOUS,
                ReaderButton.NEXT, ReaderButton.ORIGINAL, ReaderButton.AUTO_SCROLL, ReaderButton.SPEECH,
            ),
            layout.arrangement(null),
        )
    }

    @Test
    fun aNameThisBuildDoesNotKnowIsDroppedAndTheShelfTakesItsOwn() {
        val layout = ReaderToolbarLayout(listOf("nextChapter", "teleport", "speech", "back"))
        assertEquals(
            listOf(ReaderButton.NEXT, ReaderButton.AUTO_SCROLL, ReaderButton.SETTINGS, ReaderButton.BACK, ReaderButton.CATALOG, ReaderButton.PREVIOUS),
            layout.arrangement(SiteRule.Kind.COMIC),
        )
    }

    @Test
    fun foldedControlsLeaveTheBarInTheirArrangedOrder() {
        val layout = ReaderToolbarLayout(folded = listOf("speech", "catalog"))
        val (bar, folded) = layout.resolve(SiteRule.Kind.NOVEL)
        assertEquals(listOf(ReaderButton.CATALOG, ReaderButton.SPEECH), folded)
        assertEquals(
            listOf(ReaderButton.BACK, ReaderButton.BOOKMARK, ReaderButton.PREVIOUS, ReaderButton.NEXT, ReaderButton.AUTO_SCROLL, ReaderButton.SETTINGS),
            bar,
        )
        // A comic has no voice to fold.
        assertEquals(listOf(ReaderButton.CATALOG), layout.resolve(SiteRule.Kind.COMIC).second)
    }
}
