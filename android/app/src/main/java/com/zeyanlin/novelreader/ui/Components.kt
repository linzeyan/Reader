package com.zeyanlin.novelreader.ui

import android.content.Context
import android.content.Intent
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxDefaults
import androidx.compose.material3.SwipeToDismissBoxState
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.pulltorefresh.rememberPullToRefreshState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.LaunchedEffect
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.launch
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.FileProvider
import com.zeyanlin.novelreader.App
import java.io.File
import com.zeyanlin.novelreader.data.Book
import androidx.compose.foundation.Image
import androidx.compose.runtime.produceState
import androidx.compose.ui.layout.ContentScale
import kotlin.math.floor

// Geometry measured off the iOS app's own screenshots (site/img), in points, which map to dp.

/** Inset-grouped card margin; the large title starts here too. 16 at phone widths, as on iOS. */
val Margin = 16.dp

/** The card's inner horizontal padding: where row text and separators start. */
val RowPadding = 16.dp
val CardRadius = 20.dp

/** What the floating tab bar covers at the bottom of a screen, besides the system bar. */
val TabBarSpace = 62.dp + 8.dp + 24.dp

@Composable
fun app(): App = LocalContext.current.applicationContext as App

/** Whole percent, rounded down, as iOS formats reading shares. */
fun percent(fraction: Double): String = "${floor(fraction * 100).toInt()}%"

/**
 * Hands [file] to the share sheet, as iOS's `ShareLink` hands over a file URL — by a grant on
 * this one file, since another app may not read a path in here. [file] must lie under a
 * directory `res/xml/shared_files.xml` names.
 */
fun Context.shareFile(file: File, type: String) {
    val uri = FileProvider.getUriForFile(this, "$packageName.files", file)
    val send = Intent(Intent.ACTION_SEND).setType(type).putExtra(Intent.EXTRA_STREAM, uri)
        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    startActivity(Intent.createChooser(send, null))
}

/** Tabular figures, for counts and percentages that tick over in place. */
const val TABULAR = "tnum"

@Composable
fun hairline(): Dp = with(LocalDensity.current) { 1.toDp() }

enum class Edge {
    TOP, MIDDLE, BOTTOM, ONLY;

    companion object {
        fun of(index: Int, count: Int) = when {
            count == 1 -> ONLY
            index == 0 -> TOP
            index == count - 1 -> BOTTOM
            else -> MIDDLE
        }
    }
}

/**
 * A screen in the iOS shape: a list scrolling under a bar of glass buttons, with an optional
 * large title that hands over to the inline one as it scrolls away.
 */
@Composable
fun ListScreen(
    title: String,
    large: Boolean = false,
    onBack: (() -> Unit)? = null,
    actions: (@Composable RowScope.() -> Unit)? = null,
    state: LazyListState = rememberLazyListState(),
    bottomSpace: Dp = TabBarSpace,
    /** A capsule at the leading edge, where a screen with no way back has room for one. */
    leading: (@Composable RowScope.() -> Unit)? = null,
    /** The pull gesture, on a list that has something to pull; it spins until this returns. */
    onRefresh: (suspend () -> Unit)? = null,
    content: LazyListScope.() -> Unit,
) {
    val p = LocalPalette.current
    val scope = rememberCoroutineScope()
    var refreshing by remember { mutableStateOf(false) }
    val threshold = with(LocalDensity.current) { 30.dp.toPx() }
    val collapsed by remember(large) {
        derivedStateOf { !large || state.firstVisibleItemIndex > 0 || state.firstVisibleItemScrollOffset > threshold }
    }
    val scrolled by remember { derivedStateOf { state.canScrollBackward } }
    // A tab's root screen is the one without a way back; only changes count, so coming back to a
    // list does not throw away where it was.
    if (onBack == null) {
        val nav = LocalNavigator.current
        LaunchedEffect(state) { snapshotFlow { nav.toTop }.drop(1).collect { state.animateScrollToItem(0) } }
    }
    val top = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    val bottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    Box(Modifier.fillMaxSize().background(p.background)) {
        val list: @Composable () -> Unit = {
            LazyColumn(
                Modifier.fillMaxSize(),
                state = state,
                contentPadding = PaddingValues(top = top + 44.dp + if (large) 4.dp else 10.dp, bottom = bottom + bottomSpace),
            ) {
                if (large) {
                    item(key = "largeTitle") {
                        Text(
                            title, style = Type.largeTitle, color = p.label, maxLines = 1, overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.padding(start = Margin, end = Margin, top = 6.dp, bottom = 4.dp),
                        )
                    }
                }
                content()
            }
        }
        if (onRefresh == null) {
            list()
        } else {
            val pull = rememberPullToRefreshState()
            PullToRefreshBox(
                refreshing,
                onRefresh = {
                    refreshing = true
                    scope.launch {
                        try {
                            onRefresh()
                        } finally {
                            refreshing = false
                        }
                    }
                },
                modifier = Modifier.fillMaxSize(),
                state = pull,
                // UIRefreshControl's spokes, not Material's disc: fading in with the pull, held while it works.
                // Under the bar, where the list's first row starts, not behind the glass.
                indicator = {
                    val shown = if (refreshing) 1f else pull.distanceFraction.coerceIn(0f, 1f)
                    if (shown > 0f) Spinner(Modifier.align(Alignment.TopCenter).padding(top = top + 52.dp).alpha(shown), size = 24.dp)
                },
            ) { list() }
        }
        TopBar(
            title = title,
            titleAlpha = animateFloatAsState(if (collapsed) 1f else 0f, tween(150), label = "title").value,
            scrim = animateFloatAsState(if (scrolled) 1f else 0f, tween(150), label = "scrim").value,
            onBack = onBack,
            actions = actions,
            leading = leading,
        )
    }
}

