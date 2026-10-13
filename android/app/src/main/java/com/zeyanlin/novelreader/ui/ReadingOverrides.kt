package com.zeyanlin.novelreader.ui

import com.zeyanlin.novelreader.siterules.SiteRule
import kotlinx.serialization.Serializable

/**
 * What one book, or one whole shelf, may be read differently from everything else — the iOS
 * `ReaderSettings.Overrides`: how the text is laid out and turned. The script, keeping the screen
 * on and the voice stay out; they are about the person and the device, and no book has an opinion.
 *
 * Null per field, so a book can disagree about one and inherit the rest: a reader who made one
 * book bigger has decided nothing about its colours.
 */
@Serializable
data class Overrides(
    val mode: ReaderSettings.Mode? = null,
    val pageTurn: ReaderSettings.PageTurn? = null,
    /** Null follows; the empty string is the system face, *chosen*, which must not read as following. */
    val fontName: String? = null,
    val fontSize: Int? = null,
    val lineSpacing: Int? = null,
    val paragraphSpacing: Int? = null,
    val theme: ReaderSettings.Theme? = null,
    /** This layer's bottom bar: which controls are worth a place depends on what is being read. */
    val toolbar: ReaderToolbarLayout? = null,
)

/** Whose answers a question is put to: everyone's, a shelf's, or one book's on it. */
sealed interface Layer {
    /** What is being read; null for the general answers, which are about the reader instead. */
    val kind: SiteRule.Kind?

    data object General : Layer {
        override val kind = null
    }

    data class Shelf(override val kind: SiteRule.Kind) : Layer

    data class Book(val id: String, override val kind: SiteRule.Kind) : Layer

    /** The layer this one follows where it says nothing. The general answers follow nobody. */
    val above: Layer get() = if (this is Book) Shelf(kind) else General

    /**
     * This layer's own answer, else the nearest layer above's, else [general]. One walk for every
     * setting: written out field by field and layer by layer it is one rule copied twenty times.
     */
    fun <V : Any> resolve(overrides: (Layer) -> Overrides, field: (Overrides) -> V?, general: V): V {
        var at = this
        while (at != General) {
            field(overrides(at))?.let { return it }
            at = at.above
        }
        return general
    }
}

/**
 * What a layer is read with, resolved, so the readers never learn a book has layers. Read at the
 * moment of asking rather than copied: the readers' gesture handlers are set up once, and a turn
 * changed in the sheet has to reach them.
 */
class Look(private val settings: ReaderSettings, val layer: Layer) {
    val mode get() = resolve(Overrides::mode, settings.mode)
    val pageTurn get() = resolve(Overrides::pageTurn, settings.pageTurn)
    val theme get() = resolve(Overrides::theme, settings.theme)
    val fontSize get() = resolve(Overrides::fontSize, settings.fontSize)
    val lineSpacing get() = resolve(Overrides::lineSpacing, settings.lineSpacing)
    val paragraphSpacing get() = resolve(Overrides::paragraphSpacing, settings.paragraphSpacing)

    /** The arrangement, unresolved: the editor wants it for its layer, the bar for the book it draws. */
    val toolbar get() = resolve(Overrides::toolbar, settings.toolbar)

    /** Null for the system face, which a layer writes down as the empty string. */
    val fontName get() = resolve(Overrides::fontName, settings.fontName.orEmpty()).ifEmpty { null }

    private fun <V : Any> resolve(field: (Overrides) -> V?, general: V) = layer.resolve(settings::overrides, field, general)
}
