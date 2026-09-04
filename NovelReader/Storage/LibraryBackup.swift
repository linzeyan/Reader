import Foundation

/// Everything of the reader's own, in one file they can keep.
///
/// The line this format is drawn along is *what this app cannot fetch again*. A catalog,
/// a chapter's text, a comic's pages, a cover — all of it comes back from the source that
/// published it, so none of it is in here, and leaving it out is what keeps an entire
/// library inside a file small enough to mail to yourself. What does not come back is the
/// shelf itself, where the reader got to in each book, the passages they marked, the
/// sources they installed by hand, and the way they set the app up.
///
/// JSON rather than an archive, for the same reason it is small: at this size the file is
/// worth being able to read. Someone can open it to check what they are about to hand
/// over, and lift one book's marks out of it by hand if that is all they need.
///
/// This is **not** a second iCloud sync, and the difference matters. `CloudSync`
/// deliberately refuses to carry marks between devices, because a paragraph index means
/// what the rule *on that device* made of the chapter, and a highlight that lands on the
/// wrong sentence is drawn over text nobody chose. A backup is the other case: the reader
/// asked for this file, and asked for it back, usually onto the same library it left. The
/// marks travel because losing them is the failure being prevented — and every one of
/// them carries the words it was made from, so a mark that does land short is still
/// findable in the marks list rather than lost.
struct LibraryBackup: Codable {
    /// Bumped only when an older build could no longer make sense of the file. Every
    /// field added since is optional, so a backup written by a newer build still restores
    /// what an older one understands rather than being refused whole.
    static let currentVersion = 1

    var version: Int
    var createdAt: Date
    var books: [BookRecord]
    /// The sources installed by hand. They are a file the reader found and imported —
    /// this app ships with none — so a device restored without them has a shelf full of
    /// books it cannot refresh or download from.
    var rules: [SiteRule]
    var settings: Settings?

    // MARK: - One book

    /// A book as it travels, with the marks made in it.
    ///
    /// Deliberately not `Book`: that row carries `catalogUpdatedAt`, which says when *this
    /// device* last read the source's index. Restoring it would tell a fresh install its
    /// empty catalog is current, and the reader would open a book with no chapters in it
    /// and nothing scheduled to fetch them. Absent, every restored book is stale, which is
    /// exactly what it is — and staleness is already the signal that fetches a catalog.
    struct BookRecord: Codable {
        var siteId: String
        var siteBookId: String
        var kind: SiteRule.Kind
        var title: String
        var displayName: String?
        var author: String?
        var coverURL: String?
        var addedAt: Date
        var updatedAt: Date
        /// Where the reader stopped, and how far into that chapter it sat.
        var position: ReadingPosition?
        var fraction: Double?
        /// When they were last in this book — the reading history, which is nothing more
        /// than this column ordered.
        var lastReadAt: Date?
        var bookmarks: [ReadingBookmark]
        var highlights: [TextHighlight]

        var id: String { Book.makeId(siteId: siteId, siteBookId: siteBookId) }

        /// Whether this describes a book that exists only as a file on one device.
        var isLocal: Bool { siteId == Book.localSiteId }
    }

    // MARK: - What a restore came to

    /// Counted rather than described, because the reader is owed an answer to "did that
    /// work" and the numbers are the only honest one: a restore onto a library that
    /// already holds most of it legitimately changes almost nothing.
    struct Outcome: Equatable {
        var books = 0
        /// Bookmarks and highlights together. They are one idea to the reader — what I
        /// left in this book — and the marks screen already shows them under one title.
        var marks = 0
        var rules = 0
        /// Imported books whose file is not on this device, so nothing was re-created.
        /// See `restore` for why they are skipped rather than resurrected as empty rows.
        var skippedImports = 0
    }

    // MARK: - Capture

    /// Main-actor because the installed sources are: `SiteStore` is observable state the
    /// settings screen draws from, and both halves of this file read it.
    @MainActor
    static func capture(
        repo: LibraryRepo, sites: SiteStore, settings: Settings.Targets, now: Date = .now
    ) throws -> LibraryBackup {
        let books = try repo.allBooks().map { book in
            BookRecord(
                siteId: book.siteId, siteBookId: book.siteBookId, kind: book.kind,
                title: book.title, displayName: book.displayName, author: book.author,
                coverURL: book.coverURL, addedAt: book.addedAt, updatedAt: book.updatedAt,
                position: book.readingPosition, fraction: book.lastReadFraction,
                lastReadAt: book.lastReadAt,
                bookmarks: try repo.readingBookmarks(bookId: book.id),
                highlights: try repo.highlights(bookId: book.id)
            )
        }
        return LibraryBackup(
            version: currentVersion, createdAt: now, books: books, rules: sites.rules,
            settings: Settings(capturing: settings)
        )
    }

    // MARK: - Restore

