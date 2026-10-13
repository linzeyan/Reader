package com.zeyanlin.novelreader.services

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * One piece of an article in the shape it is laid out in — the iOS `ArticleBlock`, in its JSON:
 * the in-page extractor emits it and it is stored beside the article as is. Block n is anchor
 * paragraph n, so a bookmark, a highlight and a reading position mean what they meant for prose.
 */
@Serializable
data class ArticleBlock(
    /** Kept as written: an unknown kind (only possible across a downgrade) reads as a paragraph rather than failing the article. */
    private val kind: String = "paragraph",
    val runs: List<InlineRun> = emptyList(),
    /** Heading level 1…6, or list nesting depth from 1. */
    val level: Int? = null,
    /** The bullet or number a list item is drawn with, decided where the list was still visible. */
    val marker: String? = null,
    val language: String? = null,
    val image: ImageRef? = null,
) {
    enum class Kind { PARAGRAPH, HEADING, QUOTE, CODE, LIST_ITEM, IMAGE, RULE }

    val type: Kind
        get() = when (kind) {
            "heading" -> Kind.HEADING
            "quote" -> Kind.QUOTE
            "code" -> Kind.CODE
            "listItem" -> Kind.LIST_ITEM
            "image" -> Kind.IMAGE
            "rule" -> Kind.RULE
            else -> Kind.PARAGRAPH
        }

    /** One line of plain text: what search, export, excerpts and the voice read. An image answers with its alt text. */
    val plainText: String
        get() = when (type) {
            Kind.IMAGE -> image?.alt.orEmpty()
            Kind.RULE -> ""
            Kind.LIST_ITEM -> listOfNotNull(marker, runs.joinToString("") { it.text }).joinToString(" ")
            else -> runs.joinToString("") { it.text }
        }

    /** Something to read or look at — what decides whether an extraction found an article at all. */
    val hasContent get() = plainText.isNotEmpty() || type == Kind.IMAGE

    fun withImage(image: ImageRef) = copy(image = image)

    companion object {
        private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

        fun encode(blocks: List<ArticleBlock>): String = json.encodeToString(blocks)

        fun decode(text: String): List<ArticleBlock> = json.decodeFromString(text)
    }
}

/** A stretch of a block that is all one thing; links are why this exists. */
@Serializable
data class InlineRun(
    val text: String = "",
    /** Absolute, resolved while the DOM still knew the article's address. */
    val href: String? = null,
    val bold: Boolean = false,
    val italic: Boolean = false,
    val code: Boolean = false,
)

/** A picture: where it came from, and where it is now. */
@Serializable
data class ImageRef(
    /** The publisher's address, kept after the file is stored: the honest thing to show for a picture that never arrived. */
    val source: String = "",
    /** The file in the article's own image directory, once there; null while it is not. */
    val file: String? = null,
    /** Pixel size of the stored file, which the layout scales from. */
    val width: Int? = null,
    val height: Int? = null,
    val alt: String? = null,
)

/** What a picture's bytes are, from the bytes: an address is no evidence of a format — the iOS `ImageFormat`. */
enum class ImageFormat(val extension: String) {
    JPEG("jpg"), PNG("png"), GIF("gif"), WEBP("webp"), HEIF("heic"), AVIF("avif"), BMP("bmp");

    companion object {
        fun sniff(data: ByteArray): ImageFormat? {
            fun at(offset: Int, vararg bytes: Int) = data.size >= offset + bytes.size && bytes.indices.all { data[offset + it] == bytes[it].toByte() }
            fun ascii(offset: Int, text: String) = at(offset, *text.map { it.code }.toIntArray())
            return when {
                at(0, 0xFF, 0xD8, 0xFF) -> JPEG
                at(0, 0x89, 0x50, 0x4E, 0x47) -> PNG
                ascii(0, "GIF8") -> GIF
                ascii(0, "RIFF") && ascii(8, "WEBP") -> WEBP
                ascii(4, "ftyp") && (ascii(8, "avif") || ascii(8, "avis")) -> AVIF
                ascii(4, "ftyp") -> HEIF
                ascii(0, "BM") -> BMP
                else -> null
            }
        }
    }
}
