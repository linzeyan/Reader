package com.zeyanlin.novelreader.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.view.WindowManager
import androidx.activity.compose.BackHandler
import androidx.activity.compose.LocalActivity
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.animateScrollBy
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsIgnoringVisibility
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.LineHeightStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import com.zeyanlin.novelreader.data.Book
import com.zeyanlin.novelreader.data.Chapter
import com.zeyanlin.novelreader.data.ReadingBookmark
import com.zeyanlin.novelreader.data.TextHighlight
import com.zeyanlin.novelreader.data.chapterShare
import com.zeyanlin.novelreader.describe
import com.zeyanlin.novelreader.network.WebFetcher
import com.zeyanlin.novelreader.services.ArticleBlock
import com.zeyanlin.novelreader.services.ChapterText
import com.zeyanlin.novelreader.services.ChineseText
import com.zeyanlin.novelreader.services.FeedService
import com.zeyanlin.novelreader.services.SpeechBook
import com.zeyanlin.novelreader.services.SpeechReader
import com.zeyanlin.novelreader.services.SpeechScript
import com.zeyanlin.novelreader.services.SpeechSession
import com.zeyanlin.novelreader.services.TextAnchor
import com.zeyanlin.novelreader.services.range
import com.zeyanlin.novelreader.siterules.SiteRule
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.roundToInt

/** A chapter ready to draw; [article] holds a subscribed article's structure, whose plain text [paragraphs] still is, block for block. */
private class Loaded(val chapter: Chapter, val paragraphs: List<String>, val article: Article? = null)

private sealed interface Entry {
    val loaded: Loaded
    val key: String
}

private class TitleEntry(override val loaded: Loaded) : Entry {
    override val key = "t|${loaded.chapter.id}"
}

private class ParagraphEntry(override val loaded: Loaded, val index: Int) : Entry {
    override val key = "p|${loaded.chapter.id}|$index"
}

/** Where the reader is: the anchor iOS stores, plus the share of the chapter read. */
private data class Position(val chapter: Chapter, val paragraph: Int, val offset: Int, val fraction: Double)

/** What a jump lands on: a chapter, and a paragraph in it or its top — or, paged, its last page. */
private data class Landing(val chapter: Chapter, val paragraph: Int?, val offset: Int, val atEnd: Boolean = false)

/** The character under a finger: which chapter, which paragraph, where in it. */
private class Hit(val loaded: Loaded, val paragraph: Int, val offset: Int)

/** Chapters are loaded this many lazy items ahead of either end — about two screens. */
private const val AHEAD = 15

/**
 * The iOS scroll-mode reader: one continuous column across chapters, the next one loaded
 * before the reader reaches it, chrome summoned by a tap in the middle of the page.
 */
