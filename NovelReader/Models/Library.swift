import Foundation
import GRDB

/// A bookmarked novel.
///
/// `id` is `siteId|siteBookId` rather than an autoincrement row id: the same
/// book bookmarked on two devices must collapse to one row when iCloud merges
/// them, so identity has to be derivable from the source, not from insert order.
// Hashable so a book can be a `NavigationStack` path value.
struct Book: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "book"

    var id: String
    var siteId: String
    var siteBookId: String
    /// Title as published by the site.
    var title: String
    /// User override (requirement 3.2). `nil` means "follow the site".
    var displayName: String?
    var author: String?
    var coverURL: String?
    var addedAt: Date
    /// Bumped on any user edit; drives last-writer-wins during iCloud merges.
    var updatedAt: Date
    /// Reading position: which chapter, and where inside it.
    ///
    /// The chapter is named by the id the site gave it, never by its place in the
    /// catalog: `Chapter.index` is recomputed by every `replaceCatalog`, so a site
    /// inserting a chapter mid-book would slide a stored index onto the following
    /// chapter's text. Reading order is the catalog's to say — see `lastReadIndex(in:)`.
    ///
    /// Three columns rather than one encoded anchor because SQL has to read the
    /// position directly — `LibraryRepo.newChapterCounts` joins it back to the catalog
    /// for the whole library in one grouped query, which a blob would make impossible.
    /// `readingPosition` is the shape the rest of the app works in.
    var lastReadSiteChapterId: String?
    var lastReadParagraph: Int?
    var lastReadCharacterOffset: Int?
    /// How far into that chapter the position sits, 0…1, as `TextAnchor.fraction(in:)`
    /// measured it when the chapter was on screen.
    ///
    /// Stored rather than derived because deriving it needs the chapter's text: the shelf
    /// draws a row per book and holds none. Nil for a position recorded before this
    /// existed, and for one restored from another device that has not been read here
    /// since — both mean "which chapter, and nothing finer", which is what every screen
    /// showed before the column existed.
    var lastReadFraction: Double?
    /// When the reader was last in this book, and `nil` for a book they have never
    /// opened — which is what makes the recent-reading list orderable at all.
    ///
    /// A column of its own rather than `updatedAt`, which is the nearest thing that
    /// already existed: that one is bumped by a rename and by a catalog refresh
    /// picking up a new site title, so it means "last touched". A shelf sorted by it
    /// puts a book the reader only renamed above the novel they read last night, and
    /// a *history* built on it would be worse still — it would list books nobody has
    /// opened. `LibrarySort.recentlyRead` reads this now for the same reason.
    ///
    /// Written by `LibraryRepo.updateProgress`, which is the one place a reading
    /// position is recorded, and cleared en masse by `clearReadingHistory` — the
    /// history is a record of reading, and clearing it is the user saying to forget
    /// it. Their positions are untouched: forgetting *when* they read a book is not
    /// forgetting *where* they got to.
    var lastReadAt: Date?
    /// When the chapter index was last read from the site. `nil` means the
    /// catalog has never been fetched — which is not the same as "it is stale",
    /// and the two lead to very different screens.
    var catalogUpdatedAt: Date?

    /// A catalog older than this is refreshed in the background on open. A day
    /// is the shape of the content: these books gain a chapter or two a day, so
    /// checking more often costs requests for nothing, and checking less often
    /// means a daily reader keeps hitting an end that is not the end.
    static let catalogMaxAge: TimeInterval = 24 * 60 * 60

    var isCatalogStale: Bool {
        guard let catalogUpdatedAt else { return true }
        return Date().timeIntervalSince(catalogUpdatedAt) > Self.catalogMaxAge
    }

    /// What the library actually shows.
    var shownName: String { displayName?.isEmpty == false ? displayName! : title }

    /// Where the reader left off, or nil for a book that has never been opened —
    /// the distinction the detail screen draws "start" versus "continue" from.
    ///
    /// The paragraph and offset fall back to the start of the chapter rather than
    /// making the whole position nil: a book migrated from before this column
    /// existed knows its chapter and nothing finer, and the top of the right chapter
    /// is the honest answer to that.
    var readingPosition: ReadingPosition? {
        guard let lastReadSiteChapterId else { return nil }
        return ReadingPosition(
            siteChapterId: lastReadSiteChapterId,
            anchor: TextAnchor(
                paragraph: lastReadParagraph ?? 0,
                characterOffset: lastReadCharacterOffset ?? 0
            )
        )
    }

    /// Where the stored position sits in reading order, resolved against a catalog.
    ///
    /// The position names a chapter; only the catalog knows what number that chapter
    /// currently is, which is exactly why the number is not stored. Nil covers both
    /// "never opened" and "the site dropped the chapter they were in" — neither places
    /// the reader in the order, and everything that asks treats the two alike.
    ///
    /// `LibraryRepo.newChapterCounts` resolves the same thing in SQL, with a join it
    /// cannot avoid; `NewChapterTests` pins the two answers together.
    func lastReadIndex(in chapters: [Chapter]) -> Int? {
        guard let lastReadSiteChapterId else { return nil }
        return chapters.first { $0.siteChapterId == lastReadSiteChapterId }?.index
    }

    static func makeId(siteId: String, siteBookId: String) -> String {
        "\(siteId)|\(siteBookId)"
    }

    /// The reserved source for books imported from a file on the device.
    ///
    /// A book needs a source to be identified at all — `id` is derived from one —
    /// but an imported book has no site and never will, so it gets one that no
    /// rule file can ever claim. Everything that asks a `SiteStore` about it gets
    /// nil back, which is why the few screens that would show a rule's name or
    /// offer to refetch from it have to ask `isLocal` first.
    static let localSiteId = "local"

    var isLocal: Bool { siteId == Self.localSiteId }
}