@Composable
fun TopBar(
    title: String,
    titleAlpha: Float,
    scrim: Float,
    onBack: (() -> Unit)?,
    actions: (@Composable RowScope.() -> Unit)?,
    leading: (@Composable RowScope.() -> Unit)? = null,
) {
    val p = LocalPalette.current
    Box(Modifier.fillMaxWidth()) {
        // iOS 26 fades scrolled content out under the bar instead of drawing a bar.
        Box(
            Modifier.matchParentSize().background(
                Brush.verticalGradient(
                    0f to p.background.copy(alpha = scrim),
                    0.65f to p.background.copy(alpha = scrim * 0.9f),
                    1f to p.background.copy(alpha = 0f),
                ),
            ),
        )
        Box(
            Modifier.statusBarsPadding().padding(bottom = 14.dp).fillMaxWidth().height(44.dp)
                .padding(horizontal = Margin),
        ) {
            if (onBack != null) {
                GlassCircle(onBack, "返回", Modifier.align(Alignment.CenterStart)) {
                    Chevron(Modifier.padding(end = 2.dp), direction = Direction.LEFT, color = p.label, width = 10.dp, height = 18.dp, stroke = 2.5.dp)
                }
            } else if (leading != null) {
                GlassCapsule(Modifier.align(Alignment.CenterStart), leading)
            }
            Text(
                title, style = Type.headline, color = p.label, maxLines = 1, overflow = TextOverflow.Ellipsis,
                modifier = Modifier.align(Alignment.Center).padding(horizontal = 96.dp).alpha(titleAlpha),
            )
            if (actions != null) {
                GlassCapsule(Modifier.align(Alignment.CenterEnd), actions)
            }
        }
    }
}

private val glassShadow = Color.Black.copy(alpha = 0.14f)

