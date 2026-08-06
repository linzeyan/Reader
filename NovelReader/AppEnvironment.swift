import Foundation
import SwiftUI

/// Everything the view tree needs, wired once at launch.
///
/// A single owner rather than per-view construction because two of these are
/// genuinely singular: the fetcher holds the one WKWebView that carries the
/// Cloudflare clearance cookie, and the download queue must be app-wide so
/// leaving a book's screen does not silently abandon its downloads.
@MainActor
@Observable
final class AppEnvironment {
    let database: AppDatabase
    let files: ChapterFileStore
    let repo: LibraryRepo
    let downloads: DownloadStore
    let fetcher: WebFetcher
    let sites: SiteStore
    let bookService: BookService
    let search: SearchService
    let downloader: DownloadManager
    /// Shared by every unattended fetch — downloads and the reader's read-ahead.
    let pacer: RequestPacer
    let cloud: CloudSync

    /// The library, kept here so every screen sees the same list without each one
    /// re-querying on appear.
    private(set) var books: [Book] = []
    /// Set when a site demands an interactive challenge; drives the sheet that
    /// hands the web view to the user.
    var challenge: ChallengeRequest?
    /// Surfaced as a banner rather than an alert — most failures here are "one
    /// site is unhappy", not "the app is broken".
    var banner: String?

    init(
        database: AppDatabase,
        files: ChapterFileStore,
        sites: SiteStore
    ) {
        self.database = database
        self.files = files
        self.sites = sites
        let repo = LibraryRepo(database: database)
        self.repo = repo
        self.downloads = DownloadStore(database: database, files: files)
        let fetcher = WebFetcher()
        self.fetcher = fetcher
        let bookService = BookService(fetcher: fetcher, repo: repo)
        self.bookService = bookService
        self.search = SearchService(fetcher: fetcher)
        let pacer = RequestPacer()
        self.pacer = pacer
        self.downloader = DownloadManager(service: bookService, downloads: self.downloads, pacer: pacer)
        self.cloud = CloudSync(repo: repo)
        self.cloud.onRemoteChange = { [weak self] in self?.reloadLibrary() }
        reloadLibrary()
    }

    static func makeShared() -> AppEnvironment {
        let env = makeFromDisk()
        #if DEBUG
        // Screenshot mode: a launch argument swaps in a fictional demo library.
        // Debug-only, so a shipping binary does not contain it.
        DemoSeed.applyIfRequested(to: env)
        #endif
        return env
    }

    /// Falls back to an in-memory database if the on-disk one cannot be opened,
    /// so a corrupt store yields a usable (if empty) app instead of a launch
    /// crash the user can do nothing about.
    private static func makeFromDisk() -> AppEnvironment {
        do {
            return AppEnvironment(
                database: try AppDatabase.makeShared(),
                files: try ChapterFileStore.makeShared(),
                sites: try SiteStore.makeShared()
            )
        } catch {
            let fallback = AppEnvironment(
                database: try! AppDatabase.makeInMemory(),
                files: ChapterFileStore(root: URL.temporaryDirectory.appendingPathComponent("Chapters")),
                sites: SiteStore(directory: URL.temporaryDirectory.appendingPathComponent("Rules"))
            )
            fallback.banner = error.localizedDescription
            return fallback
        }
    }

    // MARK: - Library

    func reloadLibrary() {
        books = (try? repo.allBooks()) ?? []
    }

    /// Books grouped by source, in the rule order the settings screen shows.
    /// Bookmarks for a source whose rule was removed still appear, under their
    /// raw site id, rather than vanishing from the library.
    var booksBySite: [(siteId: String, name: String, books: [Book])] {
        let grouped = Dictionary(grouping: books, by: \.siteId)
        let known = sites.rules.compactMap { rule -> (String, String, [Book])? in
            guard let group = grouped[rule.id], !group.isEmpty else { return nil }
            return (rule.id, rule.name, group)
        }
        let orphanIds = grouped.keys.filter { id in !sites.rules.contains { $0.id == id } }.sorted()
        return known + orphanIds.map { ($0, $0, grouped[$0] ?? []) }
    }

    // MARK: - Mutations that must also reach iCloud

    func bookmark(rule: SiteRule, siteBookId: String, info: BookService.Info) throws -> Book {
        let book = try repo.bookmark(
            siteId: rule.id, siteBookId: siteBookId, title: info.title,
            author: info.author, coverURL: info.cover
        )
        cloud.push(book)
        reloadLibrary()
        return book
    }

    /// Bookmarks a book and pulls its chapter index in the same breath.
    ///
    /// Adding a book is already a "wait for the network" moment, so the catalog
    /// is fetched here rather than on first open — otherwise the library shows a
    /// book that turns out to be an empty screen with a spinner, which is the
    /// one moment a new source has to feel like it worked.
    ///
    /// A failed catalog does not undo the bookmark. The book is legitimately
    /// saved; the detail screen will try again. Challenges are surfaced, because
    /// those need the user and nothing else will ask them.
    @discardableResult
    func addBook(rule: SiteRule, siteBookId: String, info: BookService.Info) async throws -> Book {
        let book = try bookmark(rule: rule, siteBookId: siteBookId, info: info)
        do {
            _ = try await bookService.refreshCatalog(rule: rule, book: book)
        } catch {
            if case WebFetcher.FetchError.challengePresented = error { report(error) }
        }
        reloadLibrary()
        return book
    }

    func rename(_ book: Book, to name: String?) {
        try? repo.rename(bookId: book.id, to: name)
        reloadLibrary()
        if let updated = books.first(where: { $0.id == book.id }) { cloud.push(updated) }
    }

    /// Requirement 3.1 + 4.3: removing a bookmark also reclaims its downloads.
    /// Files first — a cascade-deleted chapter row can no longer tell us which
    /// files belonged to the book.
    func removeBookmark(_ book: Book) {
        try? downloads.delete(.book(book))
        try? repo.removeBookmark(bookId: book.id)
        cloud.removed(bookId: book.id)
        if downloader.progress?.bookId == book.id { downloader.cancel() }
        reloadLibrary()
    }

    func recordProgress(book: Book, chapterIndex: Int, offset: Int) {
        try? repo.updateProgress(bookId: book.id, chapterIndex: chapterIndex, offset: offset)
        reloadLibrary()
        if let updated = books.first(where: { $0.id == book.id }) { cloud.push(updated) }
    }

    // MARK: - Errors

    /// Routes a fetch failure: a challenge becomes the interactive sheet,
    /// everything else becomes a banner.
    func report(_ error: any Error) {
        if case WebFetcher.FetchError.challengePresented(let url) = error {
            challenge = ChallengeRequest(url: url)
        } else {
            banner = error.localizedDescription
        }
    }
}
