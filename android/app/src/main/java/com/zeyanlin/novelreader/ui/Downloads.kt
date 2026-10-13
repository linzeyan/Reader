package com.zeyanlin.novelreader.ui

import android.text.format.Formatter
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.zeyanlin.novelreader.data.Book
import com.zeyanlin.novelreader.data.Chapter
import com.zeyanlin.novelreader.services.CacheLimit
import com.zeyanlin.novelreader.services.DownloadManager
import com.zeyanlin.novelreader.services.DownloadManager.Hold
import com.zeyanlin.novelreader.services.DownloadManager.Status
import com.zeyanlin.novelreader.siterules.SiteRule
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Byte counts as the system writes them, the counterpart of `ByteCountFormatter`'s file style. */
@Composable
fun bytes(count: Long): String = Formatter.formatShortFileSize(LocalContext.current, count)

/**
 * The iOS `ChapterDownloadView`: picking exactly which chapters to keep — the arc being read,
 * downloaded, and later the arcs finished, deleted. Selection is by chapter id, so a catalog
 * refresh arriving mid-selection cannot move the ticks onto other chapters.
 */
@Composable
fun ChapterDownloadScreen(bookId: String) {
    val app = app()
    val nav = LocalNavigator.current
    val p = LocalPalette.current
    val scope = rememberCoroutineScope()
    val book by remember(bookId) { app.library.book(bookId) }.collectAsState(null)
    // A Room flow: a chapter landing rewrites its row, so this list follows the queue by itself.
    val chapters by remember(bookId) { app.library.chapters(bookId) }.collectAsState(emptyList())
    val sizes by remember { app.downloadSizes() }.collectAsState(emptyList())
    val rules by app.sites.rules.collectAsState()
    val queue by app.downloads.state.collectAsState()
    var selection by remember { mutableStateOf(emptySet<String>()) }
    var query by remember { mutableStateOf("") }
    var confirmingDelete by remember { mutableStateOf(false) }
    // Where a long press extends from: the chapter last ticked on its own. Taps keep meaning
    // one row, because scattered picking is this screen's other job.
    var anchor by remember { mutableStateOf<String?>(null) }

    val b = book ?: return Box(Modifier.fillMaxSize())
    val rule = rules.firstOrNull { it.id == b.siteId }
    val trimmed = query.trim()
    val filtered = if (trimmed.isEmpty()) chapters else chapters.filter { it.title.contains(trimmed, ignoreCase = true) }
    val downloaded = chapters.count { it.downloadedAt != null }
    val live = chapters.mapTo(HashSet()) { it.id }
    val selected = chapters.filter { it.id in selection }
    // A chapter deleted elsewhere must not stay ticked.
    LaunchedEffect(live) { selection = selection.filterTo(HashSet()) { it in live } }

    fun select(new: Set<String>) {
        // A single fresh tick moves the anchor; a range or "select all" does not. An anchor
        // that got unticked is gone.
        val added = new - selection
        if (added.size == 1) anchor = added.first()
        if (anchor != null && anchor !in new) anchor = null
        selection = new
    }

    // Over the filtered rows: with a search narrowing the list, selecting what cannot be seen
    // is how people delete chapters they never chose.
    fun extend(to: Chapter) {
        val from = filtered.indexOfFirst { it.id == anchor }
        val end = filtered.indexOfFirst { it.id == to.id }
        if (from < 0 || end < 0) {
            selection = selection + to.id
            anchor = to.id
            return
        }
        selection = selection + filtered.subList(minOf(from, end), maxOf(from, end) + 1).map { it.id }
        anchor = to.id
    }

    fun start(wanted: List<Chapter>) {
        if (rule != null) app.requestDownload(b, rule, wanted)
    }

    val all = selection.size == chapters.size && chapters.isNotEmpty()
    Box(Modifier.fillMaxSize()) {
        ListScreen(
            "下載管理",
            onBack = nav::pop,
            actions = { BarTextButton(if (all) "取消全選" else "全選") { select(if (all) emptySet() else live) } },
            bottomSpace = TabBarSpace + 64.dp,
        ) {
            item { SearchField(query, { query = it }, "搜尋章節", Modifier.padding(bottom = 16.dp)) }
            item {
                Cell(Edge.ONLY) {
                    Labeled("已下載 $downloaded / ${chapters.size} 章", bytes(sizes.firstOrNull { it.bookId == b.id }?.bytes ?: 0))
                }
            }
            gap(20.dp)
            item {
                val enabled = rule != null && downloaded < chapters.size
                Cell(Edge.TOP, onClick = { if (enabled) start(chapters) }, chevron = false) {
                    ActionLabel(Symbols.ArrowDownCircle, "下載全部章節", if (enabled) p.accent else p.tertiary)
                }
            }
            item {
                val enabled = downloaded > 0
                Cell(Edge.BOTTOM, onClick = { if (enabled) confirmingDelete = true }, chevron = false) {
                    ActionLabel(Symbols.Trash, "刪除全部下載", if (enabled) p.red else p.tertiary)
                }
            }
            header("目錄（${chapters.size} 章）", key = "catalogHeader")
            // Once for the list: this screen redraws on every chapter that lands.
            val lastReadIndex = b.lastReadIndex(chapters)
            group(filtered, key = { it.id }) { chapter, edge ->
                val ticked = chapter.id in selection
                Cell(
                    edge,
                    onClick = { select(if (ticked) selection - chapter.id else selection + chapter.id) },
                    onLongClick = { extend(chapter) },
                    chevron = false,
                    separatorStart = RowPadding + 24.dp + 14.dp,
                ) {
                    SelectionMark(ticked)
                    Spacer(Modifier.width(14.dp))
                    ChapterTitle(chapter, chapter.isMarked(b.kind, lastReadIndex), Modifier.weight(1f))
                }
            }
            // A gesture with no affordance is a feature only its author uses.
            footer("長按章節，可從上一個勾選處連選到該章。")
        }
        // The queue takes the slot the selection bar leaves, never both: a selection is the
        // reader picking the next thing to queue.
        val job = queue.job(b.id)
        if (selection.isNotEmpty()) {
            val pending = selected.filter { it.downloadedAt == null }
            val stored = selected.filter { it.downloadedAt != null }
            BottomBar(Modifier.align(Alignment.BottomCenter)) {
                // Its own button: the bar's "deselect all" only flips once everything is ticked.
                IconButton(Symbols.XmarkCircle, "取消選取", p.accent) { select(emptySet()) }
                Text("已選 ${selection.size} 章", style = Type.footnote.copy(fontFeatureSettings = TABULAR), color = p.secondary, modifier = Modifier.weight(1f))
                IconButton(Symbols.ArrowDownCircle, "下載所選", p.accent, enabled = rule != null && pending.isNotEmpty()) {
                    start(selected)
                    select(emptySet())
                }
                IconButton(Symbols.Trash, "刪除所選", p.red, enabled = stored.isNotEmpty()) {
                    scope.launch { app.deleteDownloads(stored) }
                    select(emptySet())
                }
            }
        } else if (job != null) {
            BottomBar(Modifier.align(Alignment.BottomCenter)) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("${job.completed} / ${job.total}", style = Type.footnote.copy(fontFeatureSettings = TABULAR), color = p.label)
                    ProgressBar(job.fraction)
                    queue.describe(job)?.let { Text(it, style = Type.caption2, color = p.secondary, maxLines = 2, overflow = TextOverflow.Ellipsis) }
                }
            }
        }
    }
    if (confirmingDelete) {
        ActionSheet(
            null, "刪除全部下載",
            onAction = {
                confirmingDelete = false
                scope.launch { app.deleteBookDownloads(b.id) }
            },
            onDismiss = { confirmingDelete = false },
        )
    }
}

