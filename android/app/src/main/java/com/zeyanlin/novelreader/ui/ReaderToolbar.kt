package com.zeyanlin.novelreader.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.toMutableStateList
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import com.zeyanlin.novelreader.siterules.SiteRule
import kotlinx.serialization.Serializable
import kotlin.math.abs

/**
 * One control in a reader's bottom bar, as something the reader can move and fold away — the iOS
 * `ReaderButton`. One type for both bars: a comic shelf arranging its bar is doing what the novel
 * shelf does, and two enums would be two default orders to keep in step.
 *
 * Kept by [raw] name, so a control some later build renames comes back as one this build does not
 * know and is dropped, rather than spoiling the arrangement it sits in. The declaration order is
 * the order the bars were designed in: what a reader who never opened the editor reads with.
 */
enum class ReaderButton(val raw: String, val label: String, val caption: String? = null) {
    // No caption, unlike iOS: Android has no switch for leaving by the edge, so this one is always there.
    BACK("back", "返回"),
    CATALOG("catalog", "目錄"),
    BOOKMARK("bookmark", "加入書籤"),
    PREVIOUS("previousChapter", "上一章"),
    NEXT("nextChapter", "下一章"),

    /** Re-reading a subscribed article from its page, with the browser on the long press. */
    ORIGINAL("original", "抓取全文", "只在有原始網頁的文章上出現"),
    AUTO_SCROLL("autoScroll", "開始自動捲動"),
    SPEECH("speech", "開始朗讀"),
    SETTINGS("settings", "閱讀設定"),
    ;

    /** The editor's glyph: the bar's own, in the state it spends most of its time in. Null for the drawn chevron. */
    val icon: ImageVector?
        get() = when (this) {
            BACK -> null
            CATALOG -> Symbols.ListBullet
            BOOKMARK -> Symbols.Bookmark
            PREVIOUS -> Symbols.ArrowUpToLine
            NEXT -> Symbols.ArrowDownToLine
            ORIGINAL -> Symbols.ArrowClockwise
            AUTO_SCROLL -> Symbols.PlayCircle
            SPEECH -> Symbols.Headphones
            SETTINGS -> Symbols.TextFormatSize
        }

    /**
     * Whether a shelf has this control at all — not whether it is on screen right now, which the
     * bar answers because it changes while the reader stands there (an article has an original
     * only where it came from one). No comic will ever have a sentence to read out or bookmark.
     */
    fun appears(kind: SiteRule.Kind) = when (this) {
        BOOKMARK, SPEECH -> kind != SiteRule.Kind.COMIC
        ORIGINAL -> kind == SiteRule.Kind.FEED
        else -> true
    }
}

/**
 * How the reader arranged a bottom bar — the iOS `ReaderToolbarLayout`. Stored as what the reader
 * said rather than as the finished bar, so an arrangement outlives the build it was made in: a
 * control added later is missing from [order] and goes where it was designed to sit; one removed
 * is a name nobody knows and is dropped. Neither asks the reader to arrange again.
 *
 * [folded] is named rather than implied by absence from [order]: absence already means "a control
 * this arrangement never heard of".
 */
@Serializable
data class ReaderToolbarLayout(val order: List<String> = emptyList(), val folded: List<String> = emptyList()) {
    fun isFolded(button: ReaderButton) = button.raw in folded

    /** Every control in this arrangement's order: a shelf's subset, or all of them for null — the general answers. */
    fun arrangement(kind: SiteRule.Kind?): List<ReaderButton> {
        val available = ReaderButton.entries.filter { kind == null || it.appears(kind) }
        val arranged = order.mapNotNull { raw -> available.firstOrNull { it.raw == raw } }.toMutableList()
        // Where it was designed to sit, not on the end: a new "next chapter" after the settings
        // button would be in the one place nobody looks for it.
        for (button in available) {
            if (button in arranged) continue
            val after = available.takeWhile { it != button }.lastOrNull { it in arranged }
            arranged.add(after?.let { arranged.indexOf(it) + 1 } ?: 0, button)
        }
        return arranged
    }

