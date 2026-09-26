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
/// chapter as the site rule on *this* device split it, and even synced, two devices can
/// hold different builds of a rule for a while — the same paragraph index under a
/// different build of a rule is a different sentence. A reading position that lands a screen off corrects itself as
/// soon as the reader scrolls; a bookmark that jumps to the wrong sentence is just
/// wrong, with nothing to correct it, and a highlight is worse still — it would come
/// out of the sync drawn over text nobody chose. The key budget says the same thing
/// from the other side: this store is one key per book, and marks per book are
/// unbounded.
///
/// **How far each subscription has been read is synced**, as one date: that of the newest
/// article read. Everything published up to it counts as read on the other device — an
/// article skipped past is taken as one the reader is not coming back for — which keeps a
/// subscription's record the size of any book's, where a list of ids grew with the feed.
/// It has to travel at all because it is not a convenience: until `v12.articleRead` this
/// state was the reading position, and the position has always synced.
///
/// **A removal travels as a key of its own**, `removed.<id>` holding when it happened,
/// because a missing `book.` key cannot say it: every device re-publishes its whole
/// library on each launch, so a book taken off one shelf came straight back from the
/// next device to start up. The removal has to outlast those re-publishings to win
/// against them. Last-writer-wins still decides — a book read on another device after it
/// was removed here is kept, on both — with one exception, below `joinedAtDefaultsKey`.
///
/// **Sources travel too**, a `rule.<id>` key each, compared by when they were installed and
/// removed the same way books are. A rule is a document the reader chose to install rather
/// than a fact about this device, so none of the reasons above for keeping things here
/// apply to it.
@MainActor
@Observable
final class CloudSync {
    static let enabledDefaultsKey = "icloud.sync.enabled"
    private static let keyPrefix = "book."
    private static let removedPrefix = "removed."
    private static let rulePrefix = "rule."
    private static let removedRulePrefix = "removedRule."
    /// When this device last turned sync on. Removals older than that do not reach its
    /// shelf: the first sync is a union (see `mergeOnEnable`), and a book this device kept
    /// while it was not syncing is part of what it brings, not something to delete.
    private static let joinedAtDefaultsKey = "icloud.sync.joinedAt"
    /// How long a removal is kept before it is dropped to save the store's key budget.
    // ponytail: a device offline longer than this re-publishes the book and it returns
    // everywhere; a count cap instead of an age would trade that for a size ceiling.
    private static let removalLifetime: TimeInterval = 90 * 24 * 3600
    /// Apple's ceiling on a key, in UTF-16 units. Past it a write raises an exception
    /// instead of failing, which Swift cannot catch.
    private static let keyLimit = 128

    /// One book as it travels between devices.
    private struct Record: Codable {
        var siteId: String
        var siteBookId: String
        /// What the book is, carried rather than looked up.
        ///
        /// A merge *creates* book rows on the other device, and that device may not have
        /// the rule this book names: a rule can arrive after its books, or be one this
        /// build cannot install, or have been removed there. A kind looked up
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
        /// How far a subscription has been read: the publication date of the newest article
        /// read on the sending device. Absent for novels and comics, and for a feed with
        /// nothing read yet.
        ///
        /// That article's date rather than its id, so a device that has not fetched it yet
        /// can still apply it — see `fillInReadState`.
        var readThrough: Date?
    }

    /// One source as it travels: the rule, and when it was installed.
    ///
    /// Without its notes, which are for whoever maintains the rule and run to 20 KB on some
    /// against a megabyte shared with every book; the rule itself is a couple of kilobytes.
    /// The cost is a source page with no notes on the device it arrived at.
    private struct RuleRecord: Codable {
        var updatedAt: Date
        var rule: SiteRule
    }

