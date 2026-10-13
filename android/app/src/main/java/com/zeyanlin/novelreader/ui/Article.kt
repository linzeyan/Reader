package com.zeyanlin.novelreader.ui

import android.graphics.BitmapFactory
import android.util.LruCache
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.ParagraphStyle
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withLink
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextIndent
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.zeyanlin.novelreader.services.ArticleBlock
import com.zeyanlin.novelreader.services.ChineseScript
import com.zeyanlin.novelreader.services.ChineseText
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.text.DateFormat
import java.util.Date
import kotlin.math.max

/** A subscribed article as the reader holds it: its blocks, the date under its title, and the page it came from. */
class Article(val blocks: List<ArticleBlock>, val subtitle: String?, val link: String?) {
    /** The piece's own headings, somewhere to jump to — what grows the catalog sheet its second tab. */
    val outline: List<Triple<Int, Int, String>>
        get() = blocks.mapIndexedNotNull { i, block ->
            block.plainText.trim().takeIf { block.type == ArticleBlock.Kind.HEADING && it.isNotEmpty() }?.let { Triple(i, block.level ?: 2, it) }
        }

    companion object {
        /** Only for an article that has a date: a feed that publishes none gets the title alone. */
        fun subtitle(publishedAt: Long?) =
            publishedAt?.let { DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(it)) }
    }
}

/**
 * How one paragraph of an article is drawn — the iOS `ChapterText.compose`, as one value both
 * renderers read. [text] holds exactly the paragraph's characters wherever [selectable], so every
 * offset into it is an anchor offset; a rule's asterisks are not its (empty) text, so no mark lands there.
 */
class Piece(
    val text: AnnotatedString,
    val style: TextStyle,
    val selectable: Boolean = true,
    /** A listing's tint behind the block. */
    val background: Color? = null,
    /** Drawn instead of [text] when set: a picture that reached the disk. */
    val picture: Picture? = null,
)

/** A stored picture and its pixel size, drawn as that many dp: scaled down to fit, never up — an author's 40-pixel icon is not a banner. */
class Picture(val file: File, val width: Int, val height: Int) {
    fun size(maxWidth: Float, maxHeight: Float): Pair<Float, Float> {
        val scale = minOf(maxWidth / width, maxHeight / height, 1f)
        return width * scale to height * scale
    }
}

/** The title, linked to the piece's own page but not styled as a link, with its date beneath. */
fun articleHeading(title: String, article: Article?, titleStyle: TextStyle, ink: Color, script: ChineseScript): AnnotatedString =
    buildAnnotatedString {
        val shown = ChineseText.rendered(title, script)
        val link = article?.link
        // Styles given, though empty: with none, Material's Text paints its own link colour and underline.
        if (link != null) withLink(LinkAnnotation.Url(link, TextLinkStyles(SpanStyle()))) { append(shown) } else append(shown)
        val subtitle = article?.subtitle ?: return@buildAnnotatedString
        val size = captionSize(titleStyle)
        withStyle(ParagraphStyle(lineHeight = (size * 1.4f).sp)) {
            withStyle(SpanStyle(fontSize = size.sp, fontWeight = FontWeight.Normal, color = ink.copy(alpha = SECONDARY))) { append(subtitle) }
        }
    }

