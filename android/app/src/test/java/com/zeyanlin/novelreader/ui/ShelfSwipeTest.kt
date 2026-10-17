package com.zeyanlin.novelreader.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class ShelfSwipeTest {
    private fun rest(offset: Float, velocity: Float = 0f, lead: Float? = 160f) =
        swipeRest(offset, velocity, reveal = 160f, width = 400f, lead = lead, fling = 125f)

    // As iOS's trailing swipe settles: the buttons stay out past half their width, a flick opens or shuts
    // them, and only a drag most of the way across deletes — a fast flick never does.
    @Test
    fun aRowLetGoLeftRestsWhereIosWould() {
        assertEquals(SwipeRest.CLOSED, rest(-70f))
        assertEquals(SwipeRest.OPEN, rest(-90f))
        assertEquals(SwipeRest.OPEN, rest(-30f, velocity = -500f))
        assertEquals(SwipeRest.CLOSED, rest(-150f, velocity = 500f))
        assertEquals(SwipeRest.OPEN, rest(-270f, velocity = -5000f))
        assertEquals(SwipeRest.DELETE, rest(-290f))
    }

    // The leading edge settles the same way, now that it holds two buttons — 標為已讀 and 複製原始網址 — and a
    // drag that commits on release could only ever have been one of them. A full swipe still does the
    // first, so a subscription is cleared by the gesture that always cleared it; a short drag no longer
    // copies or clears anything by accident, it shows the buttons.
    @Test
    fun aRowLetGoRightRestsOnItsLeadingButtonsTheSameWay() {
        assertEquals(SwipeRest.CLOSED, rest(70f))
        assertEquals(SwipeRest.LEAD_OPEN, rest(90f))
        assertEquals(SwipeRest.LEAD_OPEN, rest(30f, velocity = 500f))
        assertEquals(SwipeRest.CLOSED, rest(150f, velocity = -500f))
        assertEquals(SwipeRest.LEAD_OPEN, rest(270f, velocity = 5000f))
        assertEquals(SwipeRest.LEAD, rest(290f))
        // One button: half its width opens it, and the full swipe is measured from it.
        assertEquals(SwipeRest.LEAD_OPEN, rest(50f, lead = 80f))
        assertEquals(SwipeRest.LEAD, rest(250f, lead = 80f))
    }

    // An imported book with no address, on a shelf that is not the feed shelf, has nothing on that edge.
    @Test
    fun aRowWithNoLeadingActionDoesNothingDraggedRight() {
        assertEquals(SwipeRest.CLOSED, rest(200f, lead = null))
        assertEquals(SwipeRest.CLOSED, rest(20f, velocity = 500f, lead = null))
    }
}
