package com.zeyanlin.novelreader.ui

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * When a page moving on its own gives up, and how far one frame may carry it. Stopping at the first
 * frame with nowhere to go would switch the feature off at every chapter still being fetched; never
 * stopping would leave a switch on over the end of the book; and honouring a long gap in the frame
 * clock would throw a reader back from the app switcher a screen down the book.
 */
class AutoScrollDriverTest {
    private val frame = 16_666_667L

    /** Runs frames from [from] for [seconds], the surface moving only while [moves] says so; the last tick's answer. */
    private fun AutoScrollDriver.run(from: Long, seconds: Double, moves: (Long) -> Boolean): Pair<Long, Boolean> = runBlocking {
        var now = from
        var going = true
        while (going && now < from + (seconds * 1e9).toLong()) {
            now += frame
            going = tick(now, 300f) { if (moves(now)) it else 0f }
        }
        now to going
    }

    @Test
    fun aChapterThatArrivesWithinTheLimitKeepsThePageMoving() {
        val driver = AutoScrollDriver()
        // Stalled at the foot of the loaded text for four seconds, then the next chapter lands.
        val (_, going) = driver.run(0L, 6.0) { it < 1_000_000_000L || it > 5_000_000_000L }
        assertTrue(going)
    }

    @Test
    fun theEndOfTheBookSwitchesItOffAfterTheLimitNotBefore() {
        val driver = AutoScrollDriver()
        val (at, going) = driver.run(0L, 30.0) { false }
        assertFalse(going)
        val stalled = at / 1e9
        assertTrue("gave up after ${stalled}s", stalled >= 5.0 && stalled < 5.1)
    }

    @Test
    fun aLongGapInTheFrameClockMovesAtMostTwoFrames() = runBlocking {
        val driver = AutoScrollDriver()
        var asked = 0f
        driver.tick(0L, 300f) { it }
        driver.tick(60_000_000_000L, 300f) { asked = it; it }
        assertEquals(300f / 30, asked, 0.01f)
    }

    @Test
    fun theTimeAFingerHeldThePageIsNotPaidOutWhenItLifts() = runBlocking {
        val driver = AutoScrollDriver()
        driver.tick(0L, 300f) { it }
        driver.hold()
        var asked = -1f
        // The first frame after the hold only starts the clock again; the next moves one frame's worth.
        driver.tick(3_000_000_000L, 300f) { asked = it; it }
        assertEquals(-1f, asked)
        driver.tick(3_000_000_000L + frame, 300f) { asked = it; it }
        assertEquals(300f * frame / 1e9f, asked, 0.01f)
    }
}
