package com.zeyanlin.novelreader.data

import android.content.SharedPreferences
import com.zeyanlin.novelreader.services.NetworkPolicy
import com.zeyanlin.novelreader.siterules.SiteRule
import com.zeyanlin.novelreader.ui.Layer
import com.zeyanlin.novelreader.ui.Look
import com.zeyanlin.novelreader.ui.MemoryPrefs
import com.zeyanlin.novelreader.ui.Overrides
import com.zeyanlin.novelreader.ui.ReaderBackground
import com.zeyanlin.novelreader.ui.ReaderButton
import com.zeyanlin.novelreader.ui.ReaderColor
import com.zeyanlin.novelreader.ui.ReaderPalette
import com.zeyanlin.novelreader.ui.ReaderSettings
import com.zeyanlin.novelreader.ui.ReaderToolbarLayout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.nio.file.Files
import java.time.Instant

/**
 * The file is the contract with the iOS app, so the fixture is one the iOS types wrote
 * (`/tmp/swiftcheck`, Swift's own JSONEncoder) and the merge rules are the iOS tests' rules.
 */
class BackupTest {
    private val ios = LibraryBackup.read(javaClass.getResource("/backup/ios-backup.json")!!.readBytes())

    private fun at(iso: String) = Instant.parse(iso).toEpochMilli()

    private fun book(id: String, updatedAt: Long): Book {
        val (site, siteBook) = id.split("|")
        return Book(id, site, siteBook, SiteRule.Kind.NOVEL, "t", null, null, null, 0, updatedAt, null, null, null, null, null, null)
    }

    @Test
    fun anIosBackupReadsWhole() {
        val first = ios.books.first { it.id == "czbooks|100" }
        assertEquals("我的山海", first.displayName)
        assertEquals(LibraryBackup.ReadingPosition("c7", LibraryBackup.TextAnchor(4, 12)), first.position)
        assertEquals(at("2025-06-15T15:06:40Z"), first.bookmarks.single().createdAt)
        assertEquals("劃下的字", first.highlights.single().excerpt)
        val palette = ios.settings!!.customPalette!!
        assertEquals(2, (palette.background as ReaderBackground.Colors).stops.size)
        assertEquals("STSongti-TC-Regular", ios.settings!!.fontName)
        // Retention under iOS's names: a renamed field decodes to null and the setting silently stays behind.
        assertEquals(Triple(50, 7, 0), ios.settings!!.let { Triple(it.feedKeep, it.feedGrace, it.feedUnread) })
        // The shelf's too. "recent" and "text" are values neither app has, so this file leaves both alone.
        assertEquals(Triple("recent", false, "text"), ios.settings!!.let { Triple(it.librarySort, it.onlyWithNewChapters, it.defaultMediaMode) })
        assertEquals(listOf("czbooks"), ios.rules.map { it.id })
    }

    // What Swift's decoder refuses, Android must never write: fractional seconds, a colour
    // without alpha, an enum payload not under `_0`.
    @Test
    fun whatAndroidWritesIsShapedForSwift() {
        val palette = ReaderPalette(ReaderBackground.Colors(listOf(ReaderColor(0.1, 0.2, 0.3))), ReaderColor(0.9, 0.9, 0.9))
        val backup = ios.copy(createdAt = at("2026-10-11T01:02:03Z") + 456, settings = ios.settings!!.copy(customPalette = palette))
        val json = Json.parseToJsonElement(backup.encode().decodeToString()).jsonObject
        assertEquals("2026-10-11T01:02:03Z", json["createdAt"]!!.jsonPrimitive.content)
        val background = json["settings"]!!.jsonObject["customPalette"]!!.jsonObject["background"]!!.jsonObject
        val stop = background["colors"]!!.jsonObject["_0"]!!.jsonArray.single() as JsonObject
        assertEquals(1.0, stop["alpha"]!!.jsonPrimitive.content.toDouble(), 0.0)
        assertEquals(backup.copy(createdAt = at("2026-10-11T01:02:03Z")), LibraryBackup.read(backup.encode()))
    }

    private fun settings() = ReaderSettings(MemoryPrefs(), Files.createTempDirectory("reader").toFile())

