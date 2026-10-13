package com.zeyanlin.novelreader.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/**
 * Moves a scrolling surface on its own — the iOS `AutoScrollDriver`. It offers a distance and is
 * told how far the surface went, which is also how running out of book is noticed: a column
 * already at its foot answers "nowhere", a fact nobody has to be asked for.
 *
 * Without iOS's bank of sub-pixel travel: a lazy list keeps the fraction of a pixel it is asked
 * for and reports it consumed, so a reading pace's quarter-pixel frames never read as a stall.
 */
class AutoScrollDriver {
    private var lastTick: Long? = null
    private var stalledSince: Long? = null

    /** The reader has the page. Nothing elapsed meanwhile: otherwise the whole hold arrives as one step when they let go. */
    fun hold() {
        lastTick = null
        stalledSince = null
    }

    /**
     * One frame's travel at [speed] pixels a second, [step] moving the surface and answering how far it went.
     *
     * @return false once the surface has had nowhere to go for [STALL_LIMIT]: the end of the book, or a chapter that will not load.
     */
    suspend fun tick(nanos: Long, speed: Float, step: suspend (Float) -> Float): Boolean {
        val previous = lastTick
        lastTick = nanos
        if (previous == null || nanos <= previous || speed <= 0f) return true
        if (step(speed * minOf(nanos - previous, LONGEST_STEP) / 1e9f) > 0f) {
            stalledSince = null
            return true
        }
        val since = stalledSince ?: nanos.also { stalledSince = it }
        return nanos - since < STALL_LIMIT
    }

    companion object {
        /**
         * Not at once: the foot of the loaded text is a place the reader passes through on the way
         * into a chapter still being fetched, and stopping there would switch this off every time
         * the network was slower than the reading.
         */
        const val STALL_LIMIT = 5_000_000_000L

        /** Two frames' worth: a frame clock that stopped while the app was away must not throw the reader a screen down the book. */
        const val LONGEST_STEP = 1_000_000_000L / 30
    }
}

/**
 * Scrolls this list at [speed] pixels a second until it runs aground. The reader's own hand wins
 * outright — a finger on the glass ([held]), or their drag, fling or tapped turn owning the list —
 * and is waited out rather than switched off, so letting go carries on from where they left it.
 */
suspend fun LazyListState.autoScroll(speed: () -> Float, held: () -> Boolean) {
    val driver = AutoScrollDriver()
    while (true) {
        val now = withFrameNanos { it }
        if (held() || isScrollInProgress) {
            driver.hold()
            continue
        }
        val going = try {
            driver.tick(now, speed()) { scrollBy(it) }
        } catch (e: CancellationException) {
            // Refused by a scroll of higher priority that began this frame; this coroutine goes on.
            currentCoroutineContext().ensureActive()
            driver.hold()
            true
        }
        if (!going) return
    }
}

/**
 * How fast a page moving on its own moves — the iOS `AutoScrollBar`, over the toolbar rather than in
 * the settings sheet: a speed is judged by watching the text go past while it changes.
 */
@Composable
fun AutoScrollStrip(value: Int, range: IntRange, onChange: (Int) -> Unit, onTouched: () -> Unit) {
    val p = LocalPalette.current
    Row(
        Modifier.navigationBarsPadding().padding(start = 12.dp, end = 12.dp, bottom = 72.dp).fillMaxWidth()
            .shadow(10.dp, CircleShape, ambientColor = Color.Black.copy(alpha = 0.12f), spotColor = Color.Black.copy(alpha = 0.12f))
            .background(p.glass, CircleShape)
            .padding(horizontal = 18.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Icon(Symbols.Tortoise, "慢", Modifier.size(18.dp), tint = p.secondary)
        Box(Modifier.weight(1f).semantics { contentDescription = "捲動速度" }) {
            IosSlider(value, range, 1, onChange = {
                onTouched()
                onChange(it)
            })
        }
        Icon(Symbols.Hare, "快", Modifier.size(18.dp), tint = p.secondary)
    }
}
