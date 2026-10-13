package com.zeyanlin.novelreader.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import com.zeyanlin.novelreader.data.TextHighlight
import com.zeyanlin.novelreader.data.chapterShare
import com.zeyanlin.novelreader.services.ChapterText
import com.zeyanlin.novelreader.services.ChineseScript
import com.zeyanlin.novelreader.services.ChineseText
import com.zeyanlin.novelreader.services.SpokenSentence
import com.zeyanlin.novelreader.services.range
import kotlinx.coroutines.delay
import java.io.File
import kotlin.math.abs
import kotlin.math.roundToInt

/** One laid-out line: its paragraph (-1 for the title), where in it the line starts, and where it sits in the column. */
data class PageLine(val paragraph: Int, val offset: Int, val top: Float, val bottom: Float)

/**
 * A chapter's lines grouped into pages — the iOS `ChapterPaginator.rebuildPages`. Greedy: a page
 * ends at the first line that would not fit, and breaks fall between lines, never between
 * paragraphs only, or a long paragraph would leave a page holding one line.
 */
class PageMap(private val lines: List<PageLine>, private val height: Float) {
    /** Index of each page's first line. */
    private val starts: List<Int> = buildList {
        if (lines.isNotEmpty()) add(0)
        var top = lines.firstOrNull()?.top ?: 0f
        lines.forEachIndexed { i, line ->
            // `i > last()`: a line taller than the page still gets a page of its own.
            if (line.bottom - top > height && i > last()) {
                add(i)
                top = line.top
            }
        }
    }

    val count get() = starts.size

    fun top(page: Int) = lines[starts[page]].top

    /** Where the next page begins, which is where this one stops being drawn. */
    fun bottom(page: Int) = minOf(top(page) + height, starts.getOrNull(page + 1)?.let { lines[it].top } ?: Float.MAX_VALUE)

    /**
     * The page's first character, which a page can name exactly where a scrolling column can
     * only name a paragraph. Title positions keep paragraph -1, so a page of nothing but a
     * long title still has an anchor of its own.
     */
    fun anchor(page: Int): Pair<Int, Int> = lines[starts[page]].let { it.paragraph to it.offset }

    /** The page showing the character at [paragraph]/[offset]. */
    fun pageOf(paragraph: Int, offset: Int): Int {
        val page = starts.indexOfLast { val l = lines[it]; l.paragraph < paragraph || (l.paragraph == paragraph && l.offset <= offset) }
        return page.coerceAtLeast(0)
    }

    /** Where the text after [page] starts, or null for the last page. */
    fun end(page: Int): PageLine? = starts.getOrNull(page + 1)?.let { lines[it] }

    /** How much of [page] has text on it: a chapter's last page is usually a few lines, not a page's worth. */
    fun filled(page: Int) = minOf(bottom(page), lines.last().bottom) - top(page)
}

/**
 * When a grip dragged against the top or bottom of a page turns it — the iOS `SelectionEdgeRule`,
 * with the hold iOS keeps beside it. The caller keeps the clock, so the rule that moves the book
 * under a reader's finger is tested without a page or a gesture.
 *
 * Top and bottom rather than the sides, though pages turn sideways: a strip down the right is the
 * end of every line, where a finger almost always means "the end of this line". [dwell] is the
 * press that starts a selection: holding still is how the page is told "I mean this", and turning
 * on contact would make one quick slide down the page into three turns.
 */
class SelectionEdgeRule(private val strip: Float, private val dwell: Long = 400) {
    private var held = 0
    private var since = 0L
    private var previous: Float? = null

    /** 1 in the bottom strip, -1 in the top, 0 in the body; a point past the page is in the strip it left through. */
    fun strip(y: Float, height: Float) = when {
        // Two strips and no text between them would turn the page under every press.
        height <= strip * 2 -> 0
        y >= height - strip -> 1
        y <= strip -> -1
        else -> 0
    }

