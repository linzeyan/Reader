package com.zeyanlin.novelreader.services

import java.util.Locale
import kotlin.concurrent.thread

/**
 * What script the reader wants Chinese text in, and how much of the language the conversion
 * may know about — the iOS `ChineseScript`. The sources are split down the middle and not
 * even consistent with themselves, and a reader who wants one script should not have to care
 * which site a chapter came from.
 */
data class ChineseScript(val depth: Depth, val target: Target) {
    enum class Target(val raw: String, val label: String) {
        TRADITIONAL("traditional", "正體"),
        SIMPLIFIED("simplified", "簡體"),
        ;

        companion object {
            fun from(raw: String?) = entries.firstOrNull { it.raw == raw }
        }
    }

    enum class Depth(val raw: String, val label: String) {
        /** Exactly what the site served, mixed scripts and all. */
        OFF("off", "不轉換"),

        /** One character at a time: free and right most of the time, but 「斗罗大陆」 comes out 「鬥羅大陸」. */
        CHARACTERS("characters", "逐字"),

        /** Words first, characters after: 「斗羅大陸」 and 「滑鼠」, for a few megabytes of dictionaries. */
        PHRASES("phrases", "字彙"),
        ;

        companion object {
            fun from(raw: String?) = entries.firstOrNull { it.raw == raw }
        }
    }

    companion object {
        /**
         * The script this device most likely reads, for a reader who has never chosen: a reader
         * in Shanghai must not find their first chapter rewritten into a script they did not ask
         * for. A bare `zh` or `zh-CN` names no script; their likely one is Hans, as iOS's
         * `maximalIdentifier` fills in.
         */
        fun deviceDefault(locale: Locale = Locale.getDefault()): Target {
            val simplified = when (locale.script) {
                "Hans" -> true
                "" -> locale.language == "zh" && locale.country !in setOf("TW", "HK", "MO")
                else -> false
            }
            return if (simplified) Target.SIMPLIFIED else Target.TRADITIONAL
        }
    }
}

/**
 * The 簡繁 conversion — the iOS `ChineseText`. Both tiers run on OpenCC's own dictionaries,
 * copied from the SwiftyOpenCC iOS ships (`scripts/opencc_dicts.py`), through OpenCC's own
 * algorithm: segment by longest match, then pass each segment down a chain of longest-match
 * conversions. iOS's character tier is ICU's transform instead, which Android only has from
 * API 29 and a JVM test never has; OpenCC's character table is the same one-for-one map,
 * built from the same Unihan data.
 */
object ChineseText {
    /**
     * The text in the reader's script, or as it arrived where converting would move offsets.
     * Every mark a reader makes is a paragraph and an offset in it; a character map cannot move
     * those, a dictionary can. So a phrase conversion that changes the length steps down to
     * characters, and one that still would is left alone — losing one word on one paragraph is
     * something nobody notices; moving every highlight in the chapter is not.
     */
    fun rendered(text: String, script: ChineseScript): String {
        if (script.depth == ChineseScript.Depth.OFF || text.none { isHan(it) }) return text
        if (script.depth == ChineseScript.Depth.PHRASES) {
            phrased(text, script.target)?.let { if (it.length == text.length) return it }
        }
        val mapped = converter(script.target, phrases = false)?.convert(text) ?: return text
        return if (mapped.length == text.length) mapped else text
    }

    /** Loads the phrase dictionaries off the main thread, if that is the tier in force. */
    fun prewarm(script: ChineseScript) {
        if (script.depth != ChineseScript.Depth.PHRASES) return
        thread(isDaemon = true, name = "opencc") { converter(script.target, phrases = true) }
    }

    /** OpenCC's own output, length and all — what its test cases are written against. */
    internal fun phrased(text: String, target: ChineseScript.Target) = converter(target, phrases = true)?.convert(text)

    /** Worth asking first: most of what passes through has no Han character at all. */
    fun isHan(c: Char) = c in '\u3400'..'\u4DBF' || c in '\u4E00'..'\u9FFF' || c in '\uF900'..'\uFAFF'

