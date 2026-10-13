package com.zeyanlin.novelreader.ui

import android.content.Context
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.graphics.Typeface
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.drag
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.zeyanlin.novelreader.services.ChineseScript
import com.zeyanlin.novelreader.services.ChineseText
import com.zeyanlin.novelreader.siterules.SiteRule
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.descriptors.buildClassSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import java.util.UUID
import kotlin.math.max
import kotlin.math.roundToInt
import kotlin.properties.ReadWriteProperty
import kotlin.reflect.KProperty

/**
 * Reading appearance — the iOS `ReaderSettings`, holding what is ported. Per device, but carried
 * by a backup as iOS carries it. Every property writes itself down when set. A shelf and a book
 * may each answer some of these for themselves — see [Overrides].
 *
 * Not ported: swipe-to-leave (Android's back gesture is the system's own and always on).
 */
class ReaderSettings(private val prefs: SharedPreferences, files: File) {
    enum class Theme(val raw: String, val label: String) {
        SYSTEM("system", "系統"),
        LIGHT("light", "淺色"),
        DARK("dark", "深色"),
        CUSTOM("custom", "自訂"),
    }

    /**
     * How the text moves under the reader: two renderers, not one with a flag — a column
     * across chapters and a fixed page are different ways to read. Scrolling is the default.
     */
    enum class Mode(val raw: String, val label: String) {
        SCROLL("scroll", "捲動"),
        PAGINATED("paginated", "分頁"),
    }

    /**
     * What a reader does to get to the next page. The middle of the screen is the controls
     * whichever way, and a scrolling page always scrolls: there `TAP` means taps turn pages too.
     */
    enum class PageTurn(val raw: String, val label: String) {
        SWIPE("swipe", "滑動"),
        TAP("tap", "點擊"),
        BOTH("both", "兩者"),
        ;

        val turnsOnTap get() = this != SWIPE
        val turnsOnSwipe get() = this != TAP
    }

    var fontSize by int("reader.fontSize", 19)
    var lineSpacing by int("reader.lineSpacing", 9)
    var paragraphSpacing by int("reader.paragraphSpacing", 14)
    var theme by choice("reader.theme", Theme.entries, Theme.SYSTEM) { it.raw }

    /** The surface the reader built, kept whether or not it is in force, so trying the others costs nothing. */
    var customPalette by stored(
        { getString(PALETTE, null)?.let { runCatching { json.decodeFromString(ReaderPalette.serializer(), it) }.getOrNull() } ?: ReaderPalette.LIGHT },
    ) { putString(PALETTE, json.encodeToString(ReaderPalette.serializer(), it)) }

    /** Font files the reader added. The directory is the record: nothing hides from this app a file it copied in. */
    val fonts = File(files, "fonts")
    var installedFaces by mutableStateOf(fonts.list()?.sorted().orEmpty())
        private set

    /**
     * Null for the system face, [SERIF] for the device's Ming face, else an added font file.
     * Written as the empty string when null: a device that never chose starts on Ming, as iOS
     * starts on Songti — a screen of prose in the interface face reads as an interface, not a
     * page — and removing the key would turn "system, chosen" back into Ming.
     */
    var fontName by stored({
        when (val stored = getString(FONT, null)) {
            null -> SERIF
            "" -> null
            else -> stored.takeIf { it == SERIF || File(fonts, it).exists() }
        }
    }) { putString(FONT, it ?: "") }

    /**
     * Characters by default: free to start, never moves an offset, and right far more often than
     * wrong. Words are the tier a reader opts into once they have seen 「頭發」 one time too many.
     */
    var chineseScript by stored({
        ChineseScript(
            ChineseScript.Depth.from(getString(CHINESE_DEPTH, null)) ?: ChineseScript.Depth.CHARACTERS,
            ChineseScript.Target.from(getString(CHINESE_TARGET, null)) ?: ChineseScript.deviceDefault(),
        )
    }) {
        putString(CHINESE_DEPTH, it.depth.raw).putString(CHINESE_TARGET, it.target.raw)
        ChineseText.prewarm(it)
    }

    var keepScreenOn by bool("reader.keepScreenOn", true)
    var pageTurn by choice("reader.pageTurn", PageTurn.entries, PageTurn.TAP) { it.raw }
    var mode by choice("reader.mode", Mode.entries, Mode.SCROLL) { it.raw }

    /**
     * How fast a page moves on its own, in lines a minute rather than pixels: a reading speed belongs
     * to the reader, and one stored as distance would halve itself the day the type got bigger.
     * Only the speed is kept — a book that reopened already moving would start before it was looked at.
     */
    var autoScrollPace by int("reader.autoScrollPace", 20)

    /**
     * A comic's own speed, in screens a minute: there is no line to pace pictures by, and lines and
     * screens do not convert. Against the window rather than the pages, so it survives a pinch.
     */
    var comicScrollPace by stored({ getFloat("reader.comicScrollPace", 3f) }) { putFloat("reader.comicScrollPace", it) }

    /** How fast the voice reads, as Android's multiplier — not iOS's scale, and not carried by a backup, as iOS does not carry it. */
    var speechRate by stored({ getFloat("reader.speechRate", 1f) }) { putFloat("reader.speechRate", it) }