    /**
     * The turn a finger at [y] has earned by [now], 0 to stay. Armed by arriving in a strip from the
     * body, not by being in it: holding still is what a press is, so position alone would turn the
     * page under a reader marking its last line. Restarted after each turn, so a finger left there
     * turns pages at a rate the reader can still read. Stops at the chapter's ends: a highlight
     * whose two ends name different chapters is not a thing this app can store.
     */
    fun follow(y: Float, height: Float, now: Long, page: Int, count: Int): Int {
        val from = previous
        previous = y
        val at = strip(y, height)
        if (at == 0) {
            // Dragged back into the text: the reader has stopped asking for pages.
            held = 0
            return 0
        }
        if (held != at) {
            if (from != null && strip(from, height) == 0) {
                held = at
                since = now
            }
            return 0
        }
        if (now - since < dwell || page + at !in 0 until count) return 0
        since = now
        return at
    }

    /** The finger let go: the next one arrives from nowhere. */
    fun reset() {
        held = 0
        previous = null
    }
}

/** Where a chapter opens: an anchor in it, or its last page (a turn back past the chapter after). */
data class PageLanding(val paragraph: Int, val offset: Int, val atEnd: Boolean = false)

/** A laid-out paragraph: text, or — for an article's picture — a box [width] wide with no layout at all. */
private class Block(val layout: TextLayoutResult?, val top: Float, val height: Float, val piece: Piece? = null, val width: Float = 0f) {
    /** Where offsets mean anchor offsets; the title (block 0) is never one. */
    val markable get() = layout != null && piece?.selectable != false
}

private class Laid(val blocks: List<Block>, val map: PageMap)

/**
 * One chapter, one page at a time — the iOS `PaginatedChapterView`. Told a chapter and where to
 * open it, it reports where the reader is and when a turn runs off either end; changing
 * chapters stays with the reader screen, as iOS keeps it in `ReaderModel`.
 *
 * Laid out with the scrolling reader's own styles and width, so switching modes mid-chapter
 * cannot reflow the book under the reader.
 */
