package com.zeyanlin.novelreader.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.AnimationState
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animate
import androidx.compose.animation.core.animateDecay
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.rememberSplineBasedDecay
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.animateScrollBy
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateCentroid
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBarsIgnoringVisibility
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.isUnspecified
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.input.pointer.util.addPointerInputChange
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import com.zeyanlin.novelreader.Refusal
import com.zeyanlin.novelreader.data.Book
import com.zeyanlin.novelreader.data.Chapter
import com.zeyanlin.novelreader.describe
import com.zeyanlin.novelreader.network.WebFetcher
import com.zeyanlin.novelreader.services.ComicPages
import com.zeyanlin.novelreader.siterules.SiteRule
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.launch
import java.io.File
import kotlin.math.abs
import kotlin.math.min
import kotlin.math.roundToInt

/** A comic chapter ready to draw: its pages, each a file or an address to make one from. */
private class ComicChapter(val chapter: Chapter, val pages: List<ComicPages.Page>)

/** Where the reader is: a page, and how much of the chapter is read through the foot of the window. */
private data class ComicPlace(val chapter: Chapter, val page: Int, val pages: Int, val fraction: Double)

private data class ComicLanding(val chapter: Chapter, val page: Int)

/** A page not yet measured is drawn at iOS's guess: most are portrait, about 2:3. */
private const val ESTIMATED_RATIO = 1.5f

/** The seam between chapters: a medium with no other punctuation between one chapter's last panel and the next one's first. */
private val SEAM = 32.dp

/**
 * As far in as a page is worth magnifying, iOS's three. Never below 1: the column is already the
 * screen's width, so zooming out would only put black beside the page.
 * ponytail: pages are decoded at the screen's width (ArticlePictures), so a scan over twice that
 * magnifies softer than on iOS, which decodes a long edge of three widths; decode wider when it shows.
 */
private const val MAX_ZOOM = 3f

/** Where a double tap lands: "make this readable" in one go; the pinch is there for any other amount. */
private const val DOUBLE_TAP_ZOOM = 2f

/** Where a double tap in found the reader — the page, how far into it, and how far the zoom then scrolled them. */
private class ZoomedFrom(val key: Any, val offset: Int, val scrolled: Float)

/**
 * The column's magnification: [scale], and how far its left edge sits left of the screen's. Up and
 * down stay the column's own scroll, so each move answers how far to scroll it, in column pixels.
 */
internal data class Zoom(val scale: Float = 1f, val panX: Float = 0f) {
    /** Panned by [dx], never so far that black shows beside the page. */
    fun panned(dx: Float, width: Float) = copy(panX = (panX + dx).coerceIn(width * (1 - scale), 0f))

    fun lerp(to: Zoom, t: Float) = Zoom(scale + (to.scale - scale) * t, panX + (to.panX - panX) * t)

    /** Scaled by [factor] while the fingers' midpoint moves [from] → [to]: what was under them stays under them. */
    fun pinched(factor: Float, from: Offset, to: Offset, width: Float): Pair<Zoom, Float> {
        val next = (scale * factor).coerceIn(1f, MAX_ZOOM)
        val x = (from.x - panX) / scale
        return Zoom(next, to.x - x * next).panned(0f, width) to from.y / scale - to.y / next
    }

    /** In, with the point tapped brought to the middle of the screen; or out, keeping the middle of the screen still. */
    fun doubleTapped(at: Offset, width: Float, height: Float): Pair<Zoom, Float> =
        if (scale == 1f) {
            Zoom(DOUBLE_TAP_ZOOM, width / 2 - at.x * DOUBLE_TAP_ZOOM).panned(0f, width) to at.y - height / (2 * DOUBLE_TAP_ZOOM)
        } else {
            Zoom() to height / (2 * scale) - height / 2
        }
}

private fun keyOf(entry: Pair<ComicChapter, ComicPages.Page>): Any = "${entry.first.chapter.id}|${entry.second.index}"

