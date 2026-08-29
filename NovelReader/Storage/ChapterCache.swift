import Foundation

/// What the app keeps of a chapter it read online, so reaching it again is free.
///
/// Deliberately the same shape as the downloads, and for most of it the same code: a
/// `ChapterFileStore` rooted in the caches directory instead of application support.
/// "How big is this book" and "delete this book" are the same two questions in both, and
/// the store already answers them for a subtree without knowing what is in it.
///
/// What differs is who decides. A download is something the reader asked for, and only
/// the reader takes it away; this appears by itself, so it has to make room for itself —
/// a ceiling they set, and whole chapters dropped least-recently-read first to stay under
/// it. Whole chapters, because half a comic chapter is a page the reader scrolls into and
/// waits for, and the space that saved was one page's worth.
///
/// In `Library/Caches` for two reasons past tidiness: iOS may reclaim the directory when
/// the disk runs out, which is the right answer for bytes that can be fetched again, and
/// it is not backed up — nobody's iCloud should carry a copy of a comic they read once.
///
/// Comic pages are written with no file extension, unlike a download's. A downloaded
/// folder is something a person might open, and `012.webp` tells them what is in it; this
/// one is not, and a fixed name is a page that can be found by building a path instead of
/// listing a directory. It also keeps the two apart on sight: nothing in here is a
/// download, however much the tree looks like one.
@MainActor
@Observable
final class ChapterCache {
    /// The default ceiling: a gibibyte, which is a few dozen chapters of comic and more
    /// novel than anyone reads. Small enough to go unnoticed on a phone that is mostly
    /// photos, large enough that an evening's reading fits inside it.
    static let defaultLimit: Int64 = 1 << 30

    /// What the ceiling may be set to. No "unlimited", at the reader's own call: a cache
    /// with no ceiling is a download nobody agreed to, and this one fills at fifteen
    /// megabytes a chapter. Trimmed to what the device can spare — see `limits(free:)`.
    static let limitChoices: [Int64] = [
        256 << 20, 512 << 20, 1 << 30, 2 << 30, 5 << 30, 10 << 30, 20 << 30,
    ]

    /// How much the cache may hold. Lowering it takes effect at once, because a setting
    /// that only applies to future reading is a setting that did not do what it said.
    var limit: Int64 {
        didSet {
            guard limit != oldValue else { return }
            defaults.set(limit, forKey: Keys.limit)
            queue { await self.evictIfOver() }
        }
    }

    /// Bytes held, as of the last count. An estimate between counts: writes add their own
    /// size to it, and only a walk of the tree sets it to the truth. Nothing is decided on
    /// the estimate alone — eviction re-counts before it deletes anything — so the cost of
    /// it drifting is a number on the settings screen being a page or two out.
    ///
    /// `nil` until something asks, so a launch that opens no book walks nothing.
    private(set) var used: Int64?

    let files: ChapterFileStore
    private let defaults: UserDefaults
    /// Everything that changes what is on the disk, in the order it was asked for.
    ///
    /// Serial because the accounting demands it: a write adds its own size to the
    /// estimate, and an eviction counts what is really there and deletes against that
    /// count. Interleaved, an eviction would be deleting against a total taken before
    /// half the writes landed. Reading a comic queues one of these a second, so this is
    /// not a theoretical race.
    ///
    /// Exposed because a fire-and-forget write leaves a test with nothing to wait for.
    @ObservationIgnored private(set) var work: Task<Void, Never>?

    init(files: ChapterFileStore, defaults: UserDefaults = .standard) {
        self.files = files
        self.defaults = defaults
        limit = (defaults.object(forKey: Keys.limit) as? NSNumber)?.int64Value
            ?? Self.defaultLimit
    }

    private enum Keys {
        static let limit = "cache.limit"
    }

    /// Default location: Caches/Chapters.
    static func makeShared(fileManager: FileManager = .default) throws -> ChapterCache {
        let base = try fileManager.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return ChapterCache(
            files: ChapterFileStore(
                root: base.appendingPathComponent("Chapters"), fileManager: fileManager
            )
        )
    }

    // MARK: - Novels