    /**
     * Every shelf's answers go and come back whole, its bar included — the shelf restored to is
     * the one the reader left. A book's own do not travel, as on iOS, and a shelf the file has
     * following comes back following rather than keeping what this device said.
     */
    @Test
    fun eachShelfTravelsWithItsBarAndNoBookDoes() {
        val from = settings()
        val comics = ReaderToolbarLayout(listOf("settings", "back", "catalog"), listOf("catalog"))
        from.edit(Layer.Shelf(SiteRule.Kind.COMIC)) { it.copy(pageTurn = ReaderSettings.PageTurn.SWIPE, toolbar = comics) }
        from.edit(Layer.Shelf(SiteRule.Kind.NOVEL)) { it.copy(mode = ReaderSettings.Mode.PAGINATED, fontName = "", fontSize = 24) }
        val book = Layer.Book("czbooks|1", SiteRule.Kind.NOVEL)
        from.edit(book) { it.copy(fontSize = 30) }
        val captured = LibraryBackup.Settings.capture(from, NetworkPolicy.WIFI_ONLY, MemoryPrefs())
        val file = LibraryBackup.capture(emptyList(), emptyList(), emptyList(), emptyList(), captured).encode()

        // The names Swift's decoder looks for, and a bar with both lists, which it requires.
        val layers = Json.parseToJsonElement(file.decodeToString()).jsonObject["settings"]!!.jsonObject["readerOverridesByKind"]!!.jsonObject
        assertEquals(setOf("comic", "novel"), layers.keys)
        assertEquals(setOf("pageTurnRaw", "toolbar"), layers["comic"]!!.jsonObject.keys)
        assertEquals(setOf("order", "folded"), layers["comic"]!!.jsonObject["toolbar"]!!.jsonObject.keys)
        assertEquals(setOf("modeRaw", "fontName", "fontSize"), layers["novel"]!!.jsonObject.keys)

        val to = settings()
        to.edit(Layer.Shelf(SiteRule.Kind.FEED)) { it.copy(mode = ReaderSettings.Mode.PAGINATED) }
        to.edit(book) { it.copy(lineSpacing = 3) }
        LibraryBackup.read(file).settings!!.apply(to, {}, emptyList(), MemoryPrefs())
        for (kind in SiteRule.Kind.entries) assertEquals(kind.raw, from.overrides(Layer.Shelf(kind)), to.overrides(Layer.Shelf(kind)))
        assertEquals("a book's answers stay on the device that has the book", Overrides(lineSpacing = 3), to.overrides(book))
    }

    /** What Swift's JSONEncoder writes for the iOS `Overrides` and `ReaderToolbarLayout`, re-indented (`/tmp/android-setup/toolbar-swift`). */
    @Test
    fun anIosShelfsBarReadsHere() {
        val iosLayers = """
            {
              "comic" : {
                "pageTurnRaw" : "swipe",
                "toolbar" : {
                  "folded" : [ "autoScroll" ],
                  "order" : [ "settings", "back", "catalog", "previousChapter", "nextChapter", "autoScroll" ]
                }
              },
              "novel" : { "fontName" : "", "fontSize" : 22, "modeRaw" : "paginated", "themeRaw" : "dark" }
            }
        """
        val file = """{"version":1,"createdAt":"2026-10-13T00:00:00Z","books":[],"rules":[],"settings":{"readerOverridesByKind":$iosLayers}}"""
        val reader = settings()
        LibraryBackup.read(file.toByteArray()).settings!!.apply(reader, {}, emptyList(), MemoryPrefs())

        val (bar, folded) = Look(reader, Layer.Book("manhua|1", SiteRule.Kind.COMIC)).toolbar.resolve(SiteRule.Kind.COMIC)
        assertEquals(listOf(ReaderButton.SETTINGS, ReaderButton.BACK, ReaderButton.CATALOG, ReaderButton.PREVIOUS, ReaderButton.NEXT), bar)
        assertEquals(listOf(ReaderButton.AUTO_SCROLL), folded)
        assertEquals(ReaderSettings.PageTurn.SWIPE, reader.overrides(Layer.Shelf(SiteRule.Kind.COMIC)).pageTurn)
        val novels = Overrides(mode = ReaderSettings.Mode.PAGINATED, fontName = "", fontSize = 22, theme = ReaderSettings.Theme.DARK)
        assertEquals(novels, reader.overrides(Layer.Shelf(SiteRule.Kind.NOVEL)))
    }