    /**
     * What each shelf, and each book by id, was given of its own. No entry is "the same as
     * everything else", which is where every device starts.
     */
    private var shelves by stored({ layers<SiteRule.Kind>(SHELVES) }) { putString(SHELVES, json.encodeToString(it)) }
    private var books by stored({ layers<String>(BOOKS) }) { putString(BOOKS, json.encodeToString(it)) }

    /** The general bottom bar; not carried by a backup, as iOS does not carry it — a shelf's own travels in its layer. */
    var toolbar by stored(
        { getString(TOOLBAR, null)?.let { runCatching { json.decodeFromString(ReaderToolbarLayout.serializer(), it) }.getOrNull() } ?: ReaderToolbarLayout() },
    ) { putString(TOOLBAR, json.encodeToString(ReaderToolbarLayout.serializer(), it)) }

    init {
        ChineseText.prewarm(chineseScript)
    }

    /**
     * What [layer] was given and nothing more — what its panel edits, since a resolved value cannot
     * say "following". Empty for the general answers: the bottom of the chain, not a layer on it.
     */
    fun overrides(layer: Layer) = when (layer) {
        Layer.General -> null
        is Layer.Shelf -> shelves[layer.kind]
        is Layer.Book -> books[layer.id]
    } ?: Overrides()

    /**
     * Changes what [layer] answers; the general answers are the properties above, where they have
     * always lived. A layer back to following in every respect is dropped rather than stored empty,
     * or the map grows a row per book ever opened. Dropped for being *empty*, not for agreeing with
     * what it inherits: the defaults are the reader's to change tomorrow, and a book pinned to
     * today's answer must stay pinned.
     */
    fun edit(layer: Layer, change: (Overrides) -> Overrides) {
        val changed = change(overrides(layer))
        val kept = changed.takeIf { it != Overrides() }
        when (layer) {
            Layer.General -> {
                changed.mode?.let { mode = it }
                changed.pageTurn?.let { pageTurn = it }
                changed.fontName?.let { fontName = it.ifEmpty { null } }
                changed.fontSize?.let { fontSize = it }
                changed.lineSpacing?.let { lineSpacing = it }
                changed.paragraphSpacing?.let { paragraphSpacing = it }
                changed.theme?.let { theme = it }
                changed.toolbar?.let { toolbar = it }
            }
            is Layer.Shelf -> shelves = if (kept == null) shelves - layer.kind else shelves + (layer.kind to kept)
            is Layer.Book -> books = if (kept == null) books - layer.id else books + (layer.id to kept)
        }
    }

    /** Dropped with the book: one removed and added again would come back read a way nobody chose for it. */
    fun forgetOverrides(bookId: String) {
        books = books - bookId
    }

    /** The colours in force for [theme] — a book's, which is not always the general one. */
    fun palette(theme: Theme, systemDark: Boolean) = when (theme) {
        Theme.SYSTEM -> if (systemDark) ReaderPalette.DARK else ReaderPalette.LIGHT
        Theme.LIGHT -> ReaderPalette.LIGHT
        Theme.DARK -> ReaderPalette.DARK
        Theme.CUSTOM -> customPalette
    }

    // Faces

    private val families = HashMap<String, FontFamily>()

    fun family(name: String? = fontName): FontFamily = when (name) {
        null -> FontFamily.Default
        SERIF -> FontFamily.Serif
        else -> families.getOrPut(name) { FontFamily(Font(File(fonts, name))) }
    }

    fun faceName(name: String?) = when (name) {
        null -> "系統字體"
        SERIF -> "明體"
        else -> name.substringBeforeLast('.')
    }