/** [body] is the reader's own paragraph style; everything else is sized off it, so it follows the slider. */
fun articlePieces(
    article: Article,
    body: TextStyle,
    lineSpacing: Int,
    ink: Color,
    link: Color,
    script: ChineseScript,
    file: (String) -> File,
): List<Piece> {
    val size = body.fontSize.value
    val secondary = ink.copy(alpha = SECONDARY)
    fun runs(block: ArticleBlock, prefix: String = ""): AnnotatedString = buildAnnotatedString {
        append(ChineseText.rendered(prefix + block.runs.joinToString("") { it.text }, script))
        var at = prefix.length
        for (run in block.runs) {
            val end = at + run.text.length
            if (run.bold || run.italic || run.code) {
                addStyle(
                    SpanStyle(
                        fontWeight = if (run.bold) FontWeight.Bold else null,
                        fontStyle = if (run.italic) FontStyle.Italic else null,
                        fontFamily = if (run.code) FontFamily.Monospace else null,
                    ),
                    at, end,
                )
            }
            run.href?.let {
                // Coloured and underlined here: the page is drawn, and nothing else would make a link look like one.
                addStyle(SpanStyle(color = link, textDecoration = TextDecoration.Underline), at, end)
                addLink(LinkAnnotation.Url(it), at, end)
            }
            at = end
        }
    }
    return article.blocks.map { block ->
        when (block.type) {
            ArticleBlock.Kind.PARAGRAPH -> Piece(runs(block), body)
            ArticleBlock.Kind.HEADING -> {
                // Levels below three all read alike: an author nesting four deep has stopped distinguishing them too.
                val heading = size + when (block.level ?: 2) { in Int.MIN_VALUE..1 -> 6; 2 -> 4; 3 -> 2; else -> 1 }
                Piece(
                    runs(block),
                    body.copy(fontSize = heading.sp, fontWeight = FontWeight.SemiBold, fontFamily = FontFamily.Default, lineHeight = (heading * 1.2f + lineSpacing).sp),
                )
            }
            // Indented rather than ruled down the left, as on iOS.
            ArticleBlock.Kind.QUOTE -> Piece(
                runs(block),
                body.copy(fontStyle = FontStyle.Italic, color = secondary, textIndent = TextIndent(size.sp, size.sp)),
            )
            ArticleBlock.Kind.CODE -> {
                val mono = max(10f, size - 1)
                Piece(
                    AnnotatedString(ChineseText.rendered(block.plainText, script)),
                    body.copy(fontFamily = FontFamily.Monospace, fontSize = mono.sp, lineHeight = (mono * 1.17f + lineSpacing * 0.5f).sp, textIndent = TextIndent(8.sp, 8.sp)),
                    background = ink.copy(alpha = 0.06f),
                )
            }
            ArticleBlock.Kind.LIST_ITEM -> {
                val indent = size * max(1, block.level ?: 1)
                // An en space where the plain text has a space, so the offsets still line up; hanging,
                // so a second line sits under the first word rather than the bullet.
                val marker = block.marker?.let { "$it\u2002" }.orEmpty()
                val text = runs(block, marker)
                Piece(
                    buildAnnotatedString {
                        append(text)
                        addStyle(SpanStyle(color = secondary), 0, marker.length)
                    },
                    body.copy(textIndent = TextIndent(indent.sp, (indent + size).sp)),
                )
            }
            ArticleBlock.Kind.IMAGE -> {
                val image = block.image
                val stored = image?.file
                if (stored != null && (image.width ?: 0) > 0 && (image.height ?: 0) > 0) {
                    Piece(AnnotatedString(""), body, selectable = false, picture = Picture(file(stored), image.width!!, image.height!!))
                } else {
                    // Nothing to draw: the alt text is the sentence the author wrote for exactly this case.
                    val caption = captionSize(body)
                    Piece(
                        AnnotatedString(ChineseText.rendered(block.plainText, script)),
                        body.copy(fontSize = caption.sp, lineHeight = (caption * 1.3f + lineSpacing).sp, color = secondary, textAlign = TextAlign.Center),
                    )
                }
            }
            ArticleBlock.Kind.RULE -> Piece(AnnotatedString("* * *"), body.copy(color = secondary, textAlign = TextAlign.Center), selectable = false)
        }
    }
}

private const val SECONDARY = 0.6f

private fun captionSize(style: TextStyle) = max(11f, style.fontSize.value - 3)

/**
 * Pictures decoded at the size they are drawn, never the stored 2048: an illustrated post carries
 * twenty, and a column redraws every visible one on every frame.
 * ponytail: one process-wide cache of 48 MB; size it from the device's memory class if it thrashes.
 */
object ArticlePictures {
    private val cache = object : LruCache<String, ImageBitmap>(48 * 1024 * 1024) {
        override fun sizeOf(key: String, value: ImageBitmap) = value.width * value.height * 4
    }

    fun cached(file: File, widthPx: Int): ImageBitmap? = cache.get("${file.path}@$widthPx")

    suspend fun load(file: File, widthPx: Int): ImageBitmap? {
        cached(file, widthPx)?.let { return it }
        return withContext(Dispatchers.IO) {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.path, bounds)
            if (bounds.outWidth <= 0) return@withContext null
            var sample = 1
            while (bounds.outWidth / (sample * 2) >= widthPx) sample *= 2
            BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = sample })?.asImageBitmap()
        }?.also { cache.put("${file.path}@$widthPx", it) }
    }
}

/** A picture in the scrolling column: its box is laid out at once from the stored size, the bitmap fills it when decoded. */
@Composable
fun ArticlePicture(picture: Picture, maxWidth: Dp, maxHeight: Dp, modifier: Modifier = Modifier) {
    val (width, height) = picture.size(maxWidth.value, maxHeight.value)
    val px = with(LocalDensity.current) { width.dp.roundToPx() }
    val bitmap by produceState(ArticlePictures.cached(picture.file, px), picture.file, px) {
        if (value == null) value = ArticlePictures.load(picture.file, px)
    }
    Box(modifier.size(width.dp, height.dp)) {
        bitmap?.let { Image(it, null, Modifier.size(width.dp, height.dp)) }
    }
}
