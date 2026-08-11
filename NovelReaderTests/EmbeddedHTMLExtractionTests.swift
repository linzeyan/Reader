import XCTest
@testable import NovelReader

/// EPUB chapter text is read by loading the archive's XHTML into the app's one
/// web view and running the *same* extractor the site rules run. That is the
/// whole reason there is no second HTML reader in this codebase, so it has to be
/// covered: if `evaluateJavaScript` stopped working on a locally loaded document
/// — most plausibly because content scripting is switched off for it — every
/// imported EPUB would come out empty with nothing to say why.
///
/// Offline: the document arrives as bytes and its base URL is `about:blank`.
@MainActor
final class EmbeddedHTMLExtractionTests: XCTestCase {
    private func extract(_ html: String) async throws -> ExtractorScript.ChapterPayload {
        let script = try ExtractorScript.chapter(LocalBookImporter.embeddedDocumentRule)
        return try await WebFetcher().extract(
            html: Data(html.utf8), extracting: script, as: ExtractorScript.ChapterPayload.self
        )
    }

    func testParagraphsAndTitleComeOutOfEmbeddedMarkup() async throws {
        let payload = try await extract("""
        <html><head><title>山月記</title></head>
        <body>
          <h1>第一章 下山</h1>
          <p>雪停了。</p>
          <p>風也停了。</p>
        </body></html>
        """)

        XCTAssertEqual(payload.title, "第一章 下山")
        // The heading is dropped from the body: the extractor's title-echo removal
        // works on an EPUB document for the same reason it works on a site page,
        // and without it every chapter would open with its own name twice.
        XCTAssertEqual(payload.paragraphs, ["雪停了。", "風也停了。"])
    }

    /// The markup EPUB producers actually emit: `<br>` between lines, or a bare
    /// `<div>` per paragraph. Both collapse into one unreadable line under plain
    /// `textContent`, and both are already handled by the shared extractor.
    func testLineBreaksAndBlockElementsBecomeParagraphs() async throws {
        let payload = try await extract("""
        <html><body>
          <h2>虎嘯</h2>
          <div>月光落在草上。</div>
          <div>他沒有回頭。<br/>風從谷底來。</div>
          <script>document.title = 'injected';</script>
        </body></html>
        """)

        XCTAssertEqual(payload.paragraphs, ["月光落在草上。", "他沒有回頭。", "風從谷底來。"])
    }

    /// A cover page is a single image and no text. The importer relies on those
    /// extracting to nothing so it can leave them out of the catalog.
    func testImageOnlyDocumentExtractsNothing() async throws {
        let payload = try await extract("<html><body><img src='cover.jpg'/></body></html>")
        XCTAssertEqual(payload.paragraphs, [])
    }

    /// A book's own markup must not execute. The document's origin is opaque so it
    /// could not reach the cookies this web view holds for the user's sites in any
    /// case, but nothing we extract needs scripting, so it stays off.
    func testEmbeddedScriptsDoNotRun() async throws {
        let payload = try await extract("""
        <html><head><title>real</title></head>
        <body>
          <script>document.body.innerHTML = '<p>replaced</p>';</script>
          <p>原文。</p>
        </body></html>
        """)

        XCTAssertEqual(payload.paragraphs, ["原文。"])
    }

    /// Whatever an import did to the web view, an ordinary fetch has to still be
    /// possible afterwards — the two share one instance and one queue.
    func testFetcherIsStillUsableAfterwards() async throws {
        let fetcher = WebFetcher()
        let script = try ExtractorScript.chapter(LocalBookImporter.embeddedDocumentRule)
        for round in 1...3 {
            let payload = try await fetcher.extract(
                html: Data("<html><body><p>第 \(round) 次</p></body></html>".utf8),
                extracting: script, as: ExtractorScript.ChapterPayload.self
            )
            XCTAssertEqual(payload.paragraphs, ["第 \(round) 次"])
        }
        XCTAssertTrue(
            fetcher.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript,
            "content scripting must be restored, or every site fetch would break"
        )
    }
}