    /** The bar as drawn: what sits on it, and what is folded behind its last button. */
    fun resolve(kind: SiteRule.Kind) = arrangement(kind).partition { !isFolded(it) }

    companion object {
        fun of(order: List<ReaderButton>, folded: List<ReaderButton>) = ReaderToolbarLayout(order.map { it.raw }, folded.map { it.raw })
    }
}

/**
 * One control as both places that draw it need it — iOS's `Control`, for its reason: a control
 * folded away must do exactly what it did on the bar. [menu] is a control that is two actions:
 * a long press on the bar, and flattened into its two rows behind the last button, where a menu
 * inside a menu is a submenu nobody opens.
 */
class BarControl(
    val label: String,
    val onClick: (() -> Unit)?,
    val menu: List<BarControl>? = null,
    val glyph: @Composable () -> Unit,
)

/** A reader's bottom bar: [bar] evenly across, and 更多 last — only when something is folded, or it is a place spent on nothing. */
@Composable
fun ReaderBar(bar: List<BarControl>, folded: List<BarControl>) {
    val p = LocalPalette.current
    Row(
        Modifier.navigationBarsPadding().padding(start = 12.dp, end = 12.dp, bottom = 6.dp).fillMaxWidth()
            .shadow(10.dp, RoundedCornerShape(18.dp), ambientColor = Color.Black.copy(alpha = 0.12f), spotColor = Color.Black.copy(alpha = 0.12f))
            .background(p.glass, RoundedCornerShape(18.dp))
            .padding(vertical = 10.dp),
    ) {
        for (control in bar) BarItem(control)
        if (folded.isNotEmpty()) BarItem(BarControl("更多", null, folded.flatMap { it.menu ?: listOf(it) }) { ToolbarIcon(Symbols.EllipsisCircle, true) }, tapOpens = true)
    }
}

@Composable
private fun RowScope.BarItem(control: BarControl, tapOpens: Boolean = false) {
    var open by remember { mutableStateOf(false) }
    val menu = control.menu
    ToolbarItem(control.label, if (tapOpens) ({ open = true }) else control.onClick, onLongClick = menu?.takeUnless { tapOpens }?.let { { open = true } }) {
        Box {
            control.glyph()
            if (menu != null) {
                val p = LocalPalette.current
                DropdownMenu(open, { open = false }, shape = RoundedCornerShape(20.dp), containerColor = p.card) {
                    for (item in menu) {
                        DropdownMenuItem(
                            text = { Text(item.label, style = Type.body) },
                            onClick = {
                                open = false
                                item.onClick?.invoke()
                            },
                            leadingIcon = item.glyph,
                            enabled = item.onClick != null,
                        )
                    }
                }
            }
        }
    }
}

/** The row into the editor, in every settings list that has one — iOS keeps it outside its per-layer branch for that reason. */
fun LazyListScope.toolbarSection(onEdit: () -> Unit) {
    gap(20.dp)
    item {
        val p = LocalPalette.current
        Cell(Edge.ONLY, onClick = onEdit) { Text("工具列", style = Type.body, color = p.label, modifier = Modifier.weight(1f)) }
    }
    footer("頁面下方那一列放哪些按鈕、怎麼排。")
}

/**
 * Arranging the bar — the iOS `ReaderToolbarEditor`. One list rather than "on the bar" and "folded
 * away": the arrangement is one order, and a folded control keeps its place, because that place
 * is where it sits in the menu behind the last button. The general answers list every control,
 * as iOS lists them; a shelf or a book lists its shelf's subset.
 */
