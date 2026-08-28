import XCTest
@testable import NovelReader

/// What a file is, told from its first bytes.
///
/// Two decisions rest on this and neither can be seen going wrong. A response that is
/// not an image has to fail where it happened, or a chapter downloads "successfully"
/// with a WAF interstitial in it and the reader finds out offline. And a cover has to
/// be declined when EPUB 3.0 cannot carry it, or the export is invalid in a way only a
/// validator reports.
final class ImageFormatTests: XCTestCase {
    func testTellsTheFormatsTheseSitesActuallyServe() {
        XCTAssertEqual(ImageFormat(sniffing: Self.jpeg), .jpeg)
        XCTAssertEqual(ImageFormat(sniffing: Self.png), .png)
        XCTAssertEqual(ImageFormat(sniffing: Self.gif), .gif)
        // Not optional: WebP is what manhuagui serves.
        XCTAssertEqual(ImageFormat(sniffing: Self.webp), .webp)
        XCTAssertEqual(ImageFormat(sniffing: Self.heic), .isoBaseMedia)
    }

    /// The failure this exists for. A hotlink refusal is a 200 carrying an HTML page,
    /// and it arrives labelled `image/jpeg` often enough that believing the label is
    /// how a chapter of error pages gets saved as a chapter of art.
    func testAnHTMLPageIsNotAnImageHoweverItIsLabelled() {
        XCTAssertNil(ImageFormat(sniffing: Data("<!DOCTYPE html><html><body>403".utf8)))
        XCTAssertFalse(ImageFormat.isImage(Data("<!DOCTYPE html><html><body>403".utf8)))
    }

    func testTooFewBytesToTellIsNotAGuess() {
        XCTAssertNil(ImageFormat(sniffing: Data()))
        // Long enough to have started a JPEG and did not.
        XCTAssertNil(ImageFormat(sniffing: Data([0xFF, 0xD8])))
        // The RIFF container of something that is not WebP — a WAV, say.
        XCTAssertNil(ImageFormat(sniffing: Data(Array("RIFF????WAVE".utf8))))
    }

    /// The exporter names the file and declares the type from these two, so they have
    /// to agree with each other for every case it accepts.
    func testEveryFormatNamesItselfConsistently() {
        let cases: [(ImageFormat, String, String)] = [
            (.jpeg, "jpg", "image/jpeg"),
            (.png, "png", "image/png"),
            (.gif, "gif", "image/gif"),
            (.webp, "webp", "image/webp"),
        ]
        for (format, fileExtension, mediaType) in cases {
            XCTAssertEqual(format.fileExtension, fileExtension)
            XCTAssertEqual(format.mediaType, mediaType)
        }
    }

    private static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46])
    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    private static let gif = Data(Array("GIF89a".utf8))
    private static let webp = Data(Array("RIFF".utf8) + [0x1A, 0x00, 0x00, 0x00] + Array("WEBP".utf8))
    private static let heic = Data([0x00, 0x00, 0x00, 0x18] + Array("ftypheic".utf8))
}
