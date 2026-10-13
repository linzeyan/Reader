package com.zeyanlin.novelreader.data

import kotlin.math.floor
import kotlin.math.min

/**
 * How far into a chapter a reader is, the way the iOS reader measures it: the UTF-16 offset
 * of the line at the bottom of the window within the chapter as composed — title, then each
 * paragraph, newline-separated — over that text's length. Floored to a whole percent, so a
 * stored share reads the same wherever it is shown.
 */
fun chapterShare(title: String, paragraphs: List<String>, paragraph: Int, offset: Int): Double {
    val total = title.length + paragraphs.sumOf { it.length + 1 }
    if (total == 0) return 1.0
    var at = title.length + 1
    for (i in 0 until paragraph.coerceIn(0, paragraphs.size)) at += paragraphs[i].length + 1
    at += offset
    return floor(min(1.0, at.toDouble() / total) * 100) / 100
}
