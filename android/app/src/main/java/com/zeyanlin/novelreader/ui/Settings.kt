package com.zeyanlin.novelreader.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.zeyanlin.novelreader.data.DEFAULT_MEDIA_MODE
import com.zeyanlin.novelreader.data.HOME_SCREEN
import com.zeyanlin.novelreader.data.HomeScreen
import com.zeyanlin.novelreader.data.LibraryBackup
import com.zeyanlin.novelreader.data.RECENT_READING_COUNT
import com.zeyanlin.novelreader.data.RECENT_READING_RANGE
import com.zeyanlin.novelreader.data.defaultMediaMode
import com.zeyanlin.novelreader.data.raw
import com.zeyanlin.novelreader.data.recentReadingCount
import com.zeyanlin.novelreader.FEED_GRACE
import com.zeyanlin.novelreader.FEED_KEEP
import com.zeyanlin.novelreader.FEED_UNREAD
import com.zeyanlin.novelreader.describe
import com.zeyanlin.novelreader.retention
import com.zeyanlin.novelreader.services.FeedRetention
import com.zeyanlin.novelreader.services.FeedService
import com.zeyanlin.novelreader.network.WebFetcher
import com.zeyanlin.novelreader.services.NetworkPolicy
import com.zeyanlin.novelreader.services.RuleDeriver
import com.zeyanlin.novelreader.services.SearchDeriver
import com.zeyanlin.novelreader.services.SiteStore
import com.zeyanlin.novelreader.siterules.SiteRule
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** The iOS `SettingsView`, holding only what is ported: sources, appearance, downloads, storage and the version. */
@Composable
fun SettingsScreen() {
    val app = app()
    val nav = LocalNavigator.current
    val p = LocalPalette.current
    val rules by app.sites.rules.collectAsState()
    val shelf by remember { app.library.shelf() }.collectAsState(null)
    val queue by app.downloads.state.collectAsState()
    val policy by app.downloadNetwork.collectAsState()
    var picking by remember { mutableStateOf(false) }
    val context = LocalContext.current
    val version = remember {
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        "${info.versionName} (${androidx.core.content.pm.PackageInfoCompat.getLongVersionCode(info)})"
    }
    ListScreen("設定", large = true) {
        item {
            Cell(Edge.ONLY, onClick = { nav.push(Route.Sites) }) {
                Text("來源", style = Type.body, color = p.label, modifier = Modifier.weight(1f))
                // A subscription is a source too: it is listed on the next screen.
                Text("${rules.size + shelf.orEmpty().count { it.book.kind == SiteRule.Kind.FEED }}", style = Type.body, color = p.secondary)
            }
        }
        footer("App 不內建任何站台。來源都由你自己加入：從網站推導、匯入規則檔，或訂閱 RSS。")
        header("閱讀")
        item {
            Cell(Edge.TOP, onClick = { nav.push(Route.Appearance) }) {
                Text("外觀", style = Type.body, color = p.label, modifier = Modifier.weight(1f))
            }
        }
        // Above the voices, where iOS has it last: the footer under this card is about the voices row.
        item {
            Cell(Edge.MIDDLE, onClick = { nav.push(Route.Start) }) {
                Text("開啟 App 時", style = Type.body, color = p.label, modifier = Modifier.weight(1f))
            }
        }
        // The system's own screen rather than a list of voices here: on Android the engine is
        // the reader's choice too, and its screen is where voices are downloaded.
        item {
            Cell(Edge.BOTTOM, onClick = { runCatching { context.startActivity(android.content.Intent("com.android.settings.TTS_SETTINGS")) } }) {
                Text("朗讀聲音", style = Type.body, color = p.label, modifier = Modifier.weight(1f))
            }
        }
        footer("聲音由 Android 提供。想要更多或音質更好的聲音，請在這裡的「偏好的引擎」設定中下載。")
        header("下載")
        item {
            Cell(Edge.TOP, onClick = { nav.push(Route.DownloadQueue) }) {
                Text("下載佇列", style = Type.body, color = p.label, modifier = Modifier.weight(1f))
                Text("${queue.jobs.size}", style = Type.body, color = p.secondary)
            }
        }
        item {
            Box {
                Cell(Edge.BOTTOM, onClick = { picking = true }, chevron = false) {
                    Text("下載使用的網路", style = Type.body, color = p.label, modifier = Modifier.weight(1f))
                    Text(policy.label, style = Type.body, color = p.secondary)
                    Spacer(Modifier.width(6.dp))
                    Chevron(direction = Direction.DOWN, color = p.secondary, width = 10.dp, height = 6.dp)
                }
                DropdownMenu(picking, { picking = false }, shape = RoundedCornerShape(20.dp), containerColor = p.card) {
                    for (option in NetworkPolicy.entries) {
                        DropdownMenuItem(
                            text = { Text(option.label, style = Type.body) },
                            leadingIcon = {
                                Box(Modifier.size(20.dp)) {
                                    if (option == policy) Icon(Symbols.CheckmarkCircleFill, null, tint = p.accent)
                                }
                            },
                            onClick = {
                                picking = false
                                app.setDownloadNetwork(option)
                            },
                        )
                    }
                }
            }
        }
        footer("選「僅 Wi-Fi」時，在行動網路上開始下載會先問過你；下載途中切換到行動網路會自動暫停。選「Wi-Fi 與行動網路」則不再詢問。閱讀與搜尋一律使用當前可用的網路。")
        // Two links, not one inside the other: what the reader asked to keep and what reading
        // left behind are different promises.
        header("儲存空間")
        item {
            Cell(Edge.TOP, onClick = { nav.push(Route.Storage) }) {
                Text("下載", style = Type.body, color = p.label, modifier = Modifier.weight(1f))
            }
        }
        item {
            Cell(Edge.MIDDLE, onClick = { nav.push(Route.Cache) }) {
                Text("快取", style = Type.body, color = p.label, modifier = Modifier.weight(1f))
            }
        }
        // Here rather than beside the feed shelf: the one setting that deletes what the reader did
        // not ask it to, in the section people open when they are looking for space.
        item {
            Cell(Edge.BOTTOM, onClick = { nav.push(Route.Retention) }) {
                Text("訂閱保留", style = Type.body, color = p.label, modifier = Modifier.weight(1f))
            }
        }
        // iOS keeps this beside iCloud sync under 同步; with no sync here, that header would promise one.
        gap()
        item {
            Cell(Edge.ONLY, onClick = { nav.push(Route.Backup) }) {
                Text("備份", style = Type.body, color = p.label, modifier = Modifier.weight(1f))
            }
        }
        gap()
        item {
            Cell(Edge.TOP) {
                Text("版本", style = Type.body, color = p.label, modifier = Modifier.weight(1f))
                Text(version, style = Type.body, color = p.secondary)
            }
        }
        // Beside the version: nobody goes looking for a diagnostic, they are pointed at one, and
        // what they are asked for is this build — the row directly above.
        item {
            Cell(Edge.BOTTOM, onClick = { nav.push(Route.Diagnostics) }) {
                Text("診斷日誌", style = Type.body, color = p.label, modifier = Modifier.weight(1f))
            }
        }
    }
}

