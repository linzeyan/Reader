import XCTest
@testable import NovelReader

/// The writer and the reader are two halves of one format, and the reader is the
/// thing that has to accept what the writer produces — including the checksum it
/// now verifies. So these tests go through `ZipArchive` rather than asserting on
/// bytes: an agreement between the two is the only property that matters.
final class ZipBuilderTests: XCTestCase {
    func testWrittenEntriesComeBackThroughTheReader() throws {
        let stored = Data("application/epub+zip".utf8)
        let deflatable = Data(String(repeating: "夜色漸深，燈火未熄。", count: 400).utf8)
        let bytes = ZipBuilder.archive([
            ZipBuilder.Entry(name: "mimetype", data: stored, compressed: false),
            ZipBuilder.Entry(name: "OEBPS/text/c1.xhtml", data: deflatable),
        ])

        let archive = try ZipArchive(data: bytes)
        XCTAssertEqual(try archive.data(named: "mimetype"), stored)
        XCTAssertEqual(try archive.data(named: "OEBPS/text/c1.xhtml"), deflatable)
        XCTAssertLessThan(bytes.count, deflatable.count, "the long entry was not compressed")
        XCTAssertNil(try archive.data(named: "text/c1.xhtml"), "a near-miss path must not match")
    }

    /// A short entry deflates to more than it started as, and the writer stores it
    /// instead. Worth pinning because the fallback changes the compression method
    /// field, which is the one place a reader could be handed a raw payload while
    /// being told to inflate it.
    func testAnEntryThatWouldGrowIsStoredInstead() throws {
        let payload = Data("x".utf8)
        let bytes = ZipBuilder.archive([ZipBuilder.Entry(name: "a.txt", data: payload)])

        // Method field of the first local header.
        XCTAssertEqual(Array([UInt8](bytes)[8 ... 9]), [0, 0])
        XCTAssertEqual(try ZipArchive(data: bytes).data(named: "a.txt"), payload)
    }

    func testEmptyEntriesSurvive() throws {
        let bytes = ZipBuilder.archive([ZipBuilder.Entry(name: "empty.txt", data: Data())])
        XCTAssertEqual(try ZipArchive(data: bytes).data(named: "empty.txt"), Data())
    }

    /// Byte-for-byte determinism is load-bearing rather than tidy: an imported book
    /// is identified by the digest of its file, so a timestamp anywhere in here
    /// would make every re-export of the same book import as a separate copy.
    func testTheSameEntriesAlwaysProduceTheSameBytes() {
        let entries = [
            ZipBuilder.Entry(name: "mimetype", text: "application/epub+zip", compressed: false),
            ZipBuilder.Entry(name: "OEBPS/c1.xhtml", text: "<html><body><p>雪停了。</p></body></html>"),
        ]
        XCTAssertEqual(ZipBuilder.archive(entries), ZipBuilder.archive(entries))
    }
}
