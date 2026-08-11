import XCTest
@testable import NovelReader

/// An EPUB is four indirections deep — container to package to spine to
/// document — and every one of them is a place the reading order can silently
/// come out wrong. Order matters more here than anything else: a book whose
/// chapters are shuffled is worse than one that failed to import, because
/// nothing on screen says so.
final class EpubDocumentTests: XCTestCase {
    /// The manifest deliberately lists `c2` before `c1`, so a reader that trusted
    /// the manifest instead of the spine would fail visibly.
    ///
    /// The nav document is always *declared* in the manifest but only present in
    /// the archive when a test adds it — which is also how a book that promises a
    /// nav it does not ship gets covered.
    private static func minimalEpub(_ extra: [ZipWriter.Entry] = []) -> Data {
        ZipWriter.archive([
            ZipWriter.Entry(name: "mimetype", text: "application/epub+zip"),
            ZipWriter.Entry(name: "META-INF/container.xml", text: """
            <?xml version="1.0"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles>
                <rootfile full-path="OEBPS/content.opf"
                          media-type="application/oebps-package+xml"/>
              </rootfiles>
            </container>
            """, deflated: true),
            ZipWriter.Entry(name: "OEBPS/content.opf", text: """
            <?xml version="1.0"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>山月記</dc:title>
                <dc:creator>中島敦</dc:creator>
              </metadata>
              <manifest>
                <item id="cover" href="text/cover.xhtml" media-type="application/xhtml+xml"/>
                <item id="c2" href="text/c2.xhtml" media-type="application/xhtml+xml"/>
                <item id="c1" href="text/c1.xhtml" media-type="application/xhtml+xml"/>
                <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml"
                      properties="nav"/>
              </manifest>
              <spine toc="ncx">
                <itemref idref="cover" linear="no"/>
                <itemref idref="c1"/>
                <itemref idref="c2"/>
              </spine>
            </package>
            """, deflated: true),
            ZipWriter.Entry(name: "OEBPS/text/cover.xhtml", text: "<html><body><img/></body></html>"),
            ZipWriter.Entry(name: "OEBPS/text/c1.xhtml", text: """
            <html><body><h1>回鄉</h1><p>隴西的李徵。</p></body></html>
            """, deflated: true),
            ZipWriter.Entry(name: "OEBPS/text/c2.xhtml", text: """
            <html><body><h1>虎嘯</h1><p>月光落在草上。</p></body></html>
            """, deflated: true),
        ] + extra)
    }

    private static let ncx = ZipWriter.Entry(name: "OEBPS/toc.ncx", text: """
    <?xml version="1.0"?>
    <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
      <navMap>
        <navPoint id="p1" playOrder="1">
          <navLabel><text>第一章 回鄉</text></navLabel>
          <content src="text/c1.xhtml"/>
        </navPoint>
        <navPoint id="p2" playOrder="2">
          <navLabel><text>第二章 虎嘯</text></navLabel>
          <content src="text/c2.xhtml#top"/>
        </navPoint>
      </navMap>
    </ncx>
    """, deflated: true)

    private static let nav = ZipWriter.Entry(name: "OEBPS/nav.xhtml", text: """
    <?xml version="1.0"?>
    <html xmlns:epub="http://www.idpf.org/2007/ops">
      <body>
        <nav epub:type="landmarks"><ol><li><a href="text/c1.xhtml">封面</a></li></ol></nav>
        <nav epub:type="toc">
          <ol>
            <li><a href="text/c1.xhtml">上卷 回鄉</a></li>
            <li><a href="text/c2.xhtml">下卷 虎嘯</a></li>
          </ol>
        </nav>
      </body>
    </html>
    """, deflated: true)

    func testMetadataComesFromThePackageDocument() throws {
        let document = try EpubDocument.parse(Self.minimalEpub([Self.ncx]))
        XCTAssertEqual(document.title, "山月記")
        XCTAssertEqual(document.author, "中島敦")
    }

    /// Spine order wins over manifest order, and `linear="no"` documents stay out
    /// of the reading order the way the attribute says they should.
    func testReadingOrderFollowsTheSpine() throws {
        let document = try EpubDocument.parse(Self.minimalEpub([Self.ncx]))
        XCTAssertEqual(document.items.map(\.path), ["OEBPS/text/c1.xhtml", "OEBPS/text/c2.xhtml"])
    }

    /// Titles come from the ncx, with hrefs resolved relative to it and fragments
    /// dropped — `text/c2.xhtml#top` names the same document as `text/c2.xhtml`.
    func testChapterTitlesComeFromTheNcx() throws {
        let document = try EpubDocument.parse(Self.minimalEpub([Self.ncx]))
        XCTAssertEqual(document.items.map(\.tocTitle), ["第一章 回鄉", "第二章 虎嘯"])
    }

    /// When a book ships both, EPUB 3's nav document is the authority and the ncx
    /// is its legacy copy. The `landmarks` nav in the fixture has to be ignored,
    /// or the first chapter would come out titled "封面".
    func testNavDocumentWinsOverTheNcx() throws {
        let document = try EpubDocument.parse(Self.minimalEpub([Self.ncx, Self.nav]))
        XCTAssertEqual(document.items.map(\.tocTitle), ["上卷 回鄉", "下卷 虎嘯"])
    }

    /// A book with no usable table of contents still imports — the manifest here
    /// promises a nav document the archive does not contain, and there is no ncx
    /// either. The importer then falls back to each document's own heading.
    func testMissingTableOfContentsIsNotFatal() throws {
        let document = try EpubDocument.parse(Self.minimalEpub())
        XCTAssertEqual(document.items.count, 2)
        XCTAssertEqual(document.items.compactMap(\.tocTitle), [])
    }

    func testArchiveWithoutAContainerIsRejected() {
        let bytes = ZipWriter.archive([ZipWriter.Entry(name: "book.txt", text: "not an epub")])
        XCTAssertThrowsError(try EpubDocument.parse(bytes))
    }

    /// Hrefs are URLs and ZIP entry names are not, so a filename with a space
    /// appears percent-encoded in the OPF and plain in the archive.
    func testHrefsAreResolvedAgainstTheirDocumentAndPercentDecoded() {
        XCTAssertEqual(
            EpubDocument.resolve("text/chapter%201.xhtml", relativeTo: "OEBPS"),
            "OEBPS/text/chapter 1.xhtml"
        )
        XCTAssertEqual(
            EpubDocument.resolve("../images/../text/c1.xhtml#part2", relativeTo: "OEBPS/nav"),
            "OEBPS/text/c1.xhtml"
        )
        XCTAssertEqual(EpubDocument.resolve("content.opf", relativeTo: ""), "content.opf")
    }
}
