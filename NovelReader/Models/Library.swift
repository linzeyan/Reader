import Foundation
import GRDB

/// A book on the shelf — a novel or a comic, as `kind` says.
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
    /// What this book is, copied from the rule it was added through.
    ///
    /// Copied rather than looked up, because the rule is not always there to look up: a
    /// book restored from iCloud lands on a device that may never have installed the rule
    /// it names, and it still has to open in the right reader. `SiteRule.Kind` rather
    /// than a second enum saying the same two words — the rule is where this answer comes
    /// from, and two spellings of it is how a book ends up in the wrong reader.
    ///
    /// A book imported from a file on the device is a novel: nothing but text can be
    /// imported (see `LocalBookImporter`).
    var kind: SiteRule.Kind
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
    ///
    /// The same three columns hold a comic's position, under a widened reading of the
    /// middle one: `lastReadParagraph` is **which visual block** the reader stopped on —
    /// a paragraph in a novel, a *page* in a comic — and `lastReadCharacterOffset` is 0
    /// for a comic, which has nothing finer than a page to name. Widening the meaning
    /// rather than adding a comic's own pair of columns is what makes a comic position
    /// sync through iCloud and draw on the shelf without a line of new code: every query
    /// that already reads a position reads a comic's too, and there is no second position
    /// to keep in step with this one.
    var lastReadSiteChapterId: String?
    var lastReadParagraph: Int?
    var lastReadCharacterOffset: Int?
    /// How far into that chapter the position sits, 0…1, as `TextAnchor.fraction(in:)`
    /// measured it when the chapter was on screen — or, in a comic, as the reader that had
    /// the pages on screen measured it against their count. Either way it is the renderer
    /// reporting what it actually laid out, never a share worked back out of the anchor.
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

    /// Five minutes for a subscription, which is a different shape of content and a very
    /// different cost. A feed can publish several times an hour, and asking a reader who
    /// opened the app to see what is new to instead see this morning's list would be
    /// answering the wrong question.
    ///
    /// Short because the request is nearly free and nobody is being kept out: a feed is a
    /// document published to be polled, it is fetched conditionally (see `FeedFetchState`),
    /// and the usual answer is a `304` — a few hundred bytes and no parsing, no articles,
    /// no pictures. Half an hour was the novel sites' caution applied to something that
    /// does not need it.
    static let feedMaxAge: TimeInterval = 5 * 60

    var isCatalogStale: Bool {
        guard let catalogUpdatedAt else { return true }
        let age = kind == .feed ? Self.feedMaxAge : Self.catalogMaxAge
        return Date().timeIntervalSince(catalogUpdatedAt) > age
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

    /// The reserved source for subscriptions, whose `siteBookId` is the feed's own
    /// address.
    ///
    /// Reserved the same way and for the same reason: a feed describes itself, so there
    /// is no rule file behind it and never will be. What it is *not* is a second kind of
    /// local book — a subscription is fetched, refreshed and synced through iCloud like
    /// any bookmark, and only `isLocal` marks the books that exist nowhere but here.
    static let feedSiteId = "feed"

    var isLocal: Bool { siteId == Self.localSiteId }

    /// Whether a `SiteStore` could have anything to say about this book.
    ///
    /// The question every screen that shows a source name, offers to re-fetch from one,
    /// or warns that one has been uninstalled is really asking. It used to be `!isLocal`,
    /// which was the same question while there were only two answers; a subscription is
    /// the third, and it has no rule either.
    var hasRule: Bool { !isLocal && kind != .feed }
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
    /// When the publisher says this article appeared, for the one medium that has such a
    /// thing: a feed.
    ///
    /// Null for every novel and comic chapter, and that is not a gap to be filled — a
    /// chapter of a novel has no publication date of its own, only a place in the book.
    /// Which is exactly the difference this column exists for: a novel's reading order is
    /// its catalog's, while a feed has no catalog and its order *is* this date. See
    /// `LibraryRepo.mergeCatalog`.
    var publishedAt: Date?
    /// Non-nil exactly when a local text file exists (requirement 4.2).
    var downloadedAt: Date?
    /// When this article was read, for the one medium where that is a fact about the
    /// article rather than about where the reader is standing: a feed.
    ///
    /// Null for every novel and comic chapter, and never written for one. A novel is read
    /// in one direction and its position says everything — a chapter "before" the position
    /// has been passed, and that is all "read" could mean there. A feed is not read that
    /// way: articles are picked out of a list in whatever order they look interesting, so
    /// the only honest record is one per article. See the `v12.articleRead` migration for
    /// what the watermark this replaces could not say.
    var readAt: Date?

    var isDownloaded: Bool { downloadedAt != nil }

    /// Whether this article is still waiting to be read.
    ///
    /// A question only a subscription answers meaningfully: every novel and comic chapter
    /// is "unread" by this measure for ever, because nothing writes the column for them.
    /// Callers branch on `Book.kind` before asking — `ChapterRow` and the shelf's counting
    /// query both do, and `LibraryRepo.newChapterCounts` restates this in SQL.
    var isUnread: Bool { readAt == nil }

    /// The page this chapter came from, where that is an address worth opening.
    ///
    /// Nil for an article the feed published no link for: `LibraryRepo.mergeCatalog`
    /// stores an empty string there rather than the feed's own address, which would send a
    /// reader asking for the original to a document instead of a page. The scheme is
    /// checked for the same reason `ArticleImages` checks it — a `javascript:` or `data:`
    /// URL out of a publisher's document is not something to hand to the system opener.
    ///
    /// One definition, because three places ask: the reader's "open original", the tap on
    /// an article's title, and the catalog's copy-link swipe.
    var webURL: URL? {
        guard let url = URL(string: url), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

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
    /// Novels and comics only. A subscription asks `isUnread` instead, which is a
    /// different question with a different answer: the marker on an article means "you
    /// have not read this", and the one here means "the site published this while you were
    /// away". Feeds used to come through here with `expiring: false`, which made the two
    /// one function answering both badly — it could only say "unread" as "past the reading
    /// position", and that is precisely what `readAt` exists to stop being the definition.
    ///
    /// - Parameter lastReadIndex: reading order of the chapter the reader left off in,
    ///   as `Book.lastReadIndex(in:)` resolves it. Nil means they have no place in this
    ///   catalog — never opened, or the site dropped the chapter they were in — and
    ///   then every recently added chapter is ahead of them.
    func isNew(lastReadIndex: Int?, now: Date = .now) -> Bool {
        // Recent *and* stamped: a chapter indexed before the column existed has no
        // honest arrival date, and reading one as "now" would mark a whole library.
        guard let addedAt, now.timeIntervalSince(addedAt) < Self.newWindow else {
            return false
        }
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
