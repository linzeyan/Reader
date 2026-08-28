import ImageIO
import UIKit

/// The pages of one chapter: their bytes, their sizes, and the few that are decoded.
///
/// This is the layer the two readers differ by, and the reason the comic renderer is a
/// mirror of the text one rather than the same code. A chapter of text is laid out once
/// and stays laid out — `1273cfb` keeps whole columns resident because glyphs are
/// cheap. A chapter of comic pages decoded at once is not: fifty pages at a phone's
/// width is on the order of two hundred megabytes of bitmap, for a reader looking at
/// one and a half of them.
///
/// So three things are kept, at three different lifetimes:
///
/// - **sizes**, forever. Sixteen bytes a page, and the column cannot keep its stack
///   without them — a page whose bitmap was released must not go back to being an
///   estimate, or leaving a chapter and coming back would move everything under it.
/// - **bytes**, for as long as the chapter is loaded. Compressed, so a chapter is
///   5–20MB rather than hundreds, and re-decoding from them is local work with no
///   network in it.
/// - **decoded images**, only for the pages in the window the coordinator asks for.
///
/// Decoding downsamples to the width the page is drawn at. A 1600px scan on a 400pt
/// screen is 1200px of useful pixels at 3x, and decoding the other 400 costs memory for
/// detail no screen can show.
@MainActor
final class ComicPageStore {
    /// A page's size became known, so the column can replace its estimate. Fired for
    /// every page whose bytes arrive, whether or not it is being drawn — the size is
    /// read from the file's header without decoding it.
    var onSize: ((Int, CGSize) -> Void)?
    /// A page's image became available, so whatever is on screen should be redrawn.
    var onImage: ((Int) -> Void)?
    /// A page could not be fetched. Reported once per page, so a chapter with one dead
    /// image says so without burying the reader in fifty identical banners.
    var onFailure: ((Int, any Error) -> Void)?

    let urls: [URL]
    private let chapterPage: URL
    private let fetcher: ImageFetcher

    private var bytes: [Int: Data] = [:]
    private var sizes: [Int: CGSize] = [:]
    private var images: [Int: UIImage] = [:]
    /// The width each decoded image was prepared for, so a rotation redraws rather than
    /// stretching yesterday's bitmap across a wider screen.
    private var decodedFor: [Int: CGFloat] = [:]
    private var fetching: [Int: Task<Void, Never>] = [:]
    private var decoding: Set<Int> = []
    private var failed: Set<Int> = []
    /// Read once for the whole chapter — see `ImageFetcher.siteCookies`.
    private var cookies: [HTTPCookie]?
    private var cookieTask: Task<[HTTPCookie], Never>?

    init(urls: [URL], chapterPage: URL, fetcher: ImageFetcher) {
        self.urls = urls
        self.chapterPage = chapterPage
        self.fetcher = fetcher
    }

    /// Stops everything in flight. Called when the chapter leaves the loaded window;
    /// deliberately not a `deinit`, which cannot touch main-actor state.
    func cancel() {
        for task in fetching.values { task.cancel() }
        fetching = [:]
        cookieTask?.cancel()
        releaseImages()
    }

    var pageCount: Int { urls.count }

    func image(page: Int) -> UIImage? { images[page] }

    func size(page: Int) -> CGSize? { sizes[page] }

    func hasFailed(page: Int) -> Bool { failed.contains(page) }

    // MARK: - The window

    /// Says which pages are worth having in memory, and at what width.
    ///
    /// Everything outside is released — the bitmap, not the bytes or the size. Called on
    /// every scrolled frame that changes the visible range, so it has to be cheap when
    /// nothing has changed, which is why the checks below all start by asking whether
    /// the work is already done.
    ///
    /// Fetches are *not* cancelled for leaving the window. A page the reader scrolled
    /// past and came back to would otherwise be requested twice, and the request is
    /// already on the wire — cancelling it throws away the only expensive part.
    func setWindow(_ wanted: Range<Int>, width: CGFloat) {
        guard width > 0 else { return }
        // Recorded before any work starts, so a fetch or a decode landing later can ask
        // whether the page it is carrying is still one the reader is near.
        wantedPages = wanted
        pendingWidth = width
        for page in images.keys where !wanted.contains(page) || decodedFor[page] != width {
            images[page] = nil
            decodedFor[page] = nil
        }
        for page in wanted where urls.indices.contains(page) {
            if images[page] != nil || failed.contains(page) { continue }
            if let data = bytes[page] {
                decode(page: page, data: data, width: width)
            } else {
                fetch(page: page)
            }
        }
    }

    /// Releases every decoded bitmap. What a chapter scrolled off the loaded window
    /// gets before it is dropped, and what a memory warning asks of the ones that stay.
    func releaseImages() {
        images = [:]
        decodedFor = [:]
    }

    // MARK: - Fetching

