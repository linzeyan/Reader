package com.zeyanlin.novelreader.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListScope
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
import androidx.compose.runtime.saveable.Saver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.zeyanlin.novelreader.App
import com.zeyanlin.novelreader.services.FullTextExcerpt
import com.zeyanlin.novelreader.services.LibrarySearch
import com.zeyanlin.novelreader.services.LibraryTextHit
import com.zeyanlin.novelreader.services.SearchResult
import com.zeyanlin.novelreader.services.SiteSearchOutcome
import com.zeyanlin.novelreader.siterules.SiteRule
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json

/**
 * The iOS `SearchView`: sites for books the reader does not have yet — one source or all of
 * them, filling in site by site, a failing site shown as such rather than left out — or, behind
 * the switch, the text of the books they do. One field for both: the word looked for is often
 * the same, and retyping it to change the question would tax the commonest use of this screen.
 */
@Composable
fun SearchScreen() {
    val app = app()
    val nav = LocalNavigator.current
    val p = LocalPalette.current
    val scope = rememberCoroutineScope()
    val rules by app.sites.rules.collectAsState()
    val shelf by remember { app.library.shelf() }.collectAsState(null)
    // The shelf's mode decides here too: a novel source asked for a comic title answers with
    // novels that share its name, which is worse than nothing.
    val mode by app.mediaMode.collectAsState()
    val sources = rules.filter { it.kind == mode }
    val searchable = sources.filter { it.search != null }
    var query by rememberSaveable { mutableStateOf("") }
    var inLibrary by rememberSaveable { mutableStateOf(false) }
    var site by rememberSaveable { mutableStateOf<String?>(null) }
    var searched by rememberSaveable { mutableStateOf(false) }
    // Kept across leaving the tab, as iOS keeps them; what was still arriving is not — the
    // search stops when the screen goes, and a spinner brought back would never end.
    var outcomes by rememberSaveable(stateSaver = outcomesSaver) { mutableStateOf(emptyList<SiteSearchOutcome>()) }
    var pending by remember { mutableStateOf(emptyList<SiteRule>()) }
    var job by remember { mutableStateOf<Job?>(null) }
    var adding by remember { mutableStateOf(emptySet<String>()) }
    var picking by remember { mutableStateOf(false) }
    val focus = remember { FocusRequester() }
    val focusManager = LocalFocusManager.current
    val onShelf = shelf.orEmpty().map { it.book.id }.toSet()
    var hits by remember { mutableStateOf(emptyList<LibraryTextHit>()) }
    var textSearching by remember { mutableStateOf(false) }
    // Whether the query on screen has been answered, so "not found" is never said of a search still running.
    var answered by remember { mutableStateOf(false) }
    val tooShort = query.trim().let { it.codePointCount(0, it.length) < LibrarySearch.MINIMUM_QUERY_LENGTH }

    fun start() {
        val trimmed = query.trim()
        if (trimmed.isEmpty()) return
        // Down with the keyboard, as iOS does on submit: the results are what comes next.
        focusManager.clearFocus()
        job?.cancel()
        outcomes = emptyList()
        searched = true
        pending = if (site == null) searchable else searchable.filter { it.id == site }
        val rules = pending
        job = scope.launch {
            try {
                app.search.searchAll(trimmed, rules).collect { outcome ->
                    outcomes = outcomes + outcome
                    pending = pending.filter { it.id != outcome.siteId }
                }
            } finally {
                pending = emptyList()
            }
        }
    }

    fun add(result: SearchResult) {
        adding = adding + result.id
        scope.launch {
            try {
                app.add(result)
            } catch (e: Exception) {
                app.report(e, "App 正在加入《${result.title}》。")
            } finally {
                adding = adding - result.id
            }
        }
    }

    // Results name sites of the medium just left: cleared rather than re-run, since the query was
    // typed for that shelf and re-running it would spend every source of this one on it.
    var searchedMode by rememberSaveable { mutableStateOf(mode) }
    LaunchedEffect(mode) {
        if (mode == searchedMode) return@LaunchedEffect
        searchedMode = mode
        job?.cancel()
        outcomes = emptyList()
        pending = emptyList()
        searched = false
        site = null
    }

    // The shelf's switch, setting the same app-wide value: someone here for a comic should not
    // have to go back to the shelf to say so.
    ListScreen("搜尋", large = true, leading = { MediaModePicker(mode) { app.mediaMode.value = it } }) {
        item {
            SearchField(
                query, { query = it }, if (inLibrary) "內文中的一段話" else "書名或作者",
                Modifier.padding(top = 4.dp, bottom = 8.dp).focusRequester(focus),
                // My books answer as the reader types; there the key only puts the keyboard away.
                onSearch = if (inLibrary) ({ focusManager.clearFocus() }) else ({ start() }),
            )
        }
        // Above both modes' empty states, so neither can hide the way to the other.
        item {
            Box(Modifier.padding(horizontal = Margin, vertical = 8.dp)) {
                Segmented(listOf(false to "站台", true to "我的書"), inLibrary) { inLibrary = it }
            }
        }
        if (inLibrary) {
            when {
                hits.isNotEmpty() -> group(hits, key = { it.id }) { hit, edge ->
                    Cell(
                        edge, chevron = false, verticalPadding = 10.dp,
                        onClick = { nav.resume(Route.Reader(hit.book.id, hit.siteChapterId, hit.excerpt.paragraph, hit.excerpt.characterOffset)) },
                    ) { HitRow(hit) }
                }
                textSearching -> item {
                    Box(Modifier.fillParentMaxHeight(0.6f).fillMaxWidth(), contentAlignment = Alignment.Center) { Spinner(size = 24.dp) }
                }
                tooShort -> empty("在書裡找一段話", "輸入兩個字以上，從已下載的章節裡找出那一段，並跳到那一章。", Symbols.TextMagnifyingGlass)
                // Explains the boundary: "not found" and "never downloaded, so never looked at"
                // are different answers, and a reader told only the first would think it broken.
                answered -> empty("找不到這段文字", "只有已下載的章節會被搜尋。還沒下載的章節不在裡面。", Symbols.TextMagnifyingGlass)
            }
            return@ListScreen
        }
        when {
            sources.isEmpty() -> {
                when (mode) {
                    SiteRule.Kind.NOVEL -> empty("尚未加入來源", "請先在「設定 → 來源」加入站台規則檔。")
                    SiteRule.Kind.COMIC -> empty("尚未加入漫畫來源", "請先在「設定 → 來源」加入漫畫站台規則檔。")
                    SiteRule.Kind.FEED -> empty("還沒有訂閱", "貼上訂閱源的網址就能加入，一次可以貼很多個。")
                }
                return@ListScreen
            }
            searchable.isEmpty() -> {
                empty("沒有可搜尋的來源", "已安裝的來源都沒有提供搜尋，可改用貼上網址加入書籍。")
                return@ListScreen
            }
        }
        item {
            Box {
                Cell(Edge.ONLY, onClick = { picking = true }, chevron = false) {
                    Text("搜尋範圍", style = Type.body, color = p.label, modifier = Modifier.weight(1f))
                    Text(searchable.firstOrNull { it.id == site }?.name ?: "全部來源", style = Type.body, color = p.secondary)
                    Spacer(Modifier.width(6.dp))
                    Chevron(direction = Direction.DOWN, color = p.secondary, width = 10.dp, height = 6.dp)
                }
                DropdownMenu(picking, { picking = false }, shape = RoundedCornerShape(20.dp), containerColor = p.card) {
                    for ((id, name) in listOf(null to "全部來源") + searchable.map { it.id to it.name }) {
                        DropdownMenuItem(
                            text = { Text(name, style = Type.body) },
                            leadingIcon = { Box(Modifier.size(20.dp)) { if (id == site) Icon(Symbols.CheckmarkCircleFill, null, tint = p.accent) } },
                            onClick = {
                                picking = false
                                site = id
                            },
                        )
                    }
                }
            }
        }
        if (!searched) {
            gap(20.dp)
            item { Cell(Edge.ONLY) { Text("輸入關鍵字後按鍵盤上的搜尋。", style = Type.footnote, color = p.secondary) } }
        }
        for (outcome in outcomes) {
            header(outcome.siteName, key = "site:${outcome.siteId}")
            when {
                outcome.failure != null -> item(key = "failure:${outcome.siteId}") {
                    // A check or a sign-in is the reader's to clear; once it is, searching again goes
                    // through. Loaded again first: the sites searched after this one have since had the web view.
                    val challenge = outcome.challenge
                    Cell(
                        Edge.ONLY, chevron = false,
                        onClick = challenge?.let {
                            {
                                app.fetcher.webView.loadUrl(it)
                                app.challenge.value = App.Challenge(it, "App 正在搜尋「${outcome.siteName}」。", outcome.signIn)
                            }
                        },
                    ) {
                        Icon(Symbols.ExclamationTriangle, null, Modifier.size(18.dp), tint = p.orange)
                        Spacer(Modifier.width(10.dp))
                        Text(outcome.failure, style = Type.footnote, color = p.orange)
                    }
                }
                outcome.results.isEmpty() -> item(key = "none:${outcome.siteId}") {
                    Cell(Edge.ONLY) { Text("沒有結果", style = Type.footnote, color = p.secondary) }
                }
                else -> group(outcome.results, key = { "${outcome.siteId}:${it.id}" }) { result, edge ->
                    val busy = result.id in adding
                    val added = result.id in onShelf
                    Cell(
                        edge, chevron = false, separatorStart = RowPadding + 40.dp + 12.dp, verticalPadding = 10.dp,
                        onClick = if (busy || added) null else ({ add(result) }),
                    ) { ResultRow(result, busy, added) }
                }
            }
        }
        for (rule in pending.filter { r -> outcomes.none { it.siteId == r.id } }) {
            header(rule.name, key = "pending:${rule.id}")
            item(key = "searching:${rule.id}") {
                Cell(Edge.ONLY) {
                    Spinner(size = 16.dp)
                    Spacer(Modifier.width(10.dp))
                    Text("搜尋中…", style = Type.footnote, color = p.secondary)
                }
            }
        }
    }
    // On arrival, so the first tap offers Paste; only into an empty field, or the keyboard
    // would cover results the reader came back to.
    LaunchedEffect(Unit) { if (query.isEmpty() && (inLibrary || searchable.isNotEmpty())) focus.requestFocus() }
    LaunchedEffect(query, inLibrary) {
        if (!inLibrary) return@LaunchedEffect
        if (tooShort) {
            hits = emptyList()
            answered = false
            return@LaunchedEffect
        }
        // Typing 「玄重尺」 is three queries in as many tenths of a second, and only the last is a
        // question: a keystroke restarts this effect, which makes the pause a debounce.
        delay(250)
        textSearching = true
        try {
            hits = app.librarySearch.hits(query)
            answered = true
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // Nothing to offer is the honest answer to a search the database could not run.
            hits = emptyList()
            answered = true
        } finally {
            textSearching = false
        }
    }
}

