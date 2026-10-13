package com.zeyanlin.novelreader.ui

import androidx.compose.ui.geometry.Offset
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The comic column's magnification. What matters is that the reader keeps their place through it:
 * the panel under the fingers stays under them through a pinch, and a double tap brings the panel
 * tapped to the middle and comes back out without moving what is in the middle. A zoom that slides
 * the page out from under the reader is one they have to undo by hand.
 */
class ZoomTest {
    private val width = 1080f
    private val height = 2000f

    /** Where a point of the column lands on the glass, with the column scrolled to [top]. */
    private fun Zoom.onScreen(x: Float, y: Float, top: Float) = Offset(x * scale + panX, (y - top) * scale)

    @Test
    fun aPinchKeepsWhatIsUnderTheFingersUnderThem() {
        var zoom = Zoom()
        var top = 5000f
        var fingers = Offset(300f, 800f)
        val x = fingers.x
        val y = top + fingers.y
        // Spreading while the hand drifts down and right, in two steps, as a pinch arrives frame by frame.
        for (factor in listOf(1.5f, 1.6f)) {
            val next = fingers + Offset(30f, 40f)
            val (to, scroll) = zoom.pinched(factor, fingers, next, width)
            zoom = to
            top += scroll
            fingers = next
            val seen = zoom.onScreen(x, y, top)
            assertEquals(fingers.x, seen.x, 0.01f)
            assertEquals(fingers.y, seen.y, 0.01f)
        }
        assertEquals(2.4f, zoom.scale, 0.001f)
        // No further in than a scan has pixels for, nor out past the page's own width.
        assertEquals(3f, zoom.pinched(4f, fingers, fingers, width).first.scale)
        val out = zoom.pinched(0.1f, fingers, fingers, width).first
        assertEquals(1f, out.scale)
        assertEquals(0f, out.panX, 0f)
    }

    @Test
    fun aDoubleTapBringsThePanelToTheMiddleAndGoesBackOutAroundIt() {
        val top = 5000f
        val (zoomed, scroll) = Zoom().doubleTapped(Offset(800f, 1500f), width, height)
        assertEquals(Offset(width / 2, height / 2), zoomed.onScreen(800f, top + 1500f, top + scroll))
        // Near the edge the page stops at the edge rather than showing black beside it.
        val (edge, _) = Zoom().doubleTapped(Offset(1050f, 1000f), width, height)
        assertEquals(width, edge.onScreen(width, 0f, 0f).x, 0.01f)

        // Out again: what is in the middle of the screen stays there.
        val (out, back) = zoomed.doubleTapped(Offset(100f, 100f), width, height)
        val middle = top + scroll + height / 2 / zoomed.scale
        assertEquals(height / 2, out.onScreen(0f, middle, top + scroll + back).y, 0.01f)
        assertEquals(Zoom(), out)
    }
}
