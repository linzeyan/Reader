package com.zeyanlin.novelreader.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The book moves under a reader's finger here, so the rule must turn a page only when asked: a
 * grip brought to the edge and held there, never a press that happens to sit on the last line,
 * and never past the chapter a highlight has to stay inside.
 */
class SelectionEdgeRuleTest {
    private val height = 800f
    private val body = 400f
    private val bottom = 790f

    @Test
    fun aGripBroughtToTheBottomAndHeldTurnsAPagePerDwell() {
        val rule = SelectionEdgeRule(strip = 40f)
        assertEquals(0, rule.follow(body, height, now = 0, page = 0, count = 5))
        assertEquals("arriving arms, it does not turn", 0, rule.follow(bottom, height, now = 10, page = 0, count = 5))
        assertEquals(0, rule.follow(bottom, height, now = 400, page = 0, count = 5))
        assertEquals(1, rule.follow(bottom, height, now = 410, page = 0, count = 5))
        assertEquals("the next page is another dwell away", 0, rule.follow(bottom, height, now = 700, page = 1, count = 5))
        assertEquals(1, rule.follow(bottom, height, now = 810, page = 1, count = 5))
    }

    @Test
    fun aGripTakenHoldOfInTheStripNeverTurns() {
        val rule = SelectionEdgeRule(strip = 40f)
        for (now in 0L..2_000L step 50) assertEquals(0, rule.follow(bottom, height, now, page = 0, count = 5))
        // Nor does one let go and taken hold of again there, though the last drag ended in the text.
        rule.follow(body, height, now = 2_050, page = 0, count = 5)
        rule.reset()
        for (now in 2_100L..4_000L step 50) assertEquals(0, rule.follow(bottom, height, now, page = 0, count = 5))
    }

    @Test
    fun theChaptersEndsHoldTheGrip() {
        val rule = SelectionEdgeRule(strip = 40f)
        rule.follow(body, height, now = 0, page = 4, count = 5)
        rule.follow(bottom, height, now = 10, page = 4, count = 5)
        assertEquals(0, rule.follow(bottom, height, now = 1_000, page = 4, count = 5))
        rule.follow(body, height, now = 1_050, page = 0, count = 5)
        rule.follow(5f, height, now = 1_100, page = 0, count = 5)
        assertEquals(0, rule.follow(5f, height, now = 2_000, page = 0, count = 5))
    }
}
