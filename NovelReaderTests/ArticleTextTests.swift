import UIKit
import XCTest
@testable import NovelReader

/// What composing an article must not break.
///
/// Structure was added to the reader by making one attributed string out of blocks instead
/// of out of strings — deliberately, so that the anchors, the highlights, the stored
/// position, both renderers and the whole of `TextAnchor` went on working untouched. That
/// only holds while block *n* is anchor paragraph *n*, which is what most of this suite is
/// about: an article that quietly renumbered itself would move every bookmark and
/// highlight in it, silently, and there is no way back from that.
@MainActor
final class ArticleTextTests: XCTestCase {
    private func typography() -> ReaderTypography {
        ReaderTypography(
            body: .systemFont(ofSize: 18),
            title: .systemFont(ofSize: 22, weight: .semibold),
            lineSpacing: 8,
            paragraphSpacing: 14,
            color: .black
        )
    }

    private func text(
        _ blocks: [ArticleBlock], subtitle: String? = nil, layout: ArticleLayout? = nil
    ) -> ChapterText {
        ChapterText(
            title: "An article", subtitle: subtitle, blocks: blocks,
            typography: typography(), layout: layout, alignment: .natural
        )
    }

    // MARK: - Anchors

    func testEveryBlockIsOneAnchorParagraph() {
        let blocks: [ArticleBlock] = [
            ArticleBlock(kind: .heading, runs: [InlineRun(text: "A heading")], level: 2),
            .paragraph("Some prose."),
            ArticleBlock(kind: .code, runs: [InlineRun(text: "let x = 1")]),
            ArticleBlock(kind: .rule, runs: []),
            ArticleBlock(
                kind: .image, runs: [],
                image: ImageRef(source: "https://example.com/a.jpg", alt: "A picture")
            ),
            ArticleBlock(
                kind: .listItem, runs: [InlineRun(text: "An item")], level: 1, marker: "•"
            ),
        ]

        let composed = text(blocks)

        XCTAssertEqual(
            composed.paragraphRanges.count, blocks.count,
            "a block that produced no range would shift every anchor after it"
        )
        // And the ranges have to be in order and disjoint, or an offset resolves to two
        // different paragraphs depending on which end it is asked from.
        for (earlier, later) in zip(composed.paragraphRanges, composed.paragraphRanges.dropFirst()) {
            XCTAssertLessThanOrEqual(NSMaxRange(earlier), later.location)
        }
    }

    /// The subtitle is part of the heading, not a paragraph. If it took an index of its
    /// own, every stored position in every subscribed article would be off by one the day
    /// dates started being shown.
    func testASubtitleDoesNotTakeAParagraphIndex() {
        let blocks: [ArticleBlock] = [.paragraph("One."), .paragraph("Two.")]

        let withDate = text(blocks, subtitle: "4 September 2026")
        let without = text(blocks)

        XCTAssertEqual(withDate.paragraphRanges.count, 2)
        XCTAssertEqual(withDate.paragraphRanges.count, without.paragraphRanges.count)
        XCTAssertTrue(withDate.attributed.string.contains("4 September 2026"))
    }

    func testAnchorsResolveThroughTheBlockTheyName() {
        let composed = text([.paragraph("First."), .paragraph("Second."), .paragraph("Third.")])

        let anchor = TextAnchor(paragraph: 2, characterOffset: 0)
        let offset = composed.offset(for: anchor)

        XCTAssertEqual(composed.anchor(atOffset: offset), anchor)
        XCTAssertEqual(
            composed.attributed.attributedSubstring(
                from: composed.paragraphRanges[2]
            ).string,
            "Third."
        )
    }

    // MARK: - Links

    /// The list the tap hits are looked up in. A link whose range is wrong opens the wrong
    /// address from a place the reader did not press.
    func testLinksAreCollectedWithTheRangeTheyCover() throws {
        let composed = text([
            ArticleBlock(kind: .paragraph, runs: [
                InlineRun(text: "See "),
                InlineRun(text: "the other post", href: "https://example.com/other/"),
                InlineRun(text: " for more."),
            ]),
        ])

        XCTAssertEqual(composed.links.count, 1)
        let link = try XCTUnwrap(composed.links.first)
        XCTAssertEqual(link.url, URL(string: "https://example.com/other/"))
        XCTAssertEqual(
            composed.attributed.attributedSubstring(from: link.range).string, "the other post",
            "the range has to cover the link's own words and nothing around them"
        )
    }

    func testProseHasNoLinksToLookUp() {
        // Every novel chapter in the app goes through this path, and hit-testing a list
        // that is always empty is the cheap case it must stay.
        XCTAssertTrue(text([.paragraph("Nothing to see.")]).links.isEmpty)
    }