    private func fetch(page: Int) {
        guard fetching[page] == nil, urls.indices.contains(page) else { return }
        let url = urls[page]
        fetching[page] = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await self.bytes(of: url, page: page)
                self.received(data, page: page)
            } catch is CancellationError {
                // The reader left. Not a failure, and nothing to report.
            } catch {
                self.fetching[page] = nil
                self.failed.insert(page)
                self.onFailure?(page, error)
            }
        }
    }

    /// One page's bytes, from wherever that page is.
    ///
    /// A downloaded chapter arrives here as file addresses — see
    /// `ComicReaderModel.storedPages` — and the branch is on the address itself rather
    /// than on a flag passed down, so there is no way for the two to disagree. Neither
    /// the cookie jar nor the referer means anything to a file, and reading one through
    /// `URLSession` to keep a single code path would pay a main-actor hop into WebKit's
    /// cookie store for every page of a chapter that needs no network at all.
    private func bytes(of url: URL, page: Int) async throws -> Data {
        guard url.isFileURL else {
            return try await fetcher.image(
                at: url, chapterPage: chapterPage, page: page + 1, cookies: await jar()
            )
        }
        // Off the main actor: the read is small but it lands mid-scroll, and it is a
        // whole page's bytes. Copied rather than memory-mapped — the storage screen can
        // delete these files while the chapter is open, and a mapped file that goes away
        // under a decode takes the app with it.
        return try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: url)
        }.value
    }

    /// The cookie jar, read once and shared by every page of the chapter.
    private func jar() async -> [HTTPCookie] {
        if let cookies { return cookies }
        // One task, awaited by however many pages started at the same moment: without
        // this, opening a chapter reads the whole of WebKit's cookie store once per page
        // in the first window.
        let task = cookieTask ?? {
            let task = Task { await ImageFetcher.siteCookies() }
            cookieTask = task
            return task
        }()
        let jar = await task.value
        cookies = jar
        return jar
    }

    private func received(_ data: Data, page: Int) {
        fetching[page] = nil
        bytes[page] = data
        // The size first and separately: it comes from the file's header without
        // decoding anything, and it is what lets the column correct its estimate for a
        // page that is nowhere near the screen.
        if sizes[page] == nil, let size = Self.size(of: data) {
            sizes[page] = size
            onSize?(page, size)
        }
        // Only if it is still wanted. A page that arrived after the reader scrolled past
        // it has its bytes kept and its bitmap not made.
        guard let width = pendingWidth, wantedPages.contains(page) else { return }
        decode(page: page, data: data, width: width)
    }

    /// The last window asked for, remembered so a page arriving late knows whether it is
    /// still being looked at.
    private var wantedPages: Range<Int> = 0..<0
    private var pendingWidth: CGFloat?

    // MARK: - Decoding

    private func decode(page: Int, data: Data, width: CGFloat) {
        guard !decoding.contains(page) else { return }
        decoding.insert(page)
        let scale = UITraitCollection.current.displayScale
        Task.detached(priority: .userInitiated) { [weak self] in
            let image = ComicPageStore.decode(data, fitting: width, scale: scale)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.decoding.remove(page)
                guard let image, self.wantedPages.contains(page) else { return }
                self.images[page] = image
                self.decodedFor[page] = width
                self.onImage?(page)
            }
        }
    }

    /// The image's shape, read from its header.
    ///
    /// `CGImageSourceCopyPropertiesAtIndex` parses enough of the file to answer and no
    /// more — no pixels are produced. That is what makes it affordable to learn the
    /// height of every page of a chapter as its bytes land, which is what stops the
    /// column carrying fifty estimates while the reader scrolls through it.
    nonisolated static func size(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double,
              width > 0, height > 0
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Decodes to no more detail than the screen can draw.
    ///
    /// `kCGImageSourceCreateThumbnailFromImageAlways` with a pixel cap is the
    /// downsampling decode: the full image is never materialised, so a 4000px-tall scan
    /// costs what its on-screen size costs rather than what its file says. `UIImage(data:)`
    /// would decode all of it and then be drawn shrunk, which is the same picture for
    /// several times the memory.
    ///
    /// The cap is on the *longest* edge, which for a comic page is the height. A webtoon
    /// strip can be ten screens tall, and capping by width alone would let one page hold
    /// a bitmap larger than the whole rest of the chapter.
    nonisolated static func decode(_ data: Data, fitting width: CGFloat, scale: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let maxPixels = max(width * scale, 1) * Self.longEdgeAllowance
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: image, scale: scale, orientation: .up)
    }

    /// How much taller than wide a page may be decoded at full detail.
    ///
    /// Three, which covers a printed page (1.5) and a double spread with room over, and
    /// stops a webtoon strip — which can be twenty times its own width — from being
    /// decoded at a resolution nobody can see. A capped strip is drawn softer than it
    /// could be; an uncapped one is a bitmap the size of the chapter.
    nonisolated private static let longEdgeAllowance: CGFloat = 3

}