/**
 * The iOS `StartSettingsView`: which screen a launch opens on, which shelf, and how long the list on
 * that first screen is — one screen, because they are one question.
 */
@Composable
fun StartScreen() {
    val app = app()
    val nav = LocalNavigator.current
    val p = LocalPalette.current
    val scope = rememberCoroutineScope()
    var home by remember { mutableStateOf(HomeScreen.from(app.prefs.getString(HOME_SCREEN, null))) }
    var mode by remember { mutableStateOf(app.prefs.defaultMediaMode()) }
    var count by remember { mutableIntStateOf(app.prefs.recentReadingCount()) }
    val recent by remember { app.library.recent() }.collectAsState(null)
    var confirmingClear by remember { mutableStateOf(false) }
    ListScreen("開啟 App 時", onBack = nav::pop) {
        item {
            MenuPicker("首頁", home, HomeScreen.entries, { it.label }, edge = Edge.TOP) {
                home = it
                app.prefs.edit().putString(HOME_SCREEN, it.raw).apply()
            }
        }
        item {
            MenuPicker("預設書櫃", mode, SiteRule.Kind.entries, { it.label }, { it.icon }, edge = Edge.BOTTOM) {
                mode = it
                app.prefs.edit().putString(DEFAULT_MEDIA_MODE, it.raw).apply()
            }
        }
        footer("兩者都只在開啟 App 時生效；書櫃上的切換隨時可以改。")
        // Here rather than on the list itself: one of these is a delete, and a destructive button in the
        // bar of the screen it empties gets pressed by someone reaching for the first row.
        header("近期閱讀")
        item {
            Cell(Edge.TOP) {
                Text("顯示筆數", style = Type.body, color = p.label, modifier = Modifier.weight(1f))
                Text("$count", style = Type.body.copy(fontFeatureSettings = TABULAR), color = p.secondary)
                Spacer(Modifier.width(12.dp))
                Stepper(count, RECENT_READING_RANGE) {
                    count = it
                    app.prefs.edit().putInt(RECENT_READING_COUNT, it).apply()
                }
            }
        }
        item {
            // Nothing to forget is not an error, and a button that does nothing is worse than one plainly unavailable.
            val empty = recent.isNullOrEmpty()
            Cell(Edge.BOTTOM, onClick = if (empty) null else ({ confirmingClear = true }), chevron = false) {
                Text("清空近期閱讀", style = Type.body, color = if (empty) p.tertiary else p.red)
            }
        }
        footer("「近期閱讀」是開啟 App 時的第一個畫面。若列表上的書都已讀到最後一章的 100%，開啟 App 時會直接進入書櫃。")
    }
    // Asked, unlike most deletes here: the list is on another tab, and only the question can say the
    // reading positions survive it.
    if (confirmingClear) {
        ActionSheet("近期閱讀清單會被清空，每本書讀到哪裡會保留。", "清空近期閱讀", onAction = {
            confirmingClear = false
            scope.launch { app.library.clearReadingHistory() }
        }, onDismiss = { confirmingClear = false })
    }
}