@Composable
private fun RowScope.ActionLabel(icon: androidx.compose.ui.graphics.vector.ImageVector, text: String, color: androidx.compose.ui.graphics.Color) {
    Icon(icon, null, Modifier.size(24.dp), tint = color)
    Spacer(Modifier.width(14.dp))
    Text(text, style = Type.body, color = color, modifier = Modifier.weight(1f))
}

@Composable
private fun IconButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    tint: androidx.compose.ui.graphics.Color,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    val p = LocalPalette.current
    // Not BarButton, which draws in the label colour: these carry their role's tint.
    Box(
        Modifier.size(40.dp).clickable(enabled = enabled, onClickLabel = label, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, label, Modifier.size(26.dp), tint = if (enabled) tint else p.tertiary)
    }
}

/**
 * One book's share of the queue: how far it has got, what it waits for, and its two controls.
 * Shared by the queue and the book screen, so the two never describe a book differently.
 */
@Composable
fun RowScope.DownloadJobRow(job: DownloadManager.Job, queue: DownloadManager.State, showsTitle: Boolean) {
    val app = app()
    val p = LocalPalette.current
    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (showsTitle) {
            Text(job.book.shownName, style = Type.subheadline, fontWeight = FontWeight.Medium, color = p.label, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text("${job.completed} / ${job.total}", style = Type.footnote.copy(fontFeatureSettings = TABULAR), color = p.label)
            ProgressBar(job.fraction)
        }
        queue.describe(job)?.let { Text(it, style = Type.caption, color = if (job.hold == null) p.secondary else p.orange) }
        Row {
            // Pause only means something while the queue is going; otherwise the row asks it to go.
            if (job.hold == null && queue.isBusy) {
                TextAction("暫停", p.accent) { app.downloads.pauseBook(job.id) }
            } else {
                TextAction("繼續", p.accent) { app.requestResume(job.id) }
            }
            Spacer(Modifier.weight(1f))
            TextAction("取消", p.red) { app.downloads.cancelBook(job.id) }
        }
    }
}

