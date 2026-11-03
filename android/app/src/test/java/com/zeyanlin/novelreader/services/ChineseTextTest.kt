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

    /**
     * OpenCC's character table alone is mainland traditional, and the character tier is the
     * default: every 「為什麼」 and 「看著」 in a book came out 「爲什麼」 and 「看着」.
     */
    @Test
    fun characterConversionWritesTaiwansFormsBothWays() {
        val served = "为什么看着他吃饭，这里"
        val shown = "為什麼看著他吃飯，這裡"
        assertEquals(shown, ChineseText.rendered(served, ChineseScript(Depth.CHARACTERS, Target.TRADITIONAL)))
        assertEquals(served, ChineseText.rendered(shown, ChineseScript(Depth.CHARACTERS, Target.SIMPLIFIED)))
    }

    /** The iOS case of the same name: ICU swapped these for variants Taiwan does not write. */
    @Test
    fun keepsCharactersThatAreAlreadyTraditional() {
        val served = "破釜沉舟，彷徨，力挽狂澜，大汗淋漓，气势磅礴，坂本，喂！"
        for (depth in listOf(Depth.CHARACTERS, Depth.PHRASES)) {
            assertEquals(
                "$depth",
                "破釜沉舟，彷徨，力挽狂瀾，大汗淋漓，氣勢磅礴，坂本，喂！",
                ChineseText.rendered(served, ChineseScript(depth, Target.TRADITIONAL)),
            )
        }
    }

    /** The iOS case of the same name: 69shuba turns its text traditional a character at a time, and wrong. */
    @Test
    fun wordConversionRepairsTextASiteTurnedTraditionalOneCharacterAtATime() {
        val phrases = ChineseScript(Depth.PHRASES, Target.TRADITIONAL)
        assertEquals("他乾笑了一聲，遠征軍，地板上，天花板", ChineseText.rendered("他幹笑了一聲，遠徵軍，地闆上，天花闆", phrases))
        val correct = "在房間裡看著他，沈先生沉默了，乾隆皇帝，幹部們很乾淨，他的頭髮，後來皇后說，特徵，滑鼠"
        assertEquals(correct, ChineseText.rendered(correct, phrases))
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