/** UIStepper: a grey capsule split in two, each half greyed out at its end of [range]. */
@Composable
private fun Stepper(value: Int, range: IntRange, onChange: (Int) -> Unit) {
    val p = LocalPalette.current
    Row(Modifier.height(32.dp).clip(CircleShape).background(p.fill.copy(alpha = p.fill.alpha * 1.6f)), verticalAlignment = Alignment.CenterVertically) {
        for ((step, icon, name) in listOf(Triple(-1, Symbols.Minus, "遞減"), Triple(1, Symbols.Plus, "遞增"))) {
            if (step > 0) Box(Modifier.width(hairline()).height(18.dp).background(p.separator))
            val enabled = value + step in range
            Box(
                Modifier.size(47.dp, 32.dp).clickable(enabled, onClickLabel = name, role = Role.Button) { onChange(value + step) },
                contentAlignment = Alignment.Center,
            ) {
                Icon(icon, name, Modifier.size(20.dp), tint = if (enabled) p.label else p.tertiary)
            }
        }
    }
}

/**
 * The iOS `BackupView`. Its own screen for the two footers: what a backup holds and leaves out is
 * what someone needs before trusting one, and "will this wipe what I have" is what stops a restore.
 */
@Composable
fun BackupScreen() {
    val app = app()
    val nav = LocalNavigator.current
    val p = LocalPalette.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var outcome by remember { mutableStateOf<LibraryBackup.Outcome?>(null) }

    val saver = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/json")) { uri ->
        if (uri != null) scope.launch {
            try {
                val data = app.backupData()
                withContext(Dispatchers.IO) { context.contentResolver.openOutputStream(uri, "wt")!!.use { it.write(data) } }
            } catch (e: Exception) {
                app.report(e, "App 正在匯出備份。")
            }
        }
    }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) scope.launch {
            try {
                outcome = app.restoreBackup(uri)
            } catch (e: Exception) {
                app.report(e, "App 正在還原備份。")
            }
        }
    }

    ListScreen("備份", onBack = nav::pop) {
        item {
            // Dated, so two backups in one folder can be told apart by more than save order.
            Cell(Edge.ONLY, onClick = { saver.launch("novel-reader-backup-${java.time.LocalDate.now()}.json") }, chevron = false) {
                Icon(Symbols.SquareAndArrowUp, null, Modifier.size(22.dp), tint = p.accent)
                Spacer(Modifier.width(12.dp))
                Text("匯出備份", style = Type.body, color = p.accent)
            }
        }
        footer("包含書架與訂閱、每一本讀到哪裡、書籤與標註、你安裝的來源，以及 App 的設定。不含已下載的章節、漫畫頁與文章內容——那些可以重新抓回來。")
        gap()
        item {
            Cell(Edge.ONLY, onClick = { picker.launch(arrayOf("application/json", "text/plain", "application/octet-stream")) }, chevron = false) {
                Icon(Symbols.SquareAndArrowDown, null, Modifier.size(22.dp), tint = p.accent)
                Spacer(Modifier.width(12.dp))
                Text("從備份還原", style = Type.body, color = p.accent)
            }
        }
        footer("還原是合併：不會刪掉這台裝置上已有的東西；比備份還新的紀錄會保留下來。")
    }
    outcome?.let { o ->
        // The skipped line says what to do, because there is something: a reader not told
        // would assume those marks are gone.
        val skipped = if (o.skippedImports > 0) {
            "\n\n有 ${o.skippedImports} 本匯入的書不在這台裝置上，它們的標記沒有還原。重新匯入那些檔案後再還原一次這份備份，就會接回去。"
        } else {
            ""
        }
        Alert(
            "還原完成", "還原了 ${o.books} 本書、${o.marks} 個標記、${o.rules} 個來源。$skipped", "完成",
            onConfirm = { outcome = null }, onDismiss = { outcome = null }, cancel = false,
        )
    }
}

