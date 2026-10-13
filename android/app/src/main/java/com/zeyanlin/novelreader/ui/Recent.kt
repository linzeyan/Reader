package com.zeyanlin.novelreader.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.zeyanlin.novelreader.data.ShelfRow
import com.zeyanlin.novelreader.data.recentReadingCount
import com.zeyanlin.novelreader.siterules.SiteRule

/** The iOS `RecentReadingView`: books by when they were last read, each a tap from its page. */
@Composable
fun RecentScreen() {
    val app = app()
    val nav = LocalNavigator.current
    val rows by remember { app.library.recent() }.collectAsState(null)
    // Read once per visit: the length is chosen in settings, another tab, so coming back here reads it again.
    val count = remember { app.prefs.recentReadingCount() }
    ListScreen("近期閱讀", large = true) {
        val list = rows?.take(count) ?: return@ListScreen
        if (list.isEmpty()) {
            item {
                Box(Modifier.fillParentMaxHeight(0.75f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                    EmptyState(Symbols.ClockFill, "還沒有閱讀紀錄", "從書櫃打開一本書，這裡就會記住你讀到哪裡。")
                }
            }
            return@ListScreen
        }
        group(list, key = { it.book.id }) { row, edge ->
            // A chapter the site has since withdrawn leaves nothing to resume into.
            val gone = row.chapterIndex == null
            Cell(
                edge,
                onClick = if (gone) null else ({ nav.resume(Route.Reader(row.book.id)) }),
                chevron = true,
                separatorStart = RowPadding + 44.dp + 12.dp,
            ) { RecentRow(row) }
        }
    }
}

@Composable
private fun RowScope.RecentRow(row: ShelfRow) {
    val p = LocalPalette.current
    Cover(44.dp, 60.dp, row.book)
    Spacer(Modifier.width(12.dp))
    val feed = row.book.kind == SiteRule.Kind.FEED
    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Text(row.book.shownName, style = Type.body, color = p.label, maxLines = 2, overflow = TextOverflow.Ellipsis)
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(row.book.kind.icon, null, Modifier.size(15.dp), tint = p.secondary)
            Text(
                row.chapterTitle ?: if (feed) "文章已不在訂閱源中" else "章節已不在目錄中", style = Type.caption, color = p.secondary,
                maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
        }
        val index = row.chapterIndex
        when {
            row.isFinished -> Text("已讀完", style = Type.caption2, fontWeight = FontWeight.SemiBold, color = p.secondary)
            index != null -> {
                val share = row.book.lastReadFraction?.let { " · ${percent(it)}" }.orEmpty()
                Text(
                    "第 ${index + 1} / ${row.chapterCount} ${if (feed) "篇" else "章"}$share",
                    style = Type.caption2.copy(fontFeatureSettings = TABULAR), color = p.tertiary,
                )
            }
        }
    }
}
