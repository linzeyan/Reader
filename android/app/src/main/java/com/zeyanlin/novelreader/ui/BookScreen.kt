package com.zeyanlin.novelreader.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.zeyanlin.novelreader.data.Book
import com.zeyanlin.novelreader.data.Chapter
import com.zeyanlin.novelreader.services.BookExporter
import com.zeyanlin.novelreader.services.FeedService
import com.zeyanlin.novelreader.siterules.SiteRule
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.DateFormat
import java.util.Date

/** The iOS `BookDetailView`: the book, a way back into it, and its chapter index. */
@Composable
fun BookScreen(bookId: String) {
    val app = app()
    val nav = LocalNavigator.current
    val p = LocalPalette.current
    val scope = rememberCoroutineScope()
    val book by remember(bookId) { app.library.book(bookId) }.collectAsState(null)
    val chapters by remember(bookId) { app.library.chapters(bookId) }.collectAsState(null)
    val rules by app.sites.rules.collectAsState()
    val queue by app.downloads.state.collectAsState()
    var refreshing by remember { mutableStateOf(false) }
    // Null until the reader flips it: the default is the medium's, and the book has not loaded yet.
    var chosenOrder by remember { mutableStateOf(chosenDescending(app.prefs, bookId)) }

    fun refresh(book: Book) {
        if (refreshing) return
        refreshing = true
        scope.launch {
            try {
                app.refreshCatalog(book)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                app.report(e, "App 正在更新《${book.shownName}》的目錄。")
            } finally {
                refreshing = false
            }
        }
    }

    // Exporting: 0…1 while one runs (so it doubles as busy), the job for the banner's cancel,
    // the format waiting on the partial question, and the finished file waiting for a place.
    var exportProgress by remember { mutableStateOf<Double?>(null) }
    var exportJob by remember { mutableStateOf<Job?>(null) }
    var partial by remember { mutableStateOf<BookExporter.Format?>(null) }
    var pending by remember { mutableStateOf<BookExporter.Export?>(null) }
    var exportMenu by remember { mutableStateOf(false) }
    val context = LocalContext.current

    // The file was written to cache so a novel never sat in memory; once copied, it is waste.
    fun save(uri: android.net.Uri?) {
        val export = pending ?: return
        pending = null
        scope.launch {
            try {
                if (uri != null) withContext(Dispatchers.IO) {
                    context.contentResolver.openOutputStream(uri, "wt")!!.use { out -> export.file.inputStream().use { it.copyTo(out) } }
                }
            } catch (e: Exception) {
                app.report(e, "App 正在匯出《${export.filename}》。")
            } finally {
                export.file.delete()
            }
        }
    }
    val saveText = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument(BookExporter.Format.TEXT.mime)) { save(it) }
    val saveEpub = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument(BookExporter.Format.EPUB.mime)) { save(it) }
    val saveZip = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument(BookExporter.Format.COMIC.mime)) { save(it) }

    fun startExport(book: Book, format: BookExporter.Format) {
        partial = null
        exportProgress = 0.0
        exportJob = scope.launch {
            try {
                val export = app.export(book, format) { exportProgress = it }
                pending = export
                val name = "${export.filename}.${format.extension}"
                when (format) {
                    BookExporter.Format.TEXT -> saveText
                    BookExporter.Format.EPUB -> saveEpub
                    BookExporter.Format.COMIC -> saveZip
                }.launch(name)
            } catch (e: CancellationException) {
                // The reader's own decision; the banner going away is the answer.
            } catch (e: Exception) {
                app.report(e, "App 正在匯出《${book.shownName}》。")
            } finally {
                exportProgress = null
                exportJob = null
            }
        }
    }

    val b = book ?: return Box(Modifier.fillMaxSize())
    val rule = rules.firstOrNull { it.id == b.siteId }
    // A subscription is read through its own service: no rule stands behind one, ever.
    val feed = b.kind == SiteRule.Kind.FEED
    val descending = chosenOrder ?: feed
    LaunchedEffect(b.id) { if (b.catalogIsStale && (rule != null || feed)) refresh(b) }
    val downloaded = chapters?.count { it.downloadedAt != null } ?: 0
    val unread = if (feed) chapters?.count { it.readAt == null } ?: 0 else 0
    var copying by remember { mutableStateOf<Chapter?>(null) }
    val clipboard = LocalClipboardManager.current
    // Kept while the reader is on top, as the iOS screen underneath keeps it: back from a result, the
    // list is still the one that was searched.
    var query by rememberSaveable { mutableStateOf("") }
    val focus = LocalFocusManager.current

    // Asked before the file is written: someone exporting to read elsewhere needs the chance to
    // download the rest first.
    fun beginExport(format: BookExporter.Format) {
        exportMenu = false
        if (downloaded < (chapters?.size ?: 0)) partial = format else startExport(b, format)
    }

    Box(Modifier.fillMaxSize()) {
        ListScreen(
            b.shownName,
            onBack = nav::pop,
            actions = {
                if (rule != null || feed) {
                    if (refreshing) {
                        Box(Modifier.size(44.dp), contentAlignment = Alignment.Center) { Spinner() }
                    } else {
                        BarButton(Symbols.ArrowClockwise, if (feed) "重新整理訂閱源" else "重新整理目錄") { refresh(b) }
                    }
                }
                // Beside refresh, not among the actions below: those hide when the rule has gone,
                // which is exactly when rescuing the text still on the device matters most.
                // Disabled rather than hidden: the header already says how much is downloaded.
                if (exportProgress != null) {
                    Box(Modifier.size(44.dp), contentAlignment = Alignment.Center) { Spinner() }
                } else {
                    Box {
                        // A subscription's menu adds the one action about the whole of it, first, with the
                        // count that says why it is disabled when it is.
                        if (feed) {
                            BarButton(Symbols.EllipsisCircle, "更多") { exportMenu = true }
                        } else {
                            // A comic's one button, as on iOS: there is one thing it can be written out as.
                            BarButton(Symbols.SquareAndArrowUp, "匯出", enabled = downloaded > 0) {
                                if (b.kind == SiteRule.Kind.COMIC) beginExport(BookExporter.Format.COMIC) else exportMenu = true
                            }
                        }
                        DropdownMenu(exportMenu, { exportMenu = false }, shape = RoundedCornerShape(20.dp), containerColor = p.card) {
                            if (feed) {
                                DropdownMenuItem(
                                    text = { Text("全部標為已讀（$unread）", style = Type.body) },
                                    trailingIcon = { Icon(Symbols.EnvelopeOpen, null) },
                                    enabled = unread > 0,
                                    onClick = {
                                        exportMenu = false
                                        scope.launch { app.library.markAllRead(b.id) }
                                    },
                                )
                                androidx.compose.material3.HorizontalDivider(color = p.separator)
                            }
                            DropdownMenuItem(
                                text = { Text("純文字（.txt）", style = Type.body) },
                                trailingIcon = { Icon(Symbols.Doc, null) },
                                enabled = downloaded > 0,
                                onClick = { beginExport(BookExporter.Format.TEXT) },
                            )
                            DropdownMenuItem(
                                text = { Text("EPUB（.epub）", style = Type.body) },
                                trailingIcon = { Icon(Symbols.BookClosed, null) },
                                enabled = downloaded > 0,
                                onClick = { beginExport(BookExporter.Format.EPUB) },
                            )
                        }
                    }
                }
            },
        ) {
            val list = chapters
            // Always shown, as iOS's drawer is: filtering as it is typed, so the key only puts the keyboard away.
            item { SearchField(query, { query = it }, if (feed) "搜尋文章" else "搜尋章節", Modifier.padding(bottom = 16.dp), onSearch = { focus.clearFocus() }) }
            item {
                Cell(Edge.ONLY, verticalPadding = 17.dp) {
                    Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.Top) {
                        Cover(72.dp, 100.dp, b)
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text(b.shownName, style = Type.headline, color = p.label)
                            b.author?.takeIf { it.isNotEmpty() }?.let { Text(it, style = Type.subheadline, color = p.secondary) }
                            Text(sourceName(b.siteId, rules), style = Type.caption, color = p.tertiary)
                            if (list != null) {
                                // "Downloaded" is a word for something asked for; a feed's articles arrive with the
                                // refresh and leave with retention, so what is said is how much is still here.
                                Text(
                                    if (feed) "裝置上有 $downloaded / ${list.size} 篇" else "已下載 $downloaded / ${list.size} 章",
                                    style = Type.caption.copy(fontFeatureSettings = TABULAR), color = p.secondary,
                                )
                            }
                        }
                    }
                }
            }
            // An imported book has no rule by design; nothing about that needs saying.
            if (rule == null && !b.isLocal && !feed) {
                gap()
                item {
                    Cell(Edge.ONLY) {
                        Icon(Symbols.ExclamationTriangle, null, Modifier.size(22.dp), tint = p.orange)
                        Spacer(Modifier.width(12.dp))
                        Text("這本書的來源規則已被移除，重新加入後即可繼續閱讀。", style = Type.subheadline, color = p.label)
                    }
                }
            }
            gap()
            // A comic has no text to anchor a mark to, and is not waiting for one: hidden, not disabled.
            val marks = b.kind != SiteRule.Kind.COMIC
            val actions = 1 + (if (marks) 1 else 0) + (if (rule != null) 1 else 0)
            item {
                Cell(Edge.of(0, actions), onClick = { nav.push(Route.Reader(b.id)) }, separatorStart = RowPadding + 40.dp) {
                    Icon(Symbols.BookOpen, null, Modifier.size(26.dp), tint = p.accent)
                    Spacer(Modifier.width(14.dp))
                    Text(
                        if (b.lastReadSiteChapterId != null) "繼續閱讀" else "開始閱讀",
                        style = Type.body, color = p.label, modifier = Modifier.weight(1f),
                    )
                }
            }
            // Always present and uncounted: a row that appears only once used is never found, and a
            // count here would be stale the moment the reader on top of this screen adds a mark.
            if (marks) {
                item {
                    Cell(Edge.of(1, actions), onClick = { nav.push(Route.Marks(b.id)) }, separatorStart = RowPadding + 40.dp) {
                        Icon(Symbols.Bookmark, null, Modifier.size(26.dp), tint = p.accent)
                        Spacer(Modifier.width(14.dp))
                        Text("標記", style = Type.body, color = p.label, modifier = Modifier.weight(1f))
                    }
                }
            }
            // One entry point rather than "download all" and "delete all": both live on the
            // management screen, next to the per-chapter selection that makes them make sense.
            if (rule != null) {
                item {
                    val enabled = !list.isNullOrEmpty()
                    Cell(Edge.of(actions - 1, actions), onClick = { if (enabled) nav.push(Route.ChapterDownloads(b.id)) }) {
                        Icon(Symbols.ArrowDownCircle, null, Modifier.size(26.dp), tint = if (enabled) p.accent else p.tertiary)
                        Spacer(Modifier.width(14.dp))
                        Text("下載管理", style = Type.body, color = if (enabled) p.label else p.tertiary, modifier = Modifier.weight(1f))
                    }
                }
                queue.job(b.id)?.let { job -> bookDownloadSection(job, queue) { nav.push(Route.DownloadQueue) } }
            }
            header(if (feed) "文章（${list?.size ?: 0} 篇）" else "目錄（${list?.size ?: 0} 章）", key = "catalogHeader") {
                OrderToggle(descending) {
                    val flipped = !descending
                    chosenOrder = flipped
                    app.prefs.edit().putBoolean(DESCENDING + bookId, flipped).apply()
                }
            }
            when {
                list == null || (list.isEmpty() && refreshing) -> item { CatalogNote(if (feed) "正在讀取訂閱源…" else "正在讀取目錄…") }
                list.isEmpty() -> item { CatalogNote(if (feed) "還沒有取得文章，試試重新整理。" else "沒有取得章節，試試重新整理。") }
                else -> {
                    val trimmed = query.trim()
                    // No pinned row while searching: the list is being used to find something, and a
                    // row that does not match what was typed is not a result.
                    val last = if (trimmed.isEmpty()) list.firstOrNull { it.siteChapterId == b.lastReadSiteChapterId } else null
                    val matched = if (trimmed.isEmpty()) list else list.filter { it.title.contains(trimmed, ignoreCase = true) }
                    // Once for the list: per row it would scan the catalog for every chapter drawn.
                    val lastReadIndex = b.lastReadIndex(list)
                    val rows: List<Chapter?> = (if (last != null) listOf(null) else emptyList<Chapter?>()) +
                        (if (descending) matched.asReversed() else matched)
                    group(rows, key = { it?.id ?: "lastRead" }) { chapter, edge ->
                        if (chapter == null) {
                            Cell(edge, onClick = { nav.push(Route.Reader(b.id)) }, verticalPadding = 11.dp) {
                                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                    Text("上次讀到", style = Type.caption2, color = p.secondary)
                                    Text(last!!.title, style = Type.body, color = p.label, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                }
                                b.lastReadFraction?.let {
                                    Text(percent(it), style = Type.caption.copy(fontFeatureSettings = TABULAR), color = p.secondary)
                                }
                            }
                        } else if (feed) {
                            val isUnread = chapter.readAt == null
                            Cell(
                                edge,
                                onClick = { nav.push(Route.Reader(b.id, chapter.siteChapterId)) },
                                // Only where the publisher gave it an address: a menu that copied nothing is worse than none.
                                onLongClick = if (FeedService.isWeb(chapter.url)) ({ copying = chapter }) else null,
                                // No confirmation: it is undone the same way, a row at a time.
                                leadingSwipe = SwipeAction(
                                    if (isUnread) "標為已讀" else "標為未讀",
                                    if (isUnread) Symbols.EnvelopeOpen else Symbols.Envelope,
                                    if (isUnread) p.blue else androidx.compose.ui.graphics.Color(0xFF8E8E93),
                                ) {
                                    scope.launch { app.library.setArticlesRead(listOf(chapter.id), if (isUnread) System.currentTimeMillis() else null) }
                                },
                            ) {
                                ArticleTitle(chapter, Modifier.weight(1f))
                            }
                        } else {
                            Cell(edge, onClick = { nav.push(Route.Reader(b.id, chapter.siteChapterId)) }) {
                                ChapterTitle(chapter, chapter.isMarked(b.kind, lastReadIndex), Modifier.weight(1f))
                            }
                        }
                    }
                }
            }
        }
        // The import's banner, for the same reason: a long novel is a minute of one thing, so it
        // says how far along it is and offers a way out.
        AnimatedVisibility(
            exportProgress != null,
            enter = slideInVertically { -it } + fadeIn(),
            exit = slideOutVertically { -it } + fadeOut(),
        ) {
            Banner {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text("正在匯出…", style = Type.footnote, color = p.label)
                    ProgressBar((exportProgress ?: 0.0).toFloat())
                }
                Spacer(Modifier.width(14.dp))
                Text(
                    "取消", style = Type.footnote, color = p.accent, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.clickable { exportJob?.cancel() },
                )
            }
        }
    }
    copying?.let { chapter ->
        ActionSheet(chapter.title, "拷貝連結", destructive = false, onAction = {
            clipboard.setText(AnnotatedString(chapter.url))
            copying = null
        }, onDismiss = { copying = null })
    }
    partial?.let { format ->
        ActionSheet(
            "裝置上只有 $downloaded / ${chapters?.size ?: 0} 章，匯出的檔案只會包含這些章節。", "仍要匯出", destructive = false,
            onAction = { startExport(b, format) }, onDismiss = { partial = null },
        )
    }
}