    /// Merges this file into the library, and says what changed.
    ///
    /// A merge, never a replace. The reader restoring a backup is putting something back,
    /// and a restore that first emptied the shelf would make "I picked the wrong file" an
    /// unrecoverable mistake — while merging the wrong file only leaves rows to delete.
    ///
    /// A book already here keeps its own row unless the file's is newer, which is the rule
    /// `CloudSync` merges on, spelled the same way: whole-record last-writer-wins on
    /// `updatedAt`. Marks are merged regardless of which side won, because they are not
    /// part of that record — a book read further on this device is still a book whose
    /// highlights only exist in the file.
    ///
    /// Books imported from a file are described in the backup but never re-created from
    /// it. Their text is not in here and cannot be fetched from anywhere, so restoring the
    /// row alone would put a book on the shelf that opens onto nothing. If the reader
    /// imports the same file again its id comes back identical — the id *is* a hash of the
    /// file's contents — so restoring this backup a second time then lands the marks where
    /// they belong. That is why they are counted and reported rather than dropped in
    /// silence.
    @MainActor
    func restore(
        into repo: LibraryRepo, sites: SiteStore, settings targets: Settings.Targets
    ) throws -> Outcome {
        var outcome = Outcome()
        let existing = Dictionary(uniqueKeysWithValues: try repo.allBooks().map { ($0.id, $0) })

        for record in books {
            let id = record.id
            let local = existing[id]
            if record.isLocal, local == nil {
                outcome.skippedImports += 1
                continue
            }
            if local == nil || local!.updatedAt < record.updatedAt {
                try repo.bookmark(
                    siteId: record.siteId, siteBookId: record.siteBookId, kind: record.kind,
                    title: record.title, author: record.author, coverURL: record.coverURL,
                    now: record.updatedAt
                )
                try repo.rename(bookId: id, to: record.displayName, now: record.updatedAt)
                if let position = record.position {
                    // Stamped with when the reading happened, not with now: the history is
                    // this column ordered, and a restore that stamped everything with the
                    // present would report a night spent reading forty books at once.
                    try repo.updateProgress(
                        bookId: id, position: position, fraction: record.fraction,
                        now: record.lastReadAt ?? record.updatedAt
                    )
                }
                outcome.books += 1
            }
            outcome.marks += try merge(record, into: repo)
        }

        for rule in rules where sites.rule(id: rule.id) == nil {
            // One malformed rule must not take the restore down with it: the shelf, the
            // positions and the marks are what the reader came for, and a source they can
            // re-import by hand is the smallest loss in this file.
            guard let data = try? JSONEncoder().encode(rule),
                  (try? sites.importRule(data: data)) != nil
            else { continue }
            outcome.rules += 1
        }

        settings?.apply(to: targets)
        return outcome
    }

    /// Adds the marks this device does not have, and counts only those.
    ///
    /// Both `add` calls are idempotent — a mark's id is derived from the passage it
    /// covers, so restoring the same file twice cannot double anything — which is exactly
    /// why the ids already here have to be read first: without them every restore would
    /// report the whole file as new.
    private func merge(_ record: BookRecord, into repo: LibraryRepo) throws -> Int {
        var added = 0
        let knownBookmarks = Set(try repo.readingBookmarks(bookId: record.id).map(\.id))
        for bookmark in record.bookmarks where !knownBookmarks.contains(bookmark.id) {
            try repo.addReadingBookmark(
                bookId: record.id, position: bookmark.position, excerpt: bookmark.excerpt,
                now: bookmark.createdAt
            )
            added += 1
        }
        let knownHighlights = Set(try repo.highlights(bookId: record.id).map(\.id))
        for highlight in record.highlights where !knownHighlights.contains(highlight.id) {
            try repo.addHighlight(
                bookId: record.id, siteChapterId: highlight.siteChapterId,
                selection: TextSelection(
                    start: highlight.start, end: highlight.end, text: highlight.excerpt
                ),
                now: highlight.createdAt
            )
            added += 1
        }
        return added
    }
}

// MARK: - Settings

extension LibraryBackup {
    /// The app as the reader set it up.
    ///
    /// Held as raw values rather than as the enums they came from, because that is what
    /// survives being restored into a build that has since renamed a case: an unreadable
    /// value is dropped by the same `init(rawValue:)` the settings already use on launch,
    /// leaving that one preference at its default instead of failing the file. Every field
    /// is optional for the same reason in the other direction — a backup written before a
    /// setting existed simply says nothing about it.
    ///
    /// Applied to the live objects rather than written into `UserDefaults` behind them.
    /// Each settings class reads its defaults once, in `init`, and holds the values; a
    /// write underneath would take effect at the next launch and look, until then, as
    /// though the restore had missed them.
    struct Settings: Codable {
        /// The four objects a restore writes through. Passed in rather than reached for,
        /// so a test can restore into its own settings without touching the ones the
        /// running app is reading from — `ReaderSettings` is a shared singleton.
        struct Targets {
            let reader: ReaderSettings
            let library: LibrarySettings
            let downloads: DownloadSettings
            let feeds: FeedRetentionSettings
        }

