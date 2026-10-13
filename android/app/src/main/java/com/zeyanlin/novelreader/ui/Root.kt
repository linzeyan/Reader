package com.zeyanlin.novelreader.ui

import android.net.Uri
import android.view.ViewGroup
import android.webkit.WebView
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import android.view.WindowManager
import androidx.activity.compose.LocalActivity
import androidx.compose.runtime.DisposableEffect
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.zeyanlin.novelreader.App
import com.zeyanlin.novelreader.data.HOME_SCREEN
import com.zeyanlin.novelreader.data.HomeScreen
import com.zeyanlin.novelreader.data.ShelfRow
import com.zeyanlin.novelreader.data.recentReadingCount
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first

enum class Tab(val title: String) {
    RECENT("近期閱讀"),
    LIBRARY("書櫃"),
    SEARCH("搜尋"),
    SETTINGS("設定"),
    ;

    val icon: ImageVector
        get() = when (this) {
            RECENT -> Symbols.ClockFill
            LIBRARY -> ShelfSymbol
            SEARCH -> Symbols.Search
            SETTINGS -> Symbols.GearFill
        }
}

sealed interface Route {
    data class BookDetail(val bookId: String) : Route

    /**
     * [siteChapterId] opens that chapter — at [paragraph] and [offset], or its top when
     * [paragraph] is null; a null chapter resumes where the reader left off.
     */
    data class Reader(val bookId: String, val siteChapterId: String? = null, val paragraph: Int? = null, val offset: Int = 0) : Route

    data object Sites : Route

    data class Site(val id: String) : Route

    data object DeriveRule : Route

    data class ChapterDownloads(val bookId: String) : Route

    data object DownloadQueue : Route

    data object Storage : Route

    data object Cache : Route

    data object Appearance : Route

    data object ThemeEditor : Route

    data class ToolbarEditor(val layer: Layer) : Route

    data object Backup : Route

    data object Retention : Route

    data object Start : Route

    data object Diagnostics : Route

    data class Marks(val bookId: String) : Route
}

/**
 * One back stack per tab, as a TabView of NavigationStacks keeps them. Hand-rolled: five
 * routes do not need a navigation library, and the iOS transitions are easier to match by hand.
 */
class Navigator(initial: Tab) {
    var tab by mutableStateOf(initial)
        private set
    private val stacks = Tab.entries.associateWith { mutableStateListOf<Route>() }
    val stack: List<Route> get() = stacks.getValue(tab)

    /** False for the one jump iOS makes without animating: resuming from recent reading. */
    var animated = true
        private set

    fun push(route: Route) {
        animated = true
        stacks.getValue(tab).add(route)
    }

    fun pop() {
        animated = true
        stacks.getValue(tab).removeLastOrNull()
    }

    /** Counts taps on the tab already showing at its root: the list there scrolls to its top on each. */
    var toTop by mutableIntStateOf(0)
        private set

    /** Selecting the tab already showing goes back to its root, and at the root to its top, as tapping it does on iOS. */
    fun select(target: Tab) {
        animated = true
        when {
            target != tab -> tab = target
            stack.isNotEmpty() -> stacks.getValue(tab).clear()
            else -> toTop++
        }
    }

    /**
     * From recent reading or a search: the book's screen under the reader, on the shelf's stack —
     * books live there, so backing out of the reader lands on the book, not on the list it came from.
     */
    fun resume(reader: Route.Reader) {
        animated = false
        tab = Tab.LIBRARY
        stacks.getValue(Tab.LIBRARY).apply {
            clear()
            add(Route.BookDetail(reader.bookId))
            add(reader)
        }
    }

    /** To the shelf's root, unanimated: a jump from another app, onto the shelf importing its file. */
    fun shelf() {
        animated = false
        tab = Tab.LIBRARY
        stacks.getValue(Tab.LIBRARY).clear()
    }
}

val LocalNavigator = staticCompositionLocalOf<Navigator> { error("no navigator") }

/** A book read to the end of its last chapter, which recent reading no longer offers to resume. */
val ShelfRow.isFinished: Boolean
    get() = chapterIndex != null && chapterIndex == chapterCount - 1 && (book.lastReadFraction ?: 0.0) >= 1.0