/**
 * The iOS `FeedRetentionView`: three answers rather than one number, because they answer three
 * worries — room, being done with an article, and whether unread expires at all.
 */
@Composable
fun RetentionScreen() {
    val app = app()
    val nav = LocalNavigator.current
    var keep by remember { mutableStateOf(app.prefs.retention(FEED_KEEP)) }
    var grace by remember { mutableStateOf(app.prefs.retention(FEED_GRACE)) }
    var unread by remember { mutableStateOf(app.prefs.retention(FEED_UNREAD)) }
    fun days(n: Int) = when (n) { 1 -> "一天"; 7 -> "一週"; 30 -> "一個月"; 90 -> "三個月"; else -> "永久" }

    ListScreen("訂閱保留", onBack = nav::pop) {
        item {
            MenuPicker("每個訂閱保留", keep, FeedRetention.KEEP_COUNTS, { if (it == 0) "全部保留" else "$it 篇" }) {
                keep = it
                app.prefs.edit().putInt(FEED_KEEP, it).apply()
            }
        }
        footer("已讀與未讀一起計算，從最新的開始保留。訂閱源目前仍在提供的文章不會被刪除，因此更新頻繁的來源可能會多留一些。")
        // Both hidden when nothing is deleted: they are the terms of a deletion that is not happening.
        if (keep != 0) {
            gap()
            item {
                MenuPicker("超出後保留", grace, FeedRetention.GRACE_DAYS, ::days) {
                    grace = it
                    app.prefs.edit().putInt(FEED_GRACE, it).apply()
                }
            }
            footer("超出上限的文章要在裝置上放滿這段時間才會刪除，而且只在開啟 App 時清理。")
            gap()
            item {
                MenuPicker("未讀保留", unread, FeedRetention.UNREAD_DAYS, ::days) {
                    unread = it
                    app.prefs.edit().putInt(FEED_UNREAD, it).apply()
                }
            }
            footer("超出上限的未讀文章會再多留這段時間才刪除。")
            header("不會被刪除")
            footer("你正在讀的那篇、你加了書籤或標註的文章，以及訂閱源目前仍在提供的文章。")
        }
    }
}

/** One answer from a short list: a row that drops the list down, as the download network's does. */
@Composable
private fun <T> MenuPicker(
    label: String, value: T, options: List<T>, name: (T) -> String, icon: ((T) -> ImageVector)? = null, edge: Edge = Edge.ONLY, onPick: (T) -> Unit,
) {
    val p = LocalPalette.current
    var picking by remember { mutableStateOf(false) }
    Box {
        Cell(edge, onClick = { picking = true }, chevron = false) {
            Text(label, style = Type.body, color = p.label, modifier = Modifier.weight(1f))
            Text(name(value), style = Type.body, color = p.secondary)
            Spacer(Modifier.width(6.dp))
            Chevron(direction = Direction.DOWN, color = p.secondary, width = 10.dp, height = 6.dp)
        }
        DropdownMenu(picking, { picking = false }, shape = RoundedCornerShape(20.dp), containerColor = p.card) {
            for (option in options) {
                DropdownMenuItem(
                    text = { Text(name(option), style = Type.body) },
                    leadingIcon = {
                        Box(Modifier.size(20.dp)) {
                            if (option == value) Icon(Symbols.CheckmarkCircleFill, null, tint = p.accent)
                        }
                    },
                    trailingIcon = icon?.let { { Icon(it(option), null) } },
                    onClick = {
                        picking = false
                        onPick(option)
                    },
                )
            }
        }
    }
}