/**
 * The iOS comic reader: full-width pages in one column across chapters, on black whatever the
 * text reader's colours, chrome summoned by a tap in the middle. Its own screen rather than a
 * mode of the text reader: none of type, marks or the voice means anything over pictures.
 * Pinch and double tap magnify the whole column as one layer, as iOS's scroll view zooms its one
 * content view: no page is laid out or decoded again for it.
 */
@Composable
fun ComicReaderScreen(bookId: String, startChapter: String?, startPage: Int?) {
    IosTheme(dark = true) { ComicReader(bookId, startChapter, startPage) }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ComicReader(bookId: String, startChapter: String?, startPage: Int?) {
    val app = app()
    val nav = LocalNavigator.current
    val settings = app.reader
    val layer = Layer.Book(bookId, SiteRule.Kind.COMIC)
    val look = Look(settings, layer)
    val scope = rememberCoroutineScope()
    val list = rememberLazyListState()
    val loaded = remember { mutableStateListOf<ComicChapter>() }
    val entries by remember { derivedStateOf { loaded.flatMap { c -> c.pages.map { c to it } } } }
    var book by remember { mutableStateOf<Book?>(null) }
    var chapters by remember { mutableStateOf<List<Chapter>>(emptyList()) }
    var landing by remember { mutableStateOf<ComicLanding?>(null) }
    var failure by remember { mutableStateOf<Throwable?>(null) }
    var nextFailure by remember { mutableStateOf<Throwable?>(null) }
    var loadingNext by remember { mutableStateOf(false) }
    var loadingPrevious by remember { mutableStateOf(false) }
    var pulledAtTop by remember { mutableStateOf(false) }
    var ready by remember { mutableStateOf(false) }
    var chrome by remember { mutableStateOf(false) }
    var showCatalog by remember { mutableStateOf(false) }
    var showSettings by remember { mutableStateOf(false) }
    var place by remember { mutableStateOf<ComicPlace?>(null) }
    // The text reader's three, for its reasons: a session's switch, a finger that holds the pages, a strip that lingers.
    var autoScrolling by remember { mutableStateOf(false) }
    var touching by remember { mutableStateOf(false) }
    var paceAskedAt by remember { mutableStateOf<Long?>(null) }
    var lastWrite by remember { mutableStateOf(0L to (null as ComicPlace?)) }
    // Shapes outlive the items that measured them, so a page scrolled back to is laid out at its size at once.
    val ratios = remember { HashMap<File, Float>() }
    var zoom by remember { mutableStateOf(Zoom()) }
    val zoomed = zoom.scale > 1f
    // Dropped the moment the reader moves themselves: someone who panned or turned has gone somewhere on purpose.
    var zoomedFrom by remember { mutableStateOf<ZoomedFrom?>(null) }
    var fling by remember { mutableStateOf<Job?>(null) }
    val decay = rememberSplineBasedDecay<Float>()

    // The page goes where a novel keeps its paragraph, as iOS stores it, so recent reading and backups need no second shape.
    fun write(at: ComicPlace?) {
        val b = book ?: return
        if (at == null || at == lastWrite.second) return
        lastWrite = System.currentTimeMillis() to at
        app.updateProgress(b.id, at.chapter.siteChapterId, at.page, 0, at.fraction)
    }

    fun reportIfChallenge(e: Throwable) {
        if (e is WebFetcher.FetchError.NeedsTheUser) {
            app.report(e, "App 正在讀取《${book?.shownName.orEmpty()}》的章節。")
        }
    }

    fun indexOf(chapter: Chapter) = chapters.indexOfFirst { it.id == chapter.id }

    suspend fun load(b: Book, chapter: Chapter) = ComicChapter(chapter, app.comicPages(b, chapter))

    /** Replaces the column with one chapter and puts [to] at the top of the window. */
    fun jump(to: ComicLanding) {
        val b = book ?: return
        write(place)
        landing = to
        zoomedFrom = null
        ready = false
        failure = null
        nextFailure = null
        loaded.clear()
        scope.launch {
            val chapter = try {
                load(b, to.chapter)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                failure = e
                reportIfChallenge(e)
                return@launch
            }
            loaded.add(chapter)
            // A page the chapter no longer has lands on its last.
            list.scrollToItem(to.page.coerceIn(0, chapter.pages.lastIndex))
            ready = true
        }
    }

    fun loadNext() {
        val b = book ?: return
        val last = loaded.lastOrNull() ?: return
        val next = chapters.getOrNull(indexOf(last.chapter) + 1) ?: return
        loadingNext = true
        scope.launch {
            try {
                val chapter = load(b, next)
                if (loaded.none { it.chapter.id == next.id }) loaded.add(chapter)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                nextFailure = e
                reportIfChallenge(e)
            } finally {
                loadingNext = false
            }
        }
    }

    fun loadPrevious() {
        val b = book ?: return
        val first = loaded.firstOrNull() ?: return
        val previous = chapters.getOrNull(indexOf(first.chapter) - 1) ?: return
        loadingPrevious = true
        scope.launch {
            // Inserted above, the list keeps the page on screen where it is. Failures are silent:
            // the chapter above is not what anyone is waiting for.
            try {
                load(b, previous)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                null
            }?.let { loaded.add(0, it) }
            loadingPrevious = false
            pulledAtTop = false
        }
    }

    /**
     * The page at the top of the window, and the share read by the page at its foot — by page,
     * not by height, as iOS counts: heights are guesses until the pictures arrive, and a share
     * computed from them would move under a reader standing still.
     */
    fun currentPlace(): ComicPlace? {
        val info = list.layoutInfo
        val visible = info.visibleItemsInfo
        val top = visible.firstOrNull() ?: return null
        val (chapter, page) = entries.getOrNull(top.index) ?: return null
        val bottom = entries.getOrNull((visible.lastOrNull { it.offset < info.viewportEndOffset } ?: top).index)
        val fraction = if (bottom == null || bottom.first !== chapter) 1.0 else (bottom.second.index + 1).toDouble() / chapter.pages.size
        return ComicPlace(chapter.chapter, page.index, chapter.pages.size, fraction)
    }

    LaunchedEffect(bookId) {
        val b = app.library.bookNow(bookId) ?: return@LaunchedEffect
        val all = app.library.chaptersNow(bookId)
        book = b
        chapters = all
        if (all.isEmpty()) {
            failure = Refusal("沒有取得章節，試試重新整理。")
            return@LaunchedEffect
        }
        val asked = startChapter?.let { id -> all.firstOrNull { it.siteChapterId == id } }
        val resumed = all.firstOrNull { it.siteChapterId == b.lastReadSiteChapterId }
        jump(
            when {
                asked != null -> ComicLanding(asked, startPage ?: 0)
                resumed != null -> ComicLanding(resumed, b.lastReadParagraph ?: 0)
                else -> ComicLanding(all.first(), 0)
            },
        )
    }

    // The next chapter once less than a window of this one is left — one, not the text reader's
    // two: a page is most of a screen, and two would fetch the next chapter on opening this one.
    LaunchedEffect(ready) {
        if (!ready) return@LaunchedEffect
        snapshotFlow {
            val info = list.layoutInfo
            Triple(list.firstVisibleItemIndex, info.visibleItemsInfo.lastOrNull()?.index ?: 0, info.totalItemsCount)
        }.collect { (first, last, total) ->
            // The footer aside, at most a page below the window.
            if (total - 2 - last < 2 && !loadingNext && nextFailure == null) loadNext()
            if (first < 2 && !loadingPrevious && (list.lastScrolledBackward || pulledAtTop)) loadPrevious()
        }
    }

    // Progress: written as the reader moves, at most every five seconds (ProgressWriteRule.swift).
    LaunchedEffect(ready) {
        if (!ready) return@LaunchedEffect
        snapshotFlow { currentPlace() }.filterNotNull().distinctUntilChanged().collect {
            place = it
            if (System.currentTimeMillis() - lastWrite.first >= 5_000) write(it)
        }
    }

    // Pages moving on their own, at a share of the window a second — the text reader's driver.
    LaunchedEffect(autoScrolling, ready) {
        if (!autoScrolling || !ready) return@LaunchedEffect
        list.autoScroll({ settings.comicScrollPace * list.layoutInfo.viewportSize.height / 60 }, { touching })
        autoScrolling = false
    }
    LaunchedEffect(autoScrolling) { paceAskedAt = if (autoScrolling) System.currentTimeMillis() else null }
    LaunchedEffect(chrome) { if (chrome && autoScrolling) paceAskedAt = System.currentTimeMillis() }
    LaunchedEffect(paceAskedAt) {
        if (paceAskedAt == null) return@LaunchedEffect
        delay(10_000)
        paceAskedAt = null
    }

    LifecycleEventEffect(Lifecycle.Event.ON_STOP) { write(place) }
    DisposableEffect(Unit) { onDispose { write(place) } }
    // Pages moving on their own hold the screen awake whatever keepScreenOn says, for the text reader's reason.
    ReaderWindow(dark = true, settings.keepScreenOn || autoScrolling)

    // A pull past the top of the column, which moves nothing but means "the chapter before".
    val pull = remember {
        object : NestedScrollConnection {
            override fun onPostScroll(consumed: Offset, available: Offset, source: NestedScrollSource): Offset {
                if (available.y > 0) pulledAtTop = true
                return Offset.Zero
            }
        }
    }

    // A window at a time less a sliver: a page is usually taller than the screen, so there is no
    // smaller unit to line up with, and the overlap keeps a panel from being split across two taps unseen.
    val sliver = with(LocalDensity.current) { 64.dp.toPx() }
    suspend fun turn(forward: Boolean) {
        zoomedFrom = null
        val info = list.layoutInfo
        val viewport = (info.viewportEndOffset - info.viewportStartOffset).toFloat()
        if (!forward && !list.canScrollBackward) pulledAtTop = true
        val step = viewport - min(viewport * 0.12f, sliver)
        list.animateScrollBy(if (forward) step else -step)
    }

    /**
     * In around the finger, so the panel pointed at is the one brought to the middle; out to exactly
     * where the double tap in found the reader, or, when they have moved since, keeping the middle of
     * the screen still. In and straight back out is "look closer, then carry on": it must not move them.
     */
    suspend fun doubleTap(at: Offset, size: IntSize) {
        fling?.cancel()
        val from = zoom
        val back = zoomedFrom
        val top = list.layoutInfo.visibleItemsInfo.firstOrNull()?.key to list.firstVisibleItemScrollOffset
        val (to, middle) = from.doubleTapped(at, size.width.toFloat(), size.height.toFloat())
        val scroll = if (to.scale == 1f && back != null) -back.scrolled else middle
        var scrolled = 0f
        animate(0f, 1f, animationSpec = tween(300, easing = FastOutSlowInEasing)) { t, _ ->
            zoom = from.lerp(to, t)
            scrolled += list.dispatchRawDelta(scroll * t - scrolled)
        }
        zoomedFrom = top.first?.takeIf { to.scale > 1f }?.let { ZoomedFrom(it, top.second, scrolled) }
        if (to.scale == 1f && back != null) {
            // Onto the very page and offset, whatever landed above it while magnified.
            val index = entries.indexOfFirst { keyOf(it) == back.key }
            if (index >= 0) list.scrollToItem(index, back.offset)
        }
    }

    val safe = WindowInsets.systemBarsIgnoringVisibility.union(WindowInsets.displayCutout)
    Box(Modifier.fillMaxSize().background(Color.Black)) {
        Box(
            Modifier.fillMaxSize().windowInsetsPadding(safe.only(WindowInsetsSides.Vertical))
                .nestedScroll(pull)
                .pointerInput(Unit) {
                    // Two fingers are a pinch whatever the column was doing with one, so they are
                    // taken before it sees them.
                    awaitEachGesture {
                        awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
                        fling?.cancel()
                        do {
                            val event = awaitPointerEvent(PointerEventPass.Initial)
                            if (event.changes.count { it.pressed } < 2) continue
                            event.changes.forEach { it.consume() }
                            val from = event.calculateCentroid(useCurrent = false)
                            if (from.isUnspecified) continue
                            val (to, scroll) = zoom.pinched(event.calculateZoom(), from, event.calculateCentroid(), size.width.toFloat())
                            list.dispatchRawDelta(scroll)
                            zoom = to
                            zoomedFrom = null
                        } while (event.changes.any { it.pressed })
                    }
                }
                .pointerInput(Unit) {
                    awaitPointerEventScope { while (true) touching = awaitPointerEvent(PointerEventPass.Initial).changes.any { it.pressed } }
                }
                .pointerInput(Unit) {
                    // The cost of double-tap zoom, as on iOS: a single tap now waits to see whether a
                    // second is coming. Worth it — scanned lettering at phone width is what zoom is for.
                    detectTapGestures(onDoubleTap = { at -> scope.launch { doubleTap(at, size) } }) { at ->
                        if (chrome) {
                            chrome = false
                            return@detectTapGestures
                        }
                        val x = at.x / size.width
                        val y = at.y / size.height
                        val zone = when {
                            y < 0.3f || (y <= 0.7f && x < 0.3f) -> -1
                            y > 0.7f || x > 0.7f -> 1
                            else -> 0
                        }
                        if (zone == 0 || !look.pageTurn.turnsOnTap) {
                            chrome = true
                        } else {
                            scope.launch { turn(forward = zone > 0) }
                        }
                    }
                }
                .pointerInput(zoomed) {
                    if (!zoomed) {
                        // A finger that moved sideways is not a tap: the column claims only vertical drags.
                        detectHorizontalDragGestures { change, _ -> change.consume() }
                        return@pointerInput
                    }
                    // Magnified, the page goes wherever the finger takes it, both ways at once as on
                    // iOS, so the column's own up-and-down scrolling is off and its fling redone here.
                    // ponytail: the fling is vertical only; decay panX the same way if a sideways flick is missed.
                    val tracker = VelocityTracker()
                    detectDragGestures(
                        onDragStart = {
                            tracker.resetTracking()
                            zoomedFrom = null
                        },
                        onDragEnd = {
                            val velocity = tracker.calculateVelocity().y / zoom.scale
                            fling = scope.launch {
                                list.scroll {
                                    var last = 0f
                                    AnimationState(0f, -velocity).animateDecay(decay) {
                                        val step = value - last
                                        last = value
                                        if (abs(scrollBy(step) - step) > 0.5f) cancelAnimation()
                                    }
                                }
                            }
                        },
                    ) { change, drag ->
                        change.consume()
                        tracker.addPointerInputChange(change)
                        zoom = zoom.panned(drag.x, size.width.toFloat())
                        list.dispatchRawDelta(-drag.y / zoom.scale)
                        // A raw delta leaves lastScrolledBackward alone, so heading back near the top,
                        // which asks for the chapter before, is said here instead.
                        if (drag.y > 0 && list.firstVisibleItemIndex < 2) pulledAtTop = true
                    }
                },
        ) {
            LazyColumn(
                Modifier.fillMaxSize().layout { measurable, constraints ->
                    // Laid out as tall as the part of the book the glass shows, then scaled up to fill
                    // it: the column's window stays the reader's, so page turns, the place and the next
                    // chapter's trigger all measure the magnified view without knowing zoom exists.
                    val height = (constraints.maxHeight / zoom.scale).roundToInt()
                    val placeable = measurable.measure(constraints.copy(minHeight = height, maxHeight = height))
                    layout(constraints.maxWidth, constraints.maxHeight) {
                        placeable.placeWithLayer(0, 0) {
                            transformOrigin = TransformOrigin(0f, 0f)
                            scaleX = zoom.scale
                            scaleY = zoom.scale
                            // Clamped again here: a rotation narrows the screen under a pan made for the wider one.
                            translationX = zoom.panned(0f, constraints.maxWidth.toFloat()).panX
                        }
                    }
                },
                state = list,
                userScrollEnabled = !zoomed,
            ) {
                items(entries, key = ::keyOf) { (c, page) ->
                    val seam = page.index == c.pages.lastIndex && c !== loaded.lastOrNull()
                    ComicPageView(page, c.chapter.url, ratios, Modifier.padding(bottom = if (seam) SEAM else 0.dp))
                }
                if (loaded.isNotEmpty()) {
                    item(key = "footer") {
                        Footer(
                            loading = loadingNext,
                            failure = nextFailure,
                            atEnd = loaded.last().chapter.id == chapters.lastOrNull()?.id,
                            ink = Color.White,
                            retry = "重試",
                        ) {
                            nextFailure = null
                            loadNext()
                        }
                    }
                }
            }
        }

        val failed = failure
        when {
            failed != null -> Failure(describe(failed), Modifier.align(Alignment.Center), onBack = nav::pop) { landing?.let { jump(it) } }
            loaded.isEmpty() -> Spinner(Modifier.align(Alignment.Center), size = 28.dp)
        }

        AnimatedVisibility(
            chrome && place != null,
            Modifier.align(Alignment.TopCenter),
            enter = slideInVertically(tween(200)) { -it } + fadeIn(tween(200)),
            exit = slideOutVertically(tween(200)) { -it } + fadeOut(tween(200)),
        ) {
            place?.let { TitlePill(it.chapter.title, "${it.page + 1} / ${it.pages} 頁", Modifier.windowInsetsPadding(safe.only(WindowInsetsSides.Top))) }
        }
        AnimatedVisibility(
            chrome,
            Modifier.align(Alignment.BottomCenter),
            enter = slideInVertically(tween(200)) { it } + fadeIn(tween(200)),
            exit = slideOutVertically(tween(200)) { it } + fadeOut(tween(200)),
        ) {
            val index = (place?.chapter ?: landing?.chapter)?.let { indexOf(it) } ?: -1
            ComicToolbar(
                layout = look.toolbar,
                onBack = nav::pop,
                onCatalog = { showCatalog = true },
                onPrevious = chapters.getOrNull(index - 1)?.let { { jump(ComicLanding(it, 0)) } },
                onNext = chapters.getOrNull(index + 1)?.takeIf { index >= 0 }?.let { { jump(ComicLanding(it, 0)) } },
                autoScrolling = autoScrolling,
                onAutoScroll = { autoScrolling = !autoScrolling },
                onSettings = { showSettings = true },
            )
        }
        AnimatedVisibility(
            chrome && autoScrolling && paceAskedAt != null,
            Modifier.align(Alignment.BottomCenter),
            enter = slideInVertically(tween(200)) { it / 2 } + fadeIn(tween(200)),
            exit = slideOutVertically(tween(200)) { it / 2 } + fadeOut(tween(200)),
        ) {
            AutoScrollStrip(
                (settings.comicScrollPace * 10).roundToInt(), ReaderSettings.COMIC_PACE_TENTHS, { settings.comicScrollPace = it / 10f },
                onTouched = { paceAskedAt = System.currentTimeMillis() },
            )
        }
    }

    if (showCatalog) {
        CatalogSheet(
            book, chapters, place?.chapter ?: landing?.chapter, isDescending(app.prefs, bookId, false), "目錄",
            outline = emptyList(), onOutline = {}, onDismiss = { showCatalog = false },
        ) {
            showCatalog = false
            chrome = false
            jump(ComicLanding(it, 0))
        }
    }
    // The text reader's sheet, which reduces itself to what a comic answers, at half height for
    // that sheet's reason: what it changes is the screen behind it.
    if (showSettings) ReaderSettingsSheet(settings, layer) { showSettings = false }
}

/**
 * One page, full width with no gap to the next, as iOS draws them: at its measured shape once
 * known, else at the estimate. A page slow to come offers a retry after three seconds, and one
 * that failed says which page and why — a chapter of fifty pages fails one page at a time.
 */
@Composable
private fun ComicPageView(page: ComicPages.Page, referer: String, ratios: HashMap<File, Float>, modifier: Modifier) {
    val app = app()
    val p = LocalPalette.current
    BoxWithConstraints(modifier.fillMaxWidth()) {
        val px = constraints.maxWidth
        var attempt by remember(page) { mutableIntStateOf(0) }
        var slow by remember(page) { mutableStateOf(false) }
        val shown by produceState(ArticlePictures.cached(page.file, px)?.let { Result.success(it) }, page, px, attempt) {
            if (value?.isSuccess == true) return@produceState
            value = null
            slow = false
            val timer = launch {
                delay(3_000)
                slow = true
            }
            value = try {
                app.comics.bring(page, referer)
                Result.success(ArticlePictures.load(page.file, px) ?: throw ComicPages.PageError("第 ${page.index + 1} 頁回傳的不是圖片。"))
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Result.failure<ImageBitmap>(e)
            }
            timer.cancel()
        }
        val bitmap = shown?.getOrNull()
        val ratio = bitmap?.let { it.height.toFloat() / it.width }?.also { ratios[page.file] = it } ?: ratios[page.file] ?: ESTIMATED_RATIO
        Box(Modifier.fillMaxWidth().height(maxWidth * ratio), contentAlignment = Alignment.Center) {
            if (bitmap != null) {
                Image(bitmap, "第 ${page.index + 1} 頁", Modifier.fillMaxSize(), contentScale = ContentScale.FillBounds)
                return@Box
            }
            val error = shown?.exceptionOrNull()
            Column(Modifier.padding(horizontal = 32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                if (error == null) {
                    Spinner()
                    Text("第 ${page.index + 1} 頁", style = Type.footnote, color = p.secondary)
                } else {
                    Text("第 ${page.index + 1} 頁載入失敗", style = Type.footnote, color = p.label)
                    Text(describe(error), style = Type.footnote, color = p.secondary, textAlign = TextAlign.Center)
                }
                if (error != null || slow) BorderedButton("重試這一頁") { attempt++ }
            }
        }
    }
}

/** The text reader's toolbar less everything about text: no bookmark, no voice, a hand for how pages turn. */
@Composable
private fun ComicToolbar(
    layout: ReaderToolbarLayout,
    onBack: () -> Unit,
    onCatalog: () -> Unit,
    onPrevious: (() -> Unit)?,
    onNext: (() -> Unit)?,
    autoScrolling: Boolean,
    onAutoScroll: () -> Unit,
    onSettings: () -> Unit,
) {
    val p = LocalPalette.current
    val (bar, folded) = layout.resolve(SiteRule.Kind.COMIC)
    // Null for what a comic has none of, which `appears` already keeps off: a gap beats a wrong glyph.
    fun control(button: ReaderButton): BarControl? = when (button) {
        ReaderButton.BOOKMARK, ReaderButton.ORIGINAL, ReaderButton.SPEECH -> null
        ReaderButton.BACK -> BarControl("返回", onBack) { Chevron(direction = Direction.LEFT, color = p.label, width = 9.dp, height = 16.dp, stroke = 2.2.dp) }
        ReaderButton.CATALOG -> BarControl("目錄", onCatalog) { ToolbarIcon(Symbols.ListBullet, true) }
        ReaderButton.PREVIOUS -> BarControl("上一章", onPrevious) { ToolbarIcon(Symbols.ArrowUpToLine, onPrevious != null) }
        ReaderButton.NEXT -> BarControl("下一章", onNext) { ToolbarIcon(Symbols.ArrowDownToLine, onNext != null) }
        ReaderButton.AUTO_SCROLL -> BarControl(if (autoScrolling) "停止自動捲動" else "開始自動捲動", onAutoScroll) {
            ToolbarIcon(if (autoScrolling) Symbols.PauseCircle else Symbols.PlayCircle, true)
        }
        ReaderButton.SETTINGS -> BarControl("翻頁方式", onSettings) { ToolbarIcon(Symbols.HandTap, true) }
    }
    ReaderBar(bar.mapNotNull(::control), folded.mapNotNull(::control))
}
