package com.zeyanlin.novelreader.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.zeyanlin.novelreader.services.MarksExport
import com.zeyanlin.novelreader.siterules.SiteRule
import java.io.File
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale
import kotlinx.coroutines.launch

/**
 * The iOS `ReadingMarksView`: one book's bookmarks and highlights behind a switch. One screen
 * because to a reader they are one thing — what I left in this book — and a switch rather than
 * sections so two hundred highlights cannot bury the bookmarks.
 */
@Composable
fun MarksScreen(bookId: String) {
    val app = app()
    val nav = LocalNavigator.current
    val p = LocalPalette.current
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val book by remember(bookId) { app.library.book(bookId) }.collectAsState(null)
    val chapters by remember(bookId) { app.library.chapters(bookId) }.collectAsState(null)
    val bookmarks by remember(bookId) { app.library.readingBookmarks(bookId) }.collectAsState(null)
    val highlights by remember(bookId) { app.library.highlights(bookId) }.collectAsState(null)
    var showHighlights by rememberSaveable { mutableStateOf(false) }
    // Read from the stored catalog rather than kept on the mark, so a title the site has since
    // corrected reads correctly here; a chapter it has dropped is absent, and so not a destination.
    val titles = remember(chapters) { chapters.orEmpty().associate { it.siteChapterId to it.title } }

    fun open(siteChapterId: String, paragraph: Int, offset: Int): (() -> Unit)? =
        if (siteChapterId in titles) ({ nav.push(Route.Reader(bookId, siteChapterId, paragraph, offset)) }) else null

    // A purged article is gone from the feed, not from a catalog: the feed decides what it still offers.
    val gone = if (book?.kind == SiteRule.Kind.FEED) "文章已不在訂閱源中" else "章節已不在目錄中"
    val export = book?.let { MarksExport(it, chapters.orEmpty(), bookmarks.orEmpty(), highlights.orEmpty()) }

    ListScreen(
        "標記",
        onBack = nav::pop,
        actions = {
            // Both kinds, whichever list is on screen: what I left in this book means all of it.
            // Disabled rather than hidden: the empty state below already says why.
            BarButton(Symbols.SquareAndArrowUp, "匯出標記", enabled = export?.isEmpty == false) {
                // A file, as iOS shares one: the .md is what a notes app reads to render it as
                // Markdown, and what lands in Files is a document. Typed as plain text, as iOS
                // declares it, so every app that takes text is offered it.
                val file = File(app.exports.apply { mkdirs() }, export!!.filename)
                file.writeText(export.text())
                context.shareFile(file, "text/plain")
            }
        },
    ) {
        // Above the list, not a header in it: the empty state below must not hide the way to
        // the other kind.
        item {
            Box(Modifier.padding(horizontal = Margin, vertical = 8.dp)) {
                Segmented(listOf(false to "書籤", true to "劃線"), showHighlights) { showHighlights = it }
            }
        }
        if (showHighlights) {
            val list = highlights ?: return@ListScreen
            if (list.isEmpty()) {
                empty(Symbols.Highlighter, "還沒有劃線", "長按書裡的文字就能劃線：先選起一個詞，再拖動兩端的把手，想劃幾個字就劃幾個字。劃好的線也能拷貝。")
                return@ListScreen
            }
            group(list, key = { it.id }) { h, edge ->
                // The text leads: a highlight is remembered by what it says, a bookmark by where it is.
                Cell(
                    edge, onClick = open(h.siteChapterId, h.startParagraph, h.startCharacterOffset), chevron = true,
                    onDelete = { scope.launch { app.library.removeHighlight(h.id) } },
                ) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(h.excerpt, style = Type.subheadline, color = p.label, maxLines = 3, overflow = TextOverflow.Ellipsis)
                        Text(titles[h.siteChapterId] ?: gone, style = Type.caption, color = p.secondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(stamp(h.createdAt), style = Type.caption2, color = p.tertiary)
                    }
                }
            }
        } else {
            val list = bookmarks ?: return@ListScreen
            if (list.isEmpty()) {
                empty(Symbols.Bookmark, "還沒有書籤", "閱讀時點一下畫面叫出控制列，再按書籤就能把目前位置存起來。")
                return@ListScreen
            }
            group(list, key = { it.id }) { b, edge ->
                // No confirmation: this throws away a pointer, not the text it points at.
                Cell(
                    edge, onClick = open(b.siteChapterId, b.paragraph, b.characterOffset), chevron = true,
                    onDelete = { scope.launch { app.library.removeReadingBookmark(b.id) } },
                ) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(titles[b.siteChapterId] ?: gone, style = Type.subheadline, color = p.label, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        b.excerpt?.takeIf { it.isNotEmpty() }?.let {
                            Text(it, style = Type.footnote, color = p.secondary, maxLines = 2, overflow = TextOverflow.Ellipsis)
                        }
                        Text(stamp(b.createdAt), style = Type.caption2, color = p.tertiary)
                    }
                }
            }
        }
    }
}


// Taiwanese whatever the device language: every other word on screen is, and a date in English
// beside them reads as a bug.
private val stampFormat = DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT)
    .withLocale(Locale.TAIWAN).withZone(ZoneId.systemDefault())

private fun stamp(millis: Long) = stampFormat.format(Instant.ofEpochMilli(millis))

private fun LazyListScope.empty(icon: ImageVector, title: String, message: String) {
    item {
        Box(Modifier.fillParentMaxHeight(0.7f).fillMaxWidth(), contentAlignment = Alignment.Center) {
            EmptyState(icon, title, message)
        }
    }
}