    /**
     * Copies a font file in, off the main thread. Refused unless Android can draw with it: a name
     * in the picker that draws the system face is a promise the list does not keep.
     *
     * @return the face's name, or null.
     */
    fun addFace(context: Context, uri: Uri): String? {
        val shown = context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) it.getString(0) else null
        }
        val name = (shown ?: "font.ttf").replace('/', '_')
        fonts.mkdirs()
        val file = File(fonts, name)
        runCatching { context.contentResolver.openInputStream(uri)!!.use { input -> file.outputStream().use { input.copyTo(it) } } }
        // Typeface hands back the default face for a file it cannot read, or throws on older systems.
        val usable = runCatching { Typeface.createFromFile(file) }.getOrNull().let { it != null && it != Typeface.DEFAULT }
        if (!usable) {
            file.delete()
            return null
        }
        return name
    }

    /** On the main thread, once [addFace] has the file in. */
    fun facesChanged() {
        installedFaces = fonts.list()?.sorted().orEmpty()
    }

    fun removeFace(name: String) {
        File(fonts, name).delete()
        families.remove(name)
        facesChanged()
        if (fontName == name) fontName = null
        // A layer on it goes to the system face too: a face with no file behind it cannot be drawn.
        fun Overrides.off() = if (fontName == name) copy(fontName = "") else this
        shelves = shelves.mapValues { it.value.off() }
        books = books.mapValues { it.value.off() }
    }

    // Background pictures: one file, in app storage rather than the cache the system may empty.

    private val backgrounds = File(files, "ReaderBackground")
    private var cached: Pair<String, ImageBitmap>? = null

    /**
     * Reads a picked picture in at no more than 2048 px on its longest edge, as the one background
     * kept, off the main thread. A camera photo is several screens of pixels, and holding one
     * decoded behind every frame costs tens of megabytes nobody can see.
     *
     * @return the file name for a [ReaderBackground.Image], or null if it could not be read.
     */
    fun saveBackground(context: Context, uri: Uri): String? {
        val bitmap = runCatching { decode(context, uri) }.getOrNull() ?: return null
        val name = "${UUID.randomUUID()}.jpg"
        backgrounds.mkdirs()
        val written = runCatching {
            File(backgrounds, name).outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 90, it) }
        }.getOrDefault(false)
        if (!written) return null
        backgrounds.listFiles()?.filter { it.name != name }?.forEach { it.delete() }
        return name
    }

    /** Decoded once and held: the page asks for it on every pass. */
    fun backgroundImage(name: String): ImageBitmap? {
        cached?.let { (held, image) -> if (held == name) return image }
        val image = BitmapFactory.decodeFile(File(backgrounds, name).path)?.asImageBitmap() ?: return null
        cached = name to image
        return image
    }

    private fun decode(context: Context, uri: Uri): Bitmap? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            // ImageDecoder also turns a camera photo upright, which its EXIF only describes.
            return ImageDecoder.decodeBitmap(ImageDecoder.createSource(context.contentResolver, uri)) { decoder, info, _ ->
                val longest = max(info.size.width, info.size.height)
                if (longest > MAX_EDGE) {
                    val ratio = MAX_EDGE.toFloat() / longest
                    decoder.setTargetSize((info.size.width * ratio).roundToInt(), (info.size.height * ratio).roundToInt())
                }
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            }
        }
        // ponytail: API 26–27 sample down by powers of two and ignore EXIF rotation.
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        var sample = 1
        while (max(bounds.outWidth, bounds.outHeight) / (sample * 2) >= MAX_EDGE) sample *= 2
        val options = BitmapFactory.Options().apply { inSampleSize = sample }
        return context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, options) }
    }

    // Storage

    private fun <T> stored(read: SharedPreferences.() -> T, write: SharedPreferences.Editor.(T) -> Unit) =
        object : ReadWriteProperty<Any?, T> {
            private var value by mutableStateOf(prefs.read())

            override fun getValue(thisRef: Any?, property: KProperty<*>) = value

            override fun setValue(thisRef: Any?, property: KProperty<*>, value: T) {
                this.value = value
                prefs.edit().apply { write(value) }.apply()
            }
        }

    private fun int(key: String, default: Int) = stored({ getInt(key, default) }) { putInt(key, it) }

    private fun bool(key: String, default: Boolean) = stored({ getBoolean(key, default) }) { putBoolean(key, it) }

    private fun <E> choice(key: String, entries: List<E>, default: E, raw: (E) -> String) =
        stored({ getString(key, null).let { stored -> entries.firstOrNull { raw(it) == stored } } ?: default }) { putString(key, raw(it)) }

    private inline fun <reified K> SharedPreferences.layers(key: String): Map<K, Overrides> =
        getString(key, null)?.let { runCatching { json.decodeFromString<Map<K, Overrides>>(it) }.getOrNull() }.orEmpty()

    companion object {
        const val SERIF = "serif"
        val FONT_SIZES = 13..32

        /** Slow enough for a page being studied, fast enough to be skimming — iOS's `ReadingPace.range`. */
        val AUTO_SCROLL_PACES = 5..60

        /** Tenths of a screen a minute: from the lettering of a dense page to looking rather than reading — iOS's `ComicPace.range`. */
        val COMIC_PACE_TENTHS = 5..80
        private const val MAX_EDGE = 2048
        private const val SHELVES = "reader.overridesByKind"
        private const val BOOKS = "reader.overridesByBook"
        private const val FONT = "reader.fontName"
        private const val PALETTE = "reader.customPalette"
        private const val CHINESE_DEPTH = "reader.chinese.depth"
        private const val CHINESE_TARGET = "reader.chinese.target"
        private const val TOOLBAR = "reader.toolbar"
        private val json = Json { ignoreUnknownKeys = true }
    }
}

/** A colour that comes back exactly as chosen: a shade of drift between launches is a bug nobody can describe. */
@Serializable
data class ReaderColor(val red: Double, val green: Double, val blue: Double, val alpha: Double = 1.0) {
    val color get() = Color(red.toFloat(), green.toFloat(), blue.toFloat(), alpha.toFloat())

    /** Weighted rather than averaged: the eye reads green as most of a colour's light. */
    val brightness get() = 0.299 * red + 0.587 * green + 0.114 * blue

    companion object {
        fun hex(rgb: Int) = ReaderColor(((rgb shr 16) and 0xFF) / 255.0, ((rgb shr 8) and 0xFF) / 255.0, (rgb and 0xFF) / 255.0)

        fun of(color: Color) = ReaderColor(color.red.toDouble(), color.green.toDouble(), color.blue.toDouble(), color.alpha.toDouble())
    }
}

/** What the page is painted with: one colour, colours blended top to bottom, or a picture. */
@Serializable(ReaderBackgroundSerializer::class)
sealed interface ReaderBackground {
    data class Colors(val stops: List<ReaderColor>) : ReaderBackground

    /** A picture the reader supplied, by file name in [ReaderSettings]'s background directory. */
    data class Image(val name: String) : ReaderBackground
}

/**
 * Swift's own form for an enum case with a payload — `{"colors":{"_0":[…]}}` — so a palette in
 * a backup reads on iOS and an iOS one reads here. Stored on the device the same way: one form.
 */