/** The iOS `SiteListView`: installed rules by medium, and the ways to add one. */
@Composable
fun SitesScreen() {
    val app = app()
    val nav = LocalNavigator.current
    val p = LocalPalette.current
    val context = LocalContext.current
    val rules by app.sites.rules.collectAsState()
    val shelf by remember { app.library.shelf() }.collectAsState(null)
    val subscriptions = shelf.orEmpty().map { it.book }.filter { it.kind == SiteRule.Kind.FEED }
        .sortedWith(compareBy(java.text.Collator.getInstance()) { it.shownName })
    var error by remember { mutableStateOf<String?>(null) }
    var menu by remember { mutableStateOf(false) }
    var pasting by remember { mutableStateOf(false) }
    var fetching by remember { mutableStateOf(false) }

    fun install(text: () -> String) {
        error = try {
            app.sites.import(text())
            null
        } catch (e: SiteStore.ImportError) {
            e.message
        } catch (e: Exception) {
            "無法讀取這個檔案。"
        }
    }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        // Some providers label .json as octet-stream or plain text, so the picker allows those
        // and the decoder decides.
        if (uri != null) install { context.contentResolver.openInputStream(uri)!!.use { it.readBytes().decodeToString() } }
    }

    ListScreen(
        "來源",
        onBack = nav::pop,
        actions = {
            Box {
                BarButton(Symbols.Plus, "加入來源") { menu = true }
                DropdownMenu(
                    menu, { menu = false },
                    shape = RoundedCornerShape(20.dp), containerColor = p.card,
                ) {
                    // First: the only entry that does not need someone to have written a rule.
                    DropdownMenuItem(
                        text = { Text("自動建立來源…", style = Type.body) },
                        trailingIcon = { Icon(Symbols.WandAndStars, null) },
                        onClick = {
                            menu = false
                            nav.push(Route.DeriveRule)
                        },
                    )
                    HorizontalDivider(color = p.separator)
                    DropdownMenuItem(
                        text = { Text("從檔案匯入", style = Type.body) },
                        trailingIcon = { Icon(Symbols.Doc, null) },
                        onClick = {
                            menu = false
                            picker.launch(arrayOf("application/json", "text/plain", "application/octet-stream"))
                        },
                    )
                    DropdownMenuItem(
                        text = { Text("從網址匯入規則", style = Type.body) },
                        trailingIcon = { Icon(Symbols.Link, null) },
                        onClick = {
                            menu = false
                            fetching = true
                        },
                    )
                    DropdownMenuItem(
                        text = { Text("貼上 JSON", style = Type.body) },
                        trailingIcon = { Icon(Symbols.DocOnClipboard, null) },
                        onClick = {
                            menu = false
                            pasting = true
                        },
                    )
                }
            }
        },
    ) {
        error?.let { message ->
            item { Cell(Edge.ONLY) { Text(message, style = Type.footnote, color = p.red) } }
        }
        if (rules.isEmpty() && subscriptions.isEmpty()) {
            item { Cell(Edge.ONLY) { Text("尚未加入任何來源", style = Type.body, color = p.secondary) } }
        }
        for ((kind, name) in listOf(SiteRule.Kind.NOVEL to "小說", SiteRule.Kind.COMIC to "漫畫")) {
            val list = rules.filter { it.kind == kind }
            if (list.isEmpty()) continue
            header(name, key = "kind:$kind", icon = kind.icon)
            group(list, key = { it.id }) { rule, edge ->
                Cell(edge, onClick = { nav.push(Route.Site(rule.id)) }, onDelete = { app.sites.remove(rule.id) }) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(rule.name, style = Type.body, color = p.label)
                        Text(rule.host, style = Type.caption, color = p.secondary)
                        if (rule.search == null) Text("不支援搜尋", style = Type.caption2, color = p.orange)
                    }
                }
            }
        }
        // A subscription is a source of its own — a feed describes itself — so it is listed with them.
        // Not a link: its page is the one on the shelf.
        if (subscriptions.isNotEmpty()) {
            header("訂閱", key = "kind:${SiteRule.Kind.FEED}", icon = SiteRule.Kind.FEED.icon)
            group(subscriptions, key = { it.id }) { book, edge ->
                // The shelf's removal: a subscription is one thing in two lists.
                Cell(edge, onDelete = { app.deleteBook(book.id) }) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(book.shownName, style = Type.body, color = p.label)
                        Text(FeedService.host(book.siteBookId), style = Type.caption, color = p.secondary)
                    }
                }
            }
        }
    }
    if (pasting) {
        PasteRuleSheet(
            onDismiss = { pasting = false },
            onSave = { text ->
                try {
                    app.sites.import(text)
                    error = null
                    null
                } catch (e: SiteStore.ImportError) {
                    e.message
                }
            },
        )
    }
    if (fetching) RemoteRuleSheet { fetching = false }
}

