package com.zeyanlin.novelreader.services

import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction

/** One chapter as it comes out of an imported file, before it reaches the library. */
data class ImportedChapter(val title: String, val paragraphs: List<String>)

/**
 * Reads a plain-text novel: works out the encoding, then finds the chapters — the iOS
 * `TextBookParser`. Both halves are guesses that fail loudly when wrong (mojibake, or one
 * unscrollable wall of text), so the order and the thresholds are the substance here.
 */
object TextBookParser {
    /**
     * A byte-order mark first, then strict UTF-8, then Big5, then GB18030 — never GB18030
     * before Big5: it maps almost any byte sequence, so it "succeeds" on Big5 input and
     * produces plausible Simplified nonsense, where Big5 has undefined pairs and can fail.
     */
    fun decode(data: ByteArray): String? {
        fun head(vararg bytes: Int) = data.size >= bytes.size && bytes.indices.all { data[it] == bytes[it].toByte() }
        when {
            head(0xef, 0xbb, 0xbf) -> return strict(data, 3, Charsets.UTF_8)
            head(0xff, 0xfe) -> return strict(data, 2, Charsets.UTF_16LE)
            head(0xfe, 0xff) -> return strict(data, 2, Charsets.UTF_16BE)
        }
        return listOf(Charsets.UTF_8, Charset.forName("Big5"), Charset.forName("GB18030"))
            .firstNotNullOfOrNull { strict(data, 0, it) }
    }

    private fun strict(data: ByteArray, skip: Int, charset: Charset): String? = try {
        charset.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(data, skip, data.size - skip))
            .toString()
    } catch (e: CharacterCodingException) {
        null
    }

    /**
     * Splits at heading lines, falling back to [partLength]-character parts when there are
     * none to split on: the reader lays a whole chapter out at once, so a 2 MB file arriving
     * as one chapter is both unscrollable and a memory problem.
     */
    fun chapters(text: String, partLength: Int = 4_000): List<ImportedChapter> {
        val paragraphs = text.split(NEWLINES).map { it.trim() }.filter { it.isNotEmpty() }
        val found = mutableListOf<ImportedChapter>()
        var title: String? = null
        var body = mutableListOf<String>()

        // A heading with nothing under it is dropped: a volume title straight before a
        // chapter title happens, and a chapter that opens onto a blank page reads as a bug.
        fun flush() {
            if (body.isEmpty()) return
            found += ImportedChapter(title ?: "前言", body)
            body = mutableListOf()
        }

        for (paragraph in paragraphs) {
            if (isHeading(paragraph)) {
                flush()
                title = paragraph
            } else {
                body += paragraph
            }
        }
        flush()

        // One chapter out of a long file means headings in a shape this does not know.
        if (found.size <= 1 && paragraphs.sumOf { it.length } > partLength) return parts(paragraphs, partLength)
        return found
    }

    /**
     * A heading is a short line that starts like one. For Chinese the 60-character cap is the
     * only line drawn — roomy for a subtitled title, short for prose; the Latin branches add a
     * guard of their own, since 60 characters of English is a dozen words.
     */
    private fun isHeading(line: String) = line.length <= 60 && HEADING.containsMatchIn(line)

    /** Cuts at paragraph boundaries: a part that starts mid-line is worse than one that runs long. */
    private fun parts(paragraphs: List<String>, length: Int): List<ImportedChapter> {
        val result = mutableListOf<ImportedChapter>()
        var body = mutableListOf<String>()
        var used = 0
        fun flush() {
            if (body.isEmpty()) return
            result += ImportedChapter("第 ${result.size + 1} 部分", body)
            body = mutableListOf()
            used = 0
        }
        for (paragraph in paragraphs) {
            body += paragraph
            used += paragraph.length
            if (used >= length) flush()
        }
        flush()
        return result
    }

    /** Swift's `isNewline`. Empty pieces are filtered after, so runs need no care. */
    private val NEWLINES = Regex("[\n\r\u000B\u000C\u0085\u2028\u2029]")

    // The iOS pattern, with `\s` and `\b` spelled out: Android's regex is ICU, where both are
    // Unicode-aware, and the JVM the tests run on reads them as ASCII — under which
    // "Chapter １２" would have no word boundary after its full-width digits.
    private const val SPACE = "[\\s\\p{Z}]"

    /** 1–3999 in full rather than "letters from IVXLCDM", which also spells `civil` and `mild`. */
    private const val ROMAN =
        "(?=[ivxlcdm])m{0,3}(?:cm|cd|d?c{0,3})(?:xc|xl|l?x{0,3})(?:ix|iv|v?i{0,3})(?![ivxlcdm])"

    /** English cardinals are a closed set; past ninety-nine these books use digits. */
    private const val ENGLISH = "(?:" +
        "(?:twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)" +
        "(?:[ -](?:one|two|three|four|five|six|seven|eight|nine))?" +
        "|ten|eleven|twelve|(?:thir|four|fif|six|seven|eigh|nine)teen" +
        "|one|two|three|four|five|six|seven|eight|nine" +
        ")"

    /**
     * Chinese numerals listed rather than "any characters", which would promote sentences into
     * breaks. The Latin branches must end the line or go on in something other than lower
     * case: headings continue in Title Case, sentences ("Chapter 12 was…") do not.
     */
    private val HEADING = Regex(
        "^(?:" +
            "第$SPACE*[0-9０-９〇零一二三四五六七八九十百千萬万兩两廿]{1,12}$SPACE*[章卷回話话節节篇集部]" +
            "|序章|序言|楔子|引子|前言|後記|后记|終章|终章|尾聲|尾声|番外" +
            "|(?i:(?:chapter|part|book)$SPACE+(?:[0-9０-９]+|$ROMAN|$ENGLISH))" +
            "(?![\\p{L}\\p{M}\\p{Nd}\\p{Pc}])(?![\\s\\p{Z}\\p{P}]*[a-z])" +
            "|(?i:prologue|epilogue|foreword|afterword)(?!\\p{L})" +
            ")",
    )
}