object ReaderBackgroundSerializer : KSerializer<ReaderBackground> {
    override val descriptor = buildClassSerialDescriptor("ReaderBackground")
    private val stops = ListSerializer(ReaderColor.serializer())

    override fun serialize(encoder: Encoder, value: ReaderBackground) {
        val json = encoder as JsonEncoder
        val (case, payload) = when (value) {
            is ReaderBackground.Colors -> "colors" to json.json.encodeToJsonElement(stops, value.stops)
            is ReaderBackground.Image -> "image" to JsonPrimitive(value.name)
        }
        json.encodeJsonElement(buildJsonObject { put(case, buildJsonObject { put("_0", payload) }) })
    }

    override fun deserialize(decoder: Decoder): ReaderBackground {
        val json = decoder as JsonDecoder
        val cases = json.decodeJsonElement().jsonObject
        cases["colors"]?.jsonObject?.get("_0")?.let { return ReaderBackground.Colors(json.json.decodeFromJsonElement(stops, it)) }
        cases["image"]?.jsonObject?.get("_0")?.let { return ReaderBackground.Image(it.jsonPrimitive.content) }
        throw SerializationException("unknown background: ${cases.keys}")
    }
}

/** The reader's surface, resolved — the iOS `ReaderPalette`. */
@Serializable
data class ReaderPalette(val background: ReaderBackground, val foreground: ReaderColor) {
    val ink get() = foreground.color

    /** Read off the text: a picture has no single colour, but light text over it means a dark screen. */
    val isDark get() = foreground.brightness > 0.5

    val stops get() = (background as? ReaderBackground.Colors)?.stops.orEmpty()

    /** A marker's warm yellow; less transparent on a dark page, which swallows a light wash. */
    val highlight get() = Color(1f, 0.84f, 0.28f, if (isDark) 0.34f else 0.44f)

    /** Neutral while the reader is still choosing: the passage turns yellow the moment it is marked. */
    val selection get() = ink.copy(alpha = 0.24f)

    companion object {
        /** Off-white and near-black: a pure value at either end is what makes a screen glare under a lamp. */
        val LIGHT = ReaderPalette(ReaderBackground.Colors(listOf(ReaderColor.hex(0xFAF7F0))), ReaderColor.hex(0x1A1A1A))
        val DARK = ReaderPalette(ReaderBackground.Colors(listOf(ReaderColor.hex(0x121314))), ReaderColor.hex(0xBFBFBF))
    }
}

/** The page, painted. A picture is filled and cropped: letterboxed, it would show its own edges. */
@Composable
fun ReaderBackgroundView(background: ReaderBackground, modifier: Modifier = Modifier) {
    val fallback = LocalPalette.current.background
    when (background) {
        is ReaderBackground.Colors -> {
            val stops = background.stops.map { it.color }
            Box(modifier.background(if (stops.size > 1) Brush.verticalGradient(stops) else SolidColor(stops.firstOrNull() ?: fallback)))
        }
        is ReaderBackground.Image -> {
            val settings = app().reader
            val image = remember(background.name) { settings.backgroundImage(background.name) }
            // Gone with a restore, say: a plain page the reader can still read on beats nothing.
            if (image == null) Box(modifier.background(fallback)) else Image(image, null, modifier, contentScale = ContentScale.Crop)
        }
    }
}

/**
 * The reading appearance controls, shared by the reader's sheet and Settings → 外觀 so the
 * two cannot drift. [list] lays out the rows: a screen of its own, or the sheet's column.
 *
 * A switch on top picks whose answers the rows below write — the iOS `ReadingAppearanceSections`
 * scope. [book] is the one the sheet was opened in, or null in Settings: inside a book there is
 * a "this book" and one shelf worth naming, while Settings has no book and names every shelf.
 */
