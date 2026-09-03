import XCTest
@testable import NovelReader

/// What an article keeps on its way out of the markup.
///
/// The reason this suite exists and is not folded into `EmbeddedHTMLExtractionTests`: a
/// novel chapter's extractor is judged on what it *throws away* — furniture, navigation,
/// ads — while an article's is judged on what it keeps. Headings, a photograph, a listing
/// and the links inside its sentences are the piece, and the paragraphs-only version of a
/// linked post is a transcript of one.
///
/// Run through the same isolated import view a real refresh uses, with a base URL of
/// `about:blank` — which is exactly why the address every test here asserts on has to be
/// resolved by the script rather than by the DOM.
@MainActor
final class ArticleExtractionTests: XCTestCase {
    private func blocks(
        _ html: String,
        base: String = "https://example.com/posts/one/",
        title: String? = nil
    ) async throws -> [ArticleBlock] {
        let script = try ExtractorScript.article(baseURL: base, title: title)
        let payload = try await WebFetcher().extract(
            html: Data(html.utf8), extracting: script,
            as: ExtractorScript.ArticlePayload.self
        )
        return payload.blocks
    }

    // MARK: - Shape

    func testTheShapeOfAPostSurvives() async throws {
        let blocks = try await blocks("""
        <html><body><article>
          <h2>Why it matters</h2>
          <p>The first paragraph.</p>
          <blockquote>A thing someone said.</blockquote>
          <ul><li>One</li><li>Two</li></ul>
          <hr/>
          <p>The last paragraph.</p>
        </article></body></html>
        """)

        XCTAssertEqual(
            blocks.map(\.kind),
            [.heading, .paragraph, .quote, .listItem, .listItem, .rule, .paragraph],
            "every one of these reads as a different thing, and flattening them loses that"
        )
        XCTAssertEqual(blocks[0].level, 2, "a heading's level is what it is drawn at")
        XCTAssertEqual(blocks[0].plainText, "Why it matters")
        XCTAssertEqual(blocks[3].marker, "\u{2022}")
        XCTAssertEqual(blocks[3].runs.map(\.text).joined(), "One")
    }

    /// An ordered list is numbered where the structure is still visible. Nothing
    /// downstream sees a list — the reader draws one block at a time — so a marker not
    /// resolved here is a numbered list that reads as bullets.
    func testOrderedListsAreNumberedAndNestingIsCarriedAsDepth() async throws {
        let blocks = try await blocks("""
        <html><body>
          <ol start="3">
            <li>Third<ul><li>Nested</li></ul></li>
            <li>Fourth</li>
          </ol>
        </body></html>
        """)

        XCTAssertEqual(blocks.map(\.marker), ["3.", "\u{2022}", "4."])
        XCTAssertEqual(blocks.map(\.level), [1, 2, 1], "indentation is all a reader gets of the tree")
        XCTAssertEqual(
            blocks[0].runs.map(\.text).joined(), "Third",
            "a nested list must not be swallowed into the text of the item holding it"
        )
    }