    private(set) var lastSyncedAt: Date?
    private(set) var lastError: String?

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.enabledDefaultsKey)
            if isEnabled {
                defaults.set(Date(), forKey: Self.joinedAtDefaultsKey)
                enable()
            } else {
                disable()
            }
        }
    }

    private let repo: LibraryRepo
    private let sites: SiteStore
    private let store: NSUbiquitousKeyValueStore
    private let defaults: UserDefaults
    private let trace: TraceLog
    private var observer: (any NSObjectProtocol)?
    /// Called after a pull changes local rows, so the UI can reload.
    var onRemoteChange: (() -> Void)?
    /// Takes a book off this shelf because another device removed it, without telling
    /// the store again. The owner's job rather than this class's: the downloaded files
    /// have to go before the row does, since the row's cascade is what names them.
    var onRemoteRemoval: ((Book) -> Void)?

    init(
        repo: LibraryRepo,
        sites: SiteStore,
        store: NSUbiquitousKeyValueStore = .default,
        defaults: UserDefaults = .standard,
        trace: TraceLog = .makeShared()
    ) {
        self.repo = repo
        self.sites = sites
        self.store = store
        self.defaults = defaults
        self.trace = trace
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
        ) { [weak self] notification in
            let reason = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            MainActor.assumeIsolated {
                // Not a change from another device: a write of this one's did not fit.
                if reason == NSUbiquitousKeyValueStoreQuotaViolationChange {
                    self?.quotaExceeded()
                } else {
                    self?.pull()
                }
            }
        }
    }

    /// Says so where the sync switch is. Nothing else would: the store drops the write
    /// without an error, and the book it carried simply never arrives anywhere else.
    ///
    /// Cleared by the next removal — see `markRemoved`.
    private func quotaExceeded() {
        lastError = String(localized: "settings.icloud.quotaExceeded")
        trace.note("icloud quota exceeded keys=\(store.dictionaryRepresentation.count)")
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
            for rule in sites.rules { write(rule) }
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

    func removed(_ book: Book) {
        guard isEnabled, !book.isLocal else { return }
        markRemoved(Self.keyPrefix + book.id, by: Self.removedPrefix + book.id)
    }

    func push(_ rule: SiteRule) {
        guard isEnabled else { return }
        write(rule)
        store.synchronize()
    }

    func removedRule(id: String) {
        guard isEnabled else { return }
        markRemoved(Self.rulePrefix + id, by: Self.removedRulePrefix + id)
    }

    private func markRemoved(_ key: String, by removal: String) {
        guard fits(removal) else { return }
        // What makes room, so the error that asked for it goes; anything still wrong says so
        // again at the next write or pull.
        lastError = nil
        store.removeObject(forKey: key)
        store.set(Date(), forKey: removal)
        store.synchronize()
    }

    /// Every write comes after a pull has had its chance to remove the thing, so a removal
    /// still on file lost last-writer-wins, or predates this device joining. Only one this
    /// device has seen: removing a key it never had could erase a removal still on its way
    /// here, which is the resurrection that key exists to stop.
    private func put(_ data: Data, forKey key: String, clearing removal: String) {
        guard fits(removal) else { return }
        store.set(data, forKey: key)
        if store.object(forKey: removal) != nil { store.removeObject(forKey: removal) }
    }

    /// Whether a key can be written at all. Checked on the removal key, the longer of the
    /// two a thing is stored under, so one check covers both.
    ///
    /// A subscription's key carries its address, and a long enough address runs past
    /// `keyLimit`. That one does not sync, and the trace says so — by length and kind only,
    /// since the trace may not hold an address.
    // ponytail: skipped, not shortened; hash the id into the key if long addresses show up
    // in traces often enough to matter.
    private func fits(_ key: String) -> Bool {
        guard key.utf16.count > Self.keyLimit else { return true }
        trace.note("icloud key too long len=\(key.utf16.count) kind=\(key.prefix { $0 != "." })")
        return false
    }

    private func write(_ rule: SiteRule) {
        let bare = SiteRule(
            id: rule.id, name: rule.name, host: rule.host, kind: rule.kind, urls: rule.urls,
            idPatterns: rule.idPatterns, search: rule.search, book: rule.book,
            catalog: rule.catalog, chapter: rule.chapter, images: rule.images,
            signIn: rule.signIn, notes: nil
        )
        let record = RuleRecord(
            updatedAt: sites.modificationDate(ofRule: rule.id) ?? Date(), rule: bare
        )
        guard let data = try? JSONEncoder().encode(record) else { return }
        put(data, forKey: Self.rulePrefix + rule.id, clearing: Self.removedRulePrefix + rule.id)
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
        if book.kind == .feed {
            record.readThrough = try? repo.newestReadArticleDate(bookId: book.id)
        }
        guard let data = try? JSONEncoder().encode(record) else { return }
        put(data, forKey: Self.keyPrefix + book.id, clearing: Self.removedPrefix + book.id)
    }

    /// Fills in the read state another device published for a subscription whose articles
    /// this one has only just fetched.
    ///
    /// The case `pull` cannot cover on its own: setting a new device up, the book rows
    /// arrive from iCloud before there is a single article to apply them to, and by the
    /// time the first refresh brings the articles in, the record has already been merged
    /// and will not be looked at again — last-writer-wins says this device's row is as new
    /// as the one in the store.
    func fillInReadState(bookId: String) {
        guard isEnabled,
              let data = store.data(forKey: Self.keyPrefix + bookId),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              let through = record.readThrough
        else { return }
        try? repo.markReadThrough(bookId: bookId, through: through)
    }

    // MARK: - Pull

    /// Applies remote records that are newer than the local copy, and removals that are
    /// newer than it. Whole-key last-writer-wins: a book is small enough that
    /// field-level merging would add real complexity for no user-visible benefit.
    func pull() {
        guard isEnabled else { return }
        var changed = false
        do {
            let entries = store.dictionaryRepresentation
            // Sources first, so a book arriving in the same pull is filed under its
            // source's name rather than the bare id it shows until the source is here.
            let rules = changes(
                in: entries, records: Self.rulePrefix, removals: Self.removedRulePrefix,
                decode: { try? JSONDecoder().decode(RuleRecord.self, from: $0) },
                stamp: \.updatedAt,
                local: Dictionary(uniqueKeysWithValues: sites.rules.compactMap { rule in
                    sites.modificationDate(ofRule: rule.id).map { (rule.id, $0) }
                })
            )
            for id in rules.remove { try? sites.remove(id: id, publish: false) }
            for record in rules.apply.values {
                // One this build refuses to install stays in the store for a device that can.
                _ = try? sites.importRule(
                    data: JSONEncoder().encode(record.rule), syncedAt: record.updatedAt
                )
            }

            let local = Dictionary(uniqueKeysWithValues: try repo.allBooks().map { ($0.id, $0) })
            let books = changes(
                in: entries, records: Self.keyPrefix, removals: Self.removedPrefix,
                decode: { try? JSONDecoder().decode(Record.self, from: $0) },
                stamp: \.updatedAt, local: local.mapValues(\.updatedAt)
            )
            for id in books.remove { if let book = local[id] { onRemoteRemoval?(book) } }
            for (id, record) in books.apply { try apply(record, id: id) }
            // Sources count too: the shelf groups its books under them.
            changed = !(rules.remove.isEmpty && rules.apply.isEmpty
                        && books.remove.isEmpty && books.apply.isEmpty)
        } catch {
            lastError = error.localizedDescription
        }
        lastSyncedAt = Date()
        if changed { onRemoteChange?() }
    }

    /// What the store asks of this device for one kind of thing it holds: the records newer
    /// than the local copy, and the local ids whose removal is newer still.
    ///
    /// Books and sources share it because the hard part is the same for both: a removal
    /// has to outlast the copies other devices keep re-publishing until they hear of it.
    private func changes<Item>(
        in entries: [String: Any], records recordPrefix: String, removals removalPrefix: String,
        decode: (Data) -> Item?, stamp: (Item) -> Date, local: [String: Date]
    ) -> (apply: [String: Item], remove: [String]) {
        var records: [String: Item] = [:]
        var removals: [String: Date] = [:]
        for (key, value) in entries {
            if key.hasPrefix(recordPrefix), let data = value as? Data, let item = decode(data) {
                records[String(key.dropFirst(recordPrefix.count))] = item
            } else if key.hasPrefix(removalPrefix), let removedAt = value as? Date {
                removals[String(key.dropFirst(removalPrefix.count))] = removedAt
            }
        }
        let joinedAt = defaults.object(forKey: Self.joinedAtDefaultsKey) as? Date ?? .distantPast
        var remove: [String] = []
        for (id, removedAt) in removals {
            if removedAt < Date().addingTimeInterval(-Self.removalLifetime) {
                store.removeObject(forKey: removalPrefix + id)
            }
            // Changed somewhere after it was removed: that device's copy wins.
            if let item = records[id], stamp(item) > removedAt { continue }
            // A device that had not heard of the removal yet published its copy again.
            if records.removeValue(forKey: id) != nil {
                store.removeObject(forKey: recordPrefix + id)
            }
            guard let at = local[id], at <= removedAt, removedAt > joinedAt else { continue }
            remove.append(id)
        }
        let apply = records.filter { id, item in local[id].map { $0 < stamp(item) } ?? true }
        return (apply, remove)
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
        // After the bookmark, which may have created the row this points into.
        if let through = record.readThrough {
            try repo.markReadThrough(bookId: id, through: through, now: record.updatedAt)
        }
    }
}