/// One chapter of a book. Chapter *text* is never stored here — only the index
/// entry and whether a local copy exists. Text lives in files (see
/// `ChapterFileStore`) because it is bulk data with a very different lifecycle:
/// the index is queried constantly, the text is written once and deleted en masse.
struct Chapter: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "chapter"

    var id: String
    var bookId: String
    var siteChapterId: String
    /// Reading order, 0-based. Authoritative — the site's own ordering may be
    /// reversed, which the rule's `catalog.order` normalises at extraction time.
    var index: Int
    var title: String
    var url: String
    /// When a catalog refresh first saw this chapter, and `nil` when it arrived
    /// with the book's very first catalog — an entire book cannot be "new", so
    /// the first fetch deliberately marks nothing. Also `nil` for every chapter
    /// indexed before this column existed, which is the same honest answer.
    var addedAt: Date?
    /// Non-nil exactly when a local text file exists (requirement 4.2).
    var downloadedAt: Date?

    var isDownloaded: Bool { downloadedAt != nil }

    /// Whether to flag this chapter as newly published by the site.
    ///
    /// "New" means the site added it after we already had a catalog — not
    /// "unread". Unread would paint a never-opened book entirely red, which
    /// says nothing; a chapter that appeared while the reader was away is the
    /// only thing they cannot already see from their reading position.
    ///
    /// Derived rather than stored as a flag cleared on read: a flag would need a
    /// write per chapter opened, and it would go stale the moment progress
    /// arrives from another device.
    /// And it expires: a chapter stops being new a day after it appeared, read or not.
    ///
    /// Two reasons. Reading past it is otherwise the only way to clear the marker, and
    /// that is not always available — the reader's own catalog sheet holds the book it
    /// was opened with, so chapters read during that session keep their dot until the
    /// reader leaves. More fundamentally, "new" is a claim about recency: a chapter the
    /// site published last month is not news the reader is missing, it is simply a
    /// chapter they have not reached, which their position already tells them.
    ///
    /// - Parameter lastReadIndex: reading order of the chapter the reader left off in,
    ///   as `Book.lastReadIndex(in:)` resolves it. Nil means they have no place in this
    ///   catalog — never opened, or the site dropped the chapter they were in — and
    ///   then every recently added chapter is ahead of them.
    func isNew(lastReadIndex: Int?, now: Date = .now) -> Bool {
        guard let addedAt, now.timeIntervalSince(addedAt) < Self.newWindow else { return false }
        guard let lastReadIndex else { return true }
        return index > lastReadIndex
    }

    /// How long a chapter stays marked. Shared with the shelf's counting query so the
    /// two statements of this rule cannot drift to different numbers.
    static let newWindow: TimeInterval = 24 * 60 * 60

    static func makeId(bookId: String, siteChapterId: String) -> String {
        "\(bookId)|\(siteChapterId)"
    }

    /// `candidate` when it is the same name as `stored` but whole, and nil otherwise.
    ///
    /// A chapter is named by the catalog, and some of these sites truncate their own
    /// catalog's link text — 69shuba cuts at 27 characters, mid-word: the reader gets
    /// "第363章 爆發之二，逆天刷子，啓動！魔帝之" for a chapter its own page calls
    /// "第363章 爆發之二，逆天刷子，啓動！魔帝之邀！". Downloading does not help; the
    /// text comes from a file but the name still comes from the catalog.
    ///
    /// "The same name but whole" is exactly `hasPrefix`, and deliberately nothing
    /// looser: a truncation *is* a prefix, so anything that is not one is a different
    /// name rather than a completion of this one. That is what refuses the sites whose
    /// chapter heading glues the book title in front (`書名 第363章 …`) — taking that
    /// would be renaming the chapter, not repairing it.
    static func fullerTitle(_ candidate: String?, extending stored: String) -> String? {
        guard let candidate, candidate.count > stored.count, candidate.hasPrefix(stored) else {
            return nil
        }
        return candidate
    }
}
