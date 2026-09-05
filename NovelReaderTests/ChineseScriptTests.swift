import UIKit
import XCTest
@testable import NovelReader

final class ChineseScriptTests: XCTestCase {
    private func script(_ depth: ChineseScript.Depth, _ target: ChineseScript.Target) -> ChineseScript {
        ChineseScript(depth: depth, target: target)
    }

    // MARK: - The three tiers

    func testOffLeavesTheSiteSScriptExactlyAsItArrived() {
        let mixed = "简体與正體混在一起"
        XCTAssertEqual(ChineseText.rendered(mixed, in: .off), mixed)
    }

    func testConvertsInBothDirections() {
        for depth in [ChineseScript.Depth.characters, .phrases] {
            XCTAssertEqual(
                ChineseText.rendered("简体中文", in: script(depth, .traditional)), "簡體中文",
                "\(depth) should reach traditional"
            )
            XCTAssertEqual(
                ChineseText.rendered("簡體中文", in: script(depth, .simplified)), "简体中文",
                "\(depth) should reach simplified"
            )
        }
    }

    /// What justifies loading a few megabytes of dictionaries. 斗 and 鬥 both simplified
    /// to 斗, and a character map has to pick one for every 斗 it meets — so the novel
    /// 「斗羅大陸」 becomes 「鬥羅大陸」 on its own title page. Only a converter that reads
    /// the word knows this one is not a fight.
    func testWordConversionKnowsWhatCharacterConversionCannot() {
        XCTAssertEqual(ChineseText.rendered("斗罗大陆", in: script(.phrases, .traditional)), "斗羅大陸")
        XCTAssertEqual(
            ChineseText.rendered("斗罗大陆", in: script(.characters, .traditional)), "鬥羅大陸",
            "if ICU had learned words, this tier would no longer be worth its dictionaries"
        )
    }

    /// The other half of the tier: it renders vocabulary rather than transliterating it,
    /// in whichever direction the reader is going.
    func testWordConversionSwapsVocabularyBothWays() {
        XCTAssertEqual(ChineseText.rendered("鼠标", in: script(.phrases, .traditional)), "滑鼠")
        XCTAssertEqual(ChineseText.rendered("滑鼠", in: script(.phrases, .simplified)), "鼠标")
    }

    func testLeavesTextWithNoChineseInItUntouched() {
        let english = "Chapter 17 — The Crossing"
        XCTAssertEqual(ChineseText.rendered(english, in: script(.phrases, .traditional)), english)
    }

    // MARK: - The guarantee marks depend on

    /// A highlight is stored as a paragraph index and a UTF-16 offset inside it. If a
    /// conversion ever changed a run's length, every mark after it would slide — so the
    /// converter is required to hand back the original rather than do that.
    func testNeverChangesHowLongAParagraphIs() {
        let paragraphs = [
            "他抬头看了一眼头发花白的老人，忽然想起泰坦尼克号沉没那年的新闻报道。",
            "軟體工程師打開了滑鼠旁邊的筆記型電腦，螢幕上是一整頁的資訊。",
            "干了这碗酒，咱们后会有期——只是这面子，我实在挂不住。",
            "第十七章　渡口"
        ]
        for text in paragraphs {
            for depth in [ChineseScript.Depth.characters, .phrases] {
                for target in ChineseScript.Target.allCases {
                    XCTAssertEqual(
                        ChineseText.rendered(text, in: script(depth, target)).utf16.count,
                        text.utf16.count,
                        "\(depth)/\(target) moved an offset in: \(text)"
                    )
                }
            }
        }
    }

    /// The end of the same guarantee: after the composer has run, the range it recorded
    /// for a paragraph still contains that paragraph and nothing else.
    func testParagraphRangesStillPointAtTheirParagraphAfterConverting() {
        let paragraphs = [
            "他抬头看了一眼头发花白的老人。",
            "老人手里还捏着半本斗罗大陆。"
        ]
        let text = ChapterText(
            title: "第十七章　渡口",
            paragraphs: paragraphs,
            typography: typography,
            script: script(.phrases, .traditional)
        )
        let composed = text.attributed.string as NSString
        XCTAssertEqual(text.paragraphRanges.count, paragraphs.count)
        for (index, range) in text.paragraphRanges.enumerated() {
            XCTAssertEqual(
                composed.substring(with: range).utf16.count,
                paragraphs[index].utf16.count,
                "paragraph \(index) is no longer the length its range says"
            )
        }
        XCTAssertTrue(
            composed.contains("斗羅大陸"),
            "the chapter should have been converted at all, and at the tier asked for"
        )
    }

    /// Converting a listing rewrites identifiers into characters no compiler has heard of.
    func testLeavesCodeListingsAlone() {
        let listing = ArticleBlock(kind: .code, runs: [InlineRun(text: "let 简体 = \"发\"")])
        XCTAssertEqual(listing.rendered(in: script(.phrases, .traditional)), listing)
    }

    // MARK: - The setting

    func testDefaultsToPerCharacterConversion() {
        let settings = ReaderSettings(defaults: scratchDefaults())
        XCTAssertEqual(settings.chineseScript.depth, .characters)
    }

    func testRemembersBothHalvesOfTheChoice() {
        let defaults = scratchDefaults()
        let first = ReaderSettings(defaults: defaults)
        first.chineseScript = script(.phrases, .simplified)

        let reopened = ReaderSettings(defaults: defaults)
        XCTAssertEqual(reopened.chineseScript, script(.phrases, .simplified))
    }

    // MARK: - Helpers

    private var typography: ReaderTypography {
        ReaderTypography(
            body: .systemFont(ofSize: 18), title: .systemFont(ofSize: 22),
            lineSpacing: 8, paragraphSpacing: 12, color: .black
        )
    }

    private func scratchDefaults() -> UserDefaults {
        let suite = "ChineseScriptTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return defaults
    }
}