    /// A chapter's text, if this device has read it before.
    ///
    /// Marked as just-used on the way out, which is what makes the eviction order mean
    /// "least recently read" rather than "written longest ago": a book someone is halfway
    /// through and keeps coming back to should outlive one they abandoned in an evening.
    func paragraphs(of book: Book, siteChapterId: String) async -> [String]? {
        let url = files.fileURL(
            siteId: book.siteId, siteBookId: book.siteBookId, siteChapterId: siteChapterId
        )
        // Off the main actor for the same reason `ReaderView.storedParagraphs` is: this
        // lands in the middle of the scroll that asked for it, at the seam between two
        // chapters, and a filesystem hit on the main thread there is a visible stutter.
        return await Task.detached(priority: .userInitiated) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let paragraphs = text.components(separatedBy: "\n").filter { !$0.isEmpty }
            guard !paragraphs.isEmpty else { return nil }
            Self.touch(url)
            return paragraphs
        }.value
    }

    func store(paragraphs: [String], of book: Book, siteChapterId: String) {
        guard !paragraphs.isEmpty else { return }
        let files = self.files
        let siteId = book.siteId
        let siteBookId = book.siteBookId
        write(bytes: paragraphs.reduce(0) { $0 + Int64($1.utf8.count) + 1 }) {
            try files.write(
                paragraphs: paragraphs, siteId: siteId, siteBookId: siteBookId,
                siteChapterId: siteChapterId
            )
        }
    }

    // MARK: - Comics

    /// Where a page is, if this device has read it before.
    ///
    /// Asked by `ComicPageStore` in place of the address it would otherwise fetch, and
    /// what comes back is a file — the same kind of address a downloaded chapter is made
    /// of, taking the same branch. So a cached page costs a disk read, holds no
    /// compressed copy in memory, and needs neither the cookie jar nor the referer,
    /// without a line of the store knowing this exists.
    ///
    /// Asked per page rather than for the chapter at once, on purpose: a page written
    /// during this read is found by the next look, so scrolling back through a chapter is
    /// free even the first time through it. Two syscalls, and only for a page about to be
    /// fetched.
    func page(_ index: Int, of book: Book, siteChapterId: String) -> URL? {
        let directory = files.pageDirectory(
            siteId: book.siteId, siteBookId: book.siteBookId, siteChapterId: siteChapterId
        )
        let url = directory.appendingPathComponent(Self.pageName(index))
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // The chapter, not the page. Fifty files that live and die together, and the one
        // being looked at is what says the whole chapter is in use.
        Self.touch(directory)
        return url
    }

    func store(_ bytes: Data, page index: Int, of book: Book, siteChapterId: String) {
        let directory = files.pageDirectory(
            siteId: book.siteId, siteBookId: book.siteBookId, siteChapterId: siteChapterId
        )
        let url = directory.appendingPathComponent(Self.pageName(index))
        write(bytes: Int64(bytes.count)) {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            // Atomic, so a page half-written when the app is killed is not a page the
            // next read finds and fails to decode.
            try bytes.write(to: url, options: .atomic)
        }
    }

    private static func pageName(_ index: Int) -> String { String(format: "%03d", index) }

    /// Puts something in the cache without the reader waiting for it.
    ///
    /// Nothing is waiting on the answer — what was written is already on screen — so the
    /// write goes off the main actor and only the accounting comes back. A page can be
    /// megabytes, and this is called from the middle of a scroll.
    ///
    /// A write that fails is dropped in silence. A cache that cannot write is a cache
    /// that does not help; it is not a thing to interrupt somebody's reading about.
    private func write(bytes: Int64, _ body: @escaping @Sendable () throws -> Void) {
        queue {
            let written = await Task.detached(priority: .utility) {
                (try? body()) != nil
            }.value
            guard written else { return }
            self.used = (self.used ?? 0) + bytes
            await self.evictIfOver()
        }
    }

    /// Adds to the end of the queue described on `work`.
    private func queue(_ body: @escaping @MainActor () async -> Void) {
        let previous = work
        work = Task {
            await previous?.value
            await body()
        }
    }

    // MARK: - Accounting

    /// Bytes each of these books is holding, for the screen that lists them.
    ///
    /// One walk per book, off the main actor. The screen is opened to find out which book
    /// is eating the disk, so it has to be per book, and a library of a hundred is a
    /// hundred subtree walks — not something to do between two frames.
    func sizes(of books: [Book]) async -> [String: Int64] {
        let files = self.files
        return await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: books.map {
                ($0.id, files.size(of: .book(siteId: $0.siteId, siteBookId: $0.siteBookId)))
            })
        }.value
    }

    /// Recounts from the disk.
    ///
    /// The number has to survive a crash mid-delete and an eviction iOS did on its own
    /// while the app was away, and neither of those tells anybody.
    func measure() async {
        // Behind whatever is queued, so the number shown is of a disk nothing is still
        // being written to.
        await work?.value
        let root = files.root
        let held = await Task.detached(priority: .utility) { Self.held(under: root) }.value
        used = held.reduce(0) { $0 + $1.bytes }
    }

    /// Behind whatever is queued, like every other change to the tree: a page still being
    /// written for a book the reader has just removed would otherwise land after the
    /// delete and put the directory back.
    ///
    /// Leaves `used` reading high until the next count, which is the estimate doing what
    /// it is for — how much this book was holding is a walk of its subtree, and the caller
    /// that cares recounts anyway.
    func clear(_ book: Book) {
        let files = self.files
        let siteId = book.siteId
        let siteBookId = book.siteBookId
        queue { try? files.delete(.book(siteId: siteId, siteBookId: siteBookId)) }
    }

    func clearEverything() {
        let files = self.files
        queue {
            try? files.delete(.everything)
            self.used = 0
        }
    }

    /// The ceilings worth offering on this device.
    ///
    /// Nothing larger than the space there is, because a ceiling the disk cannot reach is
    /// not a choice — but always at least the smallest, so a nearly full phone still has
    /// something to pick, and always whatever is currently set, so a picker cannot open
    /// with no row selected.
    static func limits(free: Int64, current: Int64) -> [Int64] {
        let offered = limitChoices.filter { $0 <= free }
        let list = offered.isEmpty ? [limitChoices[0]] : offered
        return list.contains(current) ? list : (list + [current]).sorted()
    }

    /// How much the device could spare, for building that list.
    ///
    /// `volumeAvailableCapacityForImportantUsage` rather than plain free space: it is what
    /// the system says it would let this app have, with the reserve iOS keeps for itself
    /// already taken off.
    static func freeBytes(fileManager: FileManager = .default) -> Int64 {
        guard let url = try? fileManager.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ), let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ) else { return 0 }
        return values.volumeAvailableCapacityForImportantUsage ?? 0
    }

    // MARK: - Eviction

    /// Drops whole chapters, least recently read first, until the cache is under its
    /// ceiling again.
    ///
    /// Off the main actor, all of it. This is reached from the middle of a scroll — the
    /// page that pushed the cache over its limit was written for a reader who is looking
    /// at it — and a walk of a gibibyte of files is thousands of `stat` calls. On the main
    /// thread that is the stutter this whole feature was meant to remove.
    ///
    /// Counted afresh rather than from the running total: this is the one moment where
    /// being wrong is expensive in both directions, deleting chapters that did not need to
    /// go or believing there is room when there is not.
    private func evictIfOver() async {
        guard (used ?? 0) > limit else { return }
        let root = files.root
        let ceiling = limit
        used = await Task.detached(priority: .utility) {
            Self.prune(root: root, to: ceiling)
        }.value
    }

    /// One cached chapter: a novel chapter's file, a comic chapter's directory of pages.
    private struct Held {
        let url: URL
        let bytes: Int64
        let read: Date
    }

    private nonisolated static func prune(root: URL, to limit: Int64) -> Int64 {
        let held = self.held(under: root)
        var total = held.reduce(0) { $0 + $1.bytes }
        guard total > limit else { return total }
        for chapter in held.sorted(by: { $0.read < $1.read }) {
            guard total > limit else { break }
            guard (try? FileManager.default.removeItem(at: chapter.url)) != nil else { continue }
            total -= chapter.bytes
        }
        return total
    }

    /// Everything in the cache, three levels down — site, book, chapter.
    ///
    /// That layout is `ChapterFileStore`'s, and the only thing about it this needs to
    /// know. Anything else found at that level is counted and can be evicted like a
    /// chapter, which is the right answer for whatever a half-finished write left.
    private nonisolated static func held(under root: URL) -> [Held] {
        let manager = FileManager.default
        let store = ChapterFileStore(root: root, fileManager: manager)
        let children: (URL) -> [URL] = { url in
            (try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        }
        return children(root).flatMap(children).flatMap(children).map { url in
            let read = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            return Held(url: url, bytes: store.size(at: url), read: read ?? .distantPast)
        }
    }

    /// Marks something as just used, which is the only record kept of when it was.
    ///
    /// A modification date rather than an access date: iOS makes no promise to keep access
    /// times current, and a stale one here means throwing away the chapter somebody is
    /// reading.
    private nonisolated static func touch(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: url.path
        )
    }
}
