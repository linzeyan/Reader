import XCTest
@testable import NovelReader

/// Which queries a search actually sends. Getting this wrong is invisible in
/// the UI — it just looks like the site does not have the book.
final class ChineseVariantsTests: XCTestCase {
    /// A traditional query must also be tried in simplified, because a
    /// simplified site indexes the title in characters the reader never typed.
    func testTraditionalQueryAlsoSearchesSimplified() {
        XCTAssertEqual(ChineseVariants.forms(of: "鬥破蒼穹"), ["鬥破蒼穹", "斗破苍穹"])
    }

    func testSimplifiedQueryAlsoSearchesTraditional() {
        let forms = ChineseVariants.forms(of: "斗破苍穹")
        XCTAssertEqual(forms.first, "斗破苍穹", "The form the user typed is searched first")
        XCTAssertEqual(forms.count, 2)
        XCTAssertNotEqual(forms[0], forms[1])
    }

    /// The user's own text always leads. Conversion is character-level and gets
    /// merged characters wrong — 斗/鬥 is the classic case — so a converted form
    /// is an extra chance at a hit, never a replacement for what was typed.
    func testTheTypedFormIsAlwaysFirst() {
        for query in ["鬥破蒼穹", "斗破苍穹", "劍來", "剑来"] {
            XCTAssertEqual(ChineseVariants.forms(of: query).first, query)
        }
    }

    /// At most two: a third form would mean three page loads per site for one
    /// search, which is the burst the whole app is written to avoid.
    func testNeverMoreThanTwoForms() {
        for query in ["鬥破蒼穹", "斗破苍穹", "臺灣", "台湾", "混合traditional簡體"] {
            XCTAssertLessThanOrEqual(ChineseVariants.forms(of: query).count, 2)
        }
    }

    /// Latin queries have no second script, and a site must not be asked the
    /// same question twice.
    func testNonChineseQueriesAreSearchedOnce() {
        XCTAssertEqual(ChineseVariants.forms(of: "Harry Potter"), ["Harry Potter"])
        XCTAssertEqual(ChineseVariants.forms(of: "12345"), ["12345"])
    }

    func testWhitespaceIsTrimmedAndEmptyQueriesProduceNothing() {
        XCTAssertEqual(ChineseVariants.forms(of: "  劍來  "), ChineseVariants.forms(of: "劍來"))
        XCTAssertEqual(ChineseVariants.forms(of: "   "), [])
    }
}