@Composable
fun AppearanceSections(
    settings: ReaderSettings,
    onEditTheme: () -> Unit,
    onEditToolbar: (Layer) -> Unit,
    book: Layer.Book? = null,
    list: @Composable (LazyListScope.() -> Unit) -> Unit,
) {
    val p = LocalPalette.current
    val app = app()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val layers = if (book == null) listOf(Layer.General) + SiteRule.Kind.entries.map { Layer.Shelf(it) } else listOf(Layer.General, Layer.Shelf(book.kind), book)
    // Opens on the general answers, as it always did: narrowing is the deliberate act, so it is the
    // one that costs a tap. Saveable so a look at 自訂配色 comes back to the scope it left.
    var picked by rememberSaveable { mutableIntStateOf(0) }
    val layer = layers[picked]
    val general = layer == Layer.General
    val look = Look(settings, layer)
    val above = Look(settings, layer.above)
    val own = settings.overrides(layer)
    // Where a layer adds its line under the last row, that row is no longer the card's last.
    val alone = if (general) Edge.ONLY else Edge.TOP
    val last = if (general) Edge.BOTTOM else Edge.MIDDLE
    val addFont = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            val name = withContext(Dispatchers.IO) { settings.addFace(context, uri) }
            if (name == null) {
                app.banner.value = "這個檔案不是可用的字體。"
            } else {
                settings.facesChanged()
                settings.edit(layer) { it.copy(fontName = name) }
            }
        }
    }

    fun name(of: Layer) = when (of) {
        Layer.General -> "預設"
        // Pointed at in a book, named in Settings: four segments none of which is where you stand
        // can only be told apart by name, while in a book naming it leaves 「小說」 to be decoded.
        is Layer.Shelf -> if (book != null) "這個書櫃" else when (of.kind) {
            SiteRule.Kind.NOVEL -> "小說"
            SiteRule.Kind.COMIC -> "漫畫"
            SiteRule.Kind.FEED -> "訂閱"
        }
        is Layer.Book -> "這本書"
    }

    // The line under each of a layer's controls — see [FollowLine]. The general answers follow nobody.
    fun LazyListScope.follow(edge: Edge, inherited: String, chosen: Any?, revert: (Overrides) -> Overrides) {
        if (!general) item { FollowLine(edge, layer is Layer.Book, inherited, if (chosen == null) null else ({ settings.edit(layer, revert) })) }
    }

    list {
        item { Cell(Edge.ONLY) { Segmented(layers.indices.map { it to name(layers[it]) }, picked) { picked = it } } }
        // How far a change below reaches, said before it is made rather than found out in another book.
        footer(
            when (layer) {
                Layer.General -> "所有書都會變，書櫃或個別書設定過的除外。"
                is Layer.Shelf -> "這個書櫃裡的書都會變，個別設定過的那幾本除外。"
                is Layer.Book -> "只有這本書會變，其他書仍跟著書櫃走。"
            },
        )
        // A comic's pages are pictures: a face and a line spacing have nothing to apply to, so the
        // one question put is how they are turned.
        if ((book?.kind ?: layer.kind) != SiteRule.Kind.COMIC) {
            // First, as on iOS: the one setting here that changes how the page behaves, and the
            // rest reads differently depending on which side it is on.
            header("閱讀方式")
            item { Cell(alone) { Segmented(ReaderSettings.Mode.entries.map { it to it.label }, look.mode) { m -> settings.edit(layer) { it.copy(mode = m) } } } }
            follow(Edge.BOTTOM, above.mode.label, own.mode) { it.copy(mode = null) }
            footer("捲動：整章一路往下捲。分頁：一次一頁，像書一樣翻頁。")
            header("文字")
            item { FontPicker(settings, Edge.TOP, look.fontName) { f -> settings.edit(layer) { it.copy(fontName = f.orEmpty()) } } }
            item {
                Cell(Edge.MIDDLE, onClick = { addFont.launch(arrayOf("font/*", "application/x-font-ttf", "application/x-font-otf", "application/octet-stream")) }, chevron = false) {
                    Text("從檔案加入字體…", style = Type.body, color = p.accent)
                }
            }
            follow(Edge.MIDDLE, settings.faceName(above.fontName), own.fontName) { it.copy(fontName = null) }
            item { SliderCell(Edge.MIDDLE, "字級", look.fontSize, ReaderSettings.FONT_SIZES, 1) { v -> settings.edit(layer) { it.copy(fontSize = v) } } }
            follow(Edge.MIDDLE, "${above.fontSize}", own.fontSize) { it.copy(fontSize = null) }
            item { SliderCell(Edge.MIDDLE, "行距", look.lineSpacing, 0..20, 1) { v -> settings.edit(layer) { it.copy(lineSpacing = v) } } }
            follow(Edge.MIDDLE, "${above.lineSpacing}", own.lineSpacing) { it.copy(lineSpacing = null) }
            item { SliderCell(last, "段距", look.paragraphSpacing, 0..32, 2) { v -> settings.edit(layer) { it.copy(paragraphSpacing = v) } } }
            follow(Edge.BOTTOM, "${above.paragraphSpacing}", own.paragraphSpacing) { it.copy(paragraphSpacing = null) }

            if (general) {
                header("簡繁轉換")
                val script = settings.chineseScript
                item {
                    Cell(if (script.depth == ChineseScript.Depth.OFF) Edge.ONLY else Edge.TOP) {
                        Segmented(ChineseScript.Depth.entries.map { it to it.label }, script.depth) { settings.chineseScript = script.copy(depth = it) }
                    }
                }
                // Only where it means something: a direction to convert to is no choice for a reader not converting.
                if (script.depth != ChineseScript.Depth.OFF) {
                    item {
                        Cell(Edge.BOTTOM) {
                            Text("顯示為", style = Type.body, color = p.label)
                            Spacer(Modifier.width(16.dp))
                            Box(Modifier.weight(1f)) {
                                Segmented(ChineseScript.Target.entries.map { it to it.label }, script.target) { settings.chineseScript = script.copy(target = it) }
                            }
                        }
                    }
                }
                footer("逐字轉換不需要字典，也不會移動你畫過的線；字彙轉換會多讀一份字典，才知道「斗罗大陆」不是「鬥羅大陸」，也才會把「鼠标」寫成「滑鼠」。")
            }

            header("配色")
            item { Cell(Edge.TOP) { ThemePicker(settings, look.theme) { t -> settings.edit(layer) { it.copy(theme = t) } } } }
            // Here for a layer too: one set to 自訂 would otherwise be pinned to colours it cannot see.
            item { Cell(last, onClick = onEditTheme) { Text("自訂配色", style = Type.body, color = p.label, modifier = Modifier.weight(1f)) } }
            follow(Edge.BOTTOM, above.theme.label, own.theme) { it.copy(theme = null) }
            if (!general) footer("自訂配色只有一組。編輯它會影響所有選用自訂的書。")
        }

        header("翻頁方式")
        item { Cell(alone) { Segmented(ReaderSettings.PageTurn.entries.map { it to it.label }, look.pageTurn) { t -> settings.edit(layer) { it.copy(pageTurn = t) } } } }
        follow(Edge.BOTTOM, above.pageTurn.label, own.pageTurn) { it.copy(pageTurn = null) }
        footer("點擊翻頁時，畫面中央叫出工具列，右側與下方往後翻頁，左側與上方往前翻頁。無論選哪一種，捲動閱讀都還能捲動。")

        if (general) {
            gap(20.dp)
            item {
                Cell(Edge.ONLY) {
                    Text("閱讀時保持螢幕開啟", style = Type.body, color = p.label, modifier = Modifier.weight(1f))
                    IosSwitch(settings.keepScreenOn) { settings.keepScreenOn = it }
                }
            }
        }
        // Outside every branch above: the one question each layer, the general one included, answers alike.
        toolbarSection { onEditToolbar(layer) }
    }
}