/**
 * Which tab a launch opens on — the iOS `RootTab.home`. Only [HomeScreen.AUTOMATIC] reads [recent], and
 * only the [shown] rows its screen draws: a book pushed off the end cannot be tapped, so it cannot be
 * what makes the list worth opening on.
 */
fun homeTab(recent: List<ShelfRow>, shown: Int, preference: HomeScreen) = when (preference) {
    HomeScreen.RECENT -> Tab.RECENT
    HomeScreen.LIBRARY -> Tab.LIBRARY
    // A history of finished books is a screen of dead ends; what the reader came for is the next one.
    HomeScreen.AUTOMATIC -> if (recent.take(shown).any { !it.isFinished }) Tab.RECENT else Tab.LIBRARY
}

@Composable
fun Root() {
    val app = app()
    val p = LocalPalette.current
    var navigator by remember { mutableStateOf<Navigator?>(null) }
    LaunchedEffect(Unit) {
        val home = HomeScreen.from(app.prefs.getString(HOME_SCREEN, null))
        navigator = Navigator(homeTab(app.library.recent().first(), app.prefs.recentReadingCount(), home))
    }
    // A file from another app goes through the shelf's import, so the shelf is where the reader is
    // taken: its banner is the progress and the cancel, and the book lands there. Where iOS puts
    // up a banner over any tab instead, Android has the shelf's own to reuse.
    val showShelf by app.showShelf.collectAsState()
    LaunchedEffect(navigator, showShelf) {
        val nav = navigator ?: return@LaunchedEffect
        if (!showShelf) return@LaunchedEffect
        nav.shelf()
        app.showShelf.value = false
    }
    val challenge by app.challenge.collectAsState()
    Box(Modifier.fillMaxSize()) {
        // The fetcher's web view lives here, full size and covered, so the engine treats it as
        // on screen: a hidden or detached view gets its timers throttled, and a site check
        // stalls on that. The challenge sheet takes it over while it is up.
        if (challenge == null) WebViewHost(app.fetcher.webView, Modifier.fillMaxSize())
        Box(Modifier.fillMaxSize().background(p.background))
        navigator?.let { nav ->
            CompositionLocalProvider(LocalNavigator provides nav) { Screens(nav) }
        }
        ErrorBanner(app)
        FocusDark(app)
        // Over the black: the sheet is how a walled queue gets going again.
        challenge?.let { ChallengeSheet(it, app.fetcher.webView, app::closeChallenge) }
    }
    // Here, like the challenge sheet: a download queued from a book screen has to be answered
    // even once that screen is gone.
    val metered by app.meteredPrompt.collectAsState()
    if (metered != null) {
        Alert(
            "使用行動網路下載？", "目前是行動網路連線。整本書的章節可能用掉不少數據。這次選擇只對本次下載有效。",
            "用行動網路下載", app::confirmMeteredDownload, app::cancelMeteredDownload,
        )
    }
}

/**
 * Focus download's half that needs the window: the screen kept on while it runs, and black at
 * the lowest backlight once it goes dark — black alone still lights an LCD. A tap lights it again.
 */
@Composable
private fun FocusDark(app: App) {
    val phase by app.focus.phase.collectAsState()
    val window = LocalActivity.current?.window
    val on = phase != DownloadFocus.Phase.Off
    val dark = phase == DownloadFocus.Phase.Dark
    DisposableEffect(window, on) {
        if (on) window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        onDispose { window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) }
    }
    DisposableEffect(window, dark) {
        if (window == null || !dark) return@DisposableEffect onDispose { }
        val controller = WindowCompat.getInsetsController(window, window.decorView)
        controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        // The status bar only, as the reader hides it: hiding the navigation bar too puts up the
        // system's one-time "viewing full screen" panel, a white card lighting the black.
        controller.hide(WindowInsetsCompat.Type.statusBars())
        window.attributes = window.attributes.apply { screenBrightness = 0f }
        onDispose {
            // The reader's own brightness, rather than a remembered number that may since be wrong.
            window.attributes = window.attributes.apply { screenBrightness = WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE }
            controller.show(WindowInsetsCompat.Type.statusBars())
        }
    }
    AnimatedVisibility(dark, enter = fadeIn(tween(400)), exit = fadeOut(tween(400))) {
        Box(
            Modifier.fillMaxSize().background(Color.Black)
                .clickable(remember { MutableInteractionSource() }, indication = null, onClickLabel = "顯示下載佇列") { app.focus.wake() }
                .semantics { contentDescription = "顯示下載佇列" },
        )
    }
}