    func testAnAddressThatIsNotOneIsNotDrawnAsALink() {
        let composed = text([
            ArticleBlock(kind: .paragraph, runs: [InlineRun(text: "Broken", href: "")]),
        ])

        XCTAssertTrue(composed.links.isEmpty, "an empty address must not become a tappable link")
    }

    // MARK: - Pictures

    /// A picture that never arrived leaves the sentence around it readable. The block still
    /// has to exist, because every anchor after it is counted through it.
    func testAMissingPictureBecomesItsAltTextAndKeepsItsIndex() {
        let composed = text([
            .paragraph("Before."),
            ArticleBlock(
                kind: .image, runs: [],
                image: ImageRef(source: "https://example.com/a.jpg", alt: "A hillside")
            ),
            .paragraph("After."),
        ])

        XCTAssertEqual(composed.paragraphRanges.count, 3)
        XCTAssertEqual(
            composed.attributed.attributedSubstring(from: composed.paragraphRanges[1]).string,
            "A hillside"
        )
    }

    func testAStoredPictureIsLaidOutInsideTheMeasure() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ArticleTextTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let picture = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600)).image { _ in
            UIColor.gray.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: 800, height: 600))
        }
        try XCTUnwrap(picture.pngData()).write(to: directory.appendingPathComponent("0.png"))

        let composed = text(
            [ArticleBlock(
                kind: .image, runs: [],
                image: ImageRef(
                    source: "https://example.com/a.png", file: "0.png",
                    width: 800, height: 600, alt: "A picture"
                )
            )],
            layout: ArticleLayout(width: 300, maxImageHeight: 500, directory: directory)
        )

        let attachment = try XCTUnwrap(
            composed.attributed.attribute(
                .attachment, at: composed.paragraphRanges[0].location, effectiveRange: nil
            ) as? NSTextAttachment,
            "a picture on the device has to be drawn, not described"
        )
        XCTAssertEqual(attachment.bounds.width, 300, accuracy: 1, "scaled down to the measure")
        XCTAssertEqual(attachment.bounds.height, 225, accuracy: 1, "and kept in proportion")
    }

    func testASmallPictureIsNotBlownUpToFillTheMeasure() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ArticleTextTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let icon = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { _ in
            UIColor.gray.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        try XCTUnwrap(icon.pngData()).write(to: directory.appendingPathComponent("0.png"))

        let composed = text(
            [ArticleBlock(
                kind: .image, runs: [],
                image: ImageRef(
                    source: "https://example.com/icon.png", file: "0.png",
                    width: 40, height: 40
                )
            )],
            layout: ArticleLayout(width: 300, maxImageHeight: 500, directory: directory)
        )

        let attachment = try XCTUnwrap(
            composed.attributed.attribute(
                .attachment, at: composed.paragraphRanges[0].location, effectiveRange: nil
            ) as? NSTextAttachment
        )
        XCTAssertEqual(
            attachment.bounds.width, 40, accuracy: 1,
            "an author's inline icon blown across the column is not what they published"
        )
    }

    // MARK: - Decoding

    /// The extractor omits every flag that is false, which is most of them. A decoder that
    /// demanded them would fail a whole article over a word that simply is not bold.
    func testAbsentRunFlagsDecodeAsFalse() throws {
        let json = Data("""
        [{"kind": "paragraph", "runs": [{"text": "Plain."}]}]
        """.utf8)

        let blocks = try JSONDecoder().decode([ArticleBlock].self, from: json)

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].runs[0].text, "Plain.")
        XCTAssertFalse(blocks[0].runs[0].bold)
        XCTAssertNil(blocks[0].runs[0].href)
    }

    /// Losing the styling of one block is the small failure; refusing to open the article
    /// is the large one.
    func testAnUnknownKindReadsAsAParagraphRatherThanFailingTheArticle() throws {
        let json = Data("""
        [{"kind": "diagram", "runs": [{"text": "Something newer."}]},
         {"kind": "paragraph", "runs": [{"text": "And the rest of it."}]}]
        """.utf8)

        let blocks = try JSONDecoder().decode([ArticleBlock].self, from: json)

        XCTAssertEqual(blocks.map(\.kind), [.paragraph, .paragraph])
        XCTAssertEqual(blocks[0].plainText, "Something newer.")
    }

    /// What every part of the app that predates articles asks a block for: the highlight
    /// gesture, the bookmark excerpt, the accessibility label.
    func testPlainTextIsWhatTheRestOfTheAppReads() {
        let image = ArticleBlock(
            kind: .image, runs: [],
            image: ImageRef(source: "https://example.com/a.jpg", alt: "A hillside")
        )
        let item = ArticleBlock(
            kind: .listItem, runs: [InlineRun(text: "An item")], level: 1, marker: "1."
        )

        XCTAssertEqual(image.plainText, "A hillside")
        XCTAssertEqual(item.plainText, "1. An item")
        XCTAssertEqual(ArticleBlock(kind: .rule, runs: []).plainText, "")
    }
}