/**
 * The line under one of a layer's controls, naming what it would read with if it followed — the
 * iOS `followLine`. There in both states, since an inherited value looks exactly like a chosen
 * one; that it turns into a way back is what says this layer has stopped following. A book names
 * its shelf rather than the default: "follow the default" under a book whose shelf has its own
 * answer would name something the reader then goes and fails to find.
 */
@Composable
private fun FollowLine(edge: Edge, book: Boolean, inherited: String, revert: (() -> Unit)?) {
    val p = LocalPalette.current
    val color = if (revert == null) p.secondary else p.accent
    Cell(edge, onClick = revert, chevron = false) {
        if (revert != null) {
            Icon(Symbols.ArrowUturnBackward, null, Modifier.size(15.dp), tint = color)
            Spacer(Modifier.width(6.dp))
        }
        Text((if (book) "跟隨書櫃設定（" else "跟隨預設（") + inherited + "）", style = Type.footnote, color = color)
    }
}

/** Each name drawn in its own face: the sample is the only thing that tells you what you are picking. */
@Composable
private fun FontPicker(settings: ReaderSettings, edge: Edge, selected: String?, onPick: (String?) -> Unit) {
    val p = LocalPalette.current
    var open by remember { mutableStateOf(false) }
    Box {
        Cell(edge, onClick = { open = true }, chevron = false) {
            Text("字體", style = Type.body, color = p.label, modifier = Modifier.weight(1f))
            Text(settings.faceName(selected), style = Type.body.copy(fontFamily = settings.family(selected)), color = p.secondary)
            Spacer(Modifier.width(6.dp))
            Chevron(direction = Direction.DOWN, color = p.secondary, width = 10.dp, height = 6.dp)
        }
        DropdownMenu(open, { open = false }, shape = RoundedCornerShape(20.dp), containerColor = p.card) {
            for (face in listOf(null, ReaderSettings.SERIF) + settings.installedFaces) {
                val added = face != null && face != ReaderSettings.SERIF
                DropdownMenuItem(
                    text = { Text(settings.faceName(face), style = Type.body.copy(fontFamily = settings.family(face))) },
                    leadingIcon = {
                        Box(Modifier.size(20.dp)) { if (face == selected) Icon(Symbols.CheckmarkCircleFill, null, tint = p.accent) }
                    },
                    trailingIcon = if (added) {
                        { Icon(Symbols.Trash, "刪除", Modifier.clickable { settings.removeFace(face!!) }, tint = p.red) }
                    } else {
                        null
                    },
                    onClick = {
                        open = false
                        onPick(face)
                    },
                )
            }
        }
    }
}

@Composable
private fun SliderCell(edge: Edge, label: String, value: Int, range: IntRange, step: Int, onChange: (Int) -> Unit) {
    val p = LocalPalette.current
    Cell(edge) {
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(label, style = Type.body, color = p.label, modifier = Modifier.weight(1f))
                Text("$value", style = Type.body.copy(fontFeatureSettings = TABULAR), color = p.secondary)
            }
            IosSlider(value, range, step, onChange)
        }
    }
}