        var readerMode: String?
        var fontSize: Double?
        var lineSpacing: Double?
        var paragraphSpacing: Double?
        var theme: String?
        var fontName: String?
        var keepScreenOn: Bool?
        var tapToTurnPage: Bool?
        var librarySort: String?
        var groupBySource: Bool?
        var onlyWithNewChapters: Bool?
        var home: String?
        var defaultMediaMode: String?
        var recentReadingCount: Int?
        var downloadNetwork: String?
        var feedKeep: Int?
        var feedGrace: Int?
        var feedUnread: Int?

        init(capturing targets: Targets) {
            readerMode = targets.reader.mode.rawValue
            fontSize = targets.reader.fontSize
            lineSpacing = targets.reader.lineSpacing
            paragraphSpacing = targets.reader.paragraphSpacing
            theme = targets.reader.theme.rawValue
            fontName = targets.reader.fontName
            keepScreenOn = targets.reader.keepScreenOn
            tapToTurnPage = targets.reader.tapToTurnPage
            librarySort = targets.library.sort.rawValue
            groupBySource = targets.library.groupBySource
            onlyWithNewChapters = targets.library.onlyWithNewChapters
            home = targets.library.home.rawValue
            defaultMediaMode = targets.library.defaultMediaMode.rawValue
            recentReadingCount = targets.library.recentReadingCount
            downloadNetwork = targets.downloads.network.rawValue
            feedKeep = targets.feeds.keep.rawValue
            feedGrace = targets.feeds.grace.rawValue
            feedUnread = targets.feeds.unread.rawValue
        }

        func apply(to targets: Targets) {
            if let value = readerMode.flatMap(ReaderSettings.Mode.init(rawValue:)) {
                targets.reader.mode = value
            }
            if let fontSize { targets.reader.fontSize = fontSize }
            if let lineSpacing { targets.reader.lineSpacing = lineSpacing }
            if let paragraphSpacing { targets.reader.paragraphSpacing = paragraphSpacing }
            if let value = theme.flatMap(ReaderSettings.Theme.init(rawValue:)) {
                targets.reader.theme = value
            }
            // Assigned even when absent, unlike everything around it: nil is this one's
            // real value — the system face — and skipping it would make a backup taken
            // with no chosen font unable to put a device back the way it was.
            targets.reader.fontName = fontName
            if let keepScreenOn { targets.reader.keepScreenOn = keepScreenOn }
            if let tapToTurnPage { targets.reader.tapToTurnPage = tapToTurnPage }
            if let value = librarySort.flatMap(LibrarySort.init(rawValue:)) {
                targets.library.sort = value
            }
            if let groupBySource { targets.library.groupBySource = groupBySource }
            if let onlyWithNewChapters {
                targets.library.onlyWithNewChapters = onlyWithNewChapters
            }
            if let value = home.flatMap(HomeScreen.init(rawValue:)) {
                targets.library.home = value
            }
            if let value = defaultMediaMode.flatMap(MediaMode.init(rawValue:)) {
                targets.library.defaultMediaMode = value
            }
            // The setter clamps, so a number from a hand-edited file cannot become a SQL
            // limit of its own choosing.
            if let recentReadingCount { targets.library.recentReadingCount = recentReadingCount }
            if let value = downloadNetwork.flatMap(DownloadSettings.NetworkPolicy.init(rawValue:)) {
                targets.downloads.network = value
            }
            if let value = feedKeep.flatMap(FeedRetentionSettings.Keep.init(rawValue:)) {
                targets.feeds.keep = value
            }
            if let value = feedGrace.flatMap(FeedRetentionSettings.Grace.init(rawValue:)) {
                targets.feeds.grace = value
            }
            if let value = feedUnread.flatMap(FeedRetentionSettings.UnreadRetention.init(rawValue:)) {
                targets.feeds.unread = value
            }
        }
    }
}

// MARK: - The file itself

extension LibraryBackup {
    /// Sorted keys and readable dates, because this file's second job is being readable.
    /// ISO 8601 rather than a number of seconds for the same reason.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    enum Failure: LocalizedError, Equatable {
        /// A file this build cannot read, as opposed to one it can read parts of.
        case unsupportedVersion(Int)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion:
                return String(localized: "backup.error.version")
            case .unreadable:
                return String(localized: "backup.error.unreadable")
            }
        }
    }

    static func read(_ data: Data) throws -> LibraryBackup {
        guard let backup = try? decoder().decode(LibraryBackup.self, from: data) else {
            throw Failure.unreadable
        }
        // Newer is refused, older is not: this is version 1, and there is nothing behind
        // it. A file from a build that has since changed the shape would be restored
        // wrongly rather than not at all, which is the one outcome worth a refusal.
        guard backup.version <= currentVersion else {
            throw Failure.unsupportedVersion(backup.version)
        }
        return backup
    }
}
