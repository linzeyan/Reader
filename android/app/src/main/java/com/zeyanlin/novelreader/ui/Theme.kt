package com.zeyanlin.novelreader.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.addPathNodes
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * The iOS system colours the app's screens are drawn in. iOS sets none of its own beyond the
 * accent, so matching it means matching UIKit's grouped-list palette.
 */
@Immutable
data class Palette(
    val dark: Boolean,
    /** systemGroupedBackground */
    val background: Color,
    /** secondarySystemGroupedBackground: the inset cards */
    val card: Color,
    val label: Color,
    val secondary: Color,
    val tertiary: Color,
    /** Lighter than UIKit's: one device pixel here is far heavier than its 1/3 pt hairline. */
    val separator: Color,
    /** quaternarySystemFill: placeholder covers, slider tracks, segmented controls */
    val fill: Color,
    /** The floating glass of bars and toolbar buttons, opaque enough to read without a blur. */
    val glass: Color,
    val glassEdge: Color,
    /** The selected tab's highlight inside the tab bar. */
    val glassPill: Color,
    val red: Color,
    val orange: Color,
    val green: Color,
    /** systemBlue: a swipe that marks something read, as iOS tints it. */
    val blue: Color,
    /** AccentColor in the iOS asset catalog; one value for both appearances there too. */
    val accent: Color = Color(0xFF98735C),
)

val LightPalette = Palette(
    dark = false,
    background = Color(0xFFF2F2F7),
    card = Color.White,
    label = Color.Black,
    secondary = Color(0x993C3C43),
    tertiary = Color(0x4D3C3C43),
    separator = Color(0x293C3C43),
    fill = Color(0x14747480),
    glass = Color(0xF5FCFCFE),
    glassEdge = Color(0x14000000),
    glassPill = Color(0x12000000),
    red = Color(0xFFFF3B30),
    orange = Color(0xFFFF9500),
    green = Color(0xFF34C759),
    blue = Color(0xFF007AFF),
)

val DarkPalette = Palette(
    dark = true,
    background = Color.Black,
    card = Color(0xFF1C1C1E),
    label = Color.White,
    secondary = Color(0x99EBEBF5),
    tertiary = Color(0x4DEBEBF5),
    separator = Color(0x66545458),
    fill = Color(0x2E767680),
    glass = Color(0xF2262628),
    glassEdge = Color(0x1FFFFFFF),
    glassPill = Color(0x1FFFFFFF),
    red = Color(0xFFFF453A),
    orange = Color(0xFFFF9F0A),
    green = Color(0xFF30D158),
    blue = Color(0xFF0A84FF),
)

val LocalPalette = staticCompositionLocalOf { LightPalette }

/** The iOS text styles at the default Dynamic Type size, in sp so Android's font scale applies. */
object Type {
    val largeTitle = TextStyle(fontSize = 34.sp, lineHeight = 41.sp, fontWeight = FontWeight.Bold)
    val title2 = TextStyle(fontSize = 22.sp, lineHeight = 28.sp, fontWeight = FontWeight.Bold)
    val headline = TextStyle(fontSize = 17.sp, lineHeight = 22.sp, fontWeight = FontWeight.SemiBold)
    val body = TextStyle(fontSize = 17.sp, lineHeight = 22.sp)
    val subheadline = TextStyle(fontSize = 15.sp, lineHeight = 20.sp)
    val footnote = TextStyle(fontSize = 13.sp, lineHeight = 18.sp)
    val caption = TextStyle(fontSize = 12.sp, lineHeight = 16.sp)
    val caption2 = TextStyle(fontSize = 11.sp, lineHeight = 13.sp)

    /** The section headers of an inset-grouped list, as iOS 26 draws them. */
    val sectionHeader = TextStyle(fontSize = 17.sp, lineHeight = 22.sp, fontWeight = FontWeight.SemiBold)
}

@Composable
fun IosTheme(dark: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    val palette = if (dark) DarkPalette else LightPalette
    // Material components (sheets, sliders, menus) pick these up, so they sit in the same palette.
    val scheme = if (dark) {
        darkColorScheme(
            primary = palette.accent, background = palette.background, surface = palette.card,
            surfaceContainer = palette.card, surfaceContainerLow = palette.background,
            onSurface = palette.label, onBackground = palette.label,
        )
    } else {
        lightColorScheme(
            primary = palette.accent, background = palette.background, surface = palette.card,
            surfaceContainer = palette.card, surfaceContainerLow = palette.background,
            onSurface = palette.label, onBackground = palette.label,
        )
    }
    CompositionLocalProvider(LocalPalette provides palette) {
        MaterialTheme(colorScheme = scheme, content = content)
    }
}

/** A Material Symbols path: 960 units square, its origin at the bottom-left corner. */
internal fun symbol(pathData: String): ImageVector =
    ImageVector.Builder(defaultWidth = 24.dp, defaultHeight = 24.dp, viewportWidth = 960f, viewportHeight = 960f)
        .addGroup(translationY = 960f)
        .addPath(addPathNodes(pathData), fill = SolidColor(Color.Black))
        .clearGroup()
        .build()

/**
 * `books.vertical.fill` has no Material counterpart, so the shelf tab gets its own: two
 * upright spines and one leaning away from them, in a 24-unit box.
 */
val ShelfSymbol: ImageVector by lazy {
    fun ImageVector.Builder.spine(x: Float, top: Float, width: Float) = addPath(
        addPathNodes(
            "M${x + 1.2f},$top h${width - 2.4f} a1.2,1.2 0 0 1 1.2,1.2 V19.8 a1.2,1.2 0 0 1 -1.2,1.2 " +
                "h-${width - 2.4f} a1.2,1.2 0 0 1 -1.2,-1.2 V${top + 1.2f} a1.2,1.2 0 0 1 1.2,-1.2 z",
        ),
        fill = SolidColor(Color.Black),
    )
    ImageVector.Builder(defaultWidth = 24.dp, defaultHeight = 24.dp, viewportWidth = 24f, viewportHeight = 24f)
        .spine(1.5f, 5f, 4.6f)
        .spine(7.2f, 3f, 4.6f)
        .addGroup(rotate = 16f, pivotX = 12.8f, pivotY = 21f)
        .spine(12.8f, 4.5f, 4.6f)
        .clearGroup()
        .build()
}
