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
    /// How many of an article's pictures are fetched at once.
    ///
    /// One at a time was what this did, and on a feed it was the slowest thing the app
    /// does: an illustrated post carries ten or twenty pictures, each its own round trip,
    /// and a refresh of a shelf of subscriptions is hundreds of them end to end — minutes
    /// of waiting on latency with the network otherwise idle.
    ///
    /// Six rather than "all of them". These are all one host — a post's pictures come off
    /// the publisher's own CDN — so this is the number of connections that host sees, and
    /// twenty at once from one reader is the shape that gets answered with a 429. Six is
    /// what every desktop browser opens per host over HTTP/1.1, and over HTTP/2 — which is
    /// what a CDN serving a blog speaks — it is six streams down one connection, so the
    /// server sees less of a burst than the number suggests. A feed is a public document
    /// nobody is being kept out of; `ImageFetcher` holds the comic reader to three against
    /// hosts that are far less friendly.
    static let maxConcurrent = 6

    func stored(
        _ blocks: [ArticleBlock], book: Book, siteChapterId: String, referer: URL?
    ) async throws -> [ArticleBlock] {
        let wanted = blocks.enumerated().compactMap { position, block -> (Int, URL)? in
            guard block.kind == .image, let reference = block.image,
                  let url = URL(string: reference.source),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
            else { return nil }
            return (position, url)
        }
        guard !wanted.isEmpty else { return blocks }

        var stored = blocks
        let session = session
        try await withThrowingTaskGroup(of: Fetched?.self) { group in
            var next = wanted.startIndex
            // The window is refilled as each picture lands rather than in batches of four,
            // so one slow request holds up nothing but itself.
            func fetchNext() {
                guard next < wanted.endIndex else { return }
                let (position, url) = wanted[next]
                next += 1
                group.addTask {
                    try Task.checkCancellation()
                    guard let bytes = try await Self.fetch(url, referer: referer, in: session),
                          let prepared = Self.prepare(bytes)
                    else { return nil }
                    return Fetched(
                        position: position, data: prepared.data,
                        width: prepared.width, height: prepared.height
                    )
                }
            }
            for _ in 0..<min(Self.maxConcurrent, wanted.count) { fetchNext() }

            // Written here rather than inside the tasks: the fetches are independent and
            // the disk is not, and a `DownloadStore` write is the one step of this that
            // has no business happening from four places at once.
            while let result = try await group.next() {
                fetchNext()
                guard let result else { continue }
                // Named after the block it belongs to, so the name is unique without a
                // counter and whoever opens the directory can tell which picture is which.
                // The extension comes from the bytes: `ChapterFileStore.writePages`
                // explains why an address is not evidence of a format.
                var name = String(format: "%03d", result.position)
                if let format = ImageFormat(sniffing: result.data) {
                    name += "." + format.fileExtension
                }
                guard (try? downloads.write(
                    image: result.data, named: name, book: book, siteChapterId: siteChapterId
                )) != nil else { continue }

                stored[result.position].image?.file = name
                stored[result.position].image?.width = result.width
                stored[result.position].image?.height = result.height
            }
        }
        return stored
    }

    /// One picture, fetched and re-encoded, waiting for its turn at the disk.
    private struct Fetched {
        let position: Int
        let data: Data
        let width: Int
        let height: Int
    }

    /// Static, and handed the session, so the fetch carries nothing of this struct into the
    /// task group — the store it holds is the one thing here that must stay on one thread.
    private static func fetch(
        _ url: URL, referer: URL?, in session: URLSession
    ) async throws -> Data? {
        var request = URLRequest(url: url)
        // Ten seconds, against `URLSession`'s default sixty and the twenty this used to
        // send. `ImageFetcher` settled on the same number for the same observation: a CDN
        // that is going to answer answers quickly, and one that is going to stall stalls
        // for as long as it is given. Measured, the cost of the long wait was not
        // theoretical — three image-heavy feeds of the thirteen took eighty-nine per cent
        // of a cold subscribe between them, at thirty to forty seconds *per article*.
        request.timeoutInterval = 10
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
