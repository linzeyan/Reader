package com.zeyanlin.novelreader.data

import android.content.SharedPreferences
import com.zeyanlin.novelreader.FEED_GRACE
import com.zeyanlin.novelreader.FEED_KEEP
import com.zeyanlin.novelreader.FEED_UNREAD
import com.zeyanlin.novelreader.retention
import com.zeyanlin.novelreader.services.FeedRetention
import com.zeyanlin.novelreader.services.NetworkPolicy
import com.zeyanlin.novelreader.services.SiteStore
import com.zeyanlin.novelreader.siterules.SiteRule
import com.zeyanlin.novelreader.ui.Layer
import com.zeyanlin.novelreader.ui.Overrides
import com.zeyanlin.novelreader.ui.ReaderPalette
import com.zeyanlin.novelreader.ui.ReaderSettings
import com.zeyanlin.novelreader.ui.ReaderToolbarLayout
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlin.math.roundToInt

/**
 * Everything of the reader's own, in one file they can keep — the iOS `LibraryBackup`, in its
 * format: a file written on either platform restores on the other. What the app can fetch
 * again (catalogs, chapter text, covers) is not in it; the shelf, where each book was left,
 * the marks, the hand-installed sources and the settings are.
 */
@Serializable
data class LibraryBackup(
    val version: Int,
    @Serializable(IsoDate::class) val createdAt: Long,
    val books: List<BookRecord>,
    val rules: List<SiteRule>,
    val settings: Settings? = null,
) {
    /**
     * A book as it travels. Not [Book]: `catalogUpdatedAt` says when *this device* read the
     * source's index, and restoring it would call an empty catalog current.
     */
    @Serializable
    data class BookRecord(
        val siteId: String,
        val siteBookId: String,
        val kind: SiteRule.Kind,
        val title: String,
        val displayName: String? = null,
        val author: String? = null,
        val coverURL: String? = null,
        @Serializable(IsoDate::class) val addedAt: Long,
        @Serializable(IsoDate::class) val updatedAt: Long,
        val position: ReadingPosition? = null,
        val fraction: Double? = null,
        @Serializable(IsoDate::class) val lastReadAt: Long? = null,
        val bookmarks: List<ReadingBookmark>,
        val highlights: List<TextHighlight>,
    ) {
        val id get() = Book.makeId(siteId, siteBookId)
        val isLocal get() = siteId == SiteStore.LOCAL_SITE_ID
    }

    /** The iOS `ReadingPosition`: a chapter by the site's id, and an anchor in it. */
    @Serializable
    data class ReadingPosition(val siteChapterId: String, val anchor: TextAnchor)

    @Serializable
    data class TextAnchor(val paragraph: Int, val characterOffset: Int)

    /**
     * The settings both apps have, as raw values: one a build cannot read is skipped and that
     * preference stays where it was. iOS writes more (swipe-back, which Android leaves to the
     * system gesture); that is ignored here and never written, so an Android file says nothing about it.
     * Retention is here though the setting is per device: iOS carries it too, as the reader's choice.
     */
    @Serializable
    data class Settings(
        val readerMode: String? = null,
        /**
         * Each shelf's own answers, by kind. Only the shelves travel, as on iOS: a book's are about a
         * book this device has. Empty is "every shelf follows"; absent is a file from before shelves
         * had answers, which must not clear any.
         */
        val readerOverridesByKind: Map<String, LayerRecord>? = null,
        val fontSize: Double? = null,
        val lineSpacing: Double? = null,
        val paragraphSpacing: Double? = null,
        val theme: String? = null,
        val customPalette: ReaderPalette? = null,
        val fontName: String? = null,
        val keepScreenOn: Boolean? = null,
        val pageTurn: String? = null,
        val downloadNetwork: String? = null,
        val feedKeep: Int? = null,
        val feedGrace: Int? = null,
        val feedUnread: Int? = null,
        val librarySort: String? = null,
        val libraryGrouping: String? = null,
        val onlyWithNewChapters: Boolean? = null,
        val home: String? = null,
        val defaultMediaMode: String? = null,
        val recentReadingCount: Int? = null,
    ) {
        fun apply(reader: ReaderSettings, setNetwork: (NetworkPolicy) -> Unit, installedFaces: List<String>, prefs: SharedPreferences) {
            readerMode?.let { raw -> ReaderSettings.Mode.entries.firstOrNull { it.raw == raw } }?.let { reader.mode = it }
            readerOverridesByKind?.let { layers ->
                for (kind in SiteRule.Kind.entries) {
                    val restored = layers[kind.raw]?.overrides(installedFaces) ?: Overrides()
                    reader.edit(Layer.Shelf(kind)) { restored }
                }
            }
            fontSize?.let { reader.fontSize = it.roundToInt().coerceIn(ReaderSettings.FONT_SIZES) }
            lineSpacing?.let { reader.lineSpacing = it.roundToInt().coerceIn(0, 20) }
            paragraphSpacing?.let { reader.paragraphSpacing = it.roundToInt().coerceIn(0, 32) }
            theme?.let { raw -> ReaderSettings.Theme.entries.firstOrNull { it.raw == raw } }?.let { reader.theme = it }
            customPalette?.let { reader.customPalette = it }
            // Absent is a value here, as on iOS: the system face. A face this device does not
            // have leaves the choice alone — except iOS's Songti, whose counterpart is the Ming face.
            when {
                fontName == null -> reader.fontName = null
                fontName == ReaderSettings.SERIF || fontName.contains("Songti", ignoreCase = true) -> reader.fontName = ReaderSettings.SERIF
                fontName in installedFaces -> reader.fontName = fontName
            }
            keepScreenOn?.let { reader.keepScreenOn = it }
            pageTurn?.let { raw -> ReaderSettings.PageTurn.entries.firstOrNull { it.raw == raw } }?.let { reader.pageTurn = it }
            downloadNetwork?.let { raw -> NetworkPolicy.entries.firstOrNull { it.raw == raw } }?.let(setNetwork)
            prefs.edit().apply {
                feedKeep?.takeIf { it in FeedRetention.KEEP_COUNTS }?.let { putInt(FEED_KEEP, it) }
                feedGrace?.takeIf { it in FeedRetention.GRACE_DAYS }?.let { putInt(FEED_GRACE, it) }
                feedUnread?.takeIf { it in FeedRetention.UNREAD_DAYS }?.let { putInt(FEED_UNREAD, it) }
                librarySort?.takeIf { raw -> LibrarySort.entries.any { it.raw == raw } }?.let { putString(LIBRARY_SORT, it) }
                libraryGrouping?.takeIf { raw -> LibraryGrouping.entries.any { it.raw == raw } }?.let { putString(LIBRARY_GROUPING, it) }
                onlyWithNewChapters?.let { putBoolean(ONLY_WITH_NEW_CHAPTERS, it) }
                home?.takeIf { raw -> HomeScreen.entries.any { it.raw == raw } }?.let { putString(HOME_SCREEN, it) }
                defaultMediaMode?.takeIf { raw -> SiteRule.Kind.entries.any { it.raw == raw } }?.let { putString(DEFAULT_MEDIA_MODE, it) }
                // Clamped where it is read, so a number from a hand-edited file cannot become a list length of its own.
                recentReadingCount?.let { putInt(RECENT_READING_COUNT, it) }
            }.apply()
        }

        companion object {
            fun capture(reader: ReaderSettings, network: NetworkPolicy, prefs: SharedPreferences) = Settings(
                readerMode = reader.mode.raw,
                readerOverridesByKind = SiteRule.Kind.entries
                    .mapNotNull { kind -> reader.overrides(Layer.Shelf(kind)).takeIf { it != Overrides() }?.let { kind.raw to LayerRecord.of(it) } }
                    .toMap(),
                fontSize = reader.fontSize.toDouble(),
                lineSpacing = reader.lineSpacing.toDouble(),
                paragraphSpacing = reader.paragraphSpacing.toDouble(),
                theme = reader.theme.raw,
                customPalette = reader.customPalette,
                fontName = reader.fontName,
                keepScreenOn = reader.keepScreenOn,
                pageTurn = reader.pageTurn.raw,
                downloadNetwork = network.raw,
                feedKeep = prefs.retention(FEED_KEEP),
                feedGrace = prefs.retention(FEED_GRACE),
                feedUnread = prefs.retention(FEED_UNREAD),
                librarySort = LibrarySort.from(prefs.getString(LIBRARY_SORT, null)).raw,
                libraryGrouping = LibraryGrouping.from(prefs.getString(LIBRARY_GROUPING, null)).raw,
                onlyWithNewChapters = prefs.getBoolean(ONLY_WITH_NEW_CHAPTERS, false),
                home = HomeScreen.from(prefs.getString(HOME_SCREEN, null)).raw,
                defaultMediaMode = prefs.defaultMediaMode().raw,
                recentReadingCount = prefs.recentReadingCount(),
            )
        }
    }

    /**
     * One shelf's answers as they travel — the iOS `ReaderSettings.Overrides` as Swift codes it: raw
     * strings under its `…Raw` names and numbers as doubles, not the shape this device stores, so
     * a case either build renames comes back as "follows" rather than failing the file.
     */
    @Serializable
    data class LayerRecord(
        val modeRaw: String? = null,
        val pageTurnRaw: String? = null,
        val themeRaw: String? = null,
        val fontName: String? = null,
        val fontSize: Double? = null,
        val lineSpacing: Double? = null,
        val paragraphSpacing: Double? = null,
        val toolbar: ReaderToolbarLayout? = null,
    ) {
        fun overrides(installedFaces: List<String>) = Overrides(
            mode = ReaderSettings.Mode.entries.firstOrNull { it.raw == modeRaw },
            pageTurn = ReaderSettings.PageTurn.entries.firstOrNull { it.raw == pageTurnRaw },
            // "" is the system face, chosen. iOS's Songti is the Ming face here; a face this device
            // lacks cannot be drawn, so the shelf follows instead.
            fontName = fontName?.let { name ->
                when {
                    name == ReaderSettings.SERIF || name.contains("Songti", ignoreCase = true) -> ReaderSettings.SERIF
                    name.isEmpty() || name in installedFaces -> name
                    else -> null
                }
            },
            fontSize = fontSize?.roundToInt()?.coerceIn(ReaderSettings.FONT_SIZES),
            lineSpacing = lineSpacing?.roundToInt()?.coerceIn(0, 20),
            paragraphSpacing = paragraphSpacing?.roundToInt()?.coerceIn(0, 32),
            theme = ReaderSettings.Theme.entries.firstOrNull { it.raw == themeRaw },
            toolbar = toolbar,
        )

        companion object {
            fun of(o: Overrides) = LayerRecord(
                o.mode?.raw, o.pageTurn?.raw, o.theme?.raw, o.fontName,
                o.fontSize?.toDouble(), o.lineSpacing?.toDouble(), o.paragraphSpacing?.toDouble(), o.toolbar,
            )
        }
    }

    /** Counted, not described: "did that work" is owed an answer, and numbers are the honest one. */
    data class Outcome(val books: Int = 0, val marks: Int = 0, val rules: Int = 0, val skippedImports: Int = 0)

    /** What restoring this file changes, decided before anything is written. */
    data class Plan(
        val books: List<BookRecord>,
        val bookmarks: List<ReadingBookmark>,
        val highlights: List<TextHighlight>,
        val rules: List<SiteRule>,
        val skippedImports: Int,
    )

    /**
     * The iOS `restore`, minus the database. A merge, never a replace: a book already here keeps
     * its row unless the file's is newer (last writer wins on `updatedAt`); marks merge either
     * way, since a book read further here may still have highlights only the file holds; a mark
     * already here is not counted again. An imported book that is not on this device is skipped
     * rather than restored as a row with no text — importing the file again lands on the same id,
     * and a second restore then brings its marks back.
     */
    fun plan(existing: Map<String, Book>, knownMarks: Set<String>, installedRules: Set<String>): Plan {
        val books = mutableListOf<BookRecord>()
        val bookmarks = mutableListOf<ReadingBookmark>()
        val highlights = mutableListOf<TextHighlight>()
        var skipped = 0
        for (record in this.books) {
            val local = existing[record.id]
            if (record.isLocal && local == null) {
                skipped++
                continue
            }
            if (local == null || local.updatedAt < record.updatedAt) books += record
            // Re-derived from the record rather than trusted: the id is the place, and a
            // hand-edited file must not be able to file one book's mark under another.
            for (b in record.bookmarks) {
                val mark = ReadingBookmark.make(record.id, b.siteChapterId, b.paragraph, b.characterOffset, b.excerpt, b.createdAt)
                if (mark.id !in knownMarks && bookmarks.none { it.id == mark.id }) bookmarks += mark
            }
            for (h in record.highlights) {
                val mark = TextHighlight.make(
                    record.id, h.siteChapterId, h.startParagraph to h.startCharacterOffset,
                    h.endParagraph to h.endCharacterOffset, h.excerpt, h.createdAt,
                )
                if (mark.id !in knownMarks && highlights.none { it.id == mark.id }) highlights += mark
            }
        }
        // A source already installed is the reader's, and newer than the file's by definition.
        return Plan(books, bookmarks, highlights, rules.filter { it.id !in installedRules }, skipped)
    }

    sealed class Failure(message: String) : Exception(message) {
        class Unreadable : Failure("這個檔案不是這個 App 讀得懂的備份。")
        class UnsupportedVersion(val version: Int) : Failure("這份備份是較新版本的 App 寫出來的。")
    }

    fun encode(): ByteArray = json.encodeToString(serializer(), this).toByteArray()

    companion object {
        /** Bumped only when an older build could no longer make sense of the file; every field since is optional. */
        const val CURRENT_VERSION = 1

        /**
         * The rule files' own leniency, plus defaults written out: iOS has no default for a
         * colour's alpha or a rule's arrays, and refuses a file that leaves one out.
         */
        private val json = Json(SiteRule.json) {
            prettyPrint = true
            encodeDefaults = true
        }

        fun capture(
            books: List<Book>,
            bookmarks: List<ReadingBookmark>,
            highlights: List<TextHighlight>,
            rules: List<SiteRule>,
            settings: Settings,
            now: Long = System.currentTimeMillis(),
        ): LibraryBackup {
            val bookmarksOf = bookmarks.groupBy { it.bookId }
            val highlightsOf = highlights.groupBy { it.bookId }
            val records = books.map { b ->
                BookRecord(
                    b.siteId, b.siteBookId, b.kind, b.title, b.displayName, b.author, b.coverURL, b.addedAt, b.updatedAt,
                    b.lastReadSiteChapterId?.let { ReadingPosition(it, TextAnchor(b.lastReadParagraph ?: 0, b.lastReadCharacterOffset ?: 0)) },
                    b.lastReadFraction, b.lastReadAt, bookmarksOf[b.id].orEmpty(), highlightsOf[b.id].orEmpty(),
                )
            }
            return LibraryBackup(CURRENT_VERSION, now, records, rules, settings)
        }

        /** Newer is refused, older is not: a file from a build that changed the shape would restore wrongly, not partly. */
        fun read(bytes: ByteArray): LibraryBackup {
            val backup = try {
                json.decodeFromString(serializer(), bytes.decodeToString())
            } catch (e: SerializationException) {
                throw Failure.Unreadable()
            } catch (e: IllegalArgumentException) {
                throw Failure.Unreadable()
            }
            if (backup.version > CURRENT_VERSION) throw Failure.UnsupportedVersion(backup.version)
            return backup
        }
    }
}
