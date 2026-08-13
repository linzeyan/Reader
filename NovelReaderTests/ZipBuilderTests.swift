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
        let bytes = try archive([
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
        let bytes = try archive([ZipBuilder.Entry(name: "a.txt", data: payload)])

        // Method field of the first local header.
        XCTAssertEqual(Array([UInt8](bytes)[8 ... 9]), [0, 0])
        XCTAssertEqual(try ZipArchive(data: bytes).data(named: "a.txt"), payload)
    }

    func testEmptyEntriesSurvive() throws {
        let bytes = try archive([ZipBuilder.Entry(name: "empty.txt", data: Data())])
        XCTAssertEqual(try ZipArchive(data: bytes).data(named: "empty.txt"), Data())
    }

    /// Byte-for-byte determinism is load-bearing rather than tidy: an imported book
    /// is identified by the digest of its file, so a timestamp anywhere in here
    /// would make every re-export of the same book import as a separate copy.
    func testTheSameEntriesAlwaysProduceTheSameBytes() throws {
        let entries = [
            ZipBuilder.Entry(name: "mimetype", text: "application/epub+zip", compressed: false),
            ZipBuilder.Entry(name: "OEBPS/c1.xhtml", text: "<html><body><p>雪停了。</p></body></html>"),
        ]
        XCTAssertEqual(try archive(entries), try archive(entries))
    }

    /// An archive that was never finished has no central directory, so nothing can
    /// read it. That is the shape a cancelled export leaves on disk, and it must
    /// not look like a working file.
    func testAnUnfinishedArchiveIsNotReadable() throws {
        let url = temporaryFile()
        let builder = try ZipBuilder(creating: url)
        try builder.append(ZipBuilder.Entry(name: "a.txt", text: "雪停了。"))

        XCTAssertThrowsError(try ZipArchive(data: try Data(contentsOf: url)))
    }

    // MARK: - Helpers

    /// The writer streams into a file, so every test here goes through one and
    /// reads the result back: what the reader is handed has to be what landed on
    /// disk, not what an in-memory buffer thought it wrote.
    private func archive(_ entries: [ZipBuilder.Entry]) throws -> Data {
        let url = temporaryFile()
        let builder = try ZipBuilder(creating: url)
        for entry in entries { try builder.append(entry) }
        try builder.finish()
        return try Data(contentsOf: url)
    }

    private func temporaryFile() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ZipBuilderTests-\(UUID().uuidString).zip")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
