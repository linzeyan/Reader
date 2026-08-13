import Foundation

/// The pending download queue, as it sits on disk.
///
/// Chapter *ids* rather than whole chapter rows: the catalog in the database is
/// the truth for a chapter's title, URL and position, and one the site has since
/// removed must disappear from the queue rather than be resurrected out of a
/// stale copy. What this file carries is the one thing nothing else knows — which
/// chapters the user asked for, and in what order.
///
/// What it deliberately does *not* carry is consent to spend cellular data. That
/// consent belongs to the run it was given for (see `AppEnvironment.meteredConsent`),
/// so a file remembering it would turn one "download anyway" into a standing
/// permission that outlives every process that could have asked again.
struct PersistedDownloadQueue: Codable, Equatable {
    /// Bumped when the shape changes. A version this build does not know is
    /// treated exactly like a corrupt file — thrown away — because a queue
    /// guessed out of a format we cannot read would fetch the wrong chapters,
    /// and the worst a clean drop costs is one tap on "download" again.
    static let currentVersion = 1

    var version: Int
    var bookId: String
    /// Site chapter ids, in queue order.
    var siteChapterIds: [String]

    init(bookId: String, siteChapterIds: [String], version: Int = currentVersion) {
        self.version = version
        self.bookId = bookId
        self.siteChapterIds = siteChapterIds
    }
}

/// The one file the pending queue lives in.
///
/// A file rather than a table: this is not library data, it is a single small
/// value rewritten whole and thrown away as soon as it is spent, and giving it a
/// schema would buy a permanent migration obligation for something temporary.
///
/// In Application Support, not Caches or the temporary directory. The system
/// empties both of those whenever it wants space — and a queue iOS deletes
/// behind the user's back is precisely the bug this type exists to fix.
struct DownloadQueueStore {
    /// What was on disk.
    enum Stored: Equatable {
        /// Nothing queued. By far the common case, and not a failure.
        case empty
        case queue(PersistedDownloadQueue)
        /// Present, but not something this build can read. Already deleted by the
        /// time this is returned: half a queue recovered from a file we do not
        /// understand would download the wrong thing, silently.
        case unreadable
    }

    let url: URL
    private let fileManager: FileManager

    init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    static func makeShared(fileManager: FileManager = .default) throws -> DownloadQueueStore {
        let base = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        return DownloadQueueStore(
            url: base.appendingPathComponent("DownloadQueue.json"), fileManager: fileManager
        )
    }

    func load() -> Stored {
        guard let data = try? Data(contentsOf: url) else { return .empty }
        guard let queue = try? JSONDecoder().decode(PersistedDownloadQueue.self, from: data),
              queue.version == PersistedDownloadQueue.currentVersion
        else {
            clear()
            return .unreadable
        }
        return .queue(queue)
    }

    /// Mirrors the queue.
    ///
    /// Atomic, so the file is either the previous queue or the new one and never a
    /// truncated mixture. Not fsynced, though: the chapters already written by
    /// `DownloadStore` are the truth for what is finished, so the worst a write
    /// lost to a power cut costs is reading back a queue a few chapters out of
    /// date — which the restore filters for free.
    func save(bookId: String, siteChapterIds: [String]) {
        guard let data = try? JSONEncoder().encode(
            PersistedDownloadQueue(bookId: bookId, siteChapterIds: siteChapterIds)
        ) else { return }
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    func clear() {
        try? fileManager.removeItem(at: url)
    }
}

/// Brings a queue that outlived its process back to life — or throws it away.
///
/// Separate from `DownloadManager` because rebuilding a queue needs three things
/// the queue has no business knowing: the catalog its ids point into, the site
/// rule to fetch with, and the network policy that decides whether a download
/// nobody asked for during *this* launch may start at all.
@MainActor
final class DownloadQueueRestorer {
    private let store: DownloadQueueStore
    private let downloader: DownloadManager
    private let repo: LibraryRepo
    private let settings: DownloadSettings
    /// Where a dropped queue is reported. The same record a background window
    /// writes, rather than a second channel: "the download did not happen and
    /// here is why" is one question, and the settings screen is already where a
    /// user goes to ask it.
    private let record: BackgroundDownloads
    /// Closures rather than the stores behind them, for the reason
    /// `BackgroundDownloads` takes its connection that way: a test has to be able
    /// to pin both, and a `SiteStore` can only answer by reading real rule files.
    private let rule: @MainActor (String) -> SiteRule?
    private let connection: @MainActor () -> NetworkMonitor.Connection

