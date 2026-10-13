package com.zeyanlin.novelreader.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import com.zeyanlin.novelreader.App
import com.zeyanlin.novelreader.data.Book
import com.zeyanlin.novelreader.data.LIBRARY_GROUPING
import com.zeyanlin.novelreader.data.LIBRARY_SORT
import com.zeyanlin.novelreader.data.LibraryGrouping
import com.zeyanlin.novelreader.data.LibrarySort
import com.zeyanlin.novelreader.data.ONLY_WITH_NEW_CHAPTERS
import com.zeyanlin.novelreader.data.ShelfGroup
import com.zeyanlin.novelreader.data.ShelfRow
import com.zeyanlin.novelreader.data.shelfSections
import com.zeyanlin.novelreader.describe
import com.zeyanlin.novelreader.services.FeedService
import com.zeyanlin.novelreader.services.SiteStore
import com.zeyanlin.novelreader.siterules.SiteRule
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.LocalDate
import kotlin.math.roundToInt

/** The iOS `LibraryView`: the shelf of one medium, divided as the reader chose, each heading foldable. */
@Composable
fun LibraryScreen() {
    val app = app()
    val nav = LocalNavigator.current
    val p = LocalPalette.current
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val all by remember { app.library.shelf() }.collectAsState(null)
    val mode by app.mediaMode.collectAsState()
    val rows = all?.filter { it.book.kind == mode }
    val feeds = mode == SiteRule.Kind.FEED
    val rules by app.sites.rules.collectAsState()
    val additions by app.additions.collectAsState()
    val importing by app.importProgress.collectAsState()
    var adding by rememberSaveable { mutableStateOf(false) }
    var feedMenu by remember { mutableStateOf(false) }
    var confirmingMarkAllRead by remember { mutableStateOf(false) }
    // Only the types this app reads. Opening a file from another app is a separate feature,
    // as on iOS: it needs the manifest to claim the types for every app on the device.
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) app.importFile(uri)
    }
    // Both names a ZIP goes by: a file that arrived from Windows is often filed under the second.
    val pick = { picker.launch(if (mode == SiteRule.Kind.COMIC) arrayOf("application/zip", "application/x-zip-compressed") else arrayOf("text/plain", "application/epub+zip")) }
    // A subscription list travels as OPML, which hardly any system names a type for: both the
    // types it might be filed under, or the picker greys out the very file the reader exported.
    val opmlPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) scope.launch {
            try {
                app.importSubscriptions(uri)
                adding = true
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                app.report(e, "App 正在匯入訂閱。")
            }
        }
    }
    val opmlSaver = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("text/x-opml")) { uri ->
        if (uri != null) scope.launch {
            try {
                val document = app.subscriptionsDocument()
                withContext(Dispatchers.IO) { context.contentResolver.openOutputStream(uri, "wt")!!.use { it.write(document.toByteArray()) } }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                app.report(e, "App 正在匯出訂閱。")
            }
        }
    }
    val unread = rows?.sumOf { it.unread } ?: 0
    var folded by remember { mutableStateOf(app.prefs.getStringSet(FOLDED, emptySet())!!.toSet()) }
    var sort by remember { mutableStateOf(LibrarySort.from(app.prefs.getString(LIBRARY_SORT, null))) }
    var grouping by remember { mutableStateOf(LibraryGrouping.from(app.prefs.getString(LIBRARY_GROUPING, null))) }
    fun toggle(id: String) {
        folded = if (id in folded) folded - id else folded + id
        app.prefs.edit().putStringSet(FOLDED, folded).apply()
    }
    var onlyUnread by remember { mutableStateOf(app.prefs.getBoolean(ONLY_WITH_NEW_CHAPTERS, false)) }
    fun showOnlyUnread(on: Boolean) {
        onlyUnread = on
        app.prefs.edit().putBoolean(ONLY_WITH_NEW_CHAPTERS, on).apply()
    }
    var arranging by remember { mutableStateOf(false) }
    // A book's name and the address the long press offers to copy.
    var copying by remember { mutableStateOf<Pair<String, String>?>(null) }
    var renaming by remember { mutableStateOf<Book?>(null) }
    // The row a swipe left open. One at a time, shut by the next touch anywhere on the shelf — and that
    // touch does nothing else, as on iOS — so it is held here, where every row can see it.
    var swiped by remember { mutableStateOf<String?>(null) }
    fun unlessSwiped(action: () -> Unit) {
        if (swiped != null) swiped = null else action()
    }
    val listState = rememberLazyListState()
    LaunchedEffect(listState) { snapshotFlow { listState.isScrollInProgress }.collect { if (it) swiped = null } }
    val clipboard = LocalClipboardManager.current

    Box(Modifier.fillMaxSize()) {
        ListScreen(
            "書櫃",
            large = true,
            state = listState,
            leading = {
                // A menu, not controls on the shelf: these are set once and left alone for weeks. Hidden on
                // an empty shelf, where there is nothing to arrange.
                if (!rows.isNullOrEmpty()) {
                    Box {
                        ArrangeButton(onlyUnread) { arranging = true }
                        DropdownMenu(arranging, { arranging = false }, shape = RoundedCornerShape(20.dp), containerColor = p.card) {
                            for (option in LibrarySort.entries) {
                                MenuChoice(option.label, option == sort) {
                                    arranging = false
                                    sort = option
                                    app.prefs.edit().putString(LIBRARY_SORT, option.raw).apply()
                                }
                            }
                            // Unlabelled, as on iOS: what keeps this run readable is that it opens with 不分組,
                            // which no reader takes for a sort order. Feeds have no author to divide by.
                            HorizontalDivider(color = p.separator)
                            for (option in LibraryGrouping.entries.filter { !feeds || !it.reachesAuthors }) {
                                MenuChoice(option.label, option == grouping) {
                                    arranging = false
                                    grouping = option
                                    app.prefs.edit().putString(LIBRARY_GROUPING, option.raw).apply()
                                }
                            }
                            HorizontalDivider(color = p.separator)
                            MenuChoice(if (feeds) "只顯示有未讀的訂閱源" else "只顯示有新章的書", onlyUnread) {
                                arranging = false
                                showOnlyUnread(!onlyUnread)
                            }
                        }
                    }
                }
                // Never hidden: switching is how someone gets off an empty shelf and back to the books they have.
                MediaModePicker(mode) { app.mediaMode.value = it }
            },
            actions = {
                BarButton(Symbols.Plus, if (feeds) "新增訂閱" else "加入書籍", enabled = importing == null) { adding = true }
                if (feeds) {
                    // One menu, because a subscription list goes both ways: OPML is how forty feeds
                    // arrive from another reader, and a way out is what makes putting them in safe.
                    Box {
                        BarButton(Symbols.EllipsisCircle, "訂閱", enabled = additions.none { it.state == App.Addition.State.WAITING || it.state == App.Addition.State.RUNNING }) { feedMenu = true }
                        DropdownMenu(feedMenu, { feedMenu = false }, shape = RoundedCornerShape(20.dp), containerColor = p.card) {
                            DropdownMenuItem(
                                text = { Text("所有訂閱標為已讀", style = Type.body) },
                                trailingIcon = { Icon(Symbols.EnvelopeOpen, null) },
                                enabled = unread > 0,
                                onClick = {
                                    feedMenu = false
                                    confirmingMarkAllRead = true
                                },
                            )
                            HorizontalDivider(color = p.separator)
                            DropdownMenuItem(
                                text = { Text("匯入訂閱", style = Type.body) },
                                trailingIcon = { Icon(Symbols.SquareAndArrowDown, null) },
                                onClick = {
                                    feedMenu = false
                                    opmlPicker.launch(arrayOf("text/x-opml", "text/xml", "application/xml", "application/octet-stream"))
                                },
                            )
                            DropdownMenuItem(
                                text = { Text("匯出訂閱", style = Type.body) },
                                trailingIcon = { Icon(Symbols.SquareAndArrowUp, null) },
                                enabled = !rows.isNullOrEmpty(),
                                onClick = {
                                    feedMenu = false
                                    // Dated, largest part first: what this file is for is keeping, and a folder of them sorts by when.
                                    opmlSaver.launch("subscriptions-${LocalDate.now()}.opml")
                                },
                            )
                        }
                    }
                } else {
                    // Two buttons rather than a menu, as on iOS: one fetches from a site, the other
                    // reads a file already on the device, and neither is worth an extra tap.
                    BarButton(Symbols.SquareAndArrowDown, "匯入檔案", enabled = importing == null, onClick = pick)
                }
            },
            // Feeds only: a pull that spins and changes nothing is worse than no gesture, and forty
            // catalogs behind one gesture would hold the shared web view for a minute.
            onRefresh = if (feeds) ({ app.refreshFeeds(force = true) }) else null,
        ) {
            val list = rows ?: return@ListScreen
            if (list.isEmpty()) {
                item {
                    Box(Modifier.fillParentMaxHeight(0.75f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                        // Not gated on having a source: a pasted address with no rule behind it
                        // is where one gets worked out. iOS also says "用搜尋"; not ported yet.
                        when (mode) {
                            SiteRule.Kind.FEED -> EmptyState(Symbols.Newspaper, "還沒有訂閱", "貼上訂閱源的網址就能加入，一次可以貼很多個。") {
                                ProminentButton("新增訂閱") { adding = true }
                            }
                            SiteRule.Kind.COMIC -> EmptyState(Symbols.PhotoStack, "漫畫櫃是空的", "貼上網址加入第一本漫畫。") {
                                ProminentButton("加入書籍") { adding = true }
                            }
                            SiteRule.Kind.NOVEL -> EmptyState(Symbols.BookClosed, "書櫃是空的", "貼上網址加入第一本書。") {
                                ProminentButton("加入書籍") { adding = true }
                                Spacer(Modifier.height(10.dp))
                                BorderedButton("匯入檔案", onClick = pick)
                            }
                        }
                    }
                }
                return@ListScreen
            }
            val sections = shelfSections(list, sort, grouping.on(mode), onlyUnread) { sourceName(it, rules) }
            if (sections.isEmpty()) {
                item {
                    Box(Modifier.fillParentMaxHeight(0.75f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                        // The way out is the point: a filter that survives a relaunch and hides everything
                        // reads as a shelf that has been lost.
                        EmptyState(Symbols.BellSlash, if (feeds) "沒有訂閱源有未讀文章" else "沒有書有新章節", null) {
                            ProminentButton("顯示全部書籍") { showOnlyUnread(false) }
                        }
                    }
                }
                return@ListScreen
            }
            for ((index, section) in sections.withIndex()) {
                val name = section.name
                if (name != null) {
                    item(key = "section:${section.id}") {
                        SectionToggle(name, section.count, section.id in folded) { unlessSwiped { toggle(section.id) } }
                    }
                    if (section.id in folded) continue
                } else if (index > 0) {
                    // The books under no heading, after the authors': a card of their own, not the last author's.
                    gap()
                }
                // Authors above the loose books, as on iOS: interleaved, a row that is sometimes a group and
                // sometimes a book would reshuffle as the reader reads.
                val entries = section.groups.flatMap { listOf(it) + if (it.id in folded) emptyList() else it.rows } + section.rows
                group(entries, key = { if (it is ShelfGroup) "group:${it.id}" else (it as ShelfRow).book.id }) { entry, edge ->
                    if (entry is ShelfGroup) {
                        AuthorToggle(entry, edge, entry.id in folded) { unlessSwiped { toggle(entry.id) } }
                    } else {
                        val row = entry as ShelfRow
                        Cell(
                            edge,
                            onClick = { unlessSwiped { nav.push(Route.BookDetail(row.book.id)) } },
                            // A press rather than a third swipe: the two there change the shelf. Only where
                            // there is an address — an imported file, or a removed source, has none to give.
                            onLongClick = sourceUrl(row.book, rules)?.let { url -> { copying = row.book.shownName to url } },
                            separatorStart = RowPadding + 44.dp + 12.dp,
                            swipe = { content ->
                                ShelfSwipe(
                                    open = swiped == row.book.id,
                                    onOpen = { swiped = if (it) row.book.id else null },
                                    // A subscription's badge is a list of things waiting, and clearing it is part of
                                    // reading rather than an edit — so no confirmation, as per article.
                                    leading = if (feeds && row.unread > 0) {
                                        SwipeAction("標為已讀", Symbols.EnvelopeOpen, p.blue) { scope.launch { app.library.markAllRead(row.book.id) } }
                                    } else {
                                        null
                                    },
                                    // A bookmark can be added again; an imported file cannot, so only it asks.
                                    confirmation = if (row.book.isLocal) LOCAL_DELETE else null,
                                    onDelete = { app.deleteBook(row.book.id) },
                                    onRename = { renaming = row.book },
                                    content = content,
                                )
                            },
                        ) { BookRow(row) }
                    }
                }
            }
        }
        val running = additions.any { it.state == App.Addition.State.WAITING || it.state == App.Addition.State.RUNNING }
        // One at a time, and the import wins: the file is something the reader picked seconds
        // ago, a batch of addresses is deliberately unattended.
        AnimatedVisibility(
            importing != null,
            enter = slideInVertically { -it } + fadeIn(),
            exit = slideOutVertically { -it } + fadeOut(),
        ) {
            Banner {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text("正在匯入…", style = Type.footnote, color = p.label)
                    ProgressBar((importing ?: 0.0).toFloat())
                }
                Spacer(Modifier.width(14.dp))
                Text(
                    "取消", style = Type.footnote, color = p.accent, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.clickable { app.cancelImport() },
                )
            }
        }
        AnimatedVisibility(
            running && !adding && importing == null,
            enter = slideInVertically { -it } + fadeIn(),
            exit = slideOutVertically { -it } + fadeOut(),
        ) {
            Banner {
                val done = additions.count { it.state == App.Addition.State.ADDED || it.state == App.Addition.State.FAILED }
                Spinner(size = 16.dp)
                Text("正在加入 — 已完成 $done / ${additions.size}", style = Type.footnote, color = p.label, modifier = Modifier.weight(1f))
                Text(
                    "停止", style = Type.footnote, color = p.accent, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.clickable { app.stopAdding() },
                )
            }
        }
    }
    if (adding) AddBookSheet { adding = false }
    // As plain text, for an address bar or a message; no confirmation, since pasting shows it worked.
    copying?.let { (name, url) ->
        ActionSheet(name, "複製原始網址", destructive = false, onAction = {
            clipboard.setText(AnnotatedString(url))
            copying = null
        }, onDismiss = { copying = null })
    }
    if (confirmingMarkAllRead) {
        ActionSheet("將所有訂閱裡的文章全部標為已讀？", "全部標為已讀", destructive = false, onAction = {
            confirmingMarkAllRead = false
            scope.launch { app.library.markAllFeedsRead() }
        }, onDismiss = { confirmingMarkAllRead = false })
    }
    renaming?.let { book ->
        // On the shelf's scope: the alert's own goes with it the moment it closes.
        RenameAlert(book, onSave = { name ->
            renaming = null
            scope.launch { app.library.rename(book.id, name) }
        }, onDismiss = { renaming = null })
    }
}

