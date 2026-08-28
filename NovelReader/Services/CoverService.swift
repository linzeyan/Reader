import Foundation
import WebKit

/// Gets a book's cover onto the device, once, and hands back the file it lives in.
///
/// The shelf used to point `AsyncImage` at the site's own URL. That works for the
/// novel sites and cannot work for the comic ones — three of the four refuse an image
/// request that arrives without the page it belongs to, and `AsyncImage` sends no
/// headers. So the fetch is done by hand, with the same `Referer`, identity and
/// cookies a chapter's pages are fetched with, and the bytes are kept (`CoverStore`).
///
/// Fetched when a cover is first drawn rather than when the book is added. That covers
/// three cases one add-time fetch would not: every book already on the shelf, a book
/// restored from iCloud onto a second device, and a cover the site only published
/// after the book was added. What it costs is that a brand-new row shows its
/// placeholder for as long as one small request takes.
///
/// Nothing here paces or limits the requests, and that is deliberate. SwiftUI only
/// draws the rows that are on screen, so the burst is a screenful — which is exactly
/// the shape a browser makes of a page of thumbnails.
@MainActor
final class CoverService {
    private let store: CoverStore
    private let images: ImageFetcher
    private let rule: (String) -> SiteRule?

    /// One fetch per book, however many rows ask for it. The shelf and the reading
    /// history draw the same book at the same moment on the home screen.
    private var inFlight: [String: Task<URL?, Never>] = [:]
    /// Books whose cover would not come back. Covers are hotlinked from the source
    /// site and frequently 403 or simply do not exist, so this is the expected state
    /// rather than the error state — and asking again every time the row scrolls past
    /// would be a request per flick of a thumb, forever.
    private var refused: Set<String> = []
    private var cookieTask: Task<[HTTPCookie], Never>?

    init(store: CoverStore, images: ImageFetcher, rule: @escaping (String) -> SiteRule?) {
        self.store = store
        self.images = images
        self.rule = rule
    }

    /// - Returns: the file this book's cover is in, or nil if it has not got one.
    func cover(for book: Book) async -> URL? {
        let file = store.fileURL(for: book)
        if store.has(book) { return file }
        guard !refused.contains(book.id),
              let address = book.coverURL,
              let url = URL(string: address)
        else { return nil }
        if let running = inFlight[book.id] { return await running.value }

        let task = Task { () -> URL? in
            do {
                let bytes = try await self.images.cover(
                    at: url,
                    bookPage: self.rule(book.siteId)?.bookURL(bookId: book.siteBookId),
                    cookies: await self.jar()
                )
                try self.store.save(bytes, for: book)
                return file
            } catch {
                // Swallowed on purpose. A cover that will not come back is the expected
                // state rather than the error state — see `CoverImage` — and there is
                // nothing the reader would do about it if they were told.
                return nil
            }
        }
        inFlight[book.id] = task
        let result = await task.value
        inFlight[book.id] = nil
        if result == nil { refused.insert(book.id) }
        return result
    }

    /// Drops what is kept about a book that no longer exists. Called from the one
    /// place a book stops existing — see `AppEnvironment.removeBookmark`.
    func remove(_ book: Book) {
        try? store.remove(book)
        refused.remove(book.id)
    }

    /// The cookie jar, read once for a burst of covers rather than once per cover.
    ///
    /// Not held for the session: a jar read before the user cleared a challenge is
    /// missing the one cookie that would have made these requests work. Read once
    /// while a screenful is being fetched, and read again next time.
    private func jar() async -> [HTTPCookie] {
        if let cookieTask { return await cookieTask.value }
        let task = Task { await ImageFetcher.siteCookies() }
        cookieTask = task
        let jar = await task.value
        cookieTask = nil
        return jar
    }
}