/** A catalog row's text: primary once downloaded, secondary until then, as on iOS; 「新」 when [marked] ([Chapter.isMarked]). */
@Composable
fun ChapterTitle(chapter: Chapter, marked: Boolean, modifier: Modifier = Modifier) {
    val p = LocalPalette.current
    val downloaded = chapter.downloadedAt != null
    Text(
        chapter.title, style = Type.body, color = if (downloaded) p.label else p.secondary,
        maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = modifier,
    )
    if (marked) {
        Spacer(Modifier.width(8.dp))
        Text("新", style = Type.caption2, color = p.red, fontWeight = FontWeight.SemiBold)
    }
    if (downloaded) {
        Spacer(Modifier.width(8.dp))
        Icon(Symbols.ArrowDownCircleFill, "已下載", Modifier.size(16.dp), tint = p.green)
    }
}

/**
 * An article's row: a headline over two lines — truncated at half, it is the part a reader chooses
 * by — with its date, since in a chronological list when is half of what an article is.
 */
@Composable
private fun RowScope.ArticleTitle(chapter: Chapter, modifier: Modifier = Modifier) {
    val p = LocalPalette.current
    val downloaded = chapter.downloadedAt != null
    Column(modifier, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(chapter.title, style = Type.body, color = if (downloaded) p.label else p.secondary, maxLines = 2, overflow = TextOverflow.Ellipsis)
        chapter.publishedAt?.let {
            Text(DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(it)), style = Type.caption2, color = p.tertiary)
        }
    }
    // The same word a novel's new chapter wears: to someone scanning, both mean "this is the one to open".
    if (chapter.readAt == null) {
        Spacer(Modifier.width(8.dp))
        Text("新", style = Type.caption2, color = p.red, fontWeight = FontWeight.SemiBold)
    }
    if (downloaded) {
        Spacer(Modifier.width(8.dp))
        Icon(Symbols.ArrowDownCircleFill, "已下載", Modifier.size(16.dp), tint = p.green)
    }
}

@Composable
private fun OrderToggle(descending: Boolean, onToggle: () -> Unit) {
    val p = LocalPalette.current
    Row(
        Modifier.clickable(onClick = onToggle).padding(vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(if (descending) Symbols.ArrowUp else Symbols.ArrowDown, null, Modifier.size(14.dp), tint = p.accent)
        Text(if (descending) "倒序" else "正序", style = Type.caption2, color = p.accent)
    }
}

@Composable
private fun CatalogNote(text: String) {
    Cell(Edge.ONLY) { Text(text, style = Type.body, color = LocalPalette.current.secondary) }
}

private const val DESCENDING = "catalog.descending."

private fun chosenDescending(prefs: android.content.SharedPreferences, bookId: String) =
    if (prefs.contains(DESCENDING + bookId)) prefs.getBoolean(DESCENDING + bookId, false) else null

/** Newest first for a subscription, as on iOS — it is read from the top — and a book from its first chapter. */
fun isDescending(prefs: android.content.SharedPreferences, bookId: String, feed: Boolean) = chosenDescending(prefs, bookId) ?: feed