    /// A listing is the one thing in an article whose whitespace is meaning. Everything
    /// else collapses runs of spaces; this must not.
    func testCodeKeepsItsLinesAndIndentation() async throws {
        // Built by hand rather than as a multi-line literal: the indentation *is* the
        // assertion here, and a literal would have Swift's own margin rules in the middle
        // of it.
        let listing = "func main() {\n    print(\"hi\")\n}"
        let blocks = try await blocks(
            "<html><body><pre class=\"highlight-swift\"><code>\(listing)</code></pre></body></html>"
        )

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .code)
        XCTAssertEqual(
            blocks[0].runs.map(\.text).joined(), listing,
            "a listing whose indentation was collapsed is a different program"
        )
        XCTAssertEqual(blocks[0].language, "swift")
    }

    /// A table has no honest shape in a laid-out column, but its rows are data and
    /// dropping them silently would lose the whole point of the article that has one.
    func testATableComesOutAsItsRows() async throws {
        let blocks = try await blocks("""
        <html><body><table>
          <tr><th>Name</th><th>Size</th></tr>
          <tr><td>A</td><td>1</td></tr>
        </table></body></html>
        """)

        XCTAssertEqual(blocks.map(\.kind), [.code])
        XCTAssertEqual(blocks[0].runs.map(\.text).joined(), "Name | Size\nA | 1")
    }

    // MARK: - Links

    /// The reason `ArticleBlock` has runs at all. A link in the middle of a sentence
    /// cannot be expressed by styling the block, and an article whose links are gone has
    /// lost everything its author pointed at.
    func testALinkInsideASentenceKeepsItsAddress() async throws {
        let blocks = try await blocks("""
        <html><body><p>See <a href="/other/">the other post</a> for more.</p></body></html>
        """)

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].runs.count, 3, "the link is its own run; the sentence is not")
        XCTAssertEqual(blocks[0].runs[1].text, "the other post")
        XCTAssertEqual(
            blocks[0].runs[1].href, "https://example.com/other/",
            "resolved against the article's own address — the document's base is about:blank, "
                + "so a relative link left to the DOM resolves to nothing"
        )
        XCTAssertNil(blocks[0].runs[0].href)
        XCTAssertEqual(blocks[0].plainText, "See the other post for more.")
    }

    func testEmphasisIsCarriedByTheRunAndNotTheBlock() async throws {
        let blocks = try await blocks("""
        <html><body><p>A <strong>bold <em>and italic</em></strong> word, and <code>x = 1</code>.</p></body></html>
        """)

        let runs = blocks[0].runs
        XCTAssertEqual(runs.first(where: { $0.text == "bold " })?.bold, true)
        let both = try XCTUnwrap(runs.first(where: { $0.text == "and italic" }))
        XCTAssertTrue(both.bold && both.italic, "a nested emphasis is both, not the innermost one")
        XCTAssertEqual(runs.first(where: { $0.text == "x = 1" })?.code, true)
    }

    /// `<br>` is a break inside one paragraph. Written as a newline it would split the
    /// block and shift every anchor after it; dropped, two lines of an address run
    /// together.
    func testALineBreakStaysInsideItsBlock() async throws {
        let blocks = try await blocks("<html><body><p>One<br/>Two</p></body></html>")

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].plainText, "One\u{2028}Two")
    }

    // MARK: - Pictures

    func testAPictureIsAnAddressResolvedAgainstTheArticle() async throws {
        let blocks = try await blocks("""
        <html><body>
          <figure>
            <img src="../images/one.jpg" alt="A hillside">
            <figcaption>The hill in question.</figcaption>
          </figure>
        </body></html>
        """)

        XCTAssertEqual(blocks.map(\.kind), [.image, .paragraph])
        XCTAssertEqual(blocks[0].image?.source, "https://example.com/posts/images/one.jpg")
        XCTAssertEqual(blocks[0].image?.alt, "A hillside")
        XCTAssertEqual(blocks[1].plainText, "The hill in question.", "a caption is still words")
    }

    /// The largest of a `srcset`, because this is read once and kept: picking the
    /// phone-sized variant would freeze the article at the resolution of whichever device
    /// happened to fetch it.
    func testTheLargestVariantOfASrcsetIsTaken() async throws {
        let blocks = try await blocks("""
        <html><body><p><img src="small.jpg"
          srcset="small.jpg 400w, medium.jpg 800w, large.jpg 1600w"></p></body></html>
        """)

        XCTAssertEqual(blocks.map(\.kind), [.image])
        XCTAssertEqual(blocks[0].image?.source, "https://example.com/posts/one/large.jpg")
    }

    /// Two shapes that are never a picture in an article: the counter every newsletter
    /// puts at the foot of a post, and an inline data URI, which is already in the
    /// document and is routinely an icon.
    func testTrackingPixelsAndDataURIsAreNotPictures() async throws {
        let blocks = try await blocks("""
        <html><body>
          <p>Text.</p>
          <img src="https://track.example.net/open.gif" width="1" height="1">
          <img src="data:image/gif;base64,R0lGODlhAQABAAAAACw=">
        </body></html>
        """)

        XCTAssertEqual(blocks.map(\.kind), [.paragraph])
    }

    // MARK: - What is dropped

    /// Publishers repeat the headline as the first line of the body constantly, and the
    /// feed has already named the article. Without this every such piece opens with its
    /// own title printed twice.
    func testTheArticlesOwnTitleIsNotPrintedTwice() async throws {
        let blocks = try await blocks(
            """
            <html><body>
              <h1>Why it matters</h1>
              <p>The first paragraph.</p>
            </body></html>
            """,
            title: "Why it matters"
        )

        XCTAssertEqual(blocks.map(\.plainText), ["The first paragraph."])
    }

    /// A piece that opens by quoting its own title in a sentence is not an echo — the
    /// check is deliberately narrow, because deleting a real first paragraph is the
    /// worse failure.
    func testASentenceThatMerelyContainsTheTitleIsKept() async throws {
        let blocks = try await blocks(
            """
            <html><body><p>Why it matters is a question this post has been avoiding for
            three years, and today it stops.</p></body></html>
            """,
            title: "Why it matters"
        )

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .paragraph)
    }

    func testChromeAndScriptsAreNotContent() async throws {
        let blocks = try await blocks("""
        <html><body>
          <nav><a href="/">Home</a></nav>
          <script>document.body.innerHTML = '<p>replaced</p>';</script>
          <style>p { color: red }</style>
          <p>The article.</p>
          <form><button>Subscribe</button></form>
        </body></html>
        """)

        XCTAssertEqual(blocks.map(\.plainText), ["The article."])
    }

    /// The shape a hand-written post arrives in: text and `<div>`s with no `<p>` at all,
    /// wrapped in several layers of container. Recursing without testing for block
    /// children would emit one copy per layer; testing without recursing would flatten
    /// the whole post into a single line.
    func testNestedContainersAreWalkedOnceEach() async throws {
        let blocks = try await blocks("""
        <html><body>
          <div class="outer"><div class="inner">
            <div>First line.</div>
            <div>Second line.</div>
          </div></div>
        </body></html>
        """)

        XCTAssertEqual(blocks.map(\.plainText), ["First line.", "Second line."])
    }
}
