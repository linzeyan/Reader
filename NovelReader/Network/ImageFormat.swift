import Foundation

/// What kind of image a file is, told from its first bytes.
///
/// The bytes rather than the `Content-Type`, because the header is the part that lies:
/// an HTML error page served as `image/jpeg` is precisely what a header check waves
/// through, and that is the shape a hotlink refusal usually arrives in.
///
/// Two callers want this and want different halves of it. `ImageFetcher` only asks
/// whether the response is an image at all, so that a 200 carrying a WAF interstitial
/// fails where it happened rather than as a broken page later. `BookExporter` asks what
/// to call the cover it is about to put in an EPUB, and has to be able to decline the
/// answer — which it could not do when the type came from a cached response's MIME
/// header, because there was nothing to compare that claim against.
enum ImageFormat {
    case jpeg
    case png
    case gif
    case webp
    /// HEIC, AVIF and the rest of the ISO base media family, which share a container
    /// and are told apart only by a brand this app has no use for.
    case isoBaseMedia

    init?(sniffing data: Data) {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) {
            self = .jpeg
        } else if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            self = .png
        } else if data.starts(with: [0x47, 0x49, 0x46, 0x38]) {
            self = .gif
        } else {
            // WebP and the ISO family put a size or container magic first, so the tag
            // that identifies them sits further in. WebP is not optional here: it is
            // what manhuagui serves.
            guard data.count >= 12 else { return nil }
            let head = [UInt8](data.prefix(12))
            if Array(head[0..<4]) == Array("RIFF".utf8), Array(head[8..<12]) == Array("WEBP".utf8) {
                self = .webp
            } else if Array(head[4..<8]) == Array("ftyp".utf8) {
                self = .isoBaseMedia
            } else {
                return nil
            }
        }
    }

    /// Truncation is beyond this and beyond any check short of parsing the whole file:
    /// nothing in the first twelve bytes tells a half-written JPEG from a whole one.
    static func isImage(_ data: Data) -> Bool { ImageFormat(sniffing: data) != nil }

    var mediaType: String {
        switch self {
        case .jpeg: return "image/jpeg"
        case .png: return "image/png"
        case .gif: return "image/gif"
        case .webp: return "image/webp"
        case .isoBaseMedia: return "image/heif"
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png: return "png"
        case .gif: return "gif"
        case .webp: return "webp"
        case .isoBaseMedia: return "heic"
        }
    }
}
