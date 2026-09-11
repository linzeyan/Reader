import Foundation

/// Mirrors the library into `NSUbiquitousKeyValueStore` when the user opts in.
///
/// KVS rather than CloudKit: the synced payload is bookmarks, custom names and
/// reading positions — a few hundred bytes per book, well inside the 1 MB / 1024
/// key budget — and KVS needs no schema, no container setup and no conflict UI.
///
/// **Chapter text is never synced, and neither is the download index.**
/// `Chapter.downloadedAt` means "a local file exists on *this* device"; copying
/// that flag to a device that has no files would make the reader offer chapters
/// it cannot open. Downloads stay device-local by design.
///
/// **Saved positions (`ReadingBookmark`) and highlights (`TextHighlight`) are not
/// synced either**, for the same class of reason. Both name a paragraph inside a
/// chapter as the site rule on *this* device split it, and rules are installed and
/// derived per device — the same paragraph index under a different build of a rule is a
/// different sentence. A reading position that lands a screen off corrects itself as
/// soon as the reader scrolls; a bookmark that jumps to the wrong sentence is just
/// wrong, with nothing to correct it, and a highlight is worse still — it would come
/// out of the sync drawn over text nobody chose. The key budget says the same thing
/// from the other side: this store is one key per book, and marks per book are
/// unbounded.
///
/// **A subscription's read articles are synced**, which looks like an exception to that
/// last sentence and is not. An article's id comes from the feed document rather than from
/// a rule, so it means the same thing on every device — the objection to bookmarks does not
/// apply — and what travels is the *unread* set, which shrinks as the feed is read and is
/// refused outright past `unreadLimit`. It has to travel at all because it is not a
/// convenience: until `v12.articleRead` this state was the reading position, and the
/// position has always synced.
@MainActor
@Observable
final class CloudSync {
    static let enabledDefaultsKey = "icloud.sync.enabled"
    private static let keyPrefix = "book."

    /// One book as it travels between devices.
    private struct Record: Codable {
        var siteId: String
        var siteBookId: String
        /// What the book is, carried rather than looked up.
        ///
        /// A merge *creates* book rows on the other device, and that device may not have
        /// the rule this book names: rules travel by hand, one file at a time, so the
        /// normal case is a library that syncs before its sources do. A kind looked up
        /// locally would come back nil there, filing a comic under novels and opening it
        /// in the text reader until the day its rule arrives.
        ///
        /// Optional, and absent reads as `.novel`. A record written before comics existed
        /// describes a book that could not have been anything else, so there is nothing
        /// to guess — unlike `position`, where an old shape had to be refused outright.
        var kind: SiteRule.Kind?
        var title: String
        var displayName: String?
        var author: String?
        var coverURL: String?
        var addedAt: Date
        var updatedAt: Date
        /// The reading position, carried as the anchor itself rather than as flat
        /// fields, so the wire format cannot describe a position the app's own model
        /// cannot hold.
        ///
        /// No compatibility path is kept for older shapes of it, and there have been
        /// two: a flat `lastReadChapterIndex` / `lastReadOffset` pair, and an anchor
        /// whose chapter was a catalog index rather than the site's chapter id. A
        /// payload in either shape no longer decodes — the second one fails the whole
        /// record, since a position that is present but unreadable is not a record this
        /// app can apply — so it is skipped, and the book it described is learned about
        /// when its own device next publishes.
        ///
        /// Nothing is lost by that. Every record in this store is a mirror of a local
        /// row, so the device that owns the position re-publishes it in the current
        /// shape on its next page turn, and the merge is last-writer-wins on
        /// `updatedAt`, which a mirror of an unchanged row cannot win. Guessing a
        /// chapter id from a stale index would be worse than waiting: the guess would
        /// be resolved against a catalog this device fetched at a different time.
        var position: ReadingPosition?
        /// How far into that chapter the position sits. Travels with the position it was
        /// measured against, because it cannot be recomputed on arrival: the receiving
        /// device may never have fetched that chapter's text. Absent in records written
        /// before this field existed, which decodes to nil and reads as "which chapter,
        /// and nothing finer" — the same thing a fresh install shows.
        var fraction: Double?
        /// Which of a subscription's articles are still unread, by the id the feed gave
        /// them. Absent for novels and comics, which have no such thing.
        ///
        /// The *unread* set rather than the read one, because it is the smaller of the two
        /// by construction and this store has a byte budget: a subscription anybody reads
        /// holds far more read articles than unread ones, and the payload therefore shrinks
        /// as the thing it describes gets used. See `unreadLimit` for what happens when it
        /// does not.
        var unreadArticles: [String]?
        /// The newest article the sending device's catalog held, which is where its
        /// knowledge stops.
        ///
        /// Load-bearing, and the reason an absent unread id cannot simply be read as
        /// "read": a refresh on the receiving device can easily beat the sync, and without
        /// a cutoff every article that arrived in the meantime would be marked read for
        /// not appearing on a list written before it existed.
        var articlesThrough: Date?
    }

