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
    let monitor: NetworkMonitor
    let downloadSettings: DownloadSettings
    let librarySettings: LibrarySettings
    let localImporter: LocalBookImporter
    let backgroundDownloads: BackgroundDownloads
    /// Owned but not exposed: nothing on screen asks about a queue read back from
    /// disk, it simply appears as the paused download it was when the app died.
    private let queueRestorer: DownloadQueueRestorer

    /// The environment the running app is using, for the one caller that cannot be
    /// handed it: `BGTaskScheduler`'s launch handler is registered before any view
    /// exists and can fire without one ever existing. Weak on purpose — a
    /// background launch with no scene must hand the window back rather than build
    /// a second object graph nobody owns, on top of a database the real one holds.
    private(set) static weak var live: AppEnvironment?

    /// The library, kept here so every screen sees the same list without each one
    /// re-querying on appear.
    private(set) var books: [Book] = []
    /// How many chapters each book has gained since the reader left off, so the
    /// library can badge a row without querying per book while it scrolls.
    private(set) var newChapterCounts: [String: Int] = [:]
    /// Which chapter each book's stored position lands on in reading order, so a shelf
    /// row can say how far the reader got. Resolved in SQL and cached here for the same
    /// reason the counts are: the position names a chapter, turning that into a number
    /// needs the book's catalog, and the shelf holds no catalogs.
    private(set) var lastReadChapterIndexes: [String: Int] = [:]
    /// Set when a site demands an interactive challenge; drives the sheet that
    /// hands the web view to the user.
    var challenge: ChallengeRequest?
    /// Surfaced as a banner rather than an alert — most failures here are "one
    /// site is unhappy", not "the app is broken".
    var banner: String?
    /// Set when a download would run on a metered connection under the Wi-Fi-only
    /// policy; drives the confirmation alert the root view owns.
    var meteredPrompt: MeteredDownloadRequest?
    /// Consent is per run, not permanent: saying yes once must not silently turn
    /// the setting into "Wi-Fi and cellular".
    private var meteredConsent = false
    /// Set when *the app going away* stopped a download, so returning continues
    /// it. Never set for a pause the user asked for.
    private var resumeWhenActive = false
    /// The background time bought to finish the chapter in flight. At most one.
    private var backgroundAssertion: UIBackgroundTaskIdentifier = .invalid
    /// The import in flight, held so the progress banner's cancel button has
    /// something to pull. At most one: both toolbar buttons are disabled while an
    /// import runs, and the file picker cannot be reopened.
    private var importTask: Task<Book, any Error>?

    init(
        database: AppDatabase,
        files: ChapterFileStore,
        sites: SiteStore,
        queueStore: DownloadQueueStore
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
        let downloader = DownloadManager(
            service: bookService, downloads: self.downloads, pacer: pacer, queueStore: queueStore
        )
        self.downloader = downloader
        self.localImporter = LocalBookImporter(
            repo: repo, downloads: self.downloads, fetcher: fetcher
        )
        self.cloud = CloudSync(repo: repo)
        let monitor = NetworkMonitor()
        self.monitor = monitor
        let downloadSettings = DownloadSettings()
        self.downloadSettings = downloadSettings
        self.librarySettings = LibrarySettings()
        let backgroundDownloads = BackgroundDownloads(
            downloader: downloader,
            settings: downloadSettings,
            connection: { monitor.connection }
        )
        self.backgroundDownloads = backgroundDownloads
        self.queueRestorer = DownloadQueueRestorer(
            store: queueStore,
            downloader: downloader,
            repo: repo,
            settings: downloadSettings,
            record: backgroundDownloads,
            rule: { sites.rule(id: $0) },
            connection: { monitor.connection }
        )
        self.cloud.onRemoteChange = { [weak self] in self?.reloadLibrary() }
        monitor.onChange = { [weak self] _ in self?.networkChanged() }
        reloadLibrary()
        // Last, because a queue read back from disk points into the library and may
        // start fetching straight away: everything it touches has to exist first.
        queueRestorer.restore()
    }

    static func makeShared() -> AppEnvironment {
        let env = makeFromDisk()
        // Only the app's own graph is published. Environments built directly — by
        // tests — must not become the one a background task would drive.
        live = env
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
                sites: try SiteStore.makeShared(),
                queueStore: try DownloadQueueStore.makeShared()
            )
        } catch {
            // The queue file goes to the temporary directory along with everything
            // else here. A real saved queue points into the real library, and this
            // fallback has an empty in-memory one — restoring into it would drop
            // the queue for "the book no longer exists" and lose it for good.
            let fallback = AppEnvironment(
                database: try! AppDatabase.makeInMemory(),
                files: ChapterFileStore(root: URL.temporaryDirectory.appendingPathComponent("Chapters")),
                sites: SiteStore(directory: URL.temporaryDirectory.appendingPathComponent("Rules")),
                queueStore: DownloadQueueStore(
                    url: URL.temporaryDirectory.appendingPathComponent("DownloadQueue.json")
                )
            )
            fallback.banner = error.localizedDescription
            return fallback
        }
    }

    // MARK: - Library

    func reloadLibrary() {
        books = (try? repo.allBooks()) ?? []
        // Loaded together with the books: the two are read as one list, and a
        // separately refreshed count would show a badge next to a book that has
        // already been removed.
        newChapterCounts = (try? repo.newChapterCounts()) ?? [:]
        lastReadChapterIndexes = (try? repo.lastReadChapterIndexes()) ?? [:]
    }

    /// Books grouped by source, in the rule order the settings screen shows.
    /// Bookmarks for a source whose rule was removed still appear, under their
    /// raw site id, rather than vanishing from the library.
    ///
    /// Imported books land in that same trailing group, because no rule will ever
    /// match `Book.localSiteId` — but they are not orphans, so the name comes from
    /// `SiteStore.name(ofSite:)`, which knows the one source that has no file.
    var booksBySite: [LibrarySource] {
        let grouped = Dictionary(grouping: books, by: \.siteId)
        let known = sites.rules.compactMap { rule -> LibrarySource? in
            guard let group = grouped[rule.id], !group.isEmpty else { return nil }
            return LibrarySource(siteId: rule.id, name: rule.name, books: group)
        }
        let orphanIds = grouped.keys.filter { id in !sites.rules.contains { $0.id == id } }.sorted()
        return known + orphanIds.map {
            LibrarySource(siteId: $0, name: sites.name(ofSite: $0), books: grouped[$0] ?? [])
        }
    }

    /// The shelf exactly as the library draws it: `booksBySite` put through the
    /// reader's sort, grouping and filter choices.
    ///
    /// Computed rather than stored so it cannot go stale against either input —
    /// the books reload on every mutation and the settings change from a menu, and
    /// a cached arrangement would need to observe both. Grouping a few dozen books
    /// is nothing next to drawing them.
    var shelf: [LibrarySection] {
        LibraryShelf.sections(
            from: booksBySite,
            sort: librarySettings.sort,
            groupBySource: librarySettings.groupBySource,
            onlyWithNewChapters: librarySettings.onlyWithNewChapters,
            newChapterCounts: newChapterCounts
        )
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

    /// Imports a `.txt` or `.epub` the user picked as a book.
    ///
    /// Not pushed to iCloud, unlike every other way a book enters the library —
    /// see `CloudSync.write`. Nothing else here needs to know: the book is
    /// already complete on disk when this returns.
    ///
    /// The work is wrapped in a task rather than awaited straight through so that
    /// `cancelImport` has a handle to pull. The caller's own task is not something
    /// the progress banner can reach, and the banner is where the cancel button
    /// has to live — it is the only thing on screen that says an import is running.
    @discardableResult
    func importLocalBook(
        from url: URL, progress: @escaping LocalBookImporter.ProgressHandler
    ) async throws -> Book {
        let task = Task { try await localImporter.importBook(from: url, progress: progress) }
        importTask = task
        defer {
            importTask = nil
            // Reloaded however this ends. A cancelled or failed import rolls its
            // own partial book back (see `LocalBookImporter`), and the shelf has to
            // show the result of that rollback, not the state before it.
            reloadLibrary()
        }
        // Cancelling the caller cancels the import too, which is what an
        // unstructured task otherwise breaks: nothing here should keep writing
        // chapters for a screen that has gone away.
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Stops the import in flight, if there is one.
    ///
    /// Cooperative: the importer notices at its next checkpoint and undoes what it
    /// has written, so `importLocalBook` throws `CancellationError` rather than
    /// returning half a book. Callers must not report that as a failure.
    func cancelImport() {
        importTask?.cancel()
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

    /// - Parameters:
    ///   - fraction: how far into the chapter, measured against the text the reader had
    ///     on screen. See `Book.lastReadFraction`.
    ///   - publish: whether the rest of the app hears about it as well. The row is always
    ///     written; refreshing the shelf and pushing to iCloud are what a reader mid-page
    ///     does not need, and doing both every few seconds would re-query every book and
    ///     its new-chapter counts behind a screen nobody is looking at. The writes that
    ///     end a reading session — a chapter change, leaving, going to the background —
    ///     publish, and that is when the shelf is about to be looked at anyway.
    func recordProgress(
        book: Book, position: ReadingPosition, fraction: Double?, publish: Bool
    ) {
        try? repo.updateProgress(bookId: book.id, position: position, fraction: fraction)
        guard publish else { return }
        reloadLibrary()
        if let updated = books.first(where: { $0.id == book.id }) { cloud.push(updated) }
    }

    // MARK: - Downloads

    /// The one way a chapter download starts.
    ///
    /// Screens call this instead of `downloader.start` so the network policy is
    /// checked in exactly one place: a download of a whole book is the only thing
    /// this app does that can spend a lot of data with nobody watching, and under
    /// the Wi-Fi-only policy a metered connection asks before it does.
    func requestDownload(book: Book, rule: SiteRule, chapters: [Chapter]) {
        // A new run gets a new decision — consent for the previous one says
        // nothing about this one.
        meteredConsent = false
        request(.start(book: book, rule: rule, chapters: chapters))
    }

    /// Resuming is a start as far as the data plan is concerned: the run may have
    /// been paused precisely because the connection changed.
    func requestResume() {
        request(.resume)
    }

    func confirmMeteredDownload() {
        guard let prompt = meteredPrompt else { return }
        meteredPrompt = nil
        // Covers the rest of this run, so a queue the user just okayed is not
        // stopped again by the very connection they approved. The setting itself
        // is untouched and the next run asks again.
        meteredConsent = true
        perform(prompt.work)
    }

    func cancelMeteredDownload() {
        meteredPrompt = nil
    }

    private func request(_ work: MeteredDownloadRequest.Work) {
        if !meteredConsent, downloadSettings.network.needsConfirmation(on: monitor.connection) {
            meteredPrompt = MeteredDownloadRequest(work: work)
        } else {
            perform(work)
        }
    }

    private func perform(_ work: MeteredDownloadRequest.Work) {
        switch work {
        case .start(let book, let rule, let chapters):
            downloader.start(book: book, rule: rule, chapters: chapters)
        case .resume:
            downloader.resume()
        }
    }

    // MARK: - Leaving and returning

    /// The fetcher's WKWebView stops dead the moment the process is suspended, so
    /// a download running when the app goes away simply stalls — and it stalled
    /// *silently*, which is indistinguishable from a bug. This is that hole.
    ///
    /// iOS grants roughly thirty seconds of background time: enough for the
    /// chapter already on the wire, nowhere near enough for the queue. So the
    /// queue finishes that one chapter, then pauses with a reason, and the
    /// assertion is released the moment it comes to rest rather than being held
    /// for the full grace period.
    ///
    /// What is left over is handed to `BGTaskScheduler`, which is the only way the
    /// rest of a long book can arrive without the app being on screen.
    func enterBackground() {
        guard downloader.isBusy else { return }
        resumeWhenActive = true
        let reason = String(localized: "downloads.paused.background")
        backgroundAssertion = UIApplication.shared.beginBackgroundTask(withName: "FinishChapter") {
            // Out of time. Stop now, saved or not: the alternative is iOS killing
            // the process, which teaches the user nothing.
            Task { @MainActor [weak self] in
                self?.downloader.pause(reason: reason)
                self?.endBackgroundAssertion()
            }
        }
        downloader.stopAfterCurrentChapter(reason: reason) { [weak self] in
            guard let self else { return }
            self.endBackgroundAssertion()
            // Asked for here, and only here, because this is the first moment the
            // answer is known: the chapter that was on the wire may have been the
            // last one. It is also the only place that knows the queue was stopped
            // *by the app leaving* — a queue the user paused themselves must not be
            // restarted behind their back.
            self.backgroundDownloads.scheduleIfNeeded()
        }
    }

    /// Coming back continues what going away stopped.
    ///
    /// Through `requestResume` rather than straight to the queue: the connection
    /// may well have changed while the app was away, which is precisely when the
    /// Wi-Fi-only check earns its keep.
    func becomeActive() {
        guard resumeWhenActive else { return }
        resumeWhenActive = false
        requestResume()
    }

    /// Ending an assertion twice traps, and either the drain callback or the
    /// expiration handler can get here first.
    private func endBackgroundAssertion() {
        guard backgroundAssertion != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundAssertion)
        backgroundAssertion = .invalid
    }

    /// One entry point for a path report, because two separate things wait on it.
    ///
    /// The restored queue goes first: at launch there is no report yet, so the
    /// decision about whether a queue read off disk may run is still outstanding,
    /// and it is the one this call can settle. The policy check that follows only
    /// ever *stops* a queue, so it cannot be starved by going second.
    private func networkChanged() {
        queueRestorer.connectionChanged()
        enforceNetworkPolicy()
    }

    /// Walking out of the house mid-download must not keep spending data under a
    /// Wi-Fi-only policy — the setting would be a promise the app breaks the
    /// moment the user stops looking.
    ///
    /// Pausing rather than cancelling: the queue keeps its remaining work, and
    /// the resume button asks about cellular the same way a fresh start does.
    private func enforceNetworkPolicy() {
        guard downloader.isBusy, !meteredConsent,
              downloadSettings.network.needsConfirmation(on: monitor.connection)
        else { return }
        downloader.pause(reason: String(localized: "downloads.cellular.paused"))
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

/// A download waiting for the user to okay cellular data, carrying the work it
/// will do once they say yes.
///
/// The work travels with the request rather than being re-derived on confirm: the
/// screen that queued it may be gone by then, and "which chapters did they pick"
/// is not something the alert can reconstruct.
struct MeteredDownloadRequest: Identifiable {
    enum Work {
        case start(book: Book, rule: SiteRule, chapters: [Chapter])
        case resume
    }

    let id = UUID()
    let work: Work
}
