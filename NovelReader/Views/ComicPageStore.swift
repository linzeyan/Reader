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
/// - **bytes**, for the last `retainedPages` pages the reader was near, and only for
///   pages that came off the network. Compressed, so they are cheap next to a bitmap
///   — but "cheap" times a whole chapter times the three chapters the reader has
///   loaded is over a hundred megabytes held for pages nobody is near, which is what
///   made a long session get slower and slower. A downloaded chapter keeps none at
///   all: its pages are files this app wrote, and reading one back is a disk read.
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
    /// A page arrived from the network, so it can be kept and not asked for twice —
    /// in the chapter cache, or in the hole of a downloaded chapter it was fetched to
    /// fill. Which of those is `ComicReaderModel`'s business, not this one's: a store has
    /// no idea what a chapter is or where one is kept, it has addresses and bytes.
    var onFetched: ((Int, Data) -> Void)?
    /// Where a page already is, asked before every fetch. Answers for the pages
    /// `onFetched` has kept, which is what makes scrolling back through a chapter cost a
    /// disk read rather than the network — see `ChapterCache.page(_:of:siteChapterId:)`.
    /// Absent for a chapter read off the device, which is already nothing but files.
    var cached: ((Int) -> URL?)?
    /// A page has been waited on long enough to be worth offering a retry for, though it
    /// has not failed and is still being waited on. The same consequence as `onFailure`
    /// for whoever is drawing — the page grows a button — and a different thing to say
    /// under it, which is why it is not the same callback.
    var onSlow: ((Int) -> Void)?
    /// A page could not be fetched, so whatever is drawing it should draw that instead.
    /// Not an error anyone is asked about: one dead image out of fifty is an ordinary
    /// thing on these sites, and a banner over the page the reader is on — with the
    /// chapter still perfectly readable underneath it — is the wrong size of answer.
    /// The page itself offers the retry; see `retry(page:)`.
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
    /// The three-second countdown running beside each fetch. See `waitPatiently`.
    private var waiting: [Int: Task<Void, Never>] = [:]
    /// Which attempt at a page is the current one, so an abandoned request that answers
    /// late cannot report itself over the top of the one that replaced it.
    private var attempts: [Int: Int] = [:]
    private var decoding: Set<Int> = []
    private var failed: Set<Int> = []
    /// Asked for, not answered, and waited on long enough that the reader is owed a way
    /// to act. Not a failure: the request underneath is still running.
    private var slow: Set<Int> = []
    /// Read once for the whole chapter — see `ImageFetcher.siteCookies`.
    private var cookies: [HTTPCookie]?
    private var cookieTask: Task<[HTTPCookie], Never>?

    /// - Parameter missing: pages the caller already knows will not arrive on their own —
    ///   the gaps in a downloaded chapter, whose live addresses were substituted so that a
    ///   retry has somewhere to go (`ComicReaderModel.opening`). Marked failed from the
    ///   start rather than fetched, and that is the difference between a gap the reader can
    ///   act on and one they can only stare at: a gap is a page the download already
    ///   reported it could not get, so asking the site for it silently on open leaves them
    ///   in front of a black rectangle for as long as the request takes to give up, with
    ///   nothing to tap the whole time. The button is the honest answer, and tapping it is
    ///   the fetch.
    init(urls: [URL], chapterPage: URL, fetcher: ImageFetcher, missing: Set<Int> = []) {
        self.urls = urls
        self.chapterPage = chapterPage
        self.fetcher = fetcher
        self.failed = missing
    }

    /// Stops everything in flight. Called when the chapter leaves the loaded window;
    /// deliberately not a `deinit`, which cannot touch main-actor state.
    func cancel() {
        for task in fetching.values { task.cancel() }
        fetching = [:]
        for task in waiting.values { task.cancel() }
        waiting = [:]
        cookieTask?.cancel()
        releaseImages()
    }

    var pageCount: Int { urls.count }

    func image(page: Int) -> UIImage? { images[page] }

    func size(page: Int) -> CGSize? { sizes[page] }

    func hasFailed(page: Int) -> Bool { failed.contains(page) }

    /// Whether this page should be drawn with a retry button on it.
    ///
    /// Two different states with the same answer, and telling them apart is the caller's
    /// business: a page that failed says so under its button, while one that is merely
    /// slow says its number, because it has not failed and the app saying it has would be
    /// giving up on the reader's behalf.
    func offersRetry(page: Int) -> Bool { failed.contains(page) || slow.contains(page) }

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

    /// Asks for a page again, because the reader tapped its retry button.
    ///
    /// The mark is cleared *before* the request goes out, so the page goes back to
    /// showing its number while the request is in flight and the button reappearing is
    /// the answer to "did that work". Nothing here decides whether a retry is worth
    /// making — the reader looking at the gap is better placed to know that a chapter
    /// full of failures means the site is refusing them today.
    ///
    /// A retry offered while the first request is still out — the slow case — cancels it
    /// rather than racing it. These hosts stall with the connection held open, so the old
    /// request is not going to answer first, and leaving it running spends one of the few
    /// connections per host that the new one needs.
    func retry(page: Int) {
        let hadFailed = failed.remove(page) != nil
        let wasSlow = slow.remove(page) != nil
        guard hadFailed || wasSlow, let width = pendingWidth else { return }
        stopWaiting(page: page)
        fetching[page]?.cancel()
        fetching[page] = nil
        if let data = bytes[page] {
            decode(page: page, data: data, width: width)
        } else {
            fetch(page: page)
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
        // The kept copy in preference to the address it came from. Resolved here rather
        // than once per chapter because a page kept a moment ago should answer the next
        // look, and because a lookup that came back stale — the file evicted or deleted
        // between the answer and the read — would be a page that never loads.
        let url = cached?(page) ?? urls[page]
        let attempt = (attempts[page] ?? 0) + 1
        attempts[page] = attempt
        fetching[page] = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await self.bytes(of: url, page: page)
                guard self.attempts[page] == attempt else { return }
                self.received(data, page: page, from: url)
            } catch is CancellationError {
                // The reader left, or asked for this page again. Not a failure, and
                // nothing to report.
            } catch {
                guard self.attempts[page] == attempt else { return }
                self.fetching[page] = nil
                self.stopWaiting(page: page)
                self.slow.remove(page)
                self.failed.insert(page)
                self.onFailure?(page, error)
            }
        }
        waitPatiently(page: page, attempt: attempt)
    }

    /// Offers a retry for a page that has been asked for and has not answered yet.
    ///
    /// The request keeps running underneath — this is not a deadline, it is the reader
    /// being given something to do. Which matters because the app cannot tell a page that
    /// is arriving slowly from one that is never arriving: these CDNs stall with the
    /// connection open rather than refusing, so "we do not know yet" can last the whole of
    /// `ImageFetcher`'s ten second silence. Three seconds of a black rectangle with no way
    /// to act is already too long, and if the page does land the button is replaced by it.
    private func waitPatiently(page: Int, attempt: Int) {
        waiting[page] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.patience))
            guard !Task.isCancelled, let self, self.attempts[page] == attempt,
                  self.fetching[page] != nil, !self.failed.contains(page)
            else { return }
            self.slow.insert(page)
            self.onSlow?(page)
        }
    }

    private func stopWaiting(page: Int) {
        waiting[page]?.cancel()
        waiting[page] = nil
    }

    /// How long a page may keep the reader looking at nothing before it grows a button.
    private static let patience: TimeInterval = 3

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
        let data = try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: url)
        }.value
        // The marker the download left where this page should have been. Reported as a
        // failure so the reader draws "page 12 is missing" rather than a page number
        // that will never fill in — see `ChapterFileStore.writePages`.
        guard !data.isEmpty else { throw ImageFetchError.missing(page: page + 1) }
        return data
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

    private func received(_ data: Data, page: Int, from url: URL) {
        fetching[page] = nil
        stopWaiting(page: page)
        // It arrived, so whatever button the wait grew is no longer the answer for it.
        slow.remove(page)
        // Only what would have to come back over the network. A page that came off the
        // disk is already kept — downloaded, or cached by a previous read — and a second
        // copy of it in memory buys a decode that was never the expensive part.
        if !url.isFileURL {
            bytes[page] = data
            trimBytes()
            onFetched?(page, data)
        }
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

    /// How many pages' compressed bytes one chapter keeps.
    ///
    /// Six, which is a screen either side of the window and no more: the reader can
    /// glance back a page or two without anything being asked for again, and a chapter
    /// read end to end stops carrying its whole self. Three loaded chapters at six
    /// pages is a couple of dozen megabytes rather than the hundred and eighty a full
    /// window of long chapters used to hold — which is what made a long session get
    /// slower and slower.
    ///
    /// Scrolling further back than that asks again, and what answers is usually
    /// `ChapterCache` — every page fetched here is written there, so the second ask for
    /// a page is a disk read. Which is what makes six a defensible number rather than a
    /// stingy one.
    private static let retainedPages = 6

    /// Drops the retained pages furthest from what the reader is looking at.
    ///
    /// By distance rather than by age: someone reading forwards and someone flicking
    /// back through a fight scene both want the pages *around them*, and the page that
    /// arrived longest ago may be the one directly above the window.
    private func trimBytes() {
        guard bytes.count > Self.retainedPages else { return }
        let centre = (wantedPages.lowerBound + wantedPages.upperBound) / 2
        let ordered = bytes.keys.sorted { abs($0 - centre) < abs($1 - centre) }
        for page in ordered.dropFirst(Self.retainedPages) { bytes[page] = nil }
    }

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