@Composable
private fun TextAction(text: String, color: androidx.compose.ui.graphics.Color, onClick: () -> Unit) {
    Text(text, style = Type.footnote, color = color, modifier = Modifier.clickable(onClick = onClick).padding(vertical = 4.dp))
}

/**
 * The book screen's download section, while the book is queued: the job, the way to the
 * whole queue, and — said before it happens — that leaving the app stops it.
 */
fun androidx.compose.foundation.lazy.LazyListScope.bookDownloadSection(
    job: DownloadManager.Job,
    queue: DownloadManager.State,
    onQueue: () -> Unit,
) {
    val running = queue.isBusy
    // The queue is where focus download is, and a download just started is a phone about to be put down.
    val link = queue.jobs.size > 1 || running
    header("下載中", key = "downloadingHeader")
    item(key = "downloadJob") { Cell(if (link) Edge.TOP else Edge.ONLY) { DownloadJobRow(job, queue, showsTitle = false) } }
    if (link) {
        item(key = "downloadQueueLink") {
            Cell(Edge.BOTTOM, onClick = onQueue) {
                Text("下載佇列（${queue.jobs.size} 本）", style = Type.footnote, color = LocalPalette.current.label, modifier = Modifier.weight(1f))
            }
        }
    }
    if (running) footer("離開 App 或鎖定螢幕，下載會暫停，回來後自動繼續。想放著讓它下載，到「下載佇列」打開「專注下載」。")
}

/** Where a book stands in the queue, on its shelf row, so a download can be followed from the shelf. */
@Composable
fun ShelfDownloadState(bookId: String) {
    val app = app()
    val p = LocalPalette.current
    val queue by app.downloads.state.collectAsState()
    val job = queue.job(bookId) ?: return
    val style = Type.caption2.copy(fontFeatureSettings = TABULAR)
    when {
        job.hold == Hold.WALL -> Text("網站驗證", style = style, color = p.orange)
        job.hold == Hold.PAUSED || !queue.isBusy -> Text("已暫停", style = style, color = p.orange)
        job.id == queue.activeBookId -> Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Symbols.ArrowDownCircle, null, Modifier.size(13.dp), tint = p.accent)
            Spacer(Modifier.width(3.dp))
            Text("${job.completed} / ${job.total}", style = style, color = p.accent)
        }
        else -> Text("等待中", style = style, color = p.secondary)
    }
}

/**
 * The iOS `DownloadQueueView`: every queued book in the order it will be fetched. No
 * reordering — the order is the order asked in; a stuck queue needs hold, go, or remove.
 */
