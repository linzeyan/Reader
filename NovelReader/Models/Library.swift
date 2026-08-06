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
    /// Reading position: which chapter, and how far into it.
    var lastReadChapterIndex: Int?
    var lastReadOffset: Int?
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

    static func makeId(siteId: String, siteBookId: String) -> String {
        "\(siteId)|\(siteBookId)"
    }
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
    /// Non-nil exactly when a local text file exists (requirement 4.2).
    var downloadedAt: Date?

    var isDownloaded: Bool { downloadedAt != nil }

    static func makeId(bookId: String, siteChapterId: String) -> String {
        "\(bookId)|\(siteChapterId)"
    }
}
