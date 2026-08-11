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
    /// Three columns rather than one encoded anchor because SQL has to read the
    /// chapter index directly — `LibraryRepo.newChapterCounts` compares it against
    /// every chapter in one grouped query, which a blob would make impossible.
    /// `readingPosition` is the shape the rest of the app works in.
    var lastReadChapterIndex: Int?
    var lastReadParagraph: Int?
    var lastReadCharacterOffset: Int?
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
        guard let lastReadChapterIndex else { return nil }
        return ReadingPosition(
            chapterIndex: lastReadChapterIndex,
            anchor: TextAnchor(
                paragraph: lastReadParagraph ?? 0,
                characterOffset: lastReadCharacterOffset ?? 0
            )
        )
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
    func isNew(in book: Book) -> Bool {
        guard addedAt != nil else { return false }
        guard let lastRead = book.lastReadChapterIndex else { return true }
        return index > lastRead
    }

    static func makeId(bookId: String, siteChapterId: String) -> String {
        "\(bookId)|\(siteChapterId)"
    }
}