@Composable
fun DownloadQueueScreen() {
    val app = app()
    val nav = LocalNavigator.current
    val p = LocalPalette.current
    val queue by app.downloads.state.collectAsState()
    val phase by app.focus.phase.collectAsState()
    // How the last focus ended, said once the black lifts.
    var ending by remember { mutableStateOf<Status?>(null) }

    // Everything that could go is done or held: nothing left that keeping the screen on would move.
    LaunchedEffect(queue.isBusy) {
        if (queue.isBusy) {
            ending = null
        } else if (app.focus.phase.value != DownloadFocus.Phase.Off) {
            app.focus.stop()
            ending = queue.status.takeIf { it == Status.FINISHED || it == Status.PAUSED }
        }
    }
    DisposableEffect(Unit) { onDispose { app.focus.stop() } }

    Box(Modifier.fillMaxSize()) {
        ListScreen("下載佇列", onBack = nav::pop, bottomSpace = TabBarSpace + 64.dp) {
            if (ending == Status.PAUSED) {
                item {
                    Cell(Edge.ONLY) {
                        Icon(Symbols.ExclamationCircleFill, null, Modifier.size(22.dp), tint = p.orange)
                        Spacer(Modifier.width(12.dp))
                        Text("已停止：剩下的書需要處理", style = Type.body, color = p.orange)
                    }
                }
                gap(20.dp)
            }
            // A queue stopped by something other than a book has no book's button that answers it.
            if (queue.canResume) {
                item {
                    Cell(Edge.ONLY, onClick = { app.requestResume() }, chevron = false) {
                        Text("全部繼續", style = Type.body, color = p.accent)
                    }
                }
                queue.lastError?.let { footer(it) }
                gap(20.dp)
            }
            group(queue.jobs, key = { it.id }) { job, edge -> Cell(edge) { DownloadJobRow(job, queue, showsTitle = true) } }
            if (queue.jobs.isEmpty()) {
                item {
                    Box(Modifier.fillParentMaxHeight(0.7f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                        if (ending == Status.FINISHED) {
                            EmptyState(Symbols.CheckmarkCircleFill, "全部下載完成", "")
                        } else {
                            EmptyState(Symbols.ArrowDownCircle, "目前沒有下載", "")
                        }
                    }
                }
            }
        }
        // At the bottom, where the countdown then takes its place: the phone is put down and
        // picked up again by the same thumb.
        when (val current = phase) {
            is DownloadFocus.Phase.Counting -> BottomBar(Modifier.align(Alignment.BottomCenter)) {
                Text("${current.left} 秒後螢幕變黑", style = Type.footnote.copy(fontFeatureSettings = TABULAR), color = p.label, modifier = Modifier.weight(1f))
                BorderedButton("結束專注") { app.focus.stop() }
            }
            // Only over a running queue: a stopped one is resumed first, with the screen lit.
            DownloadFocus.Phase.Off -> if (queue.isBusy) {
                ProminentButton(
                    "專注下載",
                    Modifier.align(Alignment.BottomCenter).navigationBarsPadding()
                        .padding(start = Margin, end = Margin, bottom = 62.dp + 8.dp + 10.dp).fillMaxWidth(),
                    icon = Symbols.MoonFill,
                ) {
                    ending = null
                    app.focus.start()
                }
            }
            DownloadFocus.Phase.Dark -> Unit
        }
    }
}

/**
 * Keeps the app on screen while the queue runs, with the screen black — the phone left on a
 * table to download, without locking it and stopping the queue. Counts down first, so the
 * reader sees the queue each time a tap lights the screen. Root applies the phase to the window.
 */
class DownloadFocus(private val scope: CoroutineScope, private val seconds: Int = 10) {
    sealed interface Phase {
        data object Off : Phase
        data class Counting(val left: Int) : Phase
        data object Dark : Phase
    }

    private val mutablePhase = MutableStateFlow<Phase>(Phase.Off)
    val phase: StateFlow<Phase> = mutablePhase
    private var ticker: Job? = null

    fun start() {
        if (phase.value != Phase.Off) return
        countDown()
    }

    /** A tap on the black: the queue comes back, and the countdown starts over. */
    fun wake() {
        if (phase.value != Phase.Dark) return
        countDown()
    }

    fun stop() {
        if (phase.value == Phase.Off) return
        ticker?.cancel()
        ticker = null
        mutablePhase.value = Phase.Off
    }

    private fun countDown() {
        ticker?.cancel()
        mutablePhase.value = Phase.Counting(seconds)
        ticker = scope.launch {
            for (left in seconds - 1 downTo 0) {
                delay(1_000)
                mutablePhase.value = if (left > 0) Phase.Counting(left) else Phase.Dark
            }
        }
    }
}

/**
 * The iOS `StorageView`: what the reader asked to keep, per site and per book. Downloads only —
 * what reading leaves behind is the cache's, and mixing the totals would make this one mean nothing.
 */
@Composable
fun StorageScreen() {
    val app = app()
    val nav = LocalNavigator.current
    val p = LocalPalette.current
    val scope = rememberCoroutineScope()
    val shelf by remember { app.library.shelf() }.collectAsState(emptyList())
    val sizes by remember { app.downloadSizes() }.collectAsState(emptyList())
    val rules by app.sites.rules.collectAsState()
    var confirming by remember { mutableStateOf(false) }
    val bookBytes = sizes.associate { it.bookId to it.bytes }
    val total = sizes.sumOf { it.bytes }
    // Only books with something downloaded: a shelf of zeroes buries the one number this is for.
    val groups = shelf.map { it.book }.filter { (bookBytes[it.id] ?: 0) > 0 }.groupBy { it.siteId }
        .map { (siteId, books) -> Triple(siteId, sourceName(siteId, rules), books) }
        .sortedBy { it.second }

    // Reclaiming space is routine; destroying the only copy of an imported file is not.
    var confirmingLocal by remember { mutableStateOf<List<Book>?>(null) }
    fun apply(books: List<Book>) = scope.launch { books.forEach { app.deleteBookDownloads(it.id) } }

    ListScreen("下載", onBack = nav::pop) {
        item { Cell(Edge.TOP) { Labeled("全部下載", bytes(total)) } }
        item {
            Cell(Edge.BOTTOM, onClick = { if (total > 0) confirming = true }, chevron = false) {
                Text("刪除所有下載", style = Type.body, color = if (total > 0) p.red else p.tertiary)
            }
        }
        footer("你要求保留在裝置上的章節。除了你自己，沒有東西會刪掉它們。")
        for ((siteId, name, books) in groups) {
            header(name, key = "site:$siteId") {
                Text(bytes(books.sumOf { bookBytes[it.id] ?: 0 }), style = Type.sectionHeader, color = p.secondary)
            }
            group(books, key = { it.id }) { book, edge ->
                Cell(
                    if (edge == Edge.ONLY) Edge.TOP else if (edge == Edge.BOTTOM) Edge.MIDDLE else edge,
                    onDelete = { apply(listOf(book)) },
                    deleteConfirmation = if (book.isLocal) LOCAL_DELETE else null,
                ) {
                    Labeled(book.shownName, bytes(bookBytes[book.id] ?: 0))
                }
            }
            item(key = "deleteSite:$siteId") {
                Cell(Edge.BOTTOM, onClick = { if (books.any { it.isLocal }) confirmingLocal = books else apply(books) }, chevron = false) {
                    Text("刪除這些下載", style = Type.body, color = p.red)
                }
            }
        }
    }
    confirmingLocal?.let { books ->
        ActionSheet(
            LOCAL_DELETE, "刪除",
            onAction = {
                confirmingLocal = null
                apply(books)
            },
            onDismiss = { confirmingLocal = null },
        )
    }
    if (confirming) {
        ActionSheet(
            "所有已下載的章節都會被刪除，書籤與閱讀進度會保留。", "刪除所有下載",
            onAction = {
                confirming = false
                scope.launch { app.deleteBookDownloads(null) }
            },
            onDismiss = { confirming = false },
        )
    }
}

/**
 * The iOS `CacheView`: what the app kept without being asked, and the ways to take it back. The
 * chapter cache is listed per book, since this is opened to find which book is eating the disk;
 * the web's is one number and one button, with nothing inside it to aim at, and the fetched
 * covers go with it. Everything here can be fetched again, so nothing asks.
 */
@Composable
fun CacheScreen() {
    val app = app()
    val nav = LocalNavigator.current
    val p = LocalPalette.current
    val scope = rememberCoroutineScope()
    val shelf by remember { app.library.shelf() }.collectAsState(emptyList())
    val rules by app.sites.rules.collectAsState()
    val texts by remember { app.library.cacheSizes() }.collectAsState(emptyList())
    // Pages and the web's cache are files, which no flow follows: counted on the way in, and
    // again whenever something here removes some.
    var counts by remember { mutableIntStateOf(0) }
    var pages by remember { mutableStateOf(emptyMap<String, Long>()) }
    var web by remember { mutableLongStateOf(0L) }
    var clearingWeb by remember { mutableStateOf(false) }
    LaunchedEffect(shelf, counts) {
        val comics = shelf.map { it.book }.filter { it.kind == SiteRule.Kind.COMIC }
        pages = withContext(Dispatchers.IO) { comics.associate { it.id to app.comics.cachedBytes(it.id) } }
        web = withContext(Dispatchers.IO) { CacheLimit.webBytes(app.cacheDir) }
    }

    fun clearWeb() {
        clearingWeb = true
        // Cookies stay: they carry the sites' verification, which would otherwise be asked again.
        app.fetcher.webView.clearCache(true)
        scope.launch {
            withContext(Dispatchers.IO) { app.covers.clearCache() }
            // ponytail: clearCache returns before Chromium has deleted anything and has no
            // callback, so the recount waits a fixed second; a slow disk shows part of the old
            // number until the next visit. Recount until it holds still if that turns up.
            delay(1_000)
            counts++
            clearingWeb = false
        }
    }
    val bookBytes = texts.associate { it.bookId to it.bytes } + pages.filterValues { it > 0 }
    val used = bookBytes.values.sum()
    // Only books with something cached: the whole library would be a list of zeroes with the answer buried in it.
    val groups = shelf.map { it.book }.filter { (bookBytes[it.id] ?: 0) > 0 }.groupBy { it.siteId }
        .map { (siteId, books) -> Triple(siteId, sourceName(siteId, rules), books) }
        .sortedBy { it.second }
    // In steps, as the slider moves; applied when the finger lifts, so dragging down does not
    // evict at every stop on the way.
    var steps by remember { mutableIntStateOf((app.cacheLimit.limit / CacheLimit.STEP).toInt()) }
    // Read once: how much room the disk has is a syscall, and this redraws on every number landing.
    val free = remember { app.cacheDir.usableSpace }
    // Never below what is set, or touching the slider would lower a limit chosen on an emptier day.
    val top = (maxOf(CacheLimit.ceiling(free), app.cacheLimit.limit) / CacheLimit.STEP).toInt()
    ListScreen("快取", onBack = nav::pop) {
        header("看過的章節")
        item { Cell(Edge.TOP) { Labeled("已使用", bytes(used)) } }
        item {
            Cell(Edge.MIDDLE) {
                Column(Modifier.weight(1f)) {
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) { Labeled("上限", bytes(steps * CacheLimit.STEP)) }
                    IosSlider(steps, (CacheLimit.MINIMUM / CacheLimit.STEP).toInt()..top, 1, { steps = it }) {
                        scope.launch {
                            app.cacheLimit.set(steps * CacheLimit.STEP)
                            counts++
                        }
                    }
                }
            }
        }
        item { Cell(Edge.MIDDLE) { Labeled("此裝置可用空間", bytes(free)) } }
        item {
            Cell(Edge.BOTTOM, onClick = {
                    if (used > 0) {
                        scope.launch {
                            app.clearCache(null)
                            counts++
                        }
                    }
                }, chevron = false) {
                Text("清除章節快取", style = Type.body, color = if (used > 0) p.red else p.tertiary)
            }
        }
        footer("線上看過的章節文字與圖片。快取到達上限時，會先丟掉最久沒再打開的章節。已下載的章節不受影響。")
        for ((siteId, name, books) in groups) {
            header(name, key = "site:$siteId")
            group(books, key = { it.id }) { book, edge ->
                // No confirmation, unlike a download: all of it can be read again, and most of it
                // the limit throws away anyway.
                Cell(edge, onDelete = { scope.launch { app.clearCache(book.id); counts++ } }) {
                    Labeled(book.shownName, bytes(bookBytes[book.id] ?: 0))
                }
            }
        }
        header("其他快取")
        item { Cell(Edge.TOP) { Labeled("網頁與封面", bytes(web)) } }
        item {
            Cell(Edge.BOTTOM, onClick = if (clearingWeb) null else ::clearWeb, chevron = false) {
                Text("清除網頁與封面快取", style = Type.body, color = if (clearingWeb) p.tertiary else p.accent)
            }
        }
        footer("清除後網頁與封面要重新下載，已下載的章節與章節快取不受影響。網站的驗證狀態（cookie）會保留，不必重新完成人機驗證。")
    }
}
