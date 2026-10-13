package com.zeyanlin.novelreader.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import com.zeyanlin.novelreader.data.TextHighlight
import com.zeyanlin.novelreader.services.ChapterText
import com.zeyanlin.novelreader.services.Span
import kotlinx.coroutines.Job
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.roundToInt

/** The passage in hand: picked out by a press and the grips, or a stored highlight the reader tapped. */
data class Picked(val chapterId: String, val siteChapterId: String, val text: ChapterText, val span: Span, val stored: TextHighlight? = null)

/**
 * Marks behind one laid-out paragraph, a band per line. [inset] is half the line spacing, left
 * out so stacked lines read as marked lines rather than one block.
 */
fun DrawScope.drawSpans(layout: TextLayoutResult, spans: List<Pair<Span, Color>>, inset: Float, origin: Offset = Offset.Zero) {
    val length = layout.layoutInput.text.length
    for ((span, color) in spans) {
        val end = minOf(span.end, length)
        if (end <= span.start) continue
        for (line in layout.getLineForOffset(span.start)..layout.getLineForOffset(end - 1)) {
            val from = maxOf(span.start, layout.getLineStart(line))
            val to = minOf(end, layout.getLineEnd(line))
            if (to <= from) continue
            val left = layout.getBoundingBox(from).left
            val top = layout.getLineTop(line) + inset
            drawRect(color, origin + Offset(left, top), Size(layout.getBoundingBox(to - 1).right - left, layout.getLineBottom(line) - inset - top))
        }
    }
}

/** A character's box on its line, spacing left out — where a grip stands. */
fun TextLayoutResult.glyph(offset: Int, inset: Float): Rect {
    val i = offset.coerceIn(0, maxOf(layoutInput.text.length - 1, 0))
    val box = getBoundingBox(i)
    val line = getLineForOffset(i)
    return Rect(box.left, getLineTop(line) + inset, box.right, getLineBottom(line) - inset)
}

/**
 * Over the text: the grips that move a passage's ends a character at a time, and the menu of
 * what to do with it — the iOS `SelectionGrips` and edit menu. A renderer gives only geometry,
 * in this layer's coordinates: [glyph] the box of a chapter character on screen (null off it),
 * [caretAt] the caret nearest a point, clamped to the chapter. Holds no touches but its own,
 * so the text underneath still scrolls and takes taps.
 */
@Composable
fun MarkOverlay(
    picked: Picked,
    glyph: (Int) -> Rect?,
    caretAt: (Offset) -> Int,
    onSpan: (Span) -> Unit,
    actions: List<Pair<String, () -> Unit>>,
    tint: Color,
    /** A grip let go — for a renderer that keeps something across one drag's reports. */
    onLetGo: () -> Unit = {},
) {
    val first = glyph(picked.span.start)
    val last = glyph(picked.span.end - 1)
    // The end held still while the other is dragged; read at each move, so it outlives recomposition.
    var fixed by remember { mutableStateOf<Int?>(null) }
    fun drag(other: Int): (Offset?) -> Unit = { aim ->
        if (aim == null) {
            fixed = null
            onLetGo()
        } else {
            val held = fixed ?: other.also { fixed = it }
            picked.text.caretSelection(held, caretAt(aim))?.let(onSpan)
        }
    }
    Box(Modifier.fillMaxSize()) {
        // A stored highlight is taken up whole, to copy or remove; only a new passage is shaped.
        if (picked.stored == null) {
            first?.let { Grip(it.left, it.top, it.bottom, start = true, tint, drag(picked.span.end)) }
            last?.let { Grip(it.right, it.top, it.bottom, start = false, tint, drag(picked.span.start)) }
        }
        // Out of the way while a grip moves, as iOS puts its menu away mid-drag.
        if (fixed == null && (first != null || last != null)) EditMenu(first, last, actions)
    }
}

@Composable
private fun Grip(x: Float, top: Float, bottom: Float, start: Boolean, color: Color, onDrag: (Offset?) -> Unit) {
    val density = LocalDensity.current
    val touch = with(density) { 44.dp.toPx() }
    val knob = with(density) { 5.dp.toPx() }
    val bar = with(density) { 2.dp.toPx() }
    val drag by rememberUpdatedState(onDrag)
    // Where the aim starts: on the boundary the grip is drawn at, so taking hold of it moves nothing.
    val home by rememberUpdatedState(Offset(x, (top + bottom) / 2))
    Box(
        Modifier
            .offset { IntOffset((x - touch / 2).roundToInt(), (top - touch / 2).roundToInt()) }
            .layout { measurable, _ ->
                val w = touch.roundToInt()
                val h = (bottom - top + touch).roundToInt()
                val placeable = measurable.measure(Constraints.fixed(w, h))
                layout(w, h) { placeable.place(0, 0) }
            }
            .pointerInput(Unit) {
                var aim = Offset.Zero
                coroutineScope {
                    var resting: Job? = null
                    detectDragGestures(
                        onDragStart = {
                            aim = home
                            // A finger held still reports nothing, and holding still against a page's
                            // edge is what turns it: the aim is fed back twenty times a second, as iOS does.
                            resting = launch {
                                while (true) {
                                    delay(50)
                                    drag(aim)
                                }
                            }
                        },
                        onDragEnd = {
                            resting?.cancel()
                            drag(null)
                        },
                        onDragCancel = {
                            resting?.cancel()
                            drag(null)
                        },
                    ) { change, amount ->
                        change.consume()
                        aim += amount
                        drag(aim)
                    }
                }
            }
            .drawBehind {
                val cx = size.width / 2
                val lineTop = touch / 2
                val lineBottom = size.height - touch / 2
                drawRect(color, Offset(cx - bar / 2, lineTop), Size(bar, lineBottom - lineTop))
                drawCircle(color, knob, Offset(cx, if (start) lineTop - knob else lineBottom + knob))
            },
    )
}

/** Above the passage when there is room, else below it; centred on it when it is one line. */
@Composable
private fun EditMenu(first: Rect?, last: Rect?, actions: List<Pair<String, () -> Unit>>) {
    val p = LocalPalette.current
    val density = LocalDensity.current
    val gap = with(density) { 14.dp.toPx() }
    val margin = with(density) { Margin.toPx() }
    val shape = RoundedCornerShape(50)
    Row(
        Modifier
            .layout { measurable, constraints ->
                val menu = measurable.measure(constraints.copy(minWidth = 0, minHeight = 0))
                layout(constraints.maxWidth, constraints.maxHeight) {
                    val oneLine = first != null && last != null && abs(first.top - last.top) < 1f
                    val centre = if (oneLine) (first!!.left + last!!.right) / 2 else constraints.maxWidth / 2f
                    val x = (centre - menu.width / 2).coerceIn(margin, maxOf(margin, constraints.maxWidth - menu.width - margin))
                    val above = first?.let { it.top - gap - menu.height }
                    val y = if (above != null && above >= 0) above else (last ?: first)!!.bottom + gap
                    menu.place(x.roundToInt(), y.roundToInt())
                }
            }
            .shadow(14.dp, shape)
            .background(p.card, shape),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        actions.forEachIndexed { i, (label, action) ->
            if (i > 0) Box(Modifier.width(0.5.dp).height(20.dp).background(p.separator))
            Text(label, style = Type.subheadline, color = p.label, modifier = Modifier.clickable(onClick = action).padding(horizontal = 18.dp, vertical = 11.dp))
        }
    }
}
