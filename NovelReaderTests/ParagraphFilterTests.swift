import XCTest
@testable import NovelReader

/// `dropParagraphPatterns` exists to remove site boilerplate that sits *inside*
/// the chapter body, where no CSS selector can reach it. These tests pin the two
/// things that matter: it removes what a rule asked for, and it never removes
/// anything a rule did not ask for.
final class ParagraphFilterTests: XCTestCase {
    private let chapter = [
        "請記住本站域名: 黃金屋",
        "滾滾長江東逝水，浪花淘盡英雄。",
        "話說天下大勢，分久必合，合久必分。",
        "本章未完，請點擊下一頁繼續閱讀",
    ]

    func testDropsOnlyTheMatchingBoilerplate() {
        let kept = BookService.dropping(
            ["^請記住本站域名", "^本章未完"], from: chapter
        )
        XCTAssertEqual(kept, [
            "滾滾長江東逝水，浪花淘盡英雄。",
            "話說天下大勢，分久必合，合久必分。",
        ])
    }

    /// The overwhelmingly common case: a rule with no patterns must be a no-op,
    /// not an empty chapter.
    func testAbsentPatternsLeaveTheChapterUntouched() {
        XCTAssertEqual(BookService.dropping(nil, from: chapter), chapter)
        XCTAssertEqual(BookService.dropping([], from: chapter), chapter)
    }

    /// Rule files are user-authored and travel between devices. A pattern that
    /// does not compile must cost the user that one filter, not the chapter.
    func testUnparseablePatternIsIgnoredRatherThanFatal() {
        XCTAssertEqual(BookService.dropping(["[unclosed"], from: chapter), chapter)
        // A good pattern alongside a broken one still applies.
        let kept = BookService.dropping(["[unclosed", "^本章未完"], from: chapter)
        XCTAssertEqual(kept.count, 3)
        XCTAssertFalse(kept.contains { $0.hasPrefix("本章未完") })
    }

    /// Patterns match anywhere in the line, not just at the start — several sites
    /// append their domain to the end of a paragraph.
    func testMatchesAnywhereInTheParagraph() {
        let kept = BookService.dropping(
            ["黃金屋"], from: ["內文一", "本站網址 www.example.com 黃金屋"]
        )
        XCTAssertEqual(kept, ["內文一"])
    }
}
