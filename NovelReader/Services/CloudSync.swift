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
@MainActor
@Observable
final class CloudSync {
    static let enabledDefaultsKey = "icloud.sync.enabled"
    private static let keyPrefix = "book."

    /// One book as it travels between devices.
    private struct Record: Codable {
        var siteId: String
        var siteBookId: String
        var title: String
        var displayName: String?
        var author: String?
        var coverURL: String?
        var addedAt: Date
        var updatedAt: Date
        var lastReadChapterIndex: Int?
        var lastReadOffset: Int?
    }

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
        if isEnabled { enable() }
    }

    // MARK: - Lifecycle
    //
    // No `deinit` teardown: the observer is main-actor state and `deinit` is
    // nonisolated, and this object lives as long as the app anyway. Turning the
    // toggle off is the real teardown path.

    private func enable() {
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pull() }
        }
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
        store.synchronize()
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
        let record = Record(
            siteId: book.siteId, siteBookId: book.siteBookId, title: book.title,
            displayName: book.displayName, author: book.author, coverURL: book.coverURL,
            addedAt: book.addedAt, updatedAt: book.updatedAt,
            lastReadChapterIndex: book.lastReadChapterIndex, lastReadOffset: book.lastReadOffset
        )
        guard let data = try? JSONEncoder().encode(record) else { return }
        store.set(data, forKey: Self.keyPrefix + book.id)
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
            siteId: record.siteId, siteBookId: record.siteBookId,
            title: record.title, author: record.author, coverURL: record.coverURL,
            now: record.updatedAt
        )
        try repo.rename(bookId: id, to: record.displayName, now: record.updatedAt)
        if let index = record.lastReadChapterIndex {
            try repo.updateProgress(
                bookId: id, chapterIndex: index,
                offset: record.lastReadOffset ?? 0, now: record.updatedAt
            )
        }
    }
}
