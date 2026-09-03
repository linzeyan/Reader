import ImageIO
import UniformTypeIdentifiers

/// Brings an article's pictures onto the device.
///
/// Downloaded with the text rather than when the article is opened, and that is the whole
/// design decision here. A subscription is read the way a downloaded chapter is read — on a
/// train, in a lift, with the phone in flight mode — and a picture fetched at layout time
/// is a picture that is missing exactly when the reading is happening. It also means the
/// publisher is asked once, at refresh, instead of every time the article is opened.
///
/// The cost is disk, which is what retention is for: an article's pictures live in its own
/// directory, so the four delete scopes, the storage screen and `FeedService.purge` already
/// account for them without being told they exist.
struct ArticleImages {
    let session: URLSession
    let downloads: DownloadStore

    /// The longest edge a stored picture may have.
    ///
    /// Above this the file is re-encoded smaller. Not a saving of disk so much as of
    /// memory: a picture in an article is drawn as a text attachment, which means
    /// `UIImage(contentsOfFile:)` decodes the whole thing, and a 4000×3000 press photo is
    /// forty-eight megabytes of bitmap sitting inside a column of prose. Two thousand
    /// pixels is still more than a phone at 3x can show across its width.
    static let maxPixelSize = 2048

    /// The blocks again, with every picture that arrived pointing at a file.
    ///
    /// A picture that will not download is not an error and does not fail the article: the
    /// block keeps its address and its alt text, which is what the reader draws in its
    /// place. Only cancellation is thrown, and it is thrown rather than swallowed so a
    /// refresh the user walked away from does not store a half-illustrated article as
    /// though it were complete.
    ///
    /// - Parameter referer: the article's own page. Sent as `Referer` for the reason
    ///   `ImageFetcher` sends one: a host that serves its images only to its own pages
    ///   answers 403 to a request that arrives from nowhere.
    func stored(
        _ blocks: [ArticleBlock], book: Book, siteChapterId: String, referer: URL?
    ) async throws -> [ArticleBlock] {
        var stored = blocks
        for (position, block) in blocks.enumerated() {
            guard block.kind == .image, let reference = block.image,
                  let url = URL(string: reference.source),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
            else { continue }
            try Task.checkCancellation()
            guard let bytes = try await fetch(url, referer: referer),
                  let prepared = Self.prepare(bytes)
            else { continue }

            // Named after the block it belongs to, so the name is unique without a counter
            // and whoever opens the directory can tell which picture is which. The
            // extension comes from the bytes: `ChapterFileStore.writePages` explains why an
            // address is not evidence of a format.
            var name = String(format: "%03d", position)
            if let format = ImageFormat(sniffing: prepared.data) {
                name += "." + format.fileExtension
            }
            guard (try? downloads.write(
                image: prepared.data, named: name, book: book, siteChapterId: siteChapterId
            )) != nil else { continue }

            stored[position].image?.file = name
            stored[position].image?.width = prepared.width
            stored[position].image?.height = prepared.height
        }
        return stored
    }

    private func fetch(_ url: URL, referer: URL?) async throws -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(WebFetcher.mobileSafariUserAgent, forHTTPHeaderField: "User-Agent")
        if let referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // A cancelled request reports `URLError.cancelled`, which is not the same thing
            // as a picture that would not come back — see `ImageFetcher.load`.
            try Task.checkCancellation()
            return nil
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return nil
        }
        // A 200 that is not a picture: a hotlink-denied stub, a login page, a WAF
        // interstitial. Sniffed rather than decoded, which is twelve bytes against a decode.
        return ImageFormat.isImage(data) ? data : nil
    }

    /// The bytes to store, and the pixel size they will be drawn from.
    ///
    /// A picture already inside the cap is stored exactly as it arrived. Re-encoding one
    /// that is fine as it is would cost a generation of quality for nothing, and it is what
    /// keeps a transparent PNG or an animated GIF — neither of which survives the path
    /// below — the file the publisher actually published.
    private static func prepare(_ data: Data) -> (data: Data, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }
        guard max(width, height) > maxPixelSize else { return (data, width, height) }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        // PNG for anything with transparency, which a logo or a diagram on a coloured
        // background is; JPEG for a photograph, where PNG would be several times the file
        // for a picture nobody can tell apart. Losing the alpha instead would put a black
        // rectangle behind the one kind of picture that has none.
        let opaque = properties[kCGImagePropertyHasAlpha] as? Bool != true
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded, (opaque ? UTType.jpeg : UTType.png).identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination, scaled,
            [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (encoded as Data, scaled.width, scaled.height)
    }
}
