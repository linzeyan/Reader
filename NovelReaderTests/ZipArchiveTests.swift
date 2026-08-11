import XCTest
@testable import NovelReader

/// The ZIP reader is hand-written, so these tests are the whole safety net under
/// it. Two failure modes matter more than the rest: bytes that come back subtly
/// wrong (an off-by-one in the local header would truncate every chapter), and a
/// feature we do not support being read as if we did.
final class ZipArchiveTests: XCTestCase {
    func testStoredEntryComesBackByteForByte() throws {
        let payload = Data("第一章 開始\n落葉在風裡打轉。".utf8)
        let archive = try ZipArchive(
            data: ZipWriter.archive([ZipWriter.Entry(name: "chapter.txt", data: payload)])
        )
        XCTAssertEqual(try archive.data(named: "chapter.txt"), payload)
    }

    /// Deflate is the method every EPUB uses for its documents, and the offset of
    /// the compressed payload has to be read from the *local* header. Long and
    /// repetitive so the stream really is compressed rather than stored verbatim.
    func testDeflatedEntryRoundTrips() throws {
        let payload = Data(String(repeating: "夜色漸深，燈火未熄。", count: 400).utf8)
        let bytes = ZipWriter.archive([
            ZipWriter.Entry(name: "long.xhtml", data: payload, deflated: true)
        ])
        XCTAssertLessThan(bytes.count, payload.count, "fixture was not actually compressed")
        XCTAssertEqual(try ZipArchive(data: bytes).data(named: "long.xhtml"), payload)
    }

    /// Entries are found by exact path, and several of them sit in directories.
    func testEntriesAreAddressedByFullPath() throws {
        let archive = try ZipArchive(data: ZipWriter.archive([
            ZipWriter.Entry(name: "mimetype", text: "application/epub+zip"),
            ZipWriter.Entry(name: "META-INF/container.xml", text: "<container/>", deflated: true),
            ZipWriter.Entry(name: "OEBPS/text/c1.xhtml", text: "<html/>"),
        ]))
        XCTAssertEqual(
            try archive.data(named: "META-INF/container.xml")
                .map { String(decoding: $0, as: UTF8.self) },
            "<container/>"
        )
        XCTAssertNil(try archive.data(named: "OEBPS/c1.xhtml"), "a near-miss path must not match")
    }

    /// Absent and unreadable are different answers: an EPUB missing an optional
    /// document is still importable, so a lookup miss is nil rather than a throw.
    func testMissingEntryIsNotAnError() throws {
        let archive = try ZipArchive(data: ZipWriter.archive([
            ZipWriter.Entry(name: "a.txt", text: "a")
        ]))
        XCTAssertNil(try archive.data(named: "b.txt"))
    }

    func testNonArchiveIsRejected() {
        XCTAssertThrowsError(try ZipArchive(data: Data("just some text, not a zip".utf8)))
    }

    /// The unsupported corners have to fail at open time. Reading an encrypted
    /// entry as if it were plaintext would put ciphertext into a chapter file and
    /// only look wrong to the user, much later.
    func testEncryptedEntryIsRefused() {
        let bytes = ZipWriter.archive([
            ZipWriter.Entry(name: "secret.xhtml", data: Data("x".utf8), encrypted: true)
        ])
        XCTAssertThrowsError(try ZipArchive(data: bytes)) { error in
            guard case ZipArchive.ZipError.encrypted = error else {
                return XCTFail("expected an encryption error, got \(error)")
            }
        }
    }

    /// The failure with no other symptom: one flipped byte in a *stored* entry
    /// comes back the right length and reads as text, so without the checksum it
    /// would land in a chapter file and only ever look like a typo in the novel.
    ///
    /// The byte is flipped in the payload rather than in the recorded checksum,
    /// because that is the direction damage actually travels — a truncated
    /// download or a bad copy corrupts the data, not the directory.
    func testCorruptedStoredEntryIsRefused() throws {
        var bytes = ZipWriter.archive([
            ZipWriter.Entry(name: "c1.xhtml", text: "<html><body><p>月光落在草上。</p></body></html>")
        ])
        // A stored entry's payload begins right after the local header and its
        // name; `ZipWriter` writes no extra field, so the offset is exact.
        let payload = 30 + "c1.xhtml".utf8.count
        bytes[payload + 9] ^= 0x01

        let archive = try ZipArchive(data: bytes)
        XCTAssertThrowsError(try archive.data(named: "c1.xhtml")) { error in
            guard case ZipArchive.ZipError.checksumMismatch = error else {
                return XCTFail("expected a checksum error, got \(error)")
            }
        }
    }

    func testUnsupportedCompressionMethodIsRefused() {
        let bytes = ZipWriter.archive([
            // 12 is bzip2: legal ZIP, never used by an EPUB, and not something we
            // can decode.
            ZipWriter.Entry(name: "c1.xhtml", data: Data("x".utf8), methodOverride: 12)
        ])
        XCTAssertThrowsError(try ZipArchive(data: bytes)) { error in
            guard case ZipArchive.ZipError.unsupportedCompression(12, _) = error else {
                return XCTFail("expected an unsupported-method error, got \(error)")
            }
        }
    }
}
