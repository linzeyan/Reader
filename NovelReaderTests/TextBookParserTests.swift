import XCTest
@testable import NovelReader

/// Two guesses decide whether an imported `.txt` is readable at all, and each
/// fails in its own unmistakable way: the wrong encoding turns the whole book
/// into mojibake, and a missed heading pattern turns it into one wall of text.
/// These tests pin both.
final class TextBookParserTests: XCTestCase {
    private static let big5 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.big5.rawValue)
        )
    )

    // MARK: - Encoding

    func testUTF8IsDecoded() throws {
        let text = "第一章 起風\n山上的雪還沒融。"
        XCTAssertEqual(TextBookParser.decode(Data(text.utf8)), text)
    }

    /// The one that matters: GB18030 maps almost every byte sequence, so a
    /// detector that reached for it before Big5 would turn a Traditional Chinese
    /// file into plausible-looking Simplified nonsense rather than failing.
    func testBig5FileIsNotDecodedAsSimplified() throws {
        let text = "第一章 起風\n山上的雪還沒融。"
        let data = try XCTUnwrap(text.data(using: Self.big5))
        XCTAssertNil(String(data: data, encoding: .utf8), "fixture must not be valid UTF-8")
        XCTAssertEqual(TextBookParser.decode(data), text)
    }

    /// A byte-order mark is the file telling us outright, and UTF-16 text is not
    /// valid UTF-8, so nothing else can be allowed a say.
    func testByteOrderMarksAreObeyed() throws {
        let text = "第一章 起風\n山上的雪還沒融。"
        var utf16 = Data([0xff, 0xfe])
        utf16.append(try XCTUnwrap(text.data(using: .utf16LittleEndian)))
        XCTAssertEqual(TextBookParser.decode(utf16), text)

        var utf8 = Data([0xef, 0xbb, 0xbf])
        utf8.append(Data(text.utf8))
        XCTAssertEqual(TextBookParser.decode(utf8), text, "the mark itself must not survive")
    }

    func testUndecodableBytesAreReportedRatherThanGuessed() {
        // A lone 0xff cannot start a sequence in UTF-8 or in either legacy
        // encoding, so there is no honest answer to give.
        XCTAssertNil(TextBookParser.decode(Data([0xff, 0x41, 0xff, 0x42])))
    }

    // MARK: - Chapters

    func testHeadingLinesBecomeChapters() {
        let chapters = TextBookParser.chapters(from: """
        第一章 下山
        雪停了。
        風也停了。

        第二卷 入城
        城門在傍晚關上。
        第３回 夜行
        他沒有回頭。
        """)

        XCTAssertEqual(chapters.map(\.title), ["第一章 下山", "第二卷 入城", "第３回 夜行"])
        XCTAssertEqual(chapters[0].paragraphs, ["雪停了。", "風也停了。"])
        XCTAssertEqual(chapters[2].paragraphs, ["他沒有回頭。"])
    }

    /// Text ahead of the first heading is its own chapter rather than being
    /// swallowed into chapter one or dropped.
    func testTextBeforeTheFirstHeadingIsKept() {
        let chapters = TextBookParser.chapters(from: """
        本書由某人整理，僅供試閱。
        第一章 下山
        雪停了。
        """)

        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].paragraphs, ["本書由某人整理，僅供試閱。"])
        XCTAssertEqual(chapters[1].title, "第一章 下山")
    }

    /// An ordinary paragraph that happens to open like a heading must not cut the
    /// book in half. The length cap is the whole guard: prose that references a
    /// chapter runs on, headings stop.
    func testALongLineThatOnlyLooksLikeAHeadingStaysProse() {
        let long = "第三章的內容其實是後來才補寫的，作者在後記裡提過這件事，說是為了補上一段回憶。"
        let chapters = TextBookParser.chapters(from: """
        第一章 下山
        雪停了。
        \(long)
        """)

        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters[0].paragraphs, ["雪停了。", long])
    }

    /// Punctuation must not disqualify a heading — including at the end of the
    /// line. Titles routinely carry it, and refusing them to protect against a
    /// short prose line that opens with a chapter reference would drop headings
    /// people actually write to guard against ones they rarely do. That trade is
    /// deliberate: under the cap, a line like "第二回他就懂了。" does become a break.
    func testAHeadingKeepsItsPunctuation() {
        let chapters = TextBookParser.chapters(from: "第一章 上京：雪夜。\n雪停了。")

        XCTAssertEqual(chapters.map(\.title), ["第一章 上京：雪夜。"])
        XCTAssertEqual(chapters.first?.paragraphs, ["雪停了。"])
    }

    /// A file whose headings we cannot find must not become one enormous chapter:
    /// the reader lays a whole chapter out as one stack of text views, so a 2 MB
    /// single chapter is unscrollable as well as expensive.
    func testHeadinglessFileIsSplitIntoParts() {
        let paragraph = String(repeating: "夜色漸深，燈火未熄。", count: 20)
        let text = (1...60).map { _ in paragraph }.joined(separator: "\n")

        let chapters = TextBookParser.chapters(from: text, partLength: 1_000)

        XCTAssertGreaterThan(chapters.count, 5)
        XCTAssertEqual(Set(chapters.map(\.title)).count, chapters.count, "part titles must differ")
        // Every line survives the split, and none is split down the middle.
        XCTAssertEqual(chapters.flatMap(\.paragraphs).count, 60)
        XCTAssertTrue(chapters.allSatisfy { $0.paragraphs.allSatisfy { $0 == paragraph } })
    }

    /// A short file with a single heading keeps that heading. Falling back to
    /// "part 1" here would throw away a title the file actually gave us.
    func testShortSingleChapterFileKeepsItsTitle() {
        let chapters = TextBookParser.chapters(from: "第一章 下山\n雪停了。")
        XCTAssertEqual(chapters.map(\.title), ["第一章 下山"])
    }

    func testEmptyFileYieldsNothing() {
        XCTAssertTrue(TextBookParser.chapters(from: "\n  \n\n").isEmpty)
    }
}