@Composable
fun ReaderScreen(bookId: String, startChapter: String?, startParagraph: Int? = null, startOffset: Int = 0) {
    val app = app()
    val settings = app.reader
    // One route for both readers: everything that opens a book knows the book, not which reader it takes.
    val kind by produceState<SiteRule.Kind?>(null, bookId) { value = app.library.bookNow(bookId)?.kind }
    when (val k = kind) {
        null -> Box(Modifier.fillMaxSize())
        // A comic's page is the same paragraph number a novel keeps: the page it is on.
        SiteRule.Kind.COMIC -> ComicReaderScreen(bookId, startChapter, startParagraph)
        else -> {
            val layer = Layer.Book(bookId, k)
            val page = settings.palette(Look(settings, layer).theme, isSystemInDarkTheme())
            // The chrome follows the page, not the system, as iOS forces the colour scheme.
            IosTheme(page.isDark) { Reader(bookId, startChapter, startParagraph, startOffset, settings, layer, page) }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun Reader(bookId: String, startChapter: String?, startParagraph: Int?, startOffset: Int, settings: ReaderSettings, layer: Layer.Book, page: ReaderPalette) {
    val app = app()
    // What this book is read with. [settings] keeps what no book answers for itself: script, screen, voice.
    val look = Look(settings, layer)
    val nav = LocalNavigator.current
    val p = LocalPalette.current
    val scope = rememberCoroutineScope()
    val list = rememberLazyListState()
    val layouts = remember { HashMap<String, TextLayoutResult>() }
    val loaded = remember { mutableStateListOf<Loaded>() }
    val entries by remember { derivedStateOf { loaded.flatMap { l -> listOf(TitleEntry(l)) + l.paragraphs.indices.map { ParagraphEntry(l, it) } } } }
    var book by remember { mutableStateOf<Book?>(null) }
    var chapters by remember { mutableStateOf<List<Chapter>>(emptyList()) }
    var landing by remember { mutableStateOf<Landing?>(null) }
    var failure by remember { mutableStateOf<Throwable?>(null) }
    var nextFailure by remember { mutableStateOf<Throwable?>(null) }
    var loadingNext by remember { mutableStateOf(false) }
    var loadingPrevious by remember { mutableStateOf(false) }
    var pulledAtTop by remember { mutableStateOf(false) }
    var ready by remember { mutableStateOf(false) }
    var chrome by remember { mutableStateOf(false) }
    var showCatalog by remember { mutableStateOf(false) }
    var showSettings by remember { mutableStateOf(false) }
    var position by remember { mutableStateOf<Position?>(null) }
    var lastWrite by remember { mutableStateOf(0L to (null as Position?)) }
    val bookmarkIds by remember(bookId) { app.library.bookmarkIds(bookId) }.collectAsState(emptyList())
    val highlights by remember(bookId) { app.library.highlights(bookId) }.collectAsState(emptyList())
    var picked by remember { mutableStateOf<Picked?>(null) }
    val context = LocalContext.current
    val paged = look.mode == ReaderSettings.Mode.PAGINATED
    val speech = app.speech
    // In this book, reading or paused: a paused voice is still this book's to resume.
    val listening = speech.book?.id == bookId && speech.state != SpeechReader.State.IDLE
    val voiceReading = listening && speech.isSpeaking
    // What the page paints and follows: only a voice that is reading this book.
    val speaking = if (voiceReading) speech.current else null
    var paceAskedAt by remember { mutableStateOf<Long?>(null) }
    // For this session, not a setting: a book that reopened already moving would start before it was looked at.
    var autoScrolling by remember { mutableStateOf(false) }
    var touching by remember { mutableStateOf(false) }
    // Chapters the voice fetched past the column, for the share of a chapter it writes down.
    val voiceText = remember {
        object : LinkedHashMap<String, List<String>>() {
            override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, List<String>>?) = size > 3
        }
    }

    fun write(at: Position?) {
        val b = book ?: return
        if (at == null || at == lastWrite.second) return
        lastWrite = System.currentTimeMillis() to at
        app.updateProgress(b.id, at.chapter.siteChapterId, at.paragraph, at.offset, at.fraction)
    }

    fun reportIfChallenge(e: Throwable) {
        if (e is WebFetcher.FetchError.NeedsTheUser) {
            app.report(e, "App 正在讀取《${book?.shownName.orEmpty()}》的章節。")
        }
    }

    fun indexOf(chapter: Chapter) = chapters.indexOfFirst { it.id == chapter.id }

    val isFeed = book?.kind == SiteRule.Kind.FEED

    /**
     * The one place that decides what a chapter is — the iOS `gotContent`: an article's stored blocks
     * where there are any, prose everywhere else — so structure reaches both renderers or neither.
     */
    suspend fun load(b: Book, chapter: Chapter): Loaded {
        if (b.kind == SiteRule.Kind.FEED) {
            val blocks = app.library.articleBlocks(chapter.id)?.let { withContext(Dispatchers.Default) { ArticleBlock.decode(it) } }
            if (!blocks.isNullOrEmpty()) {
                val article = Article(blocks, Article.subtitle(chapter.publishedAt), chapter.url.takeIf(FeedService::isWeb))
                return Loaded(chapter, blocks.map { it.plainText }, article)
            }
        }
        return Loaded(chapter, app.paragraphs(b, chapter))
    }

    /** Replaces the column with one chapter and puts [to] at the top of the window. */
    fun jump(to: Landing) {
        val b = book ?: return
        picked = null
        write(position)
        // Paged, a chapter already read ahead opens at once: there is no column to rebuild.
        // Nor one to read the place from: `ready` stays false while paged, or the switch back
        // to scrolling hands the stale column's top line to the progress effect as the place.
        if (paged && loaded.any { it.chapter.id == to.chapter.id }) {
            landing = to
            ready = false
            failure = null
            return
        }
        landing = to
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
            // A paragraph the chapter no longer has lands on its last one, at its start.
            val paragraph = to.paragraph?.let { minOf(it, chapter.paragraphs.lastIndex) }
            if (paged) {
                // The page lands itself; there is no list to move, and none to call ready.
                return@launch
            } else if (paragraph == null || (paragraph == 0 && to.offset == 0)) {
                list.scrollToItem(0)
            } else {
                list.scrollToItem(1 + paragraph)
                val key = ParagraphEntry(loaded[0], paragraph).key
                if (paragraph == to.paragraph && to.offset > 0) {
                    snapshotFlow { list.layoutInfo.visibleItemsInfo.firstOrNull()?.key }.first { it == key }
                    layouts[key]?.let { layout ->
                        val line = layout.getLineForOffset(minOf(to.offset, layout.layoutInput.text.length))
                        list.scrollBy(layout.getLineTop(line))
                    }
                }
            }
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
                // The voice may have brought it in meanwhile, and a key twice in the column is a crash.
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
            // Inserted above: the list keeps the reader's line where it is. Failures are silent;
            // the chapter above is not what anyone is waiting for.
            runCatching { load(b, previous) }.getOrNull()?.let { loaded.add(0, it) }
            loadingPrevious = false
            pulledAtTop = false
        }
    }

    fun currentPosition(): Position? {
        val info = list.layoutInfo
        val visible = info.visibleItemsInfo
        val top = visible.firstOrNull() ?: return null
        val entry = entries.getOrNull(top.index) ?: return null
        val chapter = entry.loaded
        val (paragraph, offset) = when (entry) {
            is TitleEntry -> 0 to 0
            is ParagraphEntry -> entry.index to (
                layouts[entry.key]?.let { it.getLineStart(it.getLineForVerticalPosition(-top.offset.toFloat())) } ?: 0
                )
        }
        // The line straddling the bottom of the window, or the chapter's end above it.
        val bottom = visible.lastOrNull { it.offset < info.viewportEndOffset } ?: top
        val bottomEntry = entries.getOrNull(bottom.index)
        val fraction = when {
            bottomEntry == null || bottomEntry.loaded !== chapter -> 1.0
            bottomEntry is TitleEntry -> 0.0
            bottomEntry is ParagraphEntry -> {
                val ended = bottomEntry.index == chapter.paragraphs.lastIndex &&
                    bottom.offset + bottom.size <= info.viewportEndOffset
                if (ended) {
                    1.0
                } else {
                    val lineAt = layouts[bottomEntry.key]?.let {
                        it.getLineStart(it.getLineForVerticalPosition((info.viewportEndOffset - bottom.offset).toFloat()))
                    } ?: 0
                    chapterShare(chapter.chapter.title, chapter.paragraphs, bottomEntry.index, lineAt)
                }
            }
            else -> 1.0
        }
        return Position(chapter.chapter, paragraph, offset, fraction)
    }

    LaunchedEffect(bookId) {
        val b = app.library.bookNow(bookId) ?: return@LaunchedEffect
        val all = app.library.chaptersNow(bookId)
        book = b
        chapters = all
        if (all.isEmpty()) {
            failure = com.zeyanlin.novelreader.Refusal("沒有取得章節，試試重新整理。")
            return@LaunchedEffect
        }
        val asked = startChapter?.let { id -> all.firstOrNull { it.siteChapterId == id } }
        val resumed = all.firstOrNull { it.siteChapterId == b.lastReadSiteChapterId }
        jump(
            when {
                asked != null -> Landing(asked, startParagraph, startOffset)
                resumed != null -> Landing(resumed, b.lastReadParagraph ?: 0, b.lastReadCharacterOffset ?: 0)
                else -> Landing(all.first(), null, 0)
            },
        )
    }

    // Reading ahead, and back once the reader heads that way.
    LaunchedEffect(ready, paged) {
        if (!ready || paged) return@LaunchedEffect
        snapshotFlow {
            val info = list.layoutInfo
            Triple(list.firstVisibleItemIndex, info.visibleItemsInfo.lastOrNull()?.index ?: 0, info.totalItemsCount)
        }.collect { (first, last, total) ->
            if (total - 1 - last < AHEAD && !loadingNext && nextFailure == null) loadNext()
            if (first < AHEAD && !loadingPrevious && (list.lastScrolledBackward || pulledAtTop)) loadPrevious()
        }
    }

    // Progress: written as the reader moves, at most every five seconds (ProgressWriteRule.swift).
    LaunchedEffect(ready, paged) {
        if (!ready || paged) return@LaunchedEffect
        snapshotFlow { currentPosition() }.filterNotNull().distinctUntilChanged().collect {
            position = it
            if (System.currentTimeMillis() - lastWrite.first >= 5_000) write(it)
        }
    }
    // One button saves and unsaves: the filled mark is the only thing on screen that says
    // this place is saved, so the tap that filled it is the tap that undoes it.
    fun toggleBookmark(at: Position) {
        val paragraphs = loaded.firstOrNull { it.chapter.id == at.chapter.id }?.paragraphs.orEmpty()
        val mark = ReadingBookmark.make(
            bookId, at.chapter.siteChapterId, at.paragraph, at.offset,
            ReadingBookmark.excerpt(paragraphs, at.paragraph), System.currentTimeMillis(),
        )
        scope.launch { if (mark.id in bookmarkIds) app.library.removeReadingBookmark(mark.id) else app.library.addReadingBookmark(mark) }
    }

    fun moved(at: Position) {
        position = at
        if (System.currentTimeMillis() - lastWrite.first >= 5_000) write(at)
    }

    fun paragraphsOf(chapter: Chapter) = loaded.firstOrNull { it.chapter.id == chapter.id }?.paragraphs ?: voiceText[chapter.id]

    fun startListening() {
        val b = book ?: return
        val at = position ?: landing?.let { Position(it.chapter, it.paragraph ?: 0, it.offset, 0.0) } ?: return
        val start = indexOf(at.chapter).takeIf { it >= 0 } ?: return
        val script = settings.chineseScript
        speech.start(
            SpeechSession(
                SpeechBook(bookId, b.shownName), start, TextAnchor(at.paragraph, at.offset), script, settings.speechRate,
                supply = supply@{ i ->
                    val chapter = chapters.getOrNull(i) ?: return@supply null
                    val known = loaded.firstOrNull { it.chapter.id == chapter.id }
                    val got = known ?: try {
                        load(b, chapter)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        return@supply null
                    }
                    val text = got.paragraphs
                    voiceText[chapter.id] = text
                    // The voice has read to the foot of the column: the ask the page makes nearing it,
                    // and what lets listening outrun the eye.
                    if (look.mode == ReaderSettings.Mode.SCROLL && known == null && loaded.none { it.chapter.id == chapter.id } &&
                        loaded.lastOrNull()?.let { indexOf(it.chapter) } == i - 1
                    ) {
                        loaded.add(got)
                    }
                    SpeechScript.sentences(i, chapter.siteChapterId, chapter.title, text, script)
                },
                // The one place a locked phone keeps, since nothing is drawn to report one.
                note = { s ->
                    chapters.getOrNull(s.chapterIndex)?.let { c ->
                        val share = paragraphsOf(c)?.let { chapterShare(c.title, it, s.paragraph, s.range.start) } ?: 0.0
                        moved(Position(c, s.paragraph, s.range.start, share))
                    }
                },
            ),
        )
    }

    /** Three states behind two glyphs: resuming carries on from the sentence the reader stopped in. */
    fun toggleSpeech() = when {
        speech.state == SpeechReader.State.SPEAKING -> speech.pause()
        speech.state == SpeechReader.State.PAUSED && listening -> speech.resume()
        else -> startListening()
    }

    // An article is read the moment the reader is in it, by whichever way they arrived — a jump,
    // a scrolled frame, a settled page. Only the article's own flag: the position is not read state.
    LaunchedEffect(position?.chapter?.id, isFeed) {
        val at = position?.chapter ?: return@LaunchedEffect
        if (isFeed) app.library.setArticlesRead(listOf(at.id), System.currentTimeMillis())
    }

    var fetchingPage by remember { mutableStateOf(false) }

    /**
     * An article read off its own page and put back on screen — for one the feed gave no body, and for
     * one that is longer where it lives. Words first, pictures after with the words already showing.
     */
    fun readFromPage(article: Chapter) {
        // A second tap would fetch the same page twice; nothing on screen says the first is running.
        if (fetchingPage) return
        fetchingPage = true
        scope.launch {
            // Put back the way it failed, or in place: the reader standing in it keeps their anchor.
            fun redraw() {
                val at = position
                when {
                    failure != null -> landing?.let { jump(it) }
                    nextFailure != null && loaded.lastOrNull()?.let { chapters.getOrNull(indexOf(it.chapter) + 1)?.id } == article.id -> {
                        nextFailure = null
                        loadNext()
                    }
                    at != null && at.chapter.id == article.id -> {
                        loaded.removeAll { it.chapter.id == article.id }
                        jump(Landing(article, at.paragraph, at.offset))
                    }
                }
            }
            try {
                val text = app.feeds.fetchFullText(article)
                fetchingPage = false
                redraw()
                // Never reported: the article reads either way.
                if (runCatching { app.feeds.fetchImages(text, article) }.getOrDefault(false) && position?.chapter?.id == article.id) redraw()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                fetchingPage = false
                if (failure != null) failure = e else app.banner.value = describe(e)
            } finally {
                fetchingPage = false
            }
        }
    }

    // Paged: the chapters either side of the one shown, so a turn off its edge waits for nothing.
    val shown = landing?.let { l -> loaded.firstOrNull { it.chapter.id == l.chapter.id } }
    LaunchedEffect(paged, shown?.chapter?.id) {
        val b = book
        val at = shown
        if (!paged || b == null || at == null) return@LaunchedEffect
        val i = indexOf(at.chapter)
        loaded.removeAll { abs(indexOf(it.chapter) - i) > 1 }
        for (n in listOf(i + 1, i - 1)) {
            val chapter = chapters.getOrNull(n) ?: continue
            if (loaded.any { it.chapter.id == chapter.id }) continue
            // Silent: turning to it goes through jump, which says why it failed.
            val text = try {
                load(b, chapter)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                continue
            }
            loaded.add(text)
        }
    }

    // Switching modes keeps the place: the same anchor, read the other way.
    LaunchedEffect(paged) {
        position?.let { jump(Landing(it.chapter, it.paragraph, it.offset)) }
    }

    // The page under the voice, moved only once it is two thirds down and then back to a third:
    // a scroll per sentence would move the text under the eye every few seconds.
    LaunchedEffect(speaking, ready) {
        val s = speaking ?: return@LaunchedEffect
        val chapter = chapters.getOrNull(s.chapterIndex) ?: return@LaunchedEffect
        if (paged) {
            // Inside a chapter the page turns itself; a voice in the next one opens it.
            if (shown?.chapter?.id != chapter.id) jump(Landing(chapter, s.paragraph, s.range.start))
            return@LaunchedEffect
        }
        if (!ready) return@LaunchedEffect
        val l = loaded.firstOrNull { it.chapter.id == chapter.id }
        if (l == null) {
            jump(Landing(chapter, s.paragraph, s.range.start))
            return@LaunchedEffect
        }
        val key = if (s.isTitle) TitleEntry(l).key else ParagraphEntry(l, s.paragraph).key
        val index = entries.indexOfFirst { it.key == key }
        if (index < 0) return@LaunchedEffect
        val info = list.layoutInfo
        val viewport = (info.viewportEndOffset - info.viewportStartOffset).toFloat()
        val lineTop = layouts[key]?.let { it.getLineTop(it.getLineForOffset(minOf(s.range.start, it.layoutInput.text.length))) } ?: 0f
        val item = info.visibleItemsInfo.firstOrNull { it.key == key }
        if (item == null) {
            list.scrollToItem(index)
            list.scrollBy(lineTop - viewport / 3)
        } else {
            val y = item.offset + lineTop
            if (y >= 0 && y <= viewport * 2 / 3) return@LaunchedEffect
            list.animateScrollBy(y - viewport / 3)
        }
    }

    // The speed strip, for as long as somebody is setting it: offered as the voice or the page starts
    // moving or the chrome comes up over it, and gone ten seconds after it was last touched.
    // Keyed on both, as one hands over to the other: apart, the page's stop would take away the strip the voice just offered.
    LaunchedEffect(voiceReading, autoScrolling) { paceAskedAt = if (voiceReading || autoScrolling) System.currentTimeMillis() else null }
    // One page, one thing moving it. The reader has just asked for the moving page, so the voice gives
    // way; a voice that starts or resumes, here or from the lock screen, stops the page.
    LaunchedEffect(autoScrolling) { if (autoScrolling && voiceReading) speech.pause() }
    LaunchedEffect(voiceReading) { if (voiceReading) autoScrolling = false }
    LaunchedEffect(chrome) { if (chrome && (voiceReading || autoScrolling)) paceAskedAt = System.currentTimeMillis() }
    LaunchedEffect(paceAskedAt) {
        if (paceAskedAt == null) return@LaunchedEffect
        delay(10_000)
        paceAskedAt = null
    }

    LifecycleEventEffect(Lifecycle.Event.ON_STOP) { write(position) }
    DisposableEffect(Unit) {
        onDispose {
            write(position)
            // Listening ends with the book it is in: the voice outlives the screen for a locked
            // phone, not for a reader who walked back to the shelf.
            if (speech.book?.id == bookId) speech.stop()
        }
    }

    // A page moving on its own is the only reading with no touches in it, so the only one the system
    // would lock mid-way, whatever the reader answered about keeping the screen on. Not listening: a
    // locked screen is where that is meant to end up, and holding it awake would burn a pocketed battery.
    ReaderWindow(p.dark, settings.keepScreenOn || autoScrolling)

    // A pull past the top of the column, which moves nothing but means "the chapter before".
    val pull = remember {
        object : NestedScrollConnection {
            override fun onPostScroll(consumed: Offset, available: Offset, source: NestedScrollSource): Offset {
                if (available.y > 0) pulledAtTop = true
                return Offset.Zero
            }
        }
    }

    suspend fun turn(forward: Boolean) {
        val info = list.layoutInfo
        val viewport = (info.viewportEndOffset - info.viewportStartOffset).toFloat()
        val visible = info.visibleItemsInfo
        if (visible.isEmpty()) return
        val delta = if (forward) {
            // The last paragraph whose top is on screen moves to the top of the window.
            val target = visible.lastOrNull { it.offset > 0 && it.offset < viewport }
            if (target == null || target.offset < viewport / 4) viewport else target.offset.toFloat()
        } else {
            // The first visible paragraph moves to the bottom.
            val first = visible.first()
            val toBottom = (first.offset + first.size - viewport)
            if (toBottom > -viewport / 4) -viewport else max(toBottom, -viewport)
        }
        list.animateScrollBy(delta)
    }

    // Untrimmed: TextKit leaves the line spacing under a paragraph's last line too, and
    // Compose's default trim would close every gap between paragraphs.
    val leading = LineHeightStyle(LineHeightStyle.Alignment.Center, LineHeightStyle.Trim.None)
    val bodyStyle = TextStyle(
        fontFamily = settings.family(look.fontName), fontSize = look.fontSize.sp,
        // iOS adds the spacing to the face's own line height, about 1.17 em for Songti.
        lineHeight = (look.fontSize * 1.17f + look.lineSpacing).sp, lineHeightStyle = leading, color = page.ink,
    )
    val titleSize = look.fontSize + 4
    val titleStyle = TextStyle(
        fontSize = titleSize.sp, fontWeight = FontWeight.SemiBold,
        lineHeight = (titleSize * 1.2f + look.lineSpacing).sp, lineHeightStyle = leading, color = page.ink,
    )
    // TextKit puts the line spacing under every line; only what the paragraph spacing adds
    // beyond it is extra.
    val paragraphGap = max(0, look.paragraphSpacing - look.lineSpacing).dp
    val safe = WindowInsets.systemBarsIgnoringVisibility.union(WindowInsets.displayCutout)
    // Converted as drawn, never stored: offsets into the text the site served stay valid
    // because a conversion that would change a paragraph's length is not made.
    val script = settings.chineseScript

    // Marks. Everything about which characters is ChapterText's, shared with the page; what is
    // here is only where the column has put them.
    val density = LocalDensity.current
    val pad = with(density) { 20.dp.toPx() }
    val inset = with(density) { look.lineSpacing.sp.toPx() } / 2

    // The page moving on its own, through the column's own scrolling, so where the reader is and
    // when the next chapter is asked for follow as they do from a finger. Off once it runs aground.
    val lineHeight by rememberUpdatedState(with(density) { bodyStyle.lineHeight.toPx() })
    LaunchedEffect(autoScrolling, ready, paged) {
        if (!autoScrolling || !ready || paged) return@LaunchedEffect
        list.autoScroll({ settings.autoScrollPace * lineHeight / 60 }, { touching })
        autoScrolling = false
    }

    fun shownText(l: Loaded) = ChapterText(l.paragraphs.map { ChineseText.rendered(it, script) })

    // An article's blocks as drawn, per chapter, rebuilt when the type or the page changes.
    val uri = LocalUriHandler.current
    // Keyed by the article itself, not its chapter: 抓取全文 replaces one chapter's article, and
    // pieces left over from the summary would draw over the first paragraphs of the full text.
    val pieceCache = remember(bodyStyle, titleStyle, page, script) { HashMap<Article, Pair<AnnotatedString, List<Piece>>>() }
    fun pieces(l: Loaded): Pair<AnnotatedString, List<Piece>>? {
        val article = l.article ?: return null
        return pieceCache.getOrPut(article) {
            articleHeading(l.chapter.title, article, titleStyle, page.ink, script) to
                articlePieces(article, bodyStyle, look.lineSpacing, page.ink, p.accent, script) { app.feeds.imageFile(l.chapter.id, it) }
        }
    }

    /** A press picks out the word under it; the grips take it from there. */
    fun press(hit: Hit) {
        val text = shownText(hit.loaded)
        val at = text.start(hit.paragraph) + hit.offset
        val span = text.wordSelection(at, at) ?: return
        chrome = false
        picked = Picked(hit.loaded.chapter.id, hit.loaded.chapter.siteChapterId, text, span)
    }

    /** A tap puts away the passage in hand, or takes up the highlight under it; false when it does neither. */
    fun tapMarks(hit: Hit?): Boolean {
        if (picked != null) {
            picked = null
            return true
        }
        if (hit == null) return false
        val length = hit.loaded.paragraphs[hit.paragraph].length
        val mark = highlights.firstOrNull { h ->
            h.siteChapterId == hit.loaded.chapter.siteChapterId && h.range(hit.paragraph, length)?.let { hit.offset in it.start until it.end } == true
        } ?: return false
        val text = shownText(hit.loaded)
        chrome = false
        picked = Picked(hit.loaded.chapter.id, hit.loaded.chapter.siteChapterId, text, text.span(mark) ?: return false, mark)
        return true
    }

    fun markActions(pk: Picked): List<Pair<String, () -> Unit>> {
        // What the page shows, script and paragraph breaks and all, not the capped excerpt.
        val copy = "拷貝" to {
            context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText(null, pk.text.text(pk.span)))
            picked = null
        }
        val stored = pk.stored ?: return listOf(
            "劃線" to {
                val start = pk.text.anchor(pk.span.start)
                val end = pk.text.anchor(pk.span.end)
                val mark = TextHighlight.make(
                    bookId, pk.siteChapterId, start.paragraph to start.offset, end.paragraph to end.offset,
                    pk.text.text(pk.span), System.currentTimeMillis(),
                )
                scope.launch { app.library.addHighlight(mark) }
                picked = null
            },
            copy,
        )
        return listOf(
            copy,
            "移除劃線" to {
                scope.launch { app.library.removeHighlight(stored.id) }
                picked = null
            },
        )
    }

    /** The visible item under a height in the column, or the nearest one. */
    fun itemAt(y: Float) = list.layoutInfo.visibleItemsInfo.let { visible ->
        visible.firstOrNull { y >= it.offset && y < it.offset + it.size } ?: if (y < (visible.firstOrNull()?.offset ?: 0)) visible.firstOrNull() else visible.lastOrNull()
    }

    /** The character under a point, or null off every paragraph: the title is no place for a mark. */
    fun characterAt(at: Offset): Hit? {
        val item = itemAt(at.y)?.takeIf { at.y >= it.offset && at.y < it.offset + it.size } ?: return null
        val entry = entries.getOrNull(item.index) as? ParagraphEntry ?: return null
        val layout = layouts[entry.key] ?: return null
        val length = layout.layoutInput.text.length
        if (length == 0) return null
        val local = Offset(at.x - pad, at.y - item.offset)
        val caret = layout.getOffsetForPosition(local)
        // The caret nearest the finger, turned into the character the finger is on.
        val character = if (caret >= length || (caret > 0 && layout.getHorizontalPosition(caret, true) > local.x)) caret - 1 else caret
        return Hit(entry.loaded, entry.index, character)
    }

    /** A grip's caret, held to the passage's chapter: past it either way is its first or last character. */
    fun caretAt(pk: Picked, at: Offset): Int {
        val item = itemAt(at.y) ?: return pk.span.start
        val entry = entries.getOrNull(item.index) ?: return pk.text.text.length
        if (entry.loaded.chapter.id != pk.chapterId) {
            val after = loaded.indexOf(entry.loaded) > loaded.indexOfFirst { it.chapter.id == pk.chapterId }
            return if (after) pk.text.text.length else 0
        }
        if (entry !is ParagraphEntry) return 0
        val layout = layouts[entry.key] ?: return pk.span.start
        return pk.text.start(entry.index) + layout.getOffsetForPosition(Offset(at.x - pad, at.y - item.offset))
    }

    fun glyph(pk: Picked, offset: Int): Rect? {
        val anchor = pk.text.anchor(offset)
        val key = "p|${pk.chapterId}|${anchor.paragraph}"
        val item = list.layoutInfo.visibleItemsInfo.firstOrNull { it.key == key } ?: return null
        return layouts[key]?.glyph(anchor.offset, inset)?.translate(pad, item.offset.toFloat())
    }

    // Read through these, not captured: the column's gesture handler is set up once.
    val pressAt by rememberUpdatedState { at: Offset -> characterAt(at)?.let { press(it) } }
    val tapAt by rememberUpdatedState { at: Offset -> tapMarks(characterAt(at)) }
    BackHandler(enabled = picked != null) { picked = null }

    Box(Modifier.fillMaxSize()) {
        ReaderBackgroundView(page.background, Modifier.fillMaxSize())
        Box(
            Modifier.fillMaxSize().windowInsetsPadding(safe.only(WindowInsetsSides.Vertical))
                .nestedScroll(pull)
                .pointerInput(Unit) {
                    // Watched, never consumed: a finger on the glass holds a page that moves on its own.
                    awaitPointerEventScope { while (true) touching = awaitPointerEvent(PointerEventPass.Initial).changes.any { it.pressed } }
                }
                .pointerInput(paged) {
                    // Paged, the page takes its own taps: its zones are not the column's.
                    if (paged) return@pointerInput
                    detectTapGestures(onLongPress = { pressAt(it) }) { at ->
                        if (tapAt(at)) return@detectTapGestures
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
                        // A reader who turns by swiping still has to reach the controls from somewhere.
                        if (zone == 0 || !look.pageTurn.turnsOnTap) {
                            chrome = true
                        } else {
                            scope.launch { turn(forward = zone > 0) }
                        }
                    }
                }
                .pointerInput(paged) {
                    // A finger that moved sideways is not a tap: the column claims only vertical
                    // drags, and Compose would count this one's lift as a turn.
                    if (paged) return@pointerInput
                    detectHorizontalDragGestures { change, _ -> change.consume() }
                },
        ) {
            val l = landing
            if (paged) {
                if (shown != null && l != null) {
                    key(shown.chapter.id) {
                        PagedChapter(
                            chapterKey = shown.chapter.id,
                            title = shown.chapter.title,
                            paragraphs = shown.paragraphs,
                            landing = PageLanding(l.paragraph ?: -1, l.offset, l.atEnd),
                            titleStyle = titleStyle,
                            bodyStyle = bodyStyle,
                            titleGap = paragraphGap + 8.dp,
                            paragraphGap = paragraphGap,
                            script = script,
                            pageTurn = look.pageTurn,
                            ink = page.ink,
                            chrome = chrome,
                            onChrome = { chrome = it },
                            onPosition = { paragraph, offset, fraction -> moved(Position(shown.chapter, paragraph, offset, fraction)) },
                            onTurnPast = { forward ->
                                val i = indexOf(shown.chapter)
                                val next = chapters.getOrNull(if (forward) i + 1 else i - 1)
                                if (next != null) {
                                    jump(Landing(next, null, 0, atEnd = !forward))
                                } else if (forward) {
                                    // A page that turns itself has run out of book: a switch left on over a page that cannot turn is a control lying.
                                    autoScrolling = false
                                }
                            },
                            marks = highlights.filter { it.siteChapterId == shown.chapter.siteChapterId },
                            picked = picked?.takeIf { it.chapterId == shown.chapter.id },
                            palette = page,
                            inset = inset,
                            onPress = { paragraph, offset -> press(Hit(shown, paragraph, offset)) },
                            onTapText = { paragraph, offset -> tapMarks(paragraph?.let { Hit(shown, it, offset) }) },
                            overlay = { glyphOf, caretOf, letGo ->
                                picked?.let { pk -> MarkOverlay(pk, glyphOf, caretOf, { picked = pk.copy(span = it) }, markActions(pk), p.accent, letGo) }
                            },
                            spoken = speaking?.takeIf { it.siteChapterId == shown.chapter.siteChapterId },
                            autoTurn = settings.autoScrollPace.takeIf { autoScrolling },
                            heading = pieces(shown)?.first,
                            pieces = pieces(shown)?.second,
                            onLink = { runCatching { uri.openUri(it) } },
                        )
                    }
                }
            } else LazyColumn(Modifier.fillMaxSize(), state = list) {
                items(entries, key = { it.key }, contentType = { it is TitleEntry }) { entry ->
                    val l = entry.loaded
                    when (entry) {
                        is TitleEntry -> Text(
                            pieces(l)?.first ?: remember(l.chapter.title, script) { AnnotatedString(ChineseText.rendered(l.chapter.title, script)) },
                            style = titleStyle,
                            onTextLayout = { layouts[entry.key] = it },
                            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp)
                                .padding(bottom = paragraphGap + 8.dp),
                        )
                        is ParagraphEntry -> {
                            val endsChapter = entry.index == l.paragraphs.lastIndex && l !== loaded.lastOrNull()
                            val piece = pieces(l)?.second?.getOrNull(entry.index)
                            val under = if (endsChapter) 28.dp else paragraphGap
                            val picture = piece?.picture
                            if (picture != null) {
                                BoxWithConstraints(Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = under), contentAlignment = Alignment.Center) {
                                    // As tall as the window, or as wide when that is more: a tall picture is read by scrolling past it.
                                    val viewport = with(density) { list.layoutInfo.viewportSize.height.toDp() }
                                    ArticlePicture(picture, maxWidth, max(viewport.value, maxWidth.value).dp)
                                }
                                return@items
                            }
                            if (piece != null && !piece.selectable) {
                                Text(piece.text, style = piece.style, modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = under))
                                return@items
                            }
                            val text = l.paragraphs[entry.index]
                            val marks = highlights.mapNotNull { h ->
                                if (h.siteChapterId != l.chapter.siteChapterId) null else h.range(entry.index, text.length)?.let { it to page.highlight }
                            } + listOfNotNull(
                                picked?.takeIf { it.chapterId == l.chapter.id }?.let { pk -> pk.text.inParagraph(pk.span, entry.index)?.let { it to page.selection } },
                                // In the passage's ink: both say "this is the one the app is pointing at".
                                speaking?.takeIf { !it.isTitle && it.siteChapterId == l.chapter.siteChapterId && it.paragraph == entry.index }
                                    ?.let { it.range to page.selection },
                            )
                            Text(
                                piece?.text ?: remember(text, script) { AnnotatedString(ChineseText.rendered(text, script)) }, style = piece?.style ?: bodyStyle,
                                onTextLayout = { layouts[entry.key] = it },
                                modifier = Modifier.fillMaxWidth()
                                    .then(piece?.background?.let { Modifier.padding(horizontal = 12.dp).background(it).padding(horizontal = 8.dp) } ?: Modifier.padding(horizontal = 20.dp))
                                    .drawBehind { if (marks.isNotEmpty()) layouts[entry.key]?.let { drawSpans(it, marks, inset) } }
                                    .padding(bottom = under),
                            )
                        }
                    }
                }
                if (loaded.isNotEmpty()) {
                    item(key = "footer") {
                        // An article with no body is not fixed by asking the feed again; its page is.
                        val emptyNext = (nextFailure as? FeedService.EmptyArticle)?.let { chapters.getOrNull(indexOf(loaded.last().chapter) + 1) }
                            ?.takeIf { FeedService.isWeb(it.url) }
                        Footer(
                            loading = loadingNext || (emptyNext != null && fetchingPage),
                            failure = nextFailure,
                            atEnd = loaded.last().chapter.id == chapters.lastOrNull()?.id,
                            ink = page.ink,
                            retry = if (emptyNext != null) "抓取全文" else "重試",
                            onRetry = {
                                if (emptyNext != null) {
                                    readFromPage(emptyNext)
                                } else {
                                    nextFailure = null
                                    loadNext()
                                }
                            },
                        )
                    }
                }
            }
            if (!paged) {
                picked?.let { pk -> MarkOverlay(pk, { glyph(pk, it) }, { caretAt(pk, it) }, { picked = pk.copy(span = it) }, markActions(pk), p.accent) }
            }
        }

        val failed = failure
        when {
            failed != null -> {
                // Only where there is a page to read instead: a button that could not act is what this panel exists to stop.
                val original = landing?.chapter?.takeIf { isFeed && FeedService.isWeb(it.url) }
                val summaryOnly = original != null && failed is FeedService.EmptyArticle
                Failure(
                    describe(failed), Modifier.align(Alignment.Center), onBack = nav::pop,
                    onOpenOriginal = original?.let { { runCatching { uri.openUri(it.url) } } },
                    retry = if (summaryOnly) "抓取全文" else "重試",
                    busy = fetchingPage,
                ) {
                    if (summaryOnly) readFromPage(original!!) else landing?.let { jump(it) }
                }
            }
            loaded.isEmpty() -> Spinner(Modifier.align(Alignment.Center), size = 28.dp)
        }

        AnimatedVisibility(
            chrome && position != null,
            Modifier.align(Alignment.TopCenter),
            enter = slideInVertically(tween(200)) { -it } + fadeIn(tween(200)),
            exit = slideOutVertically(tween(200)) { -it } + fadeOut(tween(200)),
        ) {
            position?.let { TitlePill(it.chapter.title, percent(it.fraction), Modifier.windowInsetsPadding(safe.only(WindowInsetsSides.Top))) }
        }
        AnimatedVisibility(
            chrome,
            Modifier.align(Alignment.BottomCenter),
            enter = slideInVertically(tween(200)) { it } + fadeIn(tween(200)),
            exit = slideOutVertically(tween(200)) { it } + fadeOut(tween(200)),
        ) {
            val index = position?.let { indexOf(it.chapter) } ?: -1
            val at = position
            Toolbar(
                layout = look.toolbar,
                feed = isFeed,
                onBack = nav::pop,
                onCatalog = { showCatalog = true },
                bookmarked = at != null && ReadingBookmark.id(bookId, at.chapter.siteChapterId, at.paragraph, at.offset) in bookmarkIds,
                onBookmark = at?.let { { toggleBookmark(it) } },
                onPrevious = chapters.getOrNull(index - 1)?.let { { jump(Landing(it, null, 0)) } },
                onNext = chapters.getOrNull(index + 1)?.takeIf { index >= 0 }?.let { { jump(Landing(it, null, 0)) } },
                // Both renderers answer it, at one pace: one moves the column, the other holds a page as long as its text takes to read.
                autoScrolling = autoScrolling,
                onAutoScroll = { autoScrolling = !autoScrolling },
                speaking = voiceReading,
                // A lambda, not `::toggleSpeech`: Compose memoizes a reference without its captures.
                onSpeech = { toggleSpeech() },
                onSettings = { showSettings = true },
                // The tap re-reads the piece into this reader; the browser is the long press —
                // the gesture that keeps the reader where they are is the one that needs no discovering.
                onReload = at?.chapter?.takeIf { isFeed && FeedService.isWeb(it.url) }?.let { c -> { readFromPage(c) } },
                onOpenOriginal = at?.chapter?.takeIf { isFeed && FeedService.isWeb(it.url) }?.let { c -> { runCatching { uri.openUri(c.url) } } },
                reloading = fetchingPage,
            )
        }
        AnimatedVisibility(
            chrome && voiceReading && paceAskedAt != null,
            Modifier.align(Alignment.BottomCenter),
            enter = slideInVertically(tween(200)) { it / 2 } + fadeIn(tween(200)),
            exit = slideOutVertically(tween(200)) { it / 2 } + fadeOut(tween(200)),
        ) {
            val next = position?.let { chapters.getOrNull(indexOf(it.chapter) + 1) }
            SpeechStrip(
                settings, speech.sleepsAt, { speech.sleepsAt = it },
                downloadedOnly = next != null && next.downloadedAt == null,
                onRate = { speech.setRate(settings.speechRate) },
                onTouched = { paceAskedAt = System.currentTimeMillis() },
            )
        }
        // One strip for the two: they never both move the page, and two sliders stacked over its foot would be the chrome covering the book.
        AnimatedVisibility(
            chrome && autoScrolling && !voiceReading && paceAskedAt != null,
            Modifier.align(Alignment.BottomCenter),
            enter = slideInVertically(tween(200)) { it / 2 } + fadeIn(tween(200)),
            exit = slideOutVertically(tween(200)) { it / 2 } + fadeOut(tween(200)),
        ) {
            AutoScrollStrip(
                settings.autoScrollPace, ReaderSettings.AUTO_SCROLL_PACES, { settings.autoScrollPace = it },
                onTouched = { paceAskedAt = System.currentTimeMillis() },
            )
        }
    }

    if (showCatalog) {
        val current = position?.chapter
        CatalogSheet(
            book, chapters, current, isDescending(app.prefs, bookId, isFeed), if (isFeed) "文章" else "目錄",
            outline = current?.let { c -> loaded.firstOrNull { it.chapter.id == c.id }?.article?.outline }.orEmpty(),
            onOutline = { paragraph ->
                showCatalog = false
                chrome = false
                current?.let { jump(Landing(it, paragraph, 0)) }
            },
            onDismiss = { showCatalog = false },
        ) {
            showCatalog = false
            chrome = false
            jump(Landing(it, null, 0))
        }
    }
    if (showSettings) ReaderSettingsSheet(settings, layer) { showSettings = false }
}

