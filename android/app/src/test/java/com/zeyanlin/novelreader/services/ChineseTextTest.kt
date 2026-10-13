package com.zeyanlin.novelreader.services

import com.zeyanlin.novelreader.services.ChineseScript.Depth
import com.zeyanlin.novelreader.services.ChineseScript.Target
import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.Locale

/** The iOS `ChineseScriptTests`, plus OpenCC's own cases for the conversion they both run. */
class ChineseTextTest {
    /**
     * The cases OpenCC and SwiftyOpenCC test themselves against, at the options iOS uses.
     * Passing them is what says a paragraph reads the same on both platforms.
     */
    @Test
    fun convertsExactlyAsOpenCCDoes() {
        for ((case, target) in listOf("s2twp" to Target.TRADITIONAL, "tw2sp" to Target.SIMPLIFIED)) {
            assertEquals(case, resource("$case.ans"), ChineseText.phrased(resource("$case.in"), target))
        }
    }

    @Test
    fun offLeavesTheSitesScriptExactlyAsItArrived() {
        val mixed = "简体與正體混在一起"
        assertEquals(mixed, ChineseText.rendered(mixed, ChineseScript(Depth.OFF, Target.TRADITIONAL)))
    }

    @Test
    fun convertsInBothDirections() {
        for (depth in listOf(Depth.CHARACTERS, Depth.PHRASES)) {
            assertEquals("$depth", "簡體中文", ChineseText.rendered("简体中文", ChineseScript(depth, Target.TRADITIONAL)))
            assertEquals("$depth", "简体中文", ChineseText.rendered("簡體中文", ChineseScript(depth, Target.SIMPLIFIED)))
        }
    }

    /** What justifies the dictionaries: 斗 and 鬥 both simplified to 斗, and only a word says which. */
    @Test
    fun wordConversionKnowsWhatCharacterConversionCannot() {
        assertEquals("斗羅大陸", ChineseText.rendered("斗罗大陆", ChineseScript(Depth.PHRASES, Target.TRADITIONAL)))
        assertEquals("鬥羅大陸", ChineseText.rendered("斗罗大陆", ChineseScript(Depth.CHARACTERS, Target.TRADITIONAL)))
    }

    @Test
    fun wordConversionSwapsVocabularyBothWays() {
        assertEquals("滑鼠", ChineseText.rendered("鼠标", ChineseScript(Depth.PHRASES, Target.TRADITIONAL)))
        assertEquals("鼠标", ChineseText.rendered("滑鼠", ChineseScript(Depth.PHRASES, Target.SIMPLIFIED)))
    }

    @Test
    fun leavesTextWithNoChineseInItUntouched() {
        val english = "Chapter 17 — The Crossing"
        assertEquals(english, ChineseText.rendered(english, ChineseScript(Depth.PHRASES, Target.TRADITIONAL)))
    }

    /**
     * A reading position is a paragraph and an offset in it; a conversion that changed a
     * paragraph's length would slide every one after it. 「互联网」→「網際網路」 is the kind that
     * would, and must step down to characters instead.
     */
    @Test
    fun neverChangesHowLongAParagraphIs() {
        val paragraphs = listOf(
            "他抬头看了一眼头发花白的老人，忽然想起泰坦尼克号沉没那年的新闻报道。",
            "軟體工程師打開了滑鼠旁邊的筆記型電腦，螢幕上是一整頁的資訊。",
            "干了这碗酒，咱们后会有期——只是这面子，我实在挂不住。",
            "第十七章　渡口",
            "我们在用互联网。",
        )
        for (text in paragraphs) {
            for (depth in listOf(Depth.CHARACTERS, Depth.PHRASES)) {
                for (target in Target.entries) {
                    assertEquals("$depth/$target: $text", text.length, ChineseText.rendered(text, ChineseScript(depth, target)).length)
                }
            }
        }
        assertEquals("我們在用互聯網。", ChineseText.rendered("我们在用互联网。", ChineseScript(Depth.PHRASES, Target.TRADITIONAL)))
    }

    @Test
    fun aDeviceThatNeverChoseGetsTheScriptItsLanguageIsWrittenIn() {
        val cases = mapOf(
            "zh-Hant-TW" to Target.TRADITIONAL,
            "zh-TW" to Target.TRADITIONAL,
            "zh-HK" to Target.TRADITIONAL,
            "zh-Hans-CN" to Target.SIMPLIFIED,
            "zh-CN" to Target.SIMPLIFIED,
            "zh" to Target.SIMPLIFIED,
            "zh-Hant-CN" to Target.TRADITIONAL,
            "en-US" to Target.TRADITIONAL,
        )
        for ((tag, target) in cases) assertEquals(tag, target, ChineseScript.deviceDefault(Locale.forLanguageTag(tag)))
    }

    private fun resource(name: String) = javaClass.getResource("/opencc/$name")!!.readText()
}