@Composable
fun ToolbarEditor(settings: ReaderSettings, layer: Layer, list: @Composable (LazyListScope.() -> Unit) -> Unit) {
    val p = LocalPalette.current
    // Read at the moment of asking: the drag handler below is set up once and outlives this composition.
    val look = Look(settings, layer)
    val layout = look.toolbar
    fun write(arrangement: ReaderToolbarLayout?) = settings.edit(layer) { it.copy(toolbar = arrangement) }
    // Reordered live under the finger, written once when it lets go: one write a drag, not one a row passed.
    val order = remember(layout) { layout.arrangement(layer.kind).toMutableStateList() }
    var dragged by remember { mutableStateOf<ReaderButton?>(null) }
    var shift by remember { mutableFloatStateOf(0f) }
    val heights = remember { HashMap<ReaderButton, Int>() }
    // The gesture outlives a fold, which hands this screen a new list; it must move the one on screen.
    val current by rememberUpdatedState(order)
    list {
        header("按鈕")
        itemsIndexed(order, key = { _, it -> it.raw }) { index, button ->
            val folded = layout.isFolded(button)
            val tint = if (folded) p.secondary else p.label
            val lifted = button == dragged
            Cell(
                Edge.of(index, order.size),
                Modifier.zIndex(if (lifted) 1f else 0f).graphicsLayer { translationY = if (lifted) shift else 0f }
                    .onSizeChanged { heights[button] = it.height },
            ) {
                Box(Modifier.width(28.dp), contentAlignment = Alignment.Center) {
                    val icon = button.icon
                    if (icon == null) Chevron(direction = Direction.LEFT, color = tint, width = 9.dp, height = 16.dp, stroke = 2.2.dp) else Icon(icon, null, Modifier.size(22.dp), tint = tint)
                }
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text(button.label, style = Type.body, color = tint)
                    // On the row it applies to: a reader wondering why a control is not on the bar is looking at that control.
                    button.caption?.let { Text(it, style = Type.caption, color = p.secondary) }
                }
                Icon(
                    if (folded) Symbols.EllipsisCircle else Symbols.CheckmarkCircleFill, if (folded) "放回工具列" else "收起來",
                    Modifier.clickable(role = Role.Button) {
                        // Written in the arrangement's order, so the menu behind the last button reads down the bar.
                        write(ReaderToolbarLayout.of(order, order.filter { layout.isFolded(it) != (it == button) }))
                    }.padding(4.dp).size(22.dp),
                    tint = if (folded) p.secondary else p.accent,
                )
                Spacer(Modifier.width(12.dp))
                Icon(
                    Symbols.Line3Horizontal, "重新排序",
                    Modifier.size(22.dp).pointerInput(button, layer) {
                        val done = {
                            dragged = null
                            shift = 0f
                            val now = look.toolbar
                            write(ReaderToolbarLayout.of(current, current.filter(now::isFolded)))
                        }
                        detectVerticalDragGestures(onDragStart = { dragged = button }, onDragEnd = done, onDragCancel = done) { change, dy ->
                            change.consume()
                            shift += dy
                            // Past half the neighbour's height is where iOS lets it change places.
                            val at = current.indexOf(button)
                            val toward = if (shift > 0) at + 1 else at - 1
                            val neighbour = current.getOrNull(toward) ?: return@detectVerticalDragGestures
                            val height = heights[neighbour] ?: return@detectVerticalDragGestures
                            if (abs(shift) > height / 2f) {
                                current.add(toward, current.removeAt(at))
                                shift -= if (shift > 0) height else -height
                            }
                        }
                    },
                    tint = p.tertiary,
                )
            }
        }
        footer("拖曳可以調整順序。收起來的按鈕不會消失，都在最右邊那顆按鈕的選單裡。")
        // The way back to following — the general answers follow nobody, so a row there would do nothing.
        // Body-sized rather than the settings' FollowLine: iOS draws this one as a row of its own.
        if (layer != Layer.General) {
            gap(20.dp)
            item {
                val revert = settings.overrides(layer).toolbar?.let { { write(null) } }
                val color = if (revert == null) p.secondary else p.accent
                Cell(Edge.ONLY, onClick = revert, chevron = false) {
                    if (revert != null) {
                        Icon(Symbols.ArrowUturnBackward, null, Modifier.size(20.dp), tint = color)
                        Spacer(Modifier.width(8.dp))
                    }
                    Text(if (layer is Layer.Book) "跟隨書櫃的排列" else "跟隨預設的排列", style = Type.body, color = color)
                }
            }
        }
    }
}

@Composable
fun ToolbarEditorScreen(layer: Layer) {
    val nav = LocalNavigator.current
    ToolbarEditor(app().reader, layer) { content -> ListScreen("工具列", onBack = nav::pop, content = content) }
}