/** The iOS `RemoteRuleImportView`: fetch a rule someone has published. */
@Composable
private fun RemoteRuleSheet(onDismiss: () -> Unit) {
    val app = app()
    val p = LocalPalette.current
    val scope = rememberCoroutineScope()
    var text by remember { mutableStateOf("") }
    var working by remember { mutableStateOf(false) }
    var problem by remember { mutableStateOf<String?>(null) }
    Sheet(onDismiss) {
        SheetBar(
            "從網址匯入規則",
            leading = { BarTextButton("取消", onClick = onDismiss) },
            trailing = {
                BarTextButton("儲存", enabled = text.isNotBlank() && !working, bold = true) {
                    working = true
                    scope.launch {
                        try {
                            app.sites.importRemote(text.trim())
                            onDismiss()
                        } catch (e: SiteStore.ImportError) {
                            problem = e.message
                        } finally {
                            working = false
                        }
                    }
                }
            },
        )
        Box(Modifier.fillMaxSize()) {
            LazyColumn(Modifier.fillMaxSize()) {
                item { Cell(Edge.ONLY) { UrlField(text, { text = it }, "規則檔網址") } }
                footer("貼上一個規則檔（JSON）的網址，App 會下載並加入來源。")
                problem?.let {
                    gap(20.dp)
                    item { Cell(Edge.ONLY) { Text(it, style = Type.footnote, color = p.red) } }
                }
            }
            if (working) Spinner(Modifier.align(Alignment.Center))
        }
    }
}

/**
 * The iOS `DeriveRuleView`: turns a pasted book address into a source. Shaped around
 * confirmation rather than configuration — a title, a chapter count and the opening of chapter
 * one, all read by the rule that would be saved, and nothing that needs a CSS selector.
 */
@Composable
fun DeriveRuleScreen() {
    val app = app()
    val nav = LocalNavigator.current
    val p = LocalPalette.current
    val scope = rememberCoroutineScope()
    var text by rememberSaveable { mutableStateOf("") }
    var working by remember { mutableStateOf(false) }
    var draft by remember { mutableStateOf<RuleDeriver.Draft?>(null) }
    var error by remember { mutableStateOf<String?>(null) }

    fun analyse() {
        working = true
        error = null
        draft = null
        scope.launch {
            try {
                draft = RuleDeriver(app.fetcher, app.sites.rules.value).derive(text.trim())
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // A challenge has to reach the challenge sheet; once cleared, 分析 again works.
                if (e is WebFetcher.FetchError.ChallengePresented) app.report(e, "App 正在建立來源。")
                error = describe(e)
            } finally {
                working = false
            }
        }
    }

    ListScreen("自動建立來源", onBack = nav::pop) {
        item { Cell(Edge.TOP) { UrlField(text, { text = it }, "書籍頁網址") } }
        item {
            Cell(Edge.BOTTOM, onClick = if (text.isBlank() || working) null else ::analyse, chevron = false) {
                if (working) {
                    Spinner(size = 18.dp)
                    Spacer(Modifier.width(10.dp))
                    Text("分析中…", style = Type.body, color = p.secondary)
                } else {
                    Text("分析", style = Type.body, color = if (text.isBlank()) p.tertiary else p.accent)
                }
            }
        }
        footer("貼上任一本書的書籍頁網址。App 會實際打開該頁，推導出這個站台的規則，並先讓你確認結果。")
        error?.let {
            gap(20.dp)
            item { Cell(Edge.ONLY) { Text(it, style = Type.footnote, color = p.red) } }
        }
        draft?.let { found -> derivePreview(found) { rule ->
            try {
                app.sites.import(SiteRule.json.encodeToString(SiteRule.serializer(), rule))
                nav.pop()
            } catch (e: SiteStore.ImportError) {
                error = e.message
            }
        } }
    }
}

