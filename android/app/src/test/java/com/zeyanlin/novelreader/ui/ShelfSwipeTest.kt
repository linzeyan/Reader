package com.zeyanlin.novelreader.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class ShelfSwipeTest {
    private fun rest(offset: Float, velocity: Float = 0f, lead: Boolean = true) =
        swipeRest(offset, velocity, reveal = 160f, width = 400f, lead = if (lead) 56f else null, fling = 125f)

    // As iOS's trailing swipe settles: the buttons stay out past half their width, a flick opens or shuts
    // them, and only a drag most of the way across deletes — a fast flick never does. The leading edge
    // acts only on a row that has a leading action.
    @Test
    fun aLetGoRowRestsWhereIosWould() {
        assertEquals(SwipeRest.CLOSED, rest(-70f))
        assertEquals(SwipeRest.OPEN, rest(-90f))
        assertEquals(SwipeRest.OPEN, rest(-30f, velocity = -500f))
        assertEquals(SwipeRest.CLOSED, rest(-150f, velocity = 500f))
        assertEquals(SwipeRest.OPEN, rest(-270f, velocity = -5000f))
        assertEquals(SwipeRest.DELETE, rest(-290f))
        assertEquals(SwipeRest.LEAD, rest(60f))
        assertEquals(SwipeRest.LEAD, rest(20f, velocity = 500f))
        assertEquals(SwipeRest.CLOSED, rest(20f))
        assertEquals(SwipeRest.CLOSED, rest(200f, lead = false))
    }
}