    /// Set while a restored queue is still waiting to be told whether it may run.
    private var awaitingConnection = false

    init(
        store: DownloadQueueStore,
        downloader: DownloadManager,
        repo: LibraryRepo,
        settings: DownloadSettings,
        record: BackgroundDownloads,
        rule: @escaping @MainActor (String) -> SiteRule?,
        connection: @escaping @MainActor () -> NetworkMonitor.Connection
    ) {
        self.store = store
        self.downloader = downloader
        self.repo = repo
        self.settings = settings
        self.record = record
        self.rule = rule
        self.connection = connection
    }

    /// Reads the queue back and installs whatever of it is still real. Called
    /// once, at launch.
    func restore() {
        switch store.load() {
        case .empty:
            return
        case .unreadable:
            // Loud rather than repaired. The user loses one "download" tap; a
            // queue pieced together from a file this build cannot parse would
            // cost them the wrong chapters, and they would never know why.
            record.recordQueueLost()
        case .queue(let queue):
            install(queue)
        }
    }

    /// Re-offers the launch decision whenever the connection changes. A no-op
    /// once that decision has been made.
    func connectionChanged() {
        decide()
    }

    private func install(_ queue: PersistedDownloadQueue) {
        // A book the user has since deleted, or a source whose rule has been
        // removed, leaves nothing to fetch with. Dropped whole rather than
        // half-installed.
        guard let book = (try? repo.book(id: queue.bookId)) ?? nil,
              let rule = rule(book.siteId)
        else {
            store.clear()
            return
        }
        let catalog = (try? repo.chapters(bookId: book.id)) ?? []
        let byId = Dictionary(
            catalog.map { ($0.siteChapterId, $0) }, uniquingKeysWith: { first, _ in first }
        )
        // Two kinds of entry are dropped here, and neither may hold up the ones
        // behind it: a chapter the site has removed since the queue was written,
        // and one that has been fetched since. The index's `downloadedAt` — which
        // `DownloadStore` stamps in the same breath as it writes the file — is the
        // truth for the second, which is what lets the queue file be a few
        // chapters out of date without costing a single repeated request.
        let chapters = queue.siteChapterIds.compactMap { byId[$0] }.filter { !$0.isDownloaded }
        guard !chapters.isEmpty else {
            store.clear()
            return
        }
        downloader.restore(book: book, rule: rule, chapters: chapters)
        awaitingConnection = true
        decide()
    }

    /// The policy check a restored queue has to pass before one request goes out.
    ///
    /// Re-run from scratch rather than inherited: the consent that started this
    /// queue was given for that run, in a process that is gone, and the
    /// connection has had a whole app lifetime to change since.
    ///
    /// `allowsUnattendedDownload` — the background rule — rather than the
    /// foreground's `needsConfirmation`, and the asymmetry is the point. Nobody
    /// asked for a download during this launch, so an unclassified connection is
    /// no more evidence of Wi-Fi here than it is at 3am. Which is also why the
    /// decision waits for the first path report rather than resolving `.unknown`:
    /// at the moment the app starts, `.unknown` is all there is.
    private func decide() {
        guard awaitingConnection else { return }
        let connection = connection()
        guard connection != .unknown else { return }
        awaitingConnection = false
        // A queue the user has already dealt with by hand in the first moments
        // after launch — resumed, cancelled, or walked into a challenge — is
        // theirs now, and this must not reach over their shoulder.
        guard downloader.canResume, downloader.pendingChallenge == nil else { return }
        guard settings.network.allowsUnattendedDownload(on: connection) else {
            // A queue that comes back and then sits there has to say why, or it
            // reads as the download having failed. Only the metered case gets a
            // message, because it is the only one the user can act on — one tap
            // on resume, which asks about cellular the way a fresh start does.
            if settings.network.needsConfirmation(on: connection) {
                downloader.pause(reason: String(localized: "downloads.cellular.paused"))
            }
            return
        }
        downloader.resume()
    }
}