/** Where a shelf row comes to rest when let go. */
internal enum class SwipeRest { CLOSED, OPEN, DELETE, LEAD }

/**
 * The decision iOS's trailing swipe makes on release. [offset] is how far the row was dragged, left
 * negative; [reveal] is how wide its buttons are. Past half the buttons they stay out, and a flick opens
 * or shuts them whatever the distance. Past the midpoint between the buttons and the row's far edge it
 * deletes, as iOS's full swipe does — by distance alone, so speed never deletes by accident. Dragged the
 * other way past [lead], or flicked, it is the leading action; null when the row has none.
 */
internal fun swipeRest(offset: Float, velocity: Float, reveal: Float, width: Float, lead: Float?, fling: Float) = when {
    offset > 0f -> if (lead != null && (offset >= lead || velocity > fling)) SwipeRest.LEAD else SwipeRest.CLOSED
    -offset > (reveal + width) / 2 -> SwipeRest.DELETE
    velocity < -fling -> SwipeRest.OPEN
    velocity > fling -> SwipeRest.CLOSED
    -offset > reveal / 2 -> SwipeRest.OPEN
    else -> SwipeRest.CLOSED
}

/**
 * The shelf row's swipes, as iOS lays them out: left opens on 自訂書名 and 刪除 and stays open, or deletes
 * outright when dragged most of the way across; right is the one leading action, done and sprung back.
 * Its own rather than the shared swipe, which commits a single action per edge.
 */