    // The shelf's arrangement, the first screen and the history's length, under iOS's names both ways:
    // what Android writes comes back through a restore, and iOS's own file lands where the app reads it,
    // its count held to what the list allows.
    @Test
    fun theLaunchAndShelfSettingsTravel() {
        val here = MemoryPrefs()
        here.edit().putString(LIBRARY_GROUPING, "sourceThenAuthor").putString(HOME_SCREEN, "recent").putInt(RECENT_READING_COUNT, 9).apply()
        val file = ios.copy(settings = LibraryBackup.Settings.capture(reader(here), NetworkPolicy.WIFI_ONLY, here)).encode()
        val written = Json.parseToJsonElement(file.decodeToString()).jsonObject["settings"]!!.jsonObject
        assertEquals(listOf("sourceThenAuthor", "recent", "9"), listOf("libraryGrouping", "home", "recentReadingCount").map { written[it]!!.jsonPrimitive.content })

        val there = MemoryPrefs()
        LibraryBackup.read(file).settings!!.apply(reader(there), {}, emptyList(), there)
        assertEquals(Triple("sourceThenAuthor", "recent", 9), Triple(there.getString(LIBRARY_GROUPING, null), there.getString(HOME_SCREEN, null), there.recentReadingCount()))

        ios.settings!!.apply(reader(there), {}, emptyList(), there)
        assertEquals(Triple("source", "library", 15), Triple(there.getString(LIBRARY_GROUPING, null), there.getString(HOME_SCREEN, null), there.recentReadingCount()))
    }

    private fun reader(prefs: SharedPreferences) = ReaderSettings(prefs, Files.createTempDirectory("reader").toFile())

    @Test
    fun theNewerRecordWins() {
        val record = ios.books.first { it.id == "czbooks|100" }
        val older = ios.plan(mapOf(record.id to book(record.id, record.updatedAt - 1)), emptySet(), emptySet())
        assertTrue(older.books.any { it.id == record.id })
        val newer = ios.plan(mapOf(record.id to book(record.id, record.updatedAt + 1)), emptySet(), emptySet())
        assertTrue(newer.books.none { it.id == record.id })
        // A book read further here may still have marks only the file holds.
        assertEquals(1, newer.bookmarks.count { it.bookId == record.id })
        assertEquals(1, newer.highlights.size)
    }

    @Test
    fun aSecondRestoreChangesNothing() {
        val first = ios.plan(emptyMap(), emptySet(), emptySet())
        val existing = (first.books).associate { it.id to book(it.id, it.updatedAt) }
        val known = (first.bookmarks.map { it.id } + first.highlights.map { it.id }).toSet()
        val again = ios.plan(existing, known, ios.rules.map { it.id }.toSet())
        assertEquals(LibraryBackup.Plan(emptyList(), emptyList(), emptyList(), emptyList(), 1), again)
    }

    // Skipped, not restored as a row with no text; once the file is imported again the same
    // backup brings its marks back.
    @Test
    fun anImportedBookWaitsUntilItIsHere() {
        val away = ios.plan(emptyMap(), emptySet(), emptySet())
        assertEquals(1, away.skippedImports)
        assertTrue(away.books.none { it.isLocal } && away.bookmarks.none { it.bookId == "local|deadbeef" })
        val here = ios.plan(mapOf("local|deadbeef" to book("local|deadbeef", Long.MAX_VALUE)), emptySet(), emptySet())
        assertEquals(0, here.skippedImports)
        assertEquals(1, here.bookmarks.count { it.bookId == "local|deadbeef" })
    }

    @Test
    fun anInstalledRuleIsTheReaders() {
        assertEquals(emptyList<SiteRule>(), ios.plan(emptyMap(), emptySet(), setOf("czbooks")).rules)
    }

    // The id is the place: a hand-edited file must not file one book's mark under another.
    @Test
    fun aMarkBelongsToTheBookItTravelledWith() {
        val record = ios.books.first { it.id == "czbooks|100" }
        val forged = record.bookmarks.single().copy(id = "x", bookId = "czbooks|200")
        val backup = ios.copy(books = listOf(record.copy(bookmarks = listOf(forged))))
        val mark = backup.plan(emptyMap(), emptySet(), emptySet()).bookmarks.single()
        assertEquals("czbooks|100", mark.bookId)
        assertEquals("czbooks|100|c3|2|0", mark.id)
    }

    @Test
    fun onlyABackupThisBuildUnderstandsIsRead() {
        val newer = ios.copy(version = LibraryBackup.CURRENT_VERSION + 1).encode()
        expect<LibraryBackup.Failure.UnsupportedVersion> { LibraryBackup.read(newer) }
        expect<LibraryBackup.Failure.Unreadable> { LibraryBackup.read("not json".toByteArray()) }
        expect<LibraryBackup.Failure.Unreadable> { LibraryBackup.read("""{"id":"czbooks"}""".toByteArray()) }
    }

    private inline fun <reified T : Throwable> expect(block: () -> Unit) {
        try {
            block()
            fail("expected ${T::class.simpleName}")
        } catch (e: Throwable) {
            if (e !is T) throw e
        }
    }
}