/** The quoted sentence leads, the match picked out: a passage is remembered by what it says. */
@Composable
private fun RowScope.HitRow(hit: LibraryTextHit) {
    val p = LocalPalette.current
    val e: FullTextExcerpt = hit.excerpt
    val quote = remember(e) {
        buildAnnotatedString {
            append(e.text)
            addStyle(SpanStyle(fontWeight = FontWeight.SemiBold), e.matchStart, e.matchEnd)
        }
    }
    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(quote, style = Type.subheadline, color = p.label, maxLines = 3, overflow = TextOverflow.Ellipsis)
        Text(
            "${hit.book.shownName} · ${hit.chapterTitle}", style = Type.caption, color = p.secondary,
            maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
    }
}

/**
 * Tapping a hit puts it on the shelf: the row already has what the book page would fetch. The
 * mark on the right says where it stands — to add, adding, or already there — where iOS shows
 * a banner once; a shelf check per row also keeps one book from being added twice.
 */
@Composable
private fun RowScope.ResultRow(result: SearchResult, busy: Boolean, added: Boolean) {
    val p = LocalPalette.current
    Cover(40.dp, 54.dp, result.id, result.siteId, result.siteBookId, result.coverURL)
    Spacer(Modifier.width(12.dp))
    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Text(result.title, style = Type.body, color = p.label, maxLines = 2, overflow = TextOverflow.Ellipsis)
        result.author?.takeIf { it.isNotEmpty() }?.let {
            Text(it, style = Type.caption, color = p.secondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
    Spacer(Modifier.width(10.dp))
    Box(Modifier.size(24.dp), contentAlignment = Alignment.Center) {
        when {
            busy -> Spinner(size = 18.dp)
            added -> Icon(Symbols.CheckmarkCircleFill, "已在書櫃", tint = p.green)
            else -> Icon(Symbols.PlusCircle, "加入書櫃", tint = p.accent)
        }
    }
}

private fun LazyListScope.empty(title: String, message: String, icon: ImageVector = Symbols.Search) {
    item {
        Box(Modifier.fillParentMaxHeight(0.6f).fillMaxWidth(), contentAlignment = Alignment.Center) {
            EmptyState(icon, title, message)
        }
    }
}

private val outcomesSaver = Saver<List<SiteSearchOutcome>, String>(
    save = { Json.encodeToString(it) },
    restore = { Json.decodeFromString(it) },
)