private fun LazyListScope.derivePreview(draft: RuleDeriver.Draft, onSave: (SiteRule) -> Unit) {
    val preview = draft.preview
    header("確認結果")
    item {
        val p = LocalPalette.current
        Cell(Edge.TOP) {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(preview.bookTitle, style = Type.headline, color = p.label)
                preview.author?.let { Text(it, style = Type.subheadline, color = p.secondary) }
            }
        }
    }
    item { Cell(Edge.MIDDLE) { Labeled("章節數", "${preview.chapterCount}") } }
    preview.firstChapterTitle?.let { item { Cell(Edge.MIDDLE) { Labeled("第一章", it) } } }
    // The load-bearing check: a wrong selector shows up here as navigation text, an advert,
    // or the address of the site's logo.
    when (val evidence = preview.evidence) {
        is RuleDeriver.Preview.Evidence.Text -> item {
            Cell(Edge.BOTTOM) { Text(evidence.excerpt, style = Type.footnote, color = LocalPalette.current.secondary) }
        }
        is RuleDeriver.Preview.Evidence.Pages -> {
            item { Cell(Edge.MIDDLE) { Labeled("頁數", "${evidence.count}") } }
            item {
                Cell(Edge.BOTTOM) {
                    Text(
                        evidence.first, style = Type.caption.copy(fontFamily = FontFamily.Monospace),
                        color = LocalPalette.current.secondary, maxLines = 2, overflow = TextOverflow.MiddleEllipsis,
                    )
                }
            }
        }
    }
    if (preview.warnings.isNotEmpty()) {
        gap(20.dp)
        group(preview.warnings) { warning, edge ->
            val p = LocalPalette.current
            Cell(edge) {
                Icon(Symbols.ExclamationTriangle, null, Modifier.size(18.dp), tint = p.orange)
                Spacer(Modifier.width(10.dp))
                Text(warning, style = Type.footnote, color = p.orange)
            }
        }
    }
    gap(20.dp)
    item { Cell(Edge.TOP) { Labeled("站台", draft.rule.host) } }
    item {
        Cell(Edge.BOTTOM, onClick = { onSave(draft.rule) }, chevron = false) {
            Text("加入來源", style = Type.body, color = LocalPalette.current.accent)
        }
    }
    footer("規則存在裝置上，可隨時在此頁刪除。")
}

/** [onSave] returns why the text was refused, or null once it is installed. */
@Composable
private fun PasteRuleSheet(onDismiss: () -> Unit, onSave: (String) -> String?) {
    val p = LocalPalette.current
    var text by remember { mutableStateOf("") }
    var problem by remember { mutableStateOf<String?>(null) }
    Sheet(onDismiss) {
        SheetBar(
            "貼上 JSON",
            leading = { BarTextButton("取消", onClick = onDismiss) },
            trailing = {
                BarTextButton("儲存", enabled = text.isNotBlank(), bold = true) {
                    problem = onSave(text)
                    if (problem == null) onDismiss()
                }
            },
        )
        problem?.let {
            Text(it, style = Type.footnote, color = p.red, modifier = Modifier.padding(horizontal = Margin + RowPadding, vertical = 6.dp))
        }
        BasicTextField(
            text, { text = it },
            textStyle = Type.footnote.copy(color = p.label, fontFamily = FontFamily.Monospace),
            cursorBrush = SolidColor(p.accent),
            keyboardOptions = KeyboardOptions(autoCorrectEnabled = false),
            modifier = Modifier.fillMaxWidth().fillMaxSize().padding(horizontal = Margin + 8.dp, vertical = 8.dp),
        )
    }
}