    private val dictionaries = HashMap<String, Dictionary?>()
    private val converters = HashMap<Pair<ChineseScript.Target, Boolean>, Converter?>()

    /**
     * Built once and shared, under one lock held across the build: two chapters laying out at
     * once should wait for one set of dictionaries rather than each load their own. A set that
     * will not load is remembered as null, not retried per paragraph.
     */
    @Synchronized
    private fun converter(target: ChineseScript.Target, phrases: Boolean): Converter? =
        converters.getOrPut(target to phrases) {
            // SwiftyOpenCC's chains for [.traditionalize/.simplify, .twStandard, .twIdiom].
            val (segmentedBy, chain) = when {
                !phrases && target == ChineseScript.Target.TRADITIONAL -> "STCharacters" to listOf(listOf("STCharacters"))
                !phrases -> "TSCharacters" to listOf(listOf("TSCharacters"))
                target == ChineseScript.Target.TRADITIONAL -> "STPhrases" to listOf(
                    listOf("STPhrases", "STCharacters"), listOf("TWPhrases"), listOf("TWVariants"),
                )
                else -> "TSPhrases" to listOf(
                    listOf("TWVariantsRevPhrases", "TWVariantsRev"), listOf("TWPhrasesRev"), listOf("TSPhrases", "TSCharacters"),
                )
            }
            Converter(
                dictionary(segmentedBy) ?: return@getOrPut null,
                chain.map { group -> group.map { dictionary(it) ?: return@getOrPut null } },
            )
        }

    private fun dictionary(name: String): Dictionary? = dictionaries.getOrPut(name) {
        val stream = ChineseText::class.java.getResourceAsStream("/opencc/$name.txt") ?: return@getOrPut null
        val entries = HashMap<String, String>()
        stream.bufferedReader().useLines { lines ->
            for (line in lines) {
                val tab = line.indexOf('\t')
                if (tab <= 0) continue
                // OpenCC converts to an entry's first value.
                entries[line.substring(0, tab)] = line.substring(tab + 1).substringBefore(' ')
            }
        }
        Dictionary(entries)
    }

    private class Dictionary(private val entries: Map<String, String>) {
        private val longest = entries.keys.maxOfOrNull { it.length } ?: 0

        /** The longest key [text] has at [start], as its length and value. */
        fun match(text: String, start: Int): Pair<Int, String>? {
            for (length in minOf(longest, text.length - start) downTo 1) {
                entries[text.substring(start, start + length)]?.let { return length to it }
            }
            return null
        }
    }

    private class Converter(private val segmentation: Dictionary, private val chain: List<List<Dictionary>>) {
        fun convert(text: String): String {
            var segments = segment(text)
            for (group in chain) segments = segments.map { convert(it, group) }
            return segments.joinToString("")
        }

        /** OpenCC's `MaxMatchSegmentation`: matched words alone, unmatched runs together. */
        private fun segment(text: String): List<String> {
            val segments = ArrayList<String>()
            var runStart = 0
            var at = 0
            while (at < text.length) {
                val matched = segmentation.match(text, at)
                if (matched == null) {
                    at += Character.charCount(text.codePointAt(at))
                    continue
                }
                if (runStart < at) segments += text.substring(runStart, at)
                segments += text.substring(at, at + matched.first)
                at += matched.first
                runStart = at
            }
            if (runStart < text.length) segments += text.substring(runStart)
            return segments
        }

        /** OpenCC's `Conversion`; a group answers from its first dictionary that matches at all. */
        private fun convert(segment: String, group: List<Dictionary>): String {
            val out = StringBuilder(segment.length)
            var at = 0
            while (at < segment.length) {
                val matched = group.firstNotNullOfOrNull { it.match(segment, at) }
                if (matched == null) {
                    val length = Character.charCount(segment.codePointAt(at))
                    out.append(segment, at, at + length)
                    at += length
                } else {
                    out.append(matched.second)
                    at += matched.first
                }
            }
            return out.toString()
        }
    }
}