/** Full screen, as iOS hides the status bar; the navigation bar takes the page's colours. */
@Composable
fun ReaderWindow(dark: Boolean, keepScreenOn: Boolean) {
    val activity = LocalActivity.current
    DisposableEffect(dark) {
        val window = activity?.window ?: return@DisposableEffect onDispose { }
        val controller = WindowCompat.getInsetsController(window, window.decorView)
        val lightBars = controller.isAppearanceLightNavigationBars
        controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        controller.hide(WindowInsetsCompat.Type.statusBars())
        controller.isAppearanceLightNavigationBars = !dark
        onDispose {
            controller.show(WindowInsetsCompat.Type.statusBars())
            controller.isAppearanceLightNavigationBars = lightBars
        }
    }
    // Held only while a book is open: set from Settings, the shelf would stay awake too.
    DisposableEffect(activity, keepScreenOn) {
        val window = activity?.window
        if (window == null || !keepScreenOn) return@DisposableEffect onDispose { }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        onDispose { window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) }
    }
}

@Composable
fun Footer(loading: Boolean, failure: Throwable?, atEnd: Boolean, ink: Color, retry: String, onRetry: () -> Unit) {
    val p = LocalPalette.current
    Box(Modifier.fillMaxWidth().heightIn(min = 96.dp)) {
        when {
            loading -> Spinner(Modifier.align(Alignment.TopCenter).padding(top = 30.dp))
            failure != null -> Column(
                Modifier.padding(horizontal = 12.dp, vertical = 12.dp).fillMaxWidth()
                    .background(p.glass, RoundedCornerShape(18.dp)).padding(vertical = 12.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(describe(failure), style = Type.footnote, color = p.secondary, textAlign = TextAlign.Center)
                ProminentButton(retry, onClick = onRetry)
            }
            atEnd -> Text(
                "已經到最後了", style = Type.footnote, color = ink.copy(alpha = 0.6f),
                modifier = Modifier.align(Alignment.TopCenter).padding(top = 28.dp),
            )
        }
    }
}

@Composable
fun Failure(
    message: String,
    modifier: Modifier,
    onBack: () -> Unit,
    onOpenOriginal: (() -> Unit)? = null,
    retry: String = "重試",
    busy: Boolean = false,
    onRetry: () -> Unit,
) {
    val p = LocalPalette.current
    Column(
        modifier.padding(horizontal = 20.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(message, style = Type.footnote, color = p.secondary, textAlign = TextAlign.Center)
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
            BorderedButton("返回", onClick = onBack)
            onOpenOriginal?.let { BorderedButton("開啟原文", onClick = it) }
            if (busy) Spinner() else ProminentButton(retry, onClick = onRetry)
        }
    }
}

/** The chapter's name and how far into it, floating over the top of the page. */
@Composable
fun TitlePill(title: String, detail: String, modifier: Modifier) {
    val p = LocalPalette.current
    Row(
        modifier.padding(horizontal = 24.dp).padding(top = 6.dp)
            .shadow(8.dp, CircleShape, ambientColor = Color.Black.copy(alpha = 0.1f), spotColor = Color.Black.copy(alpha = 0.1f))
            .background(p.glass, RoundedCornerShape(50))
            .padding(horizontal = 16.dp, vertical = 9.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, style = Type.footnote, color = p.label, modifier = Modifier.weight(1f, fill = false))
        Text(detail, style = Type.footnote.copy(fontFeatureSettings = TABULAR), color = p.secondary)
    }
}

/** The iOS reader toolbar, arranged and folded as the reader arranged it — see [ReaderToolbarLayout]. */
@Composable
private fun Toolbar(
    layout: ReaderToolbarLayout,
    feed: Boolean,
    onBack: () -> Unit,
    onCatalog: () -> Unit,
    bookmarked: Boolean,
    onBookmark: (() -> Unit)?,
    onPrevious: (() -> Unit)?,
    onNext: (() -> Unit)?,
    autoScrolling: Boolean,
    onAutoScroll: () -> Unit,
    speaking: Boolean,
    onSpeech: () -> Unit,
    onSettings: () -> Unit,
    onReload: (() -> Unit)?,
    onOpenOriginal: (() -> Unit)?,
    reloading: Boolean,
) {
    val p = LocalPalette.current
    val (bar, folded) = layout.resolve(if (feed) SiteRule.Kind.FEED else SiteRule.Kind.NOVEL)
    fun control(button: ReaderButton): BarControl? = when (button) {
        ReaderButton.BACK -> BarControl("返回", onBack) { Chevron(direction = Direction.LEFT, color = p.label, width = 9.dp, height = 16.dp, stroke = 2.2.dp) }
        ReaderButton.CATALOG -> BarControl(if (feed) "文章" else "目錄", onCatalog) { ToolbarIcon(Symbols.ListBullet, true) }
        ReaderButton.BOOKMARK -> BarControl(if (bookmarked) "移除書籤" else "加入書籤", onBookmark) {
            ToolbarIcon(if (bookmarked) Symbols.BookmarkFill else Symbols.Bookmark, onBookmark != null)
        }
        ReaderButton.PREVIOUS -> BarControl(if (feed) "上一篇" else "上一章", onPrevious) { ToolbarIcon(Symbols.ArrowUpToLine, onPrevious != null) }
        ReaderButton.NEXT -> BarControl(if (feed) "下一篇" else "下一章", onNext) { ToolbarIcon(Symbols.ArrowDownToLine, onNext != null) }
        // Only where the article has a page it came from, as on iOS: elsewhere it is a button with nothing to do.
        ReaderButton.ORIGINAL -> onOpenOriginal?.let { open ->
            BarControl(
                "抓取全文", onReload,
                menu = listOf(
                    BarControl("抓取全文", onReload) { ToolbarIcon(Symbols.ArrowClockwise, onReload != null) },
                    BarControl("開啟原文", open) { ToolbarIcon(Symbols.Safari, true) },
                ),
            ) { if (reloading) Spinner(size = 20.dp) else ToolbarIcon(Symbols.ArrowClockwise, onReload != null) }
        }
        // A state, not an action: a play glyph on a page already moving would promise what it has just done.
        ReaderButton.AUTO_SCROLL -> BarControl(if (autoScrolling) "停止自動捲動" else "開始自動捲動", onAutoScroll) {
            ToolbarIcon(if (autoScrolling) Symbols.PauseCircle else Symbols.PlayCircle, true)
        }
        // Filled while the voice reads, as the bookmark is filled on a saved page.
        ReaderButton.SPEECH -> BarControl(if (speaking) "暫停朗讀" else "開始朗讀", onSpeech) { CircledIcon(if (speaking) Symbols.HeadphonesFill else Symbols.Headphones, speaking) }
        ReaderButton.SETTINGS -> BarControl("閱讀設定", onSettings) { ToolbarIcon(Symbols.TextFormatSize, true) }
    }
    ReaderBar(bar.mapNotNull(::control), folded.mapNotNull(::control))
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun androidx.compose.foundation.layout.RowScope.ToolbarItem(
    label: String,
    onClick: (() -> Unit)?,
    onLongClick: (() -> Unit)? = null,
    icon: @Composable () -> Unit,
) {
    Box(
        Modifier.weight(1f).heightIn(min = 34.dp)
            .combinedClickable(enabled = onClick != null, role = Role.Button, onLongClick = onLongClick) { onClick?.invoke() }
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) { icon() }
}

@Composable
fun ToolbarIcon(icon: ImageVector, enabled: Boolean) {
    val p = LocalPalette.current
    Icon(icon, null, Modifier.size(22.dp), tint = if (enabled) p.label else p.tertiary)
}

/** The SF `headphones.circle` shape, which Material has no glyph for: a ring, or a disc with the glyph cut out of it. */
@Composable
private fun CircledIcon(icon: ImageVector, filled: Boolean) {
    val p = LocalPalette.current
    Box(
        Modifier.size(22.dp).then(if (filled) Modifier.background(p.label, CircleShape) else Modifier.border(1.5.dp, p.label, CircleShape)),
        contentAlignment = Alignment.Center,
    ) { Icon(icon, null, Modifier.size(13.dp), tint = if (filled) p.card else p.label) }
}

/**
 * How fast the voice reads, and when it stops — the iOS `SpeechBar`, in the place iOS puts it,
 * over the toolbar. The pace goes to the voice when the slider is let go: an utterance's rate is
 * fixed once handed over, so applying it per drag frame would restart the sentence sixty times a second.
 */
@Composable
private fun SpeechStrip(
    settings: ReaderSettings,
    sleepsAt: Long?,
    onSleep: (Long?) -> Unit,
    downloadedOnly: Boolean,
    onRate: () -> Unit,
    onTouched: () -> Unit,
) {
    val p = LocalPalette.current
    var timer by remember { mutableStateOf(false) }
    val rates = SpeechReader.RATES
    Column(
        Modifier.navigationBarsPadding().padding(start = 12.dp, end = 12.dp, bottom = 72.dp).fillMaxWidth()
            .shadow(10.dp, RoundedCornerShape(18.dp), ambientColor = Color.Black.copy(alpha = 0.12f), spotColor = Color.Black.copy(alpha = 0.12f))
            .background(p.glass, RoundedCornerShape(18.dp))
            .padding(horizontal = 18.dp, vertical = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Icon(Symbols.Tortoise, "慢", Modifier.size(18.dp), tint = p.secondary)
            Box(Modifier.weight(1f).semantics { contentDescription = "朗讀速度" }) {
                IosSlider(
                    (settings.speechRate * 10).roundToInt(), (rates.start * 10).roundToInt()..(rates.endInclusive * 10).roundToInt(), 1,
                    onChange = {
                        onTouched()
                        settings.speechRate = it / 10f
                    },
                    onDone = onRate,
                )
            }
            Icon(Symbols.Hare, "快", Modifier.size(18.dp), tint = p.secondary)
            Box {
                // Filled while a timer is set: one the reader cannot see is one they will set twice.
                Icon(
                    if (sleepsAt == null) Symbols.Moon else Symbols.MoonFill, "睡眠計時",
                    Modifier.size(20.dp).clickable {
                        onTouched()
                        timer = true
                    },
                    tint = p.secondary,
                )
                DropdownMenu(timer, { timer = false }, shape = RoundedCornerShape(20.dp), containerColor = p.card) {
                    // Three answers: a reader setting this is going to sleep, not timing something.
                    for (minutes in listOf(15, 30, 60)) {
                        DropdownMenuItem(text = { Text("$minutes 分鐘", style = Type.body) }, onClick = {
                            timer = false
                            onTouched()
                            onSleep(System.currentTimeMillis() + minutes * 60_000L)
                        })
                    }
                    if (sleepsAt != null) {
                        DropdownMenuItem(text = { Text("不計時", style = Type.body) }, onClick = {
                            timer = false
                            onTouched()
                            onSleep(null)
                        })
                    }
                }
            }
        }
        // Said where it matters, the moment listening starts: a locked phone reads only what is on it.
        if (downloadedOnly) Text("鎖屏後只會朗讀已下載的章節。", style = Type.caption2, color = p.secondary, textAlign = TextAlign.Center)
    }
}

/**
 * The table of contents: every chapter, the current one centred and marked. [book] as the reader
 * opened it, deliberately, as on iOS: chapters read in this session keep 「新」 until the reader leaves.
 */
@Composable
fun CatalogSheet(
    book: Book?,
    chapters: List<Chapter>,
    current: Chapter?,
    descending: Boolean,
    title: String,
    /** The article's headings — paragraph, level, text; empty for everything but an article that has some. */
    outline: List<Triple<Int, Int, String>>,
    onOutline: (Int) -> Unit,
    onDismiss: () -> Unit,
    onPick: (Chapter) -> Unit,
) {
    val p = LocalPalette.current
    val ordered = if (descending) chapters.asReversed() else chapters
    val lastReadIndex = book?.lastReadIndex(chapters)
    val state = rememberLazyListState(max(0, ordered.indexOfFirst { it.id == current?.id } - 5))
    var showOutline by remember { mutableStateOf(outline.isNotEmpty()) }
    Sheet(onDismiss) {
        SheetBar(title, trailing = { BarTextButton("完成", bold = true, onClick = onDismiss) })
        if (outline.isNotEmpty()) {
            Box(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
                Segmented(listOf(true to "大綱", false to title), showOutline) { showOutline = it }
            }
        }
        if (showOutline && outline.isNotEmpty()) {
            // Indented from the shallowest heading the piece uses: an article that starts at h2 is not drawn half-indented.
            val shallowest = outline.minOf { it.second }
            LazyColumn(Modifier.fillMaxSize()) {
                group(outline, key = { it.first }) { (paragraph, level, text), edge ->
                    Cell(edge, onClick = { onOutline(paragraph) }, chevron = false) {
                        Text(text, style = Type.body, color = p.label, modifier = Modifier.padding(start = (16 * (level - shallowest)).dp).weight(1f))
                    }
                }
                item { Spacer(Modifier.navigationBarsPadding().height(16.dp)) }
            }
            return@Sheet
        }
        LazyColumn(Modifier.fillMaxSize(), state = state) {
            group(ordered, key = { it.id }) { chapter, edge ->
                Cell(edge, onClick = { onPick(chapter) }, chevron = false) {
                    ChapterTitle(chapter, book != null && chapter.isMarked(book.kind, lastReadIndex), Modifier.weight(1f))
                    if (chapter.id == current?.id) {
                        Spacer(Modifier.width(8.dp))
                        Chevron(color = p.accent)
                    }
                }
            }
            item { Spacer(Modifier.navigationBarsPadding().height(16.dp)) }
        }
    }
}

/**
 * 閱讀設定 at a medium detent: the controls Settings → 外觀 has, and the custom colour and toolbar
 * editors pushed inside the sheet as iOS pushes them, over the page they are changing. A comic's
 * [book] gets the one question about its pictures — how pages turn — and the toolbar, which every reader has.
 */
@Composable
fun ReaderSettingsSheet(settings: ReaderSettings, book: Layer.Book, onDismiss: () -> Unit) {
    var editingTheme by remember { mutableStateOf(false) }
    var editingToolbar by remember { mutableStateOf<Layer?>(null) }
    // Holds the sections' state through a look at 自訂配色, as a pushed screen's parent keeps it on
    // iOS: coming back to 「預設」 after picking 「這本書」 would aim the next change at every book.
    val kept = rememberSaveableStateHolder()
    val list: @Composable (LazyListScope.() -> Unit) -> Unit = { content ->
        LazyColumn {
            content()
            item { Spacer(Modifier.navigationBarsPadding().height(24.dp)) }
        }
    }
    Sheet(onDismiss, full = false) {
        val toolbarLayer = editingToolbar
        if (editingTheme) {
            SheetBar(
                "自訂配色",
                leading = { BarTextButton("閱讀設定") { editingTheme = false } },
                trailing = { BarTextButton("完成", bold = true, onClick = onDismiss) },
            )
            ThemeEditor(settings, list)
        } else if (toolbarLayer != null) {
            SheetBar(
                "工具列",
                leading = { BarTextButton("閱讀設定") { editingToolbar = null } },
                trailing = { BarTextButton("完成", bold = true, onClick = onDismiss) },
            )
            ToolbarEditor(settings, toolbarLayer, list)
        } else {
            SheetBar("閱讀設定", trailing = { BarTextButton("完成", bold = true, onClick = onDismiss) })
            kept.SaveableStateProvider("sections") {
                AppearanceSections(settings, onEditTheme = { editingTheme = true }, onEditToolbar = { editingToolbar = it }, book, list)
            }
        }
    }
}

/** A slider in the iOS 26 shape: accent fill on a grey track, a white capsule thumb. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun IosSlider(value: Int, range: IntRange, step: Int, onChange: (Int) -> Unit, onDone: () -> Unit = {}) {
    val p = LocalPalette.current
    val start = range.first.toFloat()
    val end = range.last.toFloat()
    Slider(
        value = value.toFloat(),
        onValueChange = { onChange((Math.round((it - start) / step) * step + range.first).coerceIn(range)) },
        onValueChangeFinished = onDone,
        valueRange = start..end,
        steps = (range.last - range.first) / step - 1,
        thumb = {
            Box(
                Modifier.size(width = 36.dp, height = 24.dp)
                    .shadow(4.dp, CircleShape)
                    .background(Color.White, CircleShape),
            )
        },
        track = { state ->
            val share = ((state.value - start) / (end - start)).coerceIn(0f, 1f)
            Box(Modifier.fillMaxWidth().height(4.dp).background(p.fill.copy(alpha = p.fill.alpha * 1.6f), CircleShape)) {
                Box(Modifier.fillMaxWidth(share).fillMaxHeight().background(p.accent, CircleShape))
            }
        },
    )
}