/** The iOS `SiteDetailView`. */
@Composable
fun SiteScreen(id: String) {
    val app = app()
    val nav = LocalNavigator.current
    val p = LocalPalette.current
    val rules by app.sites.rules.collectAsState()
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var probe by rememberSaveable { mutableStateOf("") }
    var working by remember { mutableStateOf(false) }
    var derived by remember { mutableStateOf<SearchDeriver.Derived?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    // A book already on the shelf from this source is the safest probe: it is known to exist on
    // the site, so no results means the derivation failed rather than the word being rare.
    LaunchedEffect(id) {
        if (probe.isEmpty()) probe = app.library.allBooksNow().firstOrNull { it.siteId == id }?.title.orEmpty()
    }
    val rule = rules.firstOrNull { it.id == id } ?: return Box(Modifier.fillMaxSize())

    fun derive() {
        working = true
        error = null
        derived = null
        scope.launch {
            try {
                derived = SearchDeriver(app.fetcher).derive(rule, probe.trim())
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // A challenge has to reach the challenge sheet; once cleared, deriving again works.
                if (e is WebFetcher.FetchError.ChallengePresented) app.report(e, "App 正在推導搜尋。")
                error = describe(e)
            } finally {
                working = false
            }
        }
    }

    ListScreen(rule.name, onBack = nav::pop) {
        val rows = listOf("站台" to rule.host, "搜尋" to if (rule.search != null) "支援" else "不支援")
        group(rows) { (label, value), edge ->
            Cell(if (edge == Edge.BOTTOM) Edge.MIDDLE else edge) {
                Text(label, style = Type.body, color = p.label, modifier = Modifier.weight(1f))
                Text(value, style = Type.body, color = if (value == "不支援") p.orange else p.secondary)
            }
        }
        // Rules are portable: one person works a site out and everyone else imports the result,
        // which only works if a rule can get back out of the app.
        item {
            Cell(Edge.BOTTOM, onClick = { context.shareFile(app.sites.file(rule.id), "application/json") }, chevron = false) {
                Icon(Symbols.SquareAndArrowUp, null, Modifier.size(22.dp), tint = p.accent)
                Spacer(Modifier.width(12.dp))
                Text("匯出規則檔", style = Type.body, color = p.accent)
            }
        }
        footer("把這個來源的規則分享給別人，對方用「從網址匯入」或「檔案匯入」即可加入。")
        if (rule.search == null) {
            header("加上搜尋")
            item {
                Cell(Edge.TOP) {
                    BasicTextField(
                        probe, { probe = it }, singleLine = true,
                        textStyle = Type.body.copy(color = p.label),
                        cursorBrush = SolidColor(p.accent),
                        keyboardOptions = KeyboardOptions(autoCorrectEnabled = false),
                        modifier = Modifier.fillMaxWidth(),
                        decorationBox = { field ->
                            if (probe.isEmpty()) Text("測試用的書名", style = Type.body, color = p.tertiary)
                            field()
                        },
                    )
                }
            }
            item {
                Cell(Edge.BOTTOM, onClick = if (probe.isBlank() || working) null else ::derive, chevron = false) {
                    if (working) {
                        Spinner(size = 18.dp)
                        Spacer(Modifier.width(10.dp))
                        Text("分析中…", style = Type.body, color = p.secondary)
                    } else {
                        Text("推導搜尋", style = Type.body, color = if (probe.isBlank()) p.tertiary else p.accent)
                    }
                }
            }
            footer("App 會用這個關鍵字實際在站上搜一次，從站方自己的搜尋框推導出規則。請填一本這個站確實有的書名。")
            error?.let {
                gap(20.dp)
                item { Cell(Edge.ONLY) { Text(it, style = Type.footnote, color = p.red) } }
            }
            derived?.let { found ->
                header("確認結果")
                group(found.sampleTitles) { title, edge -> Cell(edge) { Text(title, style = Type.footnote, color = p.label) } }
                gap(20.dp)
                item {
                    Cell(Edge.ONLY, onClick = {
                        try {
                            // Same id, so this replaces the stored rule in place and every book under it keeps working.
                            app.sites.import(SiteRule.json.encodeToString(SiteRule.serializer(), rule.copy(search = found.search)))
                            derived = null
                        } catch (e: SiteStore.ImportError) {
                            error = e.message
                        }
                    }, chevron = false) {
                        Text("加入搜尋", style = Type.body, color = p.accent)
                    }
                }
            }
        }
        rule.notes?.takeIf { it.isNotEmpty() }?.let { notes ->
            header("規則備註")
            item {
                Cell(Edge.ONLY) {
                    Text(notes.joinToString("\n\n"), style = Type.caption, color = p.secondary)
                }
            }
        }
    }
}