/** Themes as swatches drawn in the surface they select: 「淺色」 and 「自訂」 mean nothing until seen. */
@Composable
private fun ThemePicker(settings: ReaderSettings, chosen: ReaderSettings.Theme, onPick: (ReaderSettings.Theme) -> Unit) {
    val p = LocalPalette.current
    val systemDark = androidx.compose.foundation.isSystemInDarkTheme()
    Row(Modifier.horizontalScroll(rememberScrollState()).padding(vertical = 2.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        for (theme in ReaderSettings.Theme.entries) {
            val selected = theme == chosen
            val palette = when (theme) {
                ReaderSettings.Theme.SYSTEM -> if (systemDark) ReaderPalette.DARK else ReaderPalette.LIGHT
                ReaderSettings.Theme.LIGHT -> ReaderPalette.LIGHT
                ReaderSettings.Theme.DARK -> ReaderPalette.DARK
                ReaderSettings.Theme.CUSTOM -> settings.customPalette
            }
            Column(
                Modifier.clickable(remember { androidx.compose.foundation.interaction.MutableInteractionSource() }, indication = null, role = Role.RadioButton) {
                    onPick(theme)
                },
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Box(
                    Modifier.size(52.dp).clip(RoundedCornerShape(10.dp))
                        .border(if (selected) 3.dp else hairline(), if (selected) p.accent else p.separator, RoundedCornerShape(10.dp)),
                    contentAlignment = Alignment.Center,
                ) {
                    ReaderBackgroundView(palette.background, Modifier.fillMaxSize())
                    Text("文", fontSize = 20.sp, color = palette.ink)
                }
                Text(theme.label, style = Type.caption2, color = if (selected) p.accent else p.secondary)
            }
        }
    }
}

/**
 * Where a reader builds their own page — the iOS `ReaderThemeEditor`. Switches the reader onto
 * the custom palette as it opens: edits nobody can see are edits nobody can judge.
 */
@Composable
fun ThemeEditor(settings: ReaderSettings, list: @Composable (LazyListScope.() -> Unit) -> Unit) {
    val p = LocalPalette.current
    val app = app()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val palette = settings.customPalette
    // Held rather than derived: a reader who taps 圖片 before choosing one has said what they
    // are looking for, and a derived value would snap back the instant they let go.
    var pictures by remember { mutableStateOf(palette.background is ReaderBackground.Image) }
    // What colours come back to: a gradient that took four taps to mix must survive a look at a photograph.
    var kept by remember { mutableStateOf(palette.stops.ifEmpty { ReaderPalette.LIGHT.stops }) }
    var editing by remember { mutableStateOf<Int?>(null) }
    LaunchedEffect(Unit) { settings.theme = ReaderSettings.Theme.CUSTOM }

    fun apply(stops: List<ReaderColor>) {
        kept = stops
        settings.customPalette = settings.customPalette.copy(background = ReaderBackground.Colors(stops))
    }

    fun adopt(uri: Uri?) {
        if (uri == null) return
        scope.launch {
            val name = withContext(Dispatchers.IO) { settings.saveBackground(context, uri) }
            if (name == null) {
                app.banner.value = "這張圖片無法使用。"
            } else {
                settings.customPalette = settings.customPalette.copy(background = ReaderBackground.Image(name))
                pictures = true
            }
        }
    }
    val photos = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { adopt(it) }
    val files = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { adopt(it) }

    list {
        item {
            // A page of text in the reader's own colours: a gradient cannot be judged from swatches.
            Box(Modifier.padding(horizontal = Margin).fillMaxWidth().height(150.dp).clip(RoundedCornerShape(12.dp))) {
                ReaderBackgroundView(palette.background, Modifier.fillMaxSize())
                Text(
                    "夜色從窗外漫進來，紙上的字仍舊清楚。",
                    fontFamily = settings.family(), fontSize = settings.fontSize.sp,
                    lineHeight = (settings.fontSize * 1.17f + settings.lineSpacing).sp, color = palette.ink,
                    modifier = Modifier.padding(18.dp),
                )
            }
        }
        header("背景")
        item {
            Cell(Edge.TOP) {
                Segmented(listOf(false to "顏色", true to "圖片"), pictures) {
                    pictures = it
                    // Only coming back acts at once: going the other way there may be no picture
                    // yet, and the page should not go blank while the reader looks for one.
                    if (!it) apply(kept)
                }
            }
        }
        if (pictures) {
            item {
                Cell(Edge.MIDDLE, onClick = { photos.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }) {
                    Icon(Symbols.Photo, null, Modifier.size(22.dp), tint = p.accent)
                    Spacer(Modifier.width(12.dp))
                    Text("從照片選擇", style = Type.body, color = p.label, modifier = Modifier.weight(1f))
                }
            }
            item {
                Cell(Edge.BOTTOM, onClick = { files.launch(arrayOf("image/*")) }) {
                    Icon(Symbols.Folder, null, Modifier.size(22.dp), tint = p.accent)
                    Spacer(Modifier.width(12.dp))
                    Text("從檔案選擇", style = Type.body, color = p.label, modifier = Modifier.weight(1f))
                }
            }
        } else {
            val stops = palette.stops
            stops.forEachIndexed { index, stop ->
                // Keyed by the whole list: after a delete the next row must not inherit a swiped-away state.
                item(key = "stop|$index|${stops.hashCode()}") {
                    Cell(
                        Edge.MIDDLE, onClick = { editing = index }, chevron = false,
                        // The last one cannot go: a page has to be painted something.
                        onDelete = if (stops.size > 1) {
                            { apply(stops.filterIndexed { i, _ -> i != index }) }
                        } else {
                            null
                        },
                    ) {
                        Text("顏色 ${index + 1}", style = Type.body, color = p.label, modifier = Modifier.weight(1f))
                        Swatch(stop.color)
                    }
                }
            }
            item {
                val more = stops.size < MAX_STOPS
                // A copy of the last stop: nothing on screen jumps until the reader picks something.
                Cell(Edge.BOTTOM, onClick = if (more) ({ apply(stops + stops.last()) }) else null, chevron = false) {
                    Text("加入顏色", style = Type.body, color = if (more) p.accent else p.tertiary)
                }
            }
            footer("兩個以上的顏色會由上而下漸層。")
        }
        gap(20.dp)
        item {
            Cell(Edge.ONLY, onClick = { editing = INK }, chevron = false) {
                Text("文字顏色", style = Type.body, color = p.label, modifier = Modifier.weight(1f))
                Swatch(palette.ink)
            }
        }
    }

    editing?.let { target ->
        val initial = if (target == INK) palette.ink else palette.stops.getOrNull(target)?.color ?: palette.ink
        ColorPickerDialog(initial, onDismiss = { editing = null }) { chosen ->
            editing = null
            if (target == INK) {
                settings.customPalette = settings.customPalette.copy(foreground = ReaderColor.of(chosen))
            } else {
                apply(palette.stops.mapIndexed { i, stop -> if (i == target) ReaderColor.of(chosen) else stop })
            }
        }
    }
}

/** Enough to mix a sky or a sunset; past this the stops are closer than a screen of text can show. */
private const val MAX_STOPS = 5
private const val INK = -1

@Composable
private fun Swatch(color: Color) {
    Box(Modifier.size(28.dp).clip(CircleShape).background(color).border(hairline(), LocalPalette.current.separator, CircleShape))
}

/**
 * A colour chooser, as Android has none to call: saturation across and brightness down in the
 * hue picked on the bar below, the old colour beside the new.
 */
@Composable
private fun ColorPickerDialog(initial: Color, onDismiss: () -> Unit, onPick: (Color) -> Unit) {
    val p = LocalPalette.current
    val start = remember { FloatArray(3).also { android.graphics.Color.colorToHSV(initial.toArgb(), it) } }
    var hue by remember { mutableFloatStateOf(start[0]) }
    var saturation by remember { mutableFloatStateOf(start[1]) }
    var brightness by remember { mutableFloatStateOf(start[2]) }
    val chosen = Color.hsv(hue, saturation, brightness)
    Dialog(onDismiss, DialogProperties(usePlatformDefaultWidth = false)) {
        Column(
            Modifier.width(300.dp).clip(RoundedCornerShape(34.dp)).background(p.card).padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Box(
                Modifier.fillMaxWidth().aspectRatio(1.3f).clip(RoundedCornerShape(12.dp))
                    .background(Brush.horizontalGradient(listOf(Color.White, Color.hsv(hue, 1f, 1f))))
                    .background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black)))
                    .pointerInput(Unit) {
                        track { at ->
                            saturation = (at.x / size.width).coerceIn(0f, 1f)
                            brightness = 1f - (at.y / size.height).coerceIn(0f, 1f)
                        }
                    },
            ) {
                Canvas(Modifier.fillMaxSize()) {
                    val at = Offset(saturation * size.width, (1f - brightness) * size.height)
                    drawCircle(Color.White, 11.dp.toPx(), at, style = Stroke(3.dp.toPx()))
                    drawCircle(Color.Black.copy(alpha = 0.3f), 12.5.dp.toPx(), at, style = Stroke(0.75.dp.toPx()))
                }
            }
            Box(
                Modifier.fillMaxWidth().height(28.dp).clip(CircleShape)
                    .background(Brush.horizontalGradient((0..6).map { Color.hsv(minOf(it * 60f, 359.9f), 1f, 1f) }))
                    .pointerInput(Unit) { track { at -> hue = (at.x / size.width).coerceIn(0f, 1f) * 359.9f } },
            ) {
                Canvas(Modifier.fillMaxSize()) {
                    val at = Offset(hue / 359.9f * size.width, size.height / 2)
                    drawCircle(Color.White, size.height / 2 - 2.dp.toPx(), at, style = Stroke(3.dp.toPx()))
                }
            }
            Row(Modifier.fillMaxWidth().height(36.dp).clip(RoundedCornerShape(10.dp))) {
                Box(Modifier.weight(1f).fillMaxSize().background(initial))
                Box(Modifier.weight(1f).fillMaxSize().background(chosen))
            }
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                AlertButton("完成", Modifier.fillMaxWidth(), bold = true) { onPick(chosen) }
                AlertButton("取消", Modifier.fillMaxWidth(), bold = false, onClick = onDismiss)
            }
        }
    }
}