    /// How many unread ids a subscription may publish before its read state stops being
    /// synced at all.
    ///
    /// This store is a megabyte across every book, so an unbounded list is a way to lose
    /// the whole library's sync to one feed nobody reads. The cap is not a compromise on
    /// what gets synced so much as a statement about what is worth syncing: a subscription
    /// sitting on three hundred unread articles is one nobody has read on either device,
    /// and "everything is unread" is already what the receiving device shows.
    private static let unreadLimit = 250

    private(set) var lastSyncedAt: Date?
    private(set) var lastError: String?

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.enabledDefaultsKey)
            if isEnabled { enable() } else { disable() }
        }
    }

    private let repo: LibraryRepo
    private let store: NSUbiquitousKeyValueStore
    private let defaults: UserDefaults
    private var observer: (any NSObjectProtocol)?
    /// Called after a pull changes local rows, so the UI can reload.
    var onRemoteChange: (() -> Void)?

    init(
        repo: LibraryRepo,
        store: NSUbiquitousKeyValueStore = .default,
        defaults: UserDefaults = .standard
    ) {
        self.repo = repo
        self.store = store
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: Self.enabledDefaultsKey)
        // Observing only. The first sync is `startSyncing`, called once the app is on
        // screen: `synchronize` talks to the iCloud daemon and `mergeOnEnable` walks
        // every book in the store and every book in the library, and all of that sat
        // between the launch and the first frame — a reader who never turns iCloud on
        // pays nothing, and one who does was paying it before they could see anything.
        if isEnabled { observe() }
    }

    /// The first sync of the launch, once there is something on screen to sync behind.
    ///
    /// Separate from `init` rather than kicked off by it in a `Task`: a task enqueued
    /// during init runs at the main actor's next opportunity, which can still be
    /// before the first frame is committed. The caller is the one place that knows
    /// the app is up.
    func startSyncing() {
        guard isEnabled else { return }
        sync()
    }

    // MARK: - Lifecycle
    //
    // No `deinit` teardown: the observer is main-actor state and `deinit` is
    // nonisolated, and this object lives as long as the app anyway. Turning the
    // toggle off is the real teardown path.

    /// Turning the toggle on is a user action waiting on an answer, so it syncs
    /// there and then — unlike a launch, which defers to `startSyncing`.
    private func enable() {
        observe()
        sync()
    }

    private func observe() {
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pull() }
        }
    }

    private func sync() {
        store.synchronize()
        mergeOnEnable()
    }

    private func disable() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// First sync after opting in is a union, not a replace: both devices may
    /// already hold bookmarks the other has never seen, and silently dropping
    /// either side's library is unrecoverable for the user.
    private func mergeOnEnable() {
        pull()
        pushAll()
        lastSyncedAt = Date()
    }

    // MARK: - Push

    func pushAll() {
        guard isEnabled else { return }
        do {
            for book in try repo.allBooks() { write(book) }
            store.synchronize()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func push(_ book: Book) {
        guard isEnabled else { return }
        write(book)
        // No `synchronize()` here, unlike the bulk paths: this fires at every
        // chapter turn, and the round trip to the ubiquity daemon is not what
        // uploads the value — the system coalesces and sends KVS writes on its
        // own schedule. Forcing it per turn was pure battery.
    }

    func removed(bookId: String) {
        guard isEnabled else { return }
        store.removeObject(forKey: Self.keyPrefix + bookId)
        store.synchronize()
    }

    /// Books imported from a file on the device are skipped.
    ///
    /// What travels through here is a bookmark, a custom name and a reading
    /// position — none of which mean anything on a device that does not have the
    /// file. Syncing one would put a book in the other device's library that it
    /// can never open. This is the same reason the download index stays local:
    /// a record whose text only exists on one device must not claim otherwise.
    private func write(_ book: Book) {
        guard !book.isLocal else { return }
        var record = Record(
            siteId: book.siteId, siteBookId: book.siteBookId, kind: book.kind, title: book.title,
            displayName: book.displayName, author: book.author, coverURL: book.coverURL,
            addedAt: book.addedAt, updatedAt: book.updatedAt,
            position: book.readingPosition, fraction: book.lastReadFraction
        )
        if book.kind == .feed { attachReadState(to: &record, bookId: book.id) }
        guard let data = try? JSONEncoder().encode(record) else { return }
        store.set(data, forKey: Self.keyPrefix + book.id)
    }

    /// Puts a subscription's read state on the record, unless there is too much of it.
    ///
    /// Both fields or neither: an unread list without the cutoff it was written against
    /// cannot be applied safely, so a feed over the cap publishes nothing rather than half
    /// of it.
    private func attachReadState(to record: inout Record, bookId: String) {
        guard let unread = try? repo.unreadArticleIds(bookId: bookId),
              unread.count <= Self.unreadLimit,
              let through = try? repo.newestArticleDate(bookId: bookId)
        else { return }
        record.unreadArticles = unread
        record.articlesThrough = through
    }

    /// Fills in the read state another device published for a subscription whose articles
    /// this one has only just fetched.
    ///
    /// The case `pull` cannot cover on its own: setting a new device up, the book rows
    /// arrive from iCloud before there is a single article to apply them to, and by the
    /// time the first refresh brings the articles in, the record has already been merged
    /// and will not be looked at again — last-writer-wins says this device's row is as new
    /// as the one in the store.
    ///
    /// Marks read only. It is recovering state the other device already published, not
    /// arbitrating between two devices, so it must not be able to reach forward over an
    /// article somebody has deliberately put back to unread here since.
    func fillInReadState(bookId: String) {
        guard isEnabled,
              let data = store.data(forKey: Self.keyPrefix + bookId),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              let through = record.articlesThrough
        else { return }
        try? repo.applyRemoteReadState(
            bookId: bookId, unread: Set(record.unreadArticles ?? []),
            through: through, monotonic: true
        )
    }

    // MARK: - Pull

    /// Applies remote records that are newer than the local row. Whole-key
    /// last-writer-wins: a book is small enough that field-level merging would
    /// add real complexity for no user-visible benefit.
    func pull() {
        guard isEnabled else { return }
        var changed = false
        do {
            let local = Dictionary(uniqueKeysWithValues: try repo.allBooks().map { ($0.id, $0) })
            for (key, value) in store.dictionaryRepresentation
            where key.hasPrefix(Self.keyPrefix) {
                guard let data = value as? Data,
                      let record = try? JSONDecoder().decode(Record.self, from: data)
                else { continue }
                let id = String(key.dropFirst(Self.keyPrefix.count))
                if let existing = local[id], existing.updatedAt >= record.updatedAt { continue }
                try apply(record, id: id)
                changed = true
            }
        } catch {
            lastError = error.localizedDescription
        }
        lastSyncedAt = Date()
        if changed { onRemoteChange?() }
    }

    private func apply(_ record: Record, id: String) throws {
        try repo.bookmark(
            siteId: record.siteId, siteBookId: record.siteBookId, kind: record.kind ?? .novel,
            title: record.title, author: record.author, coverURL: record.coverURL,
            now: record.updatedAt
        )
        try repo.rename(bookId: id, to: record.displayName, now: record.updatedAt)
        if let position = record.position {
            try repo.updateProgress(
                bookId: id, position: position, fraction: record.fraction, now: record.updatedAt
            )
        }
        // After the bookmark, which may have created the row this points into. Not
        // monotonic: this record won last-writer-wins, so an article it calls unread was
        // put back to unread on the other device more recently than anything here.
        try repo.applyRemoteReadState(
            bookId: id, unread: Set(record.unreadArticles ?? []),
            through: record.articlesThrough, monotonic: false, now: record.updatedAt
        )
    }
}