@Composable
fun PagedChapter(
    chapterKey: String,
    title: String,
    paragraphs: List<String>,
    landing: PageLanding,
    titleStyle: TextStyle,
    bodyStyle: TextStyle,
    titleGap: Dp,
    paragraphGap: Dp,
    script: ChineseScript,
    pageTurn: ReaderSettings.PageTurn,
    ink: Color,
    chrome: Boolean,
    onChrome: (Boolean) -> Unit,
    onPosition: (paragraph: Int, offset: Int, fraction: Double) -> Unit,
    onTurnPast: (forward: Boolean) -> Unit,
    marks: List<TextHighlight>,
    picked: Picked?,
    palette: ReaderPalette,
    inset: Float,
    onPress: (paragraph: Int, offset: Int) -> Unit,
    /** True when the marks took the tap: a passage put away, or a highlight taken up. */
    onTapText: (paragraph: Int?, offset: Int) -> Boolean,
    overlay: @Composable (glyph: (Int) -> Rect?, caretAt: (Offset) -> Int, letGo: () -> Unit) -> Unit,
    /** The sentence being read aloud, when the voice is in this chapter: painted, and its page turned to. */
    spoken: SpokenSentence?,
    /** Lines a minute when the page is to turn itself, the scrolling reader's pace; null when it is not. */
    autoTurn: Int?,
    /** An article's title with its date and link, drawn in place of [title]. */
    heading: AnnotatedString? = null,
    /** An article's paragraphs as its blocks draw them; null for prose. */
    pieces: List<Piece>? = null,
    onLink: (String) -> Unit = {},
) {
    val measurer = rememberTextMeasurer(cacheSize = 0)
    var at by remember(landing) { mutableStateOf(if (landing.atEnd) null else landing.paragraph to landing.offset) }
    var forward by remember { mutableStateOf(true) }
    var drag by remember { mutableFloatStateOf(0f) }
    var shown by remember { mutableDoubleStateOf(0.0) }
    var shownAt by remember { mutableLongStateOf(0L) }
    // A turn a grip asked for: no slide, which would pull the text being aimed at out from under a still finger.
    var still by remember { mutableStateOf(false) }

    Column(Modifier.fillMaxSize().padding(horizontal = 20.dp).padding(top = 8.dp, bottom = 2.dp)) {
        BoxWithConstraints(Modifier.weight(1f).fillMaxWidth()) {
            val width = constraints.maxWidth
            val height = constraints.maxHeight.toFloat()
            val density = LocalDensity.current
            val titleGapPx = with(density) { titleGap.toPx() }
            val gapPx = with(density) { paragraphGap.toPx() }
            // ponytail: the whole chapter is measured at once, about a frame for a long one;
            // measure it a chunk at a time, as iOS does, if opening a chapter is seen to stall.
            val laid = remember(chapterKey, width, height, titleStyle, bodyStyle, titleGapPx, gapPx, script, heading, pieces) {
                val blocks = ArrayList<Block>()
                val lines = ArrayList<PageLine>()
                var y = 0f
                // As on iOS: a picture never taller than a page leaves room for a line and the spacing around it.
                val tallest = height - 2 * gapPx - with(density) { bodyStyle.lineHeight.toPx() }
                fun add(text: AnnotatedString, style: TextStyle, paragraph: Int, gap: Float, piece: Piece? = null) {
                    val picture = piece?.picture
                    if (picture != null) {
                        val (w, h) = picture.size(width / density.density, tallest / density.density).let { (w, h) -> w * density.density to h * density.density }
                        lines += PageLine(paragraph, 0, y, y + h)
                        blocks += Block(null, y, h, piece, w)
                        y += h + gap
                        return
                    }
                    val layout = measurer.measure(text, style, constraints = Constraints(maxWidth = width))
                    for (l in 0 until layout.lineCount) {
                        lines += PageLine(paragraph, layout.getLineStart(l), y + layout.getLineTop(l), y + layout.getLineBottom(l))
                    }
                    blocks += Block(layout, y, layout.size.height.toFloat(), piece)
                    y += layout.size.height + gap
                }
                add(heading ?: AnnotatedString(ChineseText.rendered(title, script)), titleStyle, -1, titleGapPx)
                paragraphs.forEachIndexed { i, text ->
                    val piece = pieces?.getOrNull(i)
                    if (piece != null) add(piece.text, piece.style, i, gapPx, piece) else add(AnnotatedString(ChineseText.rendered(text, script)), bodyStyle, i, gapPx)
                }
                Laid(blocks, PageMap(lines, height))
            }
            val map = laid.map
            val page = at?.let { (p, o) -> map.pageOf(p, o) } ?: (map.count - 1)

            // A lambda, not a local fun: the Compose compiler memoizes a `::turn` reference
            // without its captures, and the gestures kept turning from the chapter's first page.
            val turn: (Int) -> Unit = { delta ->
                val target = page + delta
                when {
                    target < 0 -> onTurnPast(false)
                    target >= map.count -> onTurnPast(true)
                    else -> {
                        forward = delta > 0
                        still = false
                        at = map.anchor(target)
                    }
                }
            }
            val pageTop = map.top(page)
            val pageHeight = map.bottom(page) - pageTop

            /** The paragraph and character under a point on this page; null on the title or between paragraphs. */
            fun characterAt(at: Offset): Pair<Int, Int>? {
                val y = at.y + pageTop
                val i = laid.blocks.indexOfFirst { y >= it.top && y < it.top + it.height }
                if (i < 1 || !laid.blocks[i].markable) return null
                val layout = laid.blocks[i].layout!!
                val length = layout.layoutInput.text.length
                if (length == 0) return null
                val local = Offset(at.x, y - laid.blocks[i].top)
                val caret = layout.getOffsetForPosition(local)
                val character = if (caret >= length || (caret > 0 && layout.getHorizontalPosition(caret, true) > local.x)) caret - 1 else caret
                return i - 1 to character
            }

            val edge = remember(density) { SelectionEdgeRule(with(density) { 40.dp.toPx() }) }

            /**
             * The caret nearest a grip's aim, on the page it is aimed at: held against the top or
             * bottom, the grip turns the page under it and keeps the passage, as on iOS. The page is
             * read from [at] rather than [page], which is this composition's and a turn behind.
             */
            fun caretAt(text: ChapterText, aim: Offset): Int {
                var current = at?.let { (p, o) -> map.pageOf(p, o) } ?: (map.count - 1)
                val turned = edge.follow(aim.y, height, System.currentTimeMillis(), current, map.count)
                if (turned != 0) {
                    current += turned
                    forward = turned > 0
                    still = true
                    at = map.anchor(current)
                }
                val top = map.top(current)
                // Short of the bottom: the bottom is the next page's first line, and a caret there
                // puts the grip off this page, which takes it, and the drag holding it, away.
                val y = aim.y.coerceIn(0f, map.bottom(current) - top - 1f) + top
                val i = laid.blocks.indexOfLast { it.top <= y }.coerceAtLeast(1)
                val block = laid.blocks.getOrNull(i) ?: return 0
                return text.start(i - 1) + (block.layout?.getOffsetForPosition(Offset(aim.x, y - block.top)) ?: 0)
            }

            fun glyph(text: ChapterText, offset: Int): Rect? {
                val anchor = text.anchor(offset)
                val block = laid.blocks.getOrNull(anchor.paragraph + 1) ?: return null
                val box = (block.layout ?: return null).glyph(anchor.offset, inset).translate(0f, block.top - pageTop)
                return box.takeIf { it.bottom > 0 && it.top < pageHeight }
            }

            /** A link under the finger — inline, or the title's own — the page's stand-in for a `Text` that handles its links itself. */
            fun linkAt(at: Offset): String? {
                val y = at.y + pageTop
                val block = laid.blocks.firstOrNull { y >= it.top && y < it.top + it.height } ?: return null
                val layout = block.layout ?: return null
                val local = Offset(at.x, y - block.top)
                val offset = layout.getOffsetForPosition(local)
                if (offset >= layout.layoutInput.text.length || !layout.getBoundingBox(offset).inflate(8f).contains(local)) return null
                return layout.layoutInput.text.getLinkAnnotations(offset, offset + 1).firstNotNullOfOrNull { (it.item as? LinkAnnotation.Url)?.url }
            }

            // Pictures on this page and its neighbours, decoded off the main thread at the size they are drawn.
            val bitmaps = remember(laid) { mutableStateMapOf<File, ImageBitmap>() }
            LaunchedEffect(page, laid) {
                val from = map.top((page - 1).coerceAtLeast(0))
                val to = map.bottom((page + 1).coerceAtMost(map.count - 1))
                for (block in laid.blocks) {
                    val picture = block.piece?.picture ?: continue
                    if (block.top + block.height < from || block.top > to || picture.file in bitmaps) continue
                    ArticlePictures.load(picture.file, block.width.roundToInt())?.let { bitmaps[picture.file] = it }
                }
            }

            val turnNow by rememberUpdatedState(turn)
            val linkNow by rememberUpdatedState { at: Offset -> linkAt(at)?.let(onLink) != null }
            val pressNow by rememberUpdatedState { at: Offset -> characterAt(at)?.let { (p, o) -> onPress(p, o) } }
            val tapMarksNow by rememberUpdatedState { at: Offset -> characterAt(at).let { onTapText(it?.first, it?.second ?: 0) } }
            val chromeNow by rememberUpdatedState(chrome)
            val tapsTurn by rememberUpdatedState(pageTurn.turnsOnTap)

            // Every way a page arrives passes through here — a turn, a landing, a re-layout —
            // and the anchor is pinned to the page's first character, so a rebuild at a new
            // size keeps the reader on the text they were reading, not on the same page number.
            LaunchedEffect(page, map) {
                val (p, o) = map.anchor(page)
                at = p to o
                val end = map.end(page)
                val share = if (end == null) 1.0 else chapterShare(title, paragraphs, end.paragraph, if (end.paragraph < 0) 0 else end.offset)
                shown = share
                shownAt = System.currentTimeMillis()
                onPosition(p.coerceAtLeast(0), if (p < 0) 0 else o, share)
            }

            // The page that turns itself, given as long as its text takes to read at the scrolling
            // reader's pace, so one speed means one thing in both. One wait per page: a page turned
            // to by hand is a page not yet read. Timed from the page's arrival, so a pace nudged
            // mid-page counts what was already read rather than pushing the turn a page away.
            val lineHeight = with(density) { bodyStyle.lineHeight.toPx() }
            LaunchedEffect(page, map, autoTurn) {
                val pace = autoTurn ?: return@LaunchedEffect
                delay((map.filled(page) / lineHeight / pace * 60_000).toLong() - (System.currentTimeMillis() - shownAt))
                turnNow(1)
            }

            // A sentence is on the page or it is not — the band the scrolling reader keeps the voice inside.
            LaunchedEffect(spoken, map) {
                val s = spoken ?: return@LaunchedEffect
                val target = map.pageOf(s.paragraph, s.range.start)
                if (target == page) return@LaunchedEffect
                forward = target > page
                still = false
                at = map.anchor(target)
            }

            AnimatedContent(
                targetState = page,
                transitionSpec = {
                    val sign = if (forward) 1 else -1
                    if (still) {
                        EnterTransition.None togetherWith ExitTransition.None
                    } else {
                        slideInHorizontally(tween(220)) { sign * it } togetherWith slideOutHorizontally(tween(220)) { -sign * it }
                    }
                },
                label = "page",
                modifier = Modifier.fillMaxSize()
                    // A small nudge under the finger, not a page dragged to the edge: the turn is the animation.
                    .offset { IntOffset((drag / 4).roundToInt(), 0) }
                    .pointerInput(Unit) {
                        detectTapGestures(onLongPress = { pressNow(it) }) { tap ->
                            when {
                                tapMarksNow(tap) -> Unit
                                linkNow(tap) -> Unit
                                chromeNow -> onChrome(false)
                                tapsTurn && tap.x < size.width * 0.25f -> turnNow(-1)
                                tapsTurn && tap.x > size.width * 0.75f -> turnNow(1)
                                // Every band, for a reader who turns by swiping: the controls must be reachable.
                                else -> onChrome(true)
                            }
                        }
                    }
                    .pointerInput(pageTurn.turnsOnSwipe) {
                        // On even for a reader who turns by tapping: a finger that moved is not a
                        // tap, yet Compose counts its lift as one, and a swipe lifted on the left
                        // would turn back. Followed, and turned on, only when swipes turn pages.
                        val swipes = pageTurn.turnsOnSwipe
                        detectDragGestures(
                            onDragEnd = {
                                if (abs(drag) > 40.dp.toPx()) turnNow(if (drag < 0) 1 else -1)
                                drag = 0f
                            },
                            onDragCancel = { drag = 0f },
                        ) { change, amount ->
                            change.consume()
                            if (swipes) drag += amount.x
                        }
                    },
            ) { index ->
                Canvas(Modifier.fillMaxSize()) {
                    if (index >= map.count) return@Canvas
                    val top = map.top(index)
                    val bottom = map.bottom(index)
                    clipRect(0f, 0f, size.width, bottom - top) {
                        laid.blocks.forEachIndexed { i, block ->
                            if (block.top + block.height <= top || block.top >= bottom) return@forEachIndexed
                            val origin = Offset(0f, block.top - top)
                            val picture = block.piece?.picture
                            if (picture != null) {
                                bitmaps[picture.file]?.let {
                                    drawImage(
                                        it, dstOffset = IntOffset(((size.width - block.width) / 2).roundToInt(), origin.y.roundToInt()),
                                        dstSize = IntSize(block.width.roundToInt(), block.height.roundToInt()),
                                    )
                                }
                                return@forEachIndexed
                            }
                            val layout = block.layout ?: return@forEachIndexed
                            block.piece?.background?.let { drawRect(it, origin, Size(size.width, block.height)) }
                            if (block.markable && i > 0) {
                                val length = layout.layoutInput.text.length
                                val spans = marks.mapNotNull { h -> h.range(i - 1, length)?.let { it to palette.highlight } } +
                                    listOfNotNull(
                                        picked?.let { pk -> pk.text.inParagraph(pk.span, i - 1)?.let { it to palette.selection } },
                                        // In the passage's ink: both say "this is the one the app is pointing at".
                                        spoken?.takeIf { !it.isTitle && it.paragraph == i - 1 }?.let { it.range to palette.selection },
                                    )
                                drawSpans(layout, spans, inset, origin)
                            }
                            drawText(layout, topLeft = origin)
                        }
                    }
                }
            }
            picked?.let { pk -> overlay({ glyph(pk.text, it) }, { caretAt(pk.text, it) }, edge::reset) }
        }
        // A share of the chapter rather than "page 3 of 12": a page count depends on the type
        // size, cannot be known before the whole chapter is laid out, and means nothing on the shelf.
        Text(
            percent(shown),
            style = Type.caption2.copy(fontFeatureSettings = TABULAR), color = ink.copy(alpha = 0.45f),
            modifier = Modifier.align(Alignment.CenterHorizontally),
        )
    }
}