@Composable
fun GlassCircle(onClick: () -> Unit, label: String, modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    val p = LocalPalette.current
    Box(
        modifier.size(44.dp)
            .shadow(10.dp, CircleShape, ambientColor = glassShadow, spotColor = glassShadow)
            .background(p.glass, CircleShape)
            .border(0.5.dp, p.glassEdge, CircleShape)
            .clip(CircleShape)
            .clickable(role = Role.Button, onClickLabel = label, onClick = onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) { content() }
}

@Composable
fun GlassCapsule(modifier: Modifier = Modifier, content: @Composable RowScope.() -> Unit) {
    val p = LocalPalette.current
    Row(
        modifier.height(44.dp)
            .shadow(10.dp, CircleShape, ambientColor = glassShadow, spotColor = glassShadow)
            .background(p.glass, CircleShape)
            .border(0.5.dp, p.glassEdge, CircleShape)
            .clip(CircleShape)
            .padding(horizontal = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
        content = content,
    )
}

/** An icon button inside a [GlassCapsule]. */
@Composable
fun BarButton(icon: ImageVector, label: String, enabled: Boolean = true, onClick: () -> Unit) {
    val p = LocalPalette.current
    Box(
        Modifier.size(44.dp).clip(CircleShape)
            .clickable(enabled = enabled, role = Role.Button, onClickLabel = label, onClick = onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, null, Modifier.size(24.dp), tint = if (enabled) p.label else p.tertiary)
    }
}

/** A text button inside a [GlassCapsule], as sheets carry them. */
@Composable
fun BarTextButton(text: String, enabled: Boolean = true, bold: Boolean = false, onClick: () -> Unit) {
    val p = LocalPalette.current
    Box(
        Modifier.height(44.dp).clip(CircleShape)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(horizontal = 14.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text, style = Type.body, color = if (enabled) p.label else p.tertiary,
            fontWeight = if (bold) FontWeight.SemiBold else FontWeight.Normal,
        )
    }
}

/**
 * One row of an inset-grouped card. Cards are drawn row by row, so each lazy item stays one
 * row: [edge] rounds the outer corners and decides whether a separator runs underneath.
 */
@Composable
fun Cell(
    edge: Edge,
    modifier: Modifier = Modifier,
    onClick: (() -> Unit)? = null,
    onLongClick: (() -> Unit)? = null,
    onDelete: (() -> Unit)? = null,
    /** Asked before [onDelete] runs, for a delete nothing can undo. */
    deleteConfirmation: String? = null,
    /** A swipe from the leading edge that acts and springs back, as iOS's leading swipe actions do. */
    leadingSwipe: SwipeAction? = null,
    /** Wraps the row inside the card's clip, for a row with a swipe of its own — the shelf's. */
    swipe: (@Composable (row: @Composable () -> Unit) -> Unit)? = null,
    chevron: Boolean = onClick != null,
    separatorStart: Dp = RowPadding,
    verticalPadding: Dp = 13.dp,
    content: @Composable RowScope.() -> Unit,
) {
    val p = LocalPalette.current
    val shape = when (edge) {
        Edge.TOP -> RoundedCornerShape(topStart = CardRadius, topEnd = CardRadius)
        Edge.BOTTOM -> RoundedCornerShape(bottomStart = CardRadius, bottomEnd = CardRadius)
        Edge.ONLY -> RoundedCornerShape(CardRadius)
        Edge.MIDDLE -> RectangleShape
    }
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    // UIKit's selection grey, not a ripple.
    val highlight = if (p.dark) Color(0xFF3A3A3C) else Color(0xFFD1D1D6)
    Box(modifier.padding(horizontal = Margin).fillMaxWidth().clip(shape)) {
        val row: @Composable () -> Unit = {
            Row(
                Modifier.fillMaxWidth()
                    .background(if (pressed) highlight else p.card)
                    .then(
                        if (onClick != null) {
                            Modifier.combinedClickable(
                                interaction, indication = null, role = Role.Button, onLongClick = onLongClick, onClick = onClick,
                            )
                        } else {
                            Modifier
                        },
                    )
                    .heightIn(min = 52.dp)
                    .padding(horizontal = RowPadding, vertical = verticalPadding),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                content()
                if (chevron) {
                    Spacer(Modifier.width(10.dp))
                    Chevron()
                }
            }
        }
        when {
            swipe != null -> swipe(row)
            onDelete != null || leadingSwipe != null -> SwipeToDelete(onDelete, deleteConfirmation, leadingSwipe, row)
            else -> row()
        }
        if (edge == Edge.TOP || edge == Edge.MIDDLE) {
            Box(
                Modifier.align(Alignment.BottomStart).padding(start = separatorStart, end = RowPadding)
                    .fillMaxWidth().height(hairline()).background(p.separator),
            )
        }
    }
}

class SwipeAction(val label: String, val icon: ImageVector, val color: Color, val act: () -> Unit)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SwipeToDelete(onDelete: (() -> Unit)?, confirmation: String?, leading: SwipeAction?, content: @Composable () -> Unit) {
    val p = LocalPalette.current
    // Not saveable, unlike rememberSwipeToDismissBoxState: a lazy list keeps a removed row's saved
    // state under its key, so a subscription deleted by a swipe and added again came back
    // dismissed and deleted itself in the middle of being added.
    val threshold = SwipeToDismissBoxDefaults.positionalThreshold
    val state = remember { SwipeToDismissBoxState(SwipeToDismissBoxValue.Settled, threshold) }
    val scope = rememberCoroutineScope()
    var asking by remember { mutableStateOf(false) }
    // One answer per swipe. An action recomposes the row, and material3 hands the still-dismissed
    // state to the new onDismiss: unguarded, mark-read and mark-unread chased each other every
    // frame, each restarting the reset that would have ended it.
    var handled by remember { mutableStateOf(false) }
    fun settle() = scope.launch {
        state.reset()
        handled = false
    }
    if (asking) {
        // Declined, the row comes back: it was swiped away to ask, not because it went.
        ActionSheet(
            confirmation, "刪除",
            onAction = {
                asking = false
                onDelete?.invoke()
            },
            onDismiss = {
                asking = false
                settle()
            },
        )
    }
    SwipeToDismissBox(
        state = state,
        enableDismissFromStartToEnd = leading != null,
        enableDismissFromEndToStart = onDelete != null,
        onDismiss = {
            if (!handled) {
                handled = true
                if (it == SwipeToDismissBoxValue.EndToStart) {
                    if (confirmation != null) asking = true else onDelete?.invoke()
                } else if (it == SwipeToDismissBoxValue.StartToEnd && leading != null) {
                    // The row stays: the action changes it, it does not take it away.
                    leading.act()
                    settle()
                }
            }
        },
        backgroundContent = {
            if (leading != null && state.dismissDirection == SwipeToDismissBoxValue.StartToEnd) Row(
                Modifier.fillMaxSize().background(leading.color).padding(horizontal = 24.dp),
                horizontalArrangement = Arrangement.Start,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(leading.icon, leading.label, tint = Color.White)
            }
            // Drawn only mid-swipe: at rest it would fringe the card's anti-aliased corners red.
            if (state.dismissDirection == SwipeToDismissBoxValue.EndToStart) Row(
                Modifier.fillMaxSize().background(p.red).padding(horizontal = 24.dp),
                horizontalArrangement = Arrangement.End,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Symbols.Trash, "刪除", tint = Color.White)
            }
        },
    ) { content() }
}

inline fun <T> LazyListScope.group(
    items: List<T>,
    noinline key: ((T) -> Any)? = null,
    crossinline cell: @Composable (item: T, edge: Edge) -> Unit,
) {
    itemsIndexed(items, key = key?.let { k -> { _: Int, item: T -> k(item) } }) { index, item ->
        cell(item, Edge.of(index, items.size))
    }
}

/** An inset-grouped section header, aligned with the text inside the card below it. */
fun LazyListScope.header(
    text: String,
    key: Any? = null,
    icon: ImageVector? = null,
    trailing: (@Composable RowScope.() -> Unit)? = null,
) {
    item(key = key) {
        val p = LocalPalette.current
        Row(
            Modifier.fillMaxWidth().padding(start = Margin + RowPadding, end = Margin + RowPadding, top = 22.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (icon != null) {
                Icon(icon, null, Modifier.size(20.dp), tint = p.secondary)
                Spacer(Modifier.width(6.dp))
            }
            Text(text, style = Type.sectionHeader, color = p.secondary, modifier = Modifier.weight(1f))
            trailing?.invoke(this)
        }
    }
}

fun LazyListScope.footer(text: String, alarming: Boolean = false) {
    item {
        val p = LocalPalette.current
        Text(
            text, style = Type.footnote, color = if (alarming) p.red else p.secondary,
            modifier = Modifier.padding(start = Margin + RowPadding, end = Margin + RowPadding, top = 8.dp),
        )
    }
}

fun LazyListScope.gap(height: Dp = 28.dp) {
    item { Spacer(Modifier.height(height)) }
}

enum class Direction { LEFT, RIGHT, DOWN }

/** UIKit's disclosure chevron: stroked, round-capped, lighter than any icon-font arrow. */
@Composable
fun Chevron(
    modifier: Modifier = Modifier,
    direction: Direction = Direction.RIGHT,
    color: Color = LocalPalette.current.tertiary,
    width: Dp = 7.dp,
    height: Dp = 12.dp,
    stroke: Dp = 2.dp,
) {
    Canvas(modifier.size(width + stroke, height + stroke)) {
        val s = stroke.toPx()
        val w = size.width - s
        val h = size.height - s
        val o = s / 2
        val path = Path().apply {
            when (direction) {
                Direction.RIGHT -> { moveTo(o, o); lineTo(o + w, o + h / 2); lineTo(o, o + h) }
                Direction.LEFT -> { moveTo(o + w, o); lineTo(o, o + h / 2); lineTo(o + w, o + h) }
                Direction.DOWN -> { moveTo(o, o); lineTo(o + w / 2, o + h); lineTo(o + w, o) }
            }
        }
        drawPath(path, color, style = Stroke(s, cap = StrokeCap.Round, join = StrokeJoin.Round))
    }
}

/** A disclosure chevron that turns from pointing down (open) to pointing right (folded). */
@Composable
fun FoldChevron(folded: Boolean, color: Color) {
    val angle by animateFloatAsState(if (folded) -90f else 0f, tween(200), label = "fold")
    Chevron(Modifier.rotate(angle), Direction.DOWN, color, width = 12.dp, height = 7.dp, stroke = 2.dp)
}

/**
 * The iOS `BookCover`: the cover from this device, fetched the first time it is drawn. Until then,
 * and for good when the site will not give one up, the placeholder — a quaternary-fill card with a
 * closed book in it — which for a hotlinked cover is the expected state, not an error.
 */
@Composable
fun Cover(width: Dp, height: Dp, bookId: String, siteId: String, siteBookId: String, address: String?) {
    val app = app()
    val p = LocalPalette.current
    // Decoded against the longer side, so a portrait or square picture is never stretched up.
    val px = with(LocalDensity.current) { height.roundToPx() }
    // Seeded from memory, so a row scrolled back into view does not flash the placeholder first.
    val image by produceState(
        listOf(app.covers.keptFile(bookId), app.covers.cachedFile(bookId)).firstNotNullOfOrNull { ArticlePictures.cached(it, px) },
        bookId, address,
    ) {
        if (value == null) value = app.covers.cover(bookId, siteId, siteBookId, address)?.let { ArticlePictures.load(it, px) }
    }
    Box(
        Modifier.size(width, height).clip(RoundedCornerShape(4.dp)).then(if (image == null) Modifier.background(p.fill) else Modifier),
        contentAlignment = Alignment.Center,
    ) {
        val picture = image
        if (picture != null) {
            Image(picture, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        } else {
            Icon(Symbols.BookClosed, null, Modifier.size(width * 0.45f), tint = p.secondary)
        }
    }
}

@Composable
fun Cover(width: Dp, height: Dp, book: Book) = Cover(width, height, book.id, book.siteId, book.siteBookId, book.coverURL)

/** UIActivityIndicatorView: eight spokes, the brightest one walking clockwise. */
@Composable
fun Spinner(modifier: Modifier = Modifier, size: Dp = 20.dp, color: Color = LocalPalette.current.secondary) {
    val transition = rememberInfiniteTransition(label = "spinner")
    val step by transition.animateFloat(
        0f, 8f, infiniteRepeatable(tween(800, easing = LinearEasing)), label = "step",
    )
    Canvas(modifier.size(size)) {
        val head = step.toInt() % 8
        val radius = this.size.minDimension / 2
        for (i in 0 until 8) {
            val age = (head - i + 8) % 8
            rotate(i * 45f) {
                drawLine(
                    color.copy(alpha = color.alpha * (1f - age * 0.1f)),
                    start = center.copy(y = center.y - radius * 0.45f),
                    end = center.copy(y = center.y - radius * 0.95f),
                    strokeWidth = radius * 0.24f,
                    cap = StrokeCap.Round,
                )
            }
        }
    }
}

/** SwiftUI's ContentUnavailableView. */
@Composable
fun EmptyState(icon: ImageVector, title: String, message: String?, actions: @Composable ColumnScope.() -> Unit = {}) {
    val p = LocalPalette.current
    Column(Modifier.fillMaxWidth().padding(horizontal = 40.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Icon(icon, null, Modifier.size(52.dp), tint = p.secondary)
        Spacer(Modifier.height(14.dp))
        Text(title, style = Type.title2, color = p.label, textAlign = TextAlign.Center)
        if (message != null) {
            Spacer(Modifier.height(8.dp))
            Text(message, style = Type.subheadline, color = p.secondary, textAlign = TextAlign.Center)
        }
        Spacer(Modifier.height(18.dp))
        actions()
    }
}

/** `.borderedProminent`, which iOS 26 draws as a capsule. */
@Composable
fun ProminentButton(text: String, modifier: Modifier = Modifier, icon: ImageVector? = null, onClick: () -> Unit) {
    val p = LocalPalette.current
    Row(
        modifier.clip(CircleShape).background(p.accent).clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 18.dp, vertical = 9.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) Icon(icon, null, Modifier.size(20.dp), tint = Color.White)
        Text(text, style = Type.body, color = Color.White, fontWeight = FontWeight.Medium)
    }
}

/** `.bordered`: tinted text on a grey capsule. */
@Composable
fun BorderedButton(text: String, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val p = LocalPalette.current
    Box(
        modifier.clip(CircleShape).background(p.fill.copy(alpha = p.fill.alpha * 1.6f))
            .clickable(role = Role.Button, onClick = onClick).padding(horizontal = 18.dp, vertical = 9.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(text, style = Type.body, color = p.accent, fontWeight = FontWeight.Medium)
    }
}

/** A segmented picker: a grey capsule track with the chosen option lifted out in white. */
@Composable
fun <T> Segmented(options: List<Pair<T, String>>, selected: T, onSelect: (T) -> Unit) {
    val p = LocalPalette.current
    Row(
        Modifier.fillMaxWidth().height(32.dp).background(p.fill.copy(alpha = p.fill.alpha * 1.6f), CircleShape).padding(2.dp),
    ) {
        for ((value, label) in options) {
            val on = value == selected
            Box(
                Modifier.weight(1f).fillMaxHeight()
                    .then(
                        if (on) {
                            Modifier.shadow(3.dp, CircleShape).background(if (p.dark) Color(0xFF636366) else Color.White, CircleShape)
                        } else {
                            Modifier
                        },
                    )
                    .clip(CircleShape).clickable(role = Role.Tab) { onSelect(value) },
                contentAlignment = Alignment.Center,
            ) {
                Text(label, style = Type.footnote, color = p.label, fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal)
            }
        }
    }
}

/**
 * A sheet in the iOS page-sheet shape. [full] opens it at full height (a page sheet);
 * otherwise it opens at its content's height (a medium detent).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun Sheet(onDismiss: () -> Unit, full: Boolean = true, content: @Composable ColumnScope.() -> Unit) {
    val p = LocalPalette.current
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        // A page sheet stops short of the status bar, the screen behind showing above it — and so
        // does a medium one dragged all the way up, or its bar would sit under the status icons.
        modifier = Modifier.statusBarsPadding().padding(top = 10.dp),
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = full),
        containerColor = p.background,
        contentColor = p.label,
        shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp),
        dragHandle = null,
        contentWindowInsets = { WindowInsets.navigationBars.union(WindowInsets.ime).only(WindowInsetsSides.Bottom) },
    ) {
        Column(if (full) Modifier.fillMaxHeight() else Modifier, content = content)
    }
}

/** A sheet's toolbar: glass text buttons either side of an inline title. */
@Composable
fun SheetBar(
    title: String,
    leading: (@Composable RowScope.() -> Unit)? = null,
    trailing: (@Composable RowScope.() -> Unit)? = null,
) {
    val p = LocalPalette.current
    Box(Modifier.fillMaxWidth().padding(horizontal = Margin, vertical = 12.dp).height(44.dp)) {
        if (leading != null) GlassCapsule(Modifier.align(Alignment.CenterStart), leading)
        Text(
            title, style = Type.headline, color = p.label, maxLines = 1, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.align(Alignment.Center).padding(horizontal = 90.dp),
        )
        if (trailing != null) GlassCapsule(Modifier.align(Alignment.CenterEnd), trailing)
    }
}

/** The floating notice that slides down over a screen: `.bar` material, radius 12. */
@Composable
fun Banner(modifier: Modifier = Modifier, content: @Composable RowScope.() -> Unit) {
    val p = LocalPalette.current
    Row(
        modifier.statusBarsPadding().padding(horizontal = Margin, vertical = 6.dp).fillMaxWidth()
            .shadow(8.dp, RoundedCornerShape(12.dp), ambientColor = glassShadow, spotColor = glassShadow)
            .background(p.glass, RoundedCornerShape(12.dp))
            .padding(horizontal = 14.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(14.dp),
        verticalAlignment = Alignment.CenterVertically,
        content = content,
    )
}

/**
 * A text field for addresses, as the iOS sheets have them: no capitalisation, no correction,
 * the URL keyboard, a placeholder, and focus on arrival so the first tap offers Paste.
 */
@Composable
fun UrlField(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    modifier: Modifier = Modifier,
    minHeight: Dp = 0.dp,
) {
    val p = LocalPalette.current
    val focus = remember { FocusRequester() }
    BasicTextField(
        value, onValueChange,
        textStyle = Type.body.copy(color = p.label),
        cursorBrush = SolidColor(p.accent),
        keyboardOptions = KeyboardOptions(
            capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false, keyboardType = KeyboardType.Uri,
        ),
        modifier = modifier.fillMaxWidth().heightIn(min = minHeight).focusRequester(focus),
        decorationBox = { field ->
            if (value.isEmpty()) Text(placeholder, style = Type.body, color = p.tertiary)
            field()
        },
    )
    LaunchedEffect(Unit) { focus.requestFocus() }
}

/** SwiftUI's `LabeledContent`: a label, and its value trailing in the secondary colour. */
@Composable
fun RowScope.Labeled(label: String, value: String) {
    val p = LocalPalette.current
    Text(label, style = Type.body, color = p.label)
    Spacer(Modifier.width(12.dp))
    Text(
        value, style = Type.body, color = p.secondary, textAlign = TextAlign.End, maxLines = 2,
        overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f),
    )
}

/** SwiftUI's linear `ProgressView`: a thin rounded track, filled in the accent colour. */
@Composable
fun ProgressBar(fraction: Float, modifier: Modifier = Modifier) {
    val p = LocalPalette.current
    Box(modifier.fillMaxWidth().height(4.dp).clip(CircleShape).background(p.fill.copy(alpha = p.fill.alpha * 1.6f))) {
        Box(Modifier.fillMaxWidth(fraction.coerceIn(0f, 1f)).fillMaxHeight().background(p.accent, CircleShape))
    }
}

/** A list row's edit-mode selection mark: an empty ring, or a filled check in the accent colour. */
@Composable
fun SelectionMark(selected: Boolean) {
    val p = LocalPalette.current
    if (selected) {
        Icon(Symbols.CheckmarkCircleFill, "已選取", Modifier.size(24.dp), tint = p.accent)
    } else {
        Icon(Symbols.CircleDotted, null, Modifier.size(24.dp), tint = p.tertiary)
    }
}

/** `.searchable`'s field: a grey capsule with a magnifying glass, the placeholder in it. */
@Composable
fun SearchField(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    modifier: Modifier = Modifier,
    /** The keyboard's search key; without it the field filters as it is typed in. */
    onSearch: (() -> Unit)? = null,
) {
    val p = LocalPalette.current
    Row(
        modifier.padding(horizontal = Margin).fillMaxWidth().height(36.dp)
            .background(p.fill.copy(alpha = p.fill.alpha * 1.6f), CircleShape).padding(horizontal = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Symbols.Search, null, Modifier.size(18.dp), tint = p.secondary)
        BasicTextField(
            value, onValueChange, singleLine = true,
            textStyle = Type.body.copy(color = p.label),
            cursorBrush = SolidColor(p.accent),
            keyboardOptions = KeyboardOptions(imeAction = if (onSearch != null) ImeAction.Search else ImeAction.Default),
            keyboardActions = KeyboardActions(onSearch = { onSearch?.invoke() }),
            modifier = Modifier.weight(1f),
            decorationBox = { field ->
                if (value.isEmpty()) Text(placeholder, style = Type.body, color = p.secondary)
                field()
            },
        )
    }
}

/**
 * A floating strip over the bottom of a screen, above the tab bar: `.safeAreaInset` with `.bar`.
 * Opaque, unlike the glass: without the blur `.bar` has, the list under it reads through its text.
 */
@Composable
fun BottomBar(modifier: Modifier = Modifier, content: @Composable RowScope.() -> Unit) {
    val p = LocalPalette.current
    Row(
        modifier.navigationBarsPadding().padding(start = Margin, end = Margin, bottom = 62.dp + 8.dp + 10.dp).fillMaxWidth()
            .shadow(10.dp, RoundedCornerShape(CardRadius), ambientColor = glassShadow, spotColor = glassShadow)
            .background(p.card, RoundedCornerShape(CardRadius))
            .border(0.5.dp, p.glassEdge, RoundedCornerShape(CardRadius))
            .padding(horizontal = 16.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
        content = content,
    )
}

/**
 * An iOS alert: title, message, and capsule buttons stacked with the action on top — the
 * layout iOS falls back to when a label will not fit beside Cancel, which ours do not.
 */
@Composable
fun Alert(
    title: String,
    message: String,
    confirm: String,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
    cancel: Boolean = true,
    /** A second, `.destructive` action under [confirm], in red. */
    destructive: String? = null,
    onDestructive: () -> Unit = {},
    /** A text field under the message, as an iOS alert carries one. */
    field: (@Composable () -> Unit)? = null,
) {
    val p = LocalPalette.current
    Dialog(onDismiss, DialogProperties(usePlatformDefaultWidth = false)) {
        Column(
            Modifier.width(300.dp).clip(RoundedCornerShape(34.dp)).background(p.card).padding(20.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(title, style = Type.headline, color = p.label, textAlign = TextAlign.Center)
            Spacer(Modifier.height(6.dp))
            Text(message, style = Type.footnote, color = p.label, textAlign = TextAlign.Center)
            if (field != null) {
                Spacer(Modifier.height(14.dp))
                field()
            }
            Spacer(Modifier.height(18.dp))
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                AlertButton(confirm, Modifier.fillMaxWidth(), bold = true, onClick = onConfirm)
                if (destructive != null) AlertButton(destructive, Modifier.fillMaxWidth(), bold = false, color = p.red, onClick = onDestructive)
                if (cancel) AlertButton("取消", Modifier.fillMaxWidth(), bold = false, onClick = onDismiss)
            }
        }
    }
}

@Composable
fun AlertButton(text: String, modifier: Modifier, bold: Boolean, color: Color? = null, onClick: () -> Unit) {
    val p = LocalPalette.current
    Box(
        modifier.heightIn(min = 48.dp).clip(CircleShape).background(p.fill.copy(alpha = p.fill.alpha * 1.6f))
            .clickable(role = Role.Button, onClick = onClick).padding(horizontal = 12.dp, vertical = 8.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text, style = Type.body, color = color ?: if (bold) p.accent else p.label, textAlign = TextAlign.Center,
            fontWeight = if (bold) FontWeight.SemiBold else FontWeight.Normal,
        )
    }
}

/**
 * `.confirmationDialog` as an iPhone draws it: a card of choices at the bottom, an optional
 * title over them, and Cancel apart below.
 */
@Composable
fun ActionSheet(title: String?, action: String, destructive: Boolean = true, onAction: () -> Unit, onDismiss: () -> Unit) {
    val p = LocalPalette.current
    Dialog(onDismiss, DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Box(
            Modifier.fillMaxSize().clickable(remember { MutableInteractionSource() }, indication = null, onClick = onDismiss),
            contentAlignment = Alignment.BottomCenter,
        ) {
            Column(Modifier.navigationBarsPadding().padding(horizontal = 8.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(CardRadius)).background(p.card)) {
                    if (title != null) {
                        Text(
                            title, style = Type.footnote, color = p.secondary, textAlign = TextAlign.Center,
                            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp),
                        )
                        Box(Modifier.fillMaxWidth().height(hairline()).background(p.separator))
                    }
                    SheetChoice(action, if (destructive) p.red else p.accent, bold = false, onClick = onAction)
                }
                Box(Modifier.fillMaxWidth().clip(RoundedCornerShape(CardRadius)).background(p.card)) {
                    SheetChoice("取消", p.accent, bold = true, onClick = onDismiss)
                }
            }
        }
    }
}

@Composable
private fun SheetChoice(text: String, color: Color, bold: Boolean, onClick: () -> Unit) {
    Box(Modifier.fillMaxWidth().heightIn(min = 56.dp).clickable(role = Role.Button, onClick = onClick), contentAlignment = Alignment.Center) {
        Text(text, style = Type.body, color = color, fontWeight = if (bold) FontWeight.SemiBold else FontWeight.Normal)
    }
}