/** Every position a finger touches down at or drags through. */
private suspend fun androidx.compose.ui.input.pointer.PointerInputScope.track(onPosition: (Offset) -> Unit) {
    awaitEachGesture {
        val down = awaitFirstDown()
        onPosition(down.position)
        drag(down.id) {
            onPosition(it.position)
            it.consume()
        }
    }
}

/** A UISwitch: green when on, a white knob that slides across. */
@Composable
fun IosSwitch(on: Boolean, onChange: (Boolean) -> Unit) {
    val p = LocalPalette.current
    val knob by animateDpAsState(if (on) 20.dp else 0.dp, label = "switch")
    Box(
        Modifier.size(51.dp, 31.dp).clip(CircleShape)
            .background(if (on) p.green else p.fill.copy(alpha = p.fill.alpha * 2.5f))
            .toggleable(on, role = Role.Switch, onValueChange = onChange)
            .padding(2.dp),
    ) {
        Box(Modifier.offset(x = knob).size(27.dp).shadow(2.dp, CircleShape).background(Color.White, CircleShape))
    }
}

/** Settings → 外觀: the controls the reader's sheet shows, without a book open. */
@Composable
fun AppearanceScreen() {
    val app = app()
    val nav = LocalNavigator.current
    AppearanceSections(app.reader, onEditTheme = { nav.push(Route.ThemeEditor) }, onEditToolbar = { nav.push(Route.ToolbarEditor(it)) }) { content ->
        ListScreen("外觀", onBack = nav::pop, content = content)
    }
}

@Composable
fun ThemeEditorScreen() {
    val nav = LocalNavigator.current
    ThemeEditor(app().reader) { content -> ListScreen("自訂配色", onBack = nav::pop, content = content) }
}