@Composable
private fun ShelfSwipe(
    open: Boolean, onOpen: (Boolean) -> Unit, leading: SwipeAction?, confirmation: String?,
    onDelete: () -> Unit, onRename: () -> Unit, content: @Composable () -> Unit,
) {
    val p = LocalPalette.current
    val density = LocalDensity.current
    val scope = rememberCoroutineScope()
    // Not saveable, for SwipeToDelete's reason: a lazy list would hand a deleted row's state to whatever
    // comes back under its key.
    val offset = remember { Animatable(0f) }
    var width by remember { mutableFloatStateOf(0f) }
    var asking by remember { mutableStateOf(false) }
    val reveal = with(density) { 160.dp.toPx() }
    // SwipeToDismissBox's own thresholds, so 標為已讀 answers the drag it always did.
    val lead = with(density) { 56.dp.toPx() }
    val fling = with(density) { 125.dp.toPx() }

    fun close() {
        onOpen(false)
        scope.launch { offset.animateTo(0f) }
    }
    // Off the edge first, as a full swipe leaves it; then gone, or back if the question is declined.
    fun delete() {
        scope.launch {
            offset.animateTo(-width)
            onOpen(false)
            if (confirmation != null) asking = true else onDelete()
        }
    }
    fun rename() {
        onRename()
        close()
    }
    // Another row opened, or the shelf was touched elsewhere. Only a row resting open shuts: one on its
    // way off the edge is being deleted.
    LaunchedEffect(open) { if (!open && offset.targetValue == -reveal) offset.animateTo(0f) }
    if (asking) {
        ActionSheet(confirmation, "刪除", onAction = {
            asking = false
            onDelete()
        }, onDismiss = {
            asking = false
            scope.launch { offset.animateTo(0f) }
        })
    }
    Box(
        Modifier.fillMaxWidth().onSizeChanged { width = it.width.toFloat() }.semantics {
            // A swipe nobody using TalkBack can make: the same two, as actions on the row.
            customActions = listOf(
                CustomAccessibilityAction("自訂書名") { rename(); true },
                CustomAccessibilityAction("刪除") { delete(); true },
            )
        },
    ) {
        val x = offset.value
        if (x > 0f && leading != null) Row(
            Modifier.matchParentSize().background(leading.color).padding(horizontal = 24.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(leading.icon, leading.label, tint = Color.White)
        }
        if (x < 0f) Row(Modifier.matchParentSize(), horizontalArrangement = Arrangement.End) {
            Row(Modifier.fillMaxHeight().width(with(density) { (-x).toDp() })) {
                // Past the line, 刪除 takes the whole strip: what letting go now will do. systemIndigo, as iOS tints rename.
                if (-x <= (reveal + width) / 2) SwipeButton("自訂書名", Symbols.Pencil, Color(if (p.dark) 0xFF5E5CE6 else 0xFF5856D6), ::rename)
                SwipeButton("刪除", Symbols.Trash, p.red, ::delete)
            }
        }
        Box(
            Modifier.offset { IntOffset(x.roundToInt(), 0) }.draggable(
                rememberDraggableState { delta ->
                    scope.launch { offset.snapTo((offset.value + delta).coerceIn(-width, if (leading != null) width else 0f)) }
                },
                Orientation.Horizontal,
                onDragStopped = { velocity ->
                    when (swipeRest(offset.value, velocity, reveal, width, if (leading != null) lead else null, fling)) {
                        SwipeRest.OPEN -> {
                            onOpen(true)
                            offset.animateTo(-reveal)
                        }
                        SwipeRest.CLOSED -> close()
                        SwipeRest.DELETE -> delete()
                        SwipeRest.LEAD -> {
                            leading?.act()
                            offset.animateTo(0f)
                        }
                    }
                },
            ),
        ) { content() }
    }
}

@Composable
private fun RowScope.SwipeButton(label: String, icon: ImageVector, color: Color, onClick: () -> Unit) {
    Column(
        Modifier.weight(1f).fillMaxHeight().clipToBounds().background(color).clickable(onClickLabel = label, onClick = onClick),
        verticalArrangement = Arrangement.spacedBy(4.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(icon, null, Modifier.size(22.dp), tint = Color.White)
        Text(label, style = Type.footnote, color = Color.White, maxLines = 1, softWrap = false)
    }
}

/**
 * The iOS rename alert. The field holds the reader's own name, not the title: emptying it is how the
 * site's name comes back, which is what the message says.
 */
@Composable
private fun RenameAlert(book: Book, onSave: (String) -> Unit, onDismiss: () -> Unit) {
    val p = LocalPalette.current
    var draft by remember { mutableStateOf(book.displayName.orEmpty().let { TextFieldValue(it, TextRange(it.length)) }) }
    Alert("自訂書名", "留空則使用網站上的原始書名。", "儲存", onConfirm = { onSave(draft.text) }, onDismiss = onDismiss) {
        val focus = remember { FocusRequester() }
        BasicTextField(
            draft, { draft = it }, singleLine = true,
            textStyle = Type.body.copy(color = p.label),
            cursorBrush = SolidColor(p.accent),
            modifier = Modifier.fillMaxWidth().focusRequester(focus)
                .background(p.fill.copy(alpha = p.fill.alpha * 1.6f), RoundedCornerShape(10.dp))
                .padding(horizontal = 12.dp, vertical = 10.dp),
            decorationBox = { field ->
                if (draft.text.isEmpty()) Text("自訂名稱", style = Type.body, color = p.tertiary)
                field()
            },
        )
        // Inside the dialog: its window composes after the screen's, and focus asked before the field exists throws.
        LaunchedEffect(Unit) { focus.requestFocus() }
    }
}

/**
 * Which shelf this is — the iOS `MediaModePicker`: icons in the bar, the one that is on filled and
 * tinted. Not a segmented control, which on iOS did not fit the toolbar's capsule either.
 */
@Composable
fun MediaModePicker(mode: SiteRule.Kind, onPick: (SiteRule.Kind) -> Unit) {
    val p = LocalPalette.current
    for ((kind, name) in listOf(SiteRule.Kind.NOVEL to "小說", SiteRule.Kind.COMIC to "漫畫", SiteRule.Kind.FEED to "訂閱")) {
        val on = kind == mode
        Box(
            Modifier.size(40.dp, 44.dp).clickable(onClickLabel = name) { onPick(kind) }
                .semantics { contentDescription = name; selected = on },
            contentAlignment = Alignment.Center,
        ) {
            val icon = when (kind) {
                SiteRule.Kind.NOVEL -> if (on) Symbols.BookClosedFill else Symbols.BookClosed
                SiteRule.Kind.COMIC -> if (on) Symbols.PhotoStackFill else Symbols.PhotoStack
                SiteRule.Kind.FEED -> if (on) Symbols.NewspaperFill else Symbols.Newspaper
            }
            Icon(icon, null, Modifier.size(22.dp), tint = if (on) p.accent else p.secondary)
        }
    }
}

/**
 * `line.3.horizontal.decrease.circle`, filled while the filter is on: that fill is the only thing on
 * screen saying so, and the filter outlives the launch it was set in. Drawn, because Material has
 * the lines but nothing with the circle around them.
 */
@Composable
private fun ArrangeButton(filtering: Boolean, onClick: () -> Unit) {
    val p = LocalPalette.current
    Box(
        Modifier.size(44.dp).clip(CircleShape).clickable(role = Role.Button, onClickLabel = "排列", onClick = onClick)
            .semantics { contentDescription = "排列" },
        contentAlignment = Alignment.Center,
    ) {
        // The 24 dp symbols' circle — `ellipsis.circle` beside it is 20 across with a 2 dp stroke.
        Box(
            Modifier.size(20.dp).then(if (filtering) Modifier.background(p.label, CircleShape) else Modifier.border(2.dp, p.label, CircleShape)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Symbols.Filter, null, Modifier.size(14.dp), tint = if (filtering) p.glass else p.label)
        }
    }
}

/** A menu row with the checkmark the settings pickers use, for the choice that is on. */
@Composable
private fun MenuChoice(text: String, on: Boolean, onClick: () -> Unit) {
    val p = LocalPalette.current
    DropdownMenuItem(
        text = { Text(text, style = Type.body) },
        leadingIcon = { Box(Modifier.size(20.dp)) { if (on) Icon(Symbols.CheckmarkCircleFill, null, tint = p.accent) } },
        onClick = onClick,
    )
}

const val LOCAL_DELETE = "匯入的書刪掉就沒有了，App 無法重新下載本機檔案。"

/** What a shelf section calls its source: imported files and subscriptions have no rule to take a name from. */
fun sourceName(siteId: String, rules: List<SiteRule>) = when (siteId) {
    SiteStore.LOCAL_SITE_ID -> "本機檔案"
    FeedService.FEED_SITE_ID -> "訂閱"
    else -> rules.firstOrNull { it.id == siteId }?.name ?: siteId
}

/**
 * Where a book came from — the iOS `SiteStore.sourceURL`. A subscription's id already is its address,
 * and the one worth handing on; an imported file has no rule, so no address.
 */
private fun sourceUrl(book: Book, rules: List<SiteRule>): String? =
    if (book.kind == SiteRule.Kind.FEED) book.siteBookId else rules.firstOrNull { it.id == book.siteId }?.bookUrl(book.siteBookId)

private const val FOLDED = "library.folded"

/**
 * An author inside a source's card — the iOS `DisclosureGroup` row: the name, how many are behind it
 * (a folded row that does not say is one nobody opens twice), and its own chevron.
 */
@Composable
private fun AuthorToggle(group: ShelfGroup, edge: Edge, folded: Boolean, onToggle: () -> Unit) {
    val p = LocalPalette.current
    Cell(edge, onClick = onToggle, chevron = false) {
        Text(group.author, style = Type.body, color = p.label, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        Text("${group.rows.size}", style = Type.footnote.copy(fontFeatureSettings = TABULAR), color = p.secondary)
        Spacer(Modifier.width(10.dp))
        FoldChevron(folded, p.accent)
    }
}

/** A section header that folds its section: name, count, and a turning chevron. */
@Composable
private fun SectionToggle(name: String, count: Int, folded: Boolean, onToggle: () -> Unit) {
    val p = LocalPalette.current
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onToggle)
            .padding(start = Margin + RowPadding, end = Margin + RowPadding, top = 22.dp, bottom = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(name, style = Type.sectionHeader, color = p.secondary, modifier = Modifier.weight(1f))
        Text("$count", style = Type.sectionHeader.copy(fontFeatureSettings = TABULAR), color = p.secondary)
        FoldChevron(folded, p.secondary)
    }
}

@Composable
private fun RowScope.BookRow(row: ShelfRow) {
    val p = LocalPalette.current
    Cover(44.dp, 60.dp, row.book)
    Spacer(Modifier.width(12.dp))
    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Text(row.book.shownName, style = Type.body, color = p.label, maxLines = 2, overflow = TextOverflow.Ellipsis)
        row.book.author?.takeIf { it.isNotEmpty() }?.let {
            Text(it, style = Type.caption, color = p.secondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        val feed = row.book.kind == SiteRule.Kind.FEED
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            row.chapterIndex?.let { index ->
                val share = row.book.lastReadFraction?.let { " · ${percent(it)}" }.orEmpty()
                // What a feed holds is articles: "第 12 章" for someone's twelfth post describes a novel it is not.
                Text("讀到第 ${index + 1} ${if (feed) "篇" else "章"}$share", style = Type.caption2.copy(fontFeatureSettings = TABULAR), color = p.tertiary)
            }
            if (row.unread > 0) {
                // Not the same claim on the two shelves: a novel's "new" wears off after a day, a
                // subscription's unread never does (see Chapter.isMarked).
                Text(if (feed) "${row.unread} 篇未讀" else "${row.unread} 章新", style = Type.caption2.copy(fontFeatureSettings = TABULAR), color = p.red, fontWeight = FontWeight.SemiBold)
            }
        }
        ShelfDownloadState(row.book.id)
    }
}

/**
 * The iOS `AddBookSheet`: paste addresses, one a line, and watch each one go. There is no
 * preview step; a line either becomes a book or says why it did not.
 */
@Composable
private fun AddBookSheet(onDismiss: () -> Unit) {
    val app = app()
    val p = LocalPalette.current
    val additions by app.additions.collectAsState()
    val rules by app.sites.rules.collectAsState()
    val feeds = app.mediaMode.collectAsState().value == SiteRule.Kind.FEED
    val title = if (feeds) "新增訂閱" else "加入書籍"
    var text by rememberSaveable { mutableStateOf("") }
    // The same address twice is one: two more trips through a WAF for the same shelf.
    val urls = text.lines().map { it.trim() }.filter { it.isNotEmpty() }.distinct()
    val running = additions.any { it.state == App.Addition.State.WAITING || it.state == App.Addition.State.RUNNING }
    val failed = additions.count { it.state == App.Addition.State.FAILED }
    LaunchedEffect(additions) {
        // Everything went in: nothing left to read here.
        if (additions.isNotEmpty() && !running && failed == 0) {
            app.clearAdditions()
            onDismiss()
        }
    }
    Sheet(onDismiss) {
        when {
            additions.isEmpty() -> SheetBar(
                title,
                leading = { BarTextButton("取消", onClick = onDismiss) },
                trailing = {
                    BarTextButton("加入", enabled = urls.isNotEmpty(), bold = true) {
                        app.add(urls, if (feeds) App.AddKind.SUBSCRIPTION else App.AddKind.BOOK)
                    }
                },
            )
            running -> SheetBar(
                title,
                leading = { BarTextButton("停止") { app.stopAdding() } },
                trailing = { BarTextButton("隱藏", bold = true, onClick = onDismiss) },
            )
            else -> SheetBar(
                title,
                trailing = {
                    BarTextButton("完成", bold = true) {
                        app.clearAdditions()
                        onDismiss()
                    }
                },
            )
        }
        LazyColumn(Modifier.fillMaxSize()) {
            if (additions.isEmpty()) {
                item {
                    Cell(Edge.ONLY) { UrlField(text, { text = it }, if (feeds) "貼上訂閱源網址，一行一個" else "貼上書籍網址，一行一個", minHeight = 88.dp) }
                }
                if (feeds) {
                    footer("一行一個網址：訂閱源，或網站首頁（會自動找出它的訂閱源）。支援 RSS、Atom 與 JSON Feed。")
                } else {
                    footer("一行一個網址，小說與漫畫可以混貼。還沒有來源的網站，App 會試著自動建立來源。")
                }
                // A feed describes itself: no installed rule has anything to do with subscribing.
                if (rules.isNotEmpty() && !feeds) {
                    header("已安裝的來源")
                    group(rules, key = { it.id }) { rule, edge ->
                        Cell(edge, separatorStart = RowPadding + 36.dp) {
                            Icon(rule.kind.icon, null, Modifier.size(22.dp), tint = p.accent)
                            Spacer(Modifier.width(14.dp))
                            Text(rule.name, style = Type.body, color = p.label, modifier = Modifier.weight(1f))
                            Text(rule.host, style = Type.caption, color = p.secondary)
                        }
                    }
                }
            } else {
                val done = additions.count { it.state == App.Addition.State.ADDED || it.state == App.Addition.State.FAILED }
                header("已完成 $done / ${additions.size}")
                group(additions) { addition, edge ->
                    Cell(edge, separatorStart = RowPadding + 28.dp) { AdditionRow(addition) }
                }
                if (!running && failed > 0) footer("$failed 個網址沒有加入", alarming = true)
            }
        }
    }
}

@Composable
private fun RowScope.AdditionRow(addition: App.Addition) {
    val p = LocalPalette.current
    Box(Modifier.width(18.dp), contentAlignment = Alignment.Center) {
        when (addition.state) {
            App.Addition.State.WAITING -> Icon(Symbols.CircleDotted, null, Modifier.size(18.dp), tint = p.tertiary)
            App.Addition.State.RUNNING -> Spinner(size = 16.dp)
            App.Addition.State.ADDED -> Icon(Symbols.CheckmarkCircleFill, null, Modifier.size(18.dp), tint = p.green)
            App.Addition.State.FAILED -> Icon(Symbols.ExclamationCircleFill, null, Modifier.size(18.dp), tint = p.red)
        }
    }
    Spacer(Modifier.width(10.dp))
    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(addition.url, style = Type.footnote, color = p.label, maxLines = 1, overflow = TextOverflow.MiddleEllipsis)
        addition.note?.let {
            Text(
                it, style = Type.caption2, maxLines = 2, overflow = TextOverflow.Ellipsis,
                color = if (addition.state == App.Addition.State.FAILED) p.red else p.secondary,
            )
        }
    }
}

val SiteRule.Kind.icon
    get() = when (this) {
        SiteRule.Kind.COMIC -> Symbols.PhotoStack
        SiteRule.Kind.FEED -> Symbols.Newspaper
        else -> Symbols.BookClosed
    }

val SiteRule.Kind.label
    get() = when (this) {
        SiteRule.Kind.NOVEL -> "小說"
        SiteRule.Kind.COMIC -> "漫畫"
        SiteRule.Kind.FEED -> "訂閱"
    }
