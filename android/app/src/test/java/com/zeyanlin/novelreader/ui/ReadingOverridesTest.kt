package com.zeyanlin.novelreader.ui

import com.zeyanlin.novelreader.siterules.SiteRule
import org.junit.Assert.assertEquals
import org.junit.Test
import java.nio.file.Files

/**
 * Whose answer a book is read with. The order is the feature: a book's own answer, then its
 * shelf's, then the default — field by field, so a reader who made one novel bigger has said
 * nothing about its colours, and nothing about any other book.
 */
class ReadingOverridesTest {
    private val shelf = Layer.Shelf(SiteRule.Kind.NOVEL)
    private val book = Layer.Book("czbooks|1", SiteRule.Kind.NOVEL)
    private val stored = HashMap<Layer, Overrides>()

    private fun <V : Any> Layer.read(field: (Overrides) -> V?, general: V) = resolve({ stored[it] ?: Overrides() }, field, general)

    private fun size(layer: Layer) = layer.read(Overrides::fontSize, 19)

    @Test
    fun aBookFollowsItsShelfThenTheDefaultOneFieldAtATime() {
        assertEquals(19, size(book))

        stored[shelf] = Overrides(fontSize = 22)
        assertEquals("the shelf answers for a book that says nothing", 22, size(book))

        stored[book] = Overrides(lineSpacing = 4)
        assertEquals("disagreeing about one thing is not disagreeing about all", 22, size(book))

        stored[book] = Overrides(fontSize = 16)
        assertEquals(16, size(book))
        assertEquals("a book's answer never reaches its shelf", 22, size(shelf))
        assertEquals("nor the next book on it", 22, size(Layer.Book("czbooks|2", SiteRule.Kind.NOVEL)))
        assertEquals("nor another shelf", 19, size(Layer.Shelf(SiteRule.Kind.COMIC)))
    }

    /** The system face is written down as "": a book taken off its shelf's Ming face must stay off it. */
    @Test
    fun theSystemFaceChosenIsAnAnswerNotFollowing() {
        stored[shelf] = Overrides(fontName = ReaderSettings.SERIF)
        stored[book] = Overrides(fontName = "")
        assertEquals("", book.read(Overrides::fontName, ReaderSettings.SERIF))
        assertEquals(ReaderSettings.SERIF, Layer.Book("czbooks|2", SiteRule.Kind.NOVEL).read(Overrides::fontName, ""))
    }

    /**
     * The bar a reader is handed is the one arranged nearest the book: someone who folds the
     * catalog away on comics has said nothing about novels, and a comic arranged on its own has
     * said nothing about its shelf. Through the settings the readers draw from, relaunch included.
     */
    @Test
    fun aBookReadsWithTheBarArrangedNearestIt() {
        val prefs = MemoryPrefs()
        val dir = Files.createTempDirectory("reader").toFile()
        val settings = ReaderSettings(prefs, dir)
        val comic = Layer.Book("manhua|1", SiteRule.Kind.COMIC)
        val novel = Layer.Book("czbooks|1", SiteRule.Kind.NOVEL)
        fun bar(layer: Layer) = Look(settings, layer).toolbar

        val everywhere = ReaderToolbarLayout.of(ReaderButton.entries.reversed(), emptyList())
        settings.edit(Layer.General) { it.copy(toolbar = everywhere) }
        assertEquals("the default is the bar of a book nobody arranged", everywhere, bar(comic))

        val comics = ReaderToolbarLayout(folded = listOf("catalog"))
        settings.edit(Layer.Shelf(SiteRule.Kind.COMIC)) { it.copy(toolbar = comics) }
        assertEquals(comics, bar(comic))
        assertEquals("one shelf's bar is not another's", everywhere, bar(novel))

        val own = ReaderToolbarLayout(folded = listOf("back"))
        settings.edit(comic) { it.copy(toolbar = own) }
        assertEquals(own, bar(comic))
        assertEquals("a book's bar never reaches its shelf", comics, bar(Layer.Shelf(SiteRule.Kind.COMIC)))
        assertEquals("kept across a relaunch", own, Look(ReaderSettings(prefs, dir), comic).toolbar)

        settings.edit(comic) { it.copy(toolbar = null) }
        assertEquals("put back, the book follows its shelf again", comics, bar(comic))
        assertEquals("and leaves no empty row behind", Overrides(), settings.overrides(comic))
    }
}