@Composable
private fun Screens(nav: Navigator) {
    data class Place(val tab: Tab, val depth: Int, val route: Route?)

    val holder = rememberSaveableStateHolder()
    val place = Place(nav.tab, nav.stack.size, nav.stack.lastOrNull())
    BackHandler(enabled = nav.stack.isNotEmpty()) { nav.pop() }
    Box(Modifier.fillMaxSize()) {
        AnimatedContent(
            targetState = place,
            transitionSpec = {
                val push = tween<androidx.compose.ui.unit.IntOffset>(350, easing = FastOutSlowInEasing)
                when {
                    !nav.animated -> EnterTransition.None togetherWith ExitTransition.None
                    initialState.tab != targetState.tab -> fadeIn(tween(120)) togetherWith fadeOut(tween(120))
                    targetState.depth > initialState.depth ->
                        slideInHorizontally(push) { it } togetherWith slideOutHorizontally(push) { -it / 4 }
                    else -> (slideInHorizontally(push) { -it / 4 } togetherWith slideOutHorizontally(push) { it })
                        .apply { targetContentZIndex = -1f }
                }
            },
            label = "screens",
        ) { target ->
            holder.SaveableStateProvider("${target.tab}/${target.depth}/${target.route}") {
                when (val route = target.route) {
                    null -> when (target.tab) {
                        Tab.RECENT -> RecentScreen()
                        Tab.LIBRARY -> LibraryScreen()
                        Tab.SEARCH -> SearchScreen()
                        Tab.SETTINGS -> SettingsScreen()
                    }
                    is Route.BookDetail -> BookScreen(route.bookId)
                    is Route.Reader -> ReaderScreen(route.bookId, route.siteChapterId, route.paragraph, route.offset)
                    Route.Sites -> SitesScreen()
                    is Route.Site -> SiteScreen(route.id)
                    Route.DeriveRule -> DeriveRuleScreen()
                    is Route.ChapterDownloads -> ChapterDownloadScreen(route.bookId)
                    Route.DownloadQueue -> DownloadQueueScreen()
                    Route.Storage -> StorageScreen()
                    Route.Cache -> CacheScreen()
                    Route.Appearance -> AppearanceScreen()
                    Route.ThemeEditor -> ThemeEditorScreen()
                    is Route.ToolbarEditor -> ToolbarEditorScreen(route.layer)
                    Route.Backup -> BackupScreen()
                    Route.Retention -> RetentionScreen()
                    Route.Start -> StartScreen()
                    Route.Diagnostics -> DiagnosticsScreen()
                    is Route.Marks -> MarksScreen(route.bookId)
                }
            }
        }
        // The reader is full screen on iOS too; everything else keeps the tab bar.
        AnimatedVisibility(
            place.route !is Route.Reader,
            Modifier.align(Alignment.BottomCenter),
            enter = fadeIn(tween(200)),
            exit = fadeOut(tween(100)),
        ) {
            TabBar(nav.tab) { nav.select(it) }
        }
    }
}

/** The iOS 26 tab bar: a floating glass capsule, the selected tab lifted in a pill. */
@Composable
private fun TabBar(selected: Tab, onSelect: (Tab) -> Unit) {
    val p = LocalPalette.current
    val shadow = Color.Black.copy(alpha = 0.12f)
    androidx.compose.foundation.layout.Row(
        Modifier.navigationBarsPadding().padding(start = Margin, end = Margin, bottom = 8.dp)
            .fillMaxWidth().height(62.dp)
            .shadow(18.dp, CircleShape, ambientColor = shadow, spotColor = shadow)
            .background(p.glass, CircleShape)
            .border(0.5.dp, p.glassEdge, CircleShape)
            .padding(4.dp),
    ) {
        for (tab in Tab.entries) {
            val on = tab == selected
            val tint = if (on) p.accent else p.label
            Column(
                Modifier.weight(1f).fillMaxHeight().clip(CircleShape)
                    .background(if (on) p.glassPill else Color.Transparent)
                    .clickable(remember { MutableInteractionSource() }, indication = null, role = Role.Tab) { onSelect(tab) }
                    .semantics {
                        contentDescription = tab.title
                        this.selected = on
                    },
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Icon(tab.icon, null, Modifier.size(28.dp), tint = tint)
                Text(tab.title, fontSize = 10.sp, lineHeight = 12.sp, fontWeight = FontWeight.SemiBold, color = tint)
            }
        }
    }
}

@Composable
private fun WebViewHost(webView: WebView, modifier: Modifier) {
    AndroidView(
        factory = {
            (webView.parent as? ViewGroup)?.removeView(webView)
            webView
        },
        modifier = modifier,
    )
}

/** Failures nobody else shows: red, at the top, gone after five seconds or a tap. */
@Composable
private fun ErrorBanner(app: App) {
    val message by app.banner.collectAsState()
    var shown by remember { mutableStateOf("") }
    LaunchedEffect(message) {
        message?.let {
            shown = it
            delay(5_000)
            app.banner.value = null
        }
    }
    AnimatedVisibility(
        message != null,
        enter = slideInVertically { -it } + fadeIn(),
        exit = slideOutVertically { -it } + fadeOut(),
    ) {
        Text(
            shown, style = Type.footnote, color = Color.White,
            modifier = Modifier.statusBarsPadding().padding(horizontal = Margin, vertical = 6.dp).fillMaxWidth()
                .background(LocalPalette.current.red.copy(alpha = 0.92f), RoundedCornerShape(12.dp))
                .clickable { app.banner.value = null }
                .padding(horizontal = 14.dp, vertical = 10.dp),
        )
    }
}

/**
 * The iOS `ChallengeSheet`: the fetcher's own web view, handed to the reader to complete a
 * check that would not clear itself, or to sign in. Closing it never retries anything by itself.
 */
@Composable
private fun ChallengeSheet(challenge: App.Challenge, webView: WebView, onClose: () -> Unit) {
    val p = LocalPalette.current
    // A window of its own, not a layer of the app's: every other sheet (adding books, the
    // reader's settings) is a window over the app, and a wall met while one is up opened
    // underneath it, out of reach, while the row asked the reader to tap to sign in.
    Dialog(onClose, DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Column(
            Modifier.statusBarsPadding().padding(top = 10.dp).fillMaxSize()
                .clip(RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp)).background(p.background)
                // A sign-in is typed: the page has to scroll its button out from under the keyboard.
                .imePadding(),
        ) {
            // The two must not be confused: "prove you are human" and "type your password".
            SheetBar(
                if (challenge.signIn) "在網站登入" else "網站驗證",
                leading = { BarTextButton("取消", onClick = onClose) },
                trailing = { BarTextButton("完成", bold = true, onClick = onClose) },
            )
            Column(Modifier.padding(horizontal = Margin + 4.dp)) {
                Text(
                    Uri.parse(challenge.url).host ?: challenge.url, style = Type.footnote, fontFamily = FontFamily.Monospace,
                    color = p.secondary, maxLines = 1, overflow = TextOverflow.MiddleEllipsis,
                )
                Text(challenge.doing, style = Type.subheadline, color = p.label, modifier = Modifier.padding(top = 8.dp))
                Text(
                    if (challenge.signIn) {
                        "這個網站只給登入的讀者看這本書。請在下方登入後按「完成」，App 會接著繼續。你打的東西 App 看不到，會直接送到那個網站。"
                    } else {
                        "這個網站要求人工驗證。請在下方完成驗證後按「完成」，App 會接著繼續。"
                    },
                    style = Type.subheadline, color = p.secondary, modifier = Modifier.padding(top = 4.dp, bottom = 12.dp),
                )
            }
            WebViewHost(webView, Modifier.fillMaxSize())
        }
    }
}
