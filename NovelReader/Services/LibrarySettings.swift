import Foundation

/// How the reader wants their shelf arranged.
///
/// In `UserDefaults` and deliberately *not* synced, for the same reason
/// `ReaderSettings` and `DownloadSettings` are not: this is a view preference, and
/// the iCloud store here carries content only — bookmarks, reading positions and
/// the download index. A shelf arrangement chosen on a phone is not an opinion
/// about the iPad's shelf, and pushing it would make one device silently rearrange
/// the other.
///
/// Separate from `ReaderSettings` rather than added to it: that type is the
/// reading page's appearance, and a shelf that sorted itself out of a screen
/// called "Reading" would be findable by nobody.
@Observable
final class LibrarySettings {
    var sort: LibrarySort {
        didSet { defaults.set(sort.rawValue, forKey: Keys.sort) }
    }

    /// Grouping by source, on by default — see `LibraryView` for why the shelf is
    /// grouped at all. Off makes it one list, which is what someone who reads from
    /// a single source wants.
    var groupBySource: Bool {
        didSet { defaults.set(groupBySource, forKey: Keys.groupBySource) }
    }

    /// Shows only books the source has added chapters to. Persisted like the rest,
    /// so the toolbar has to say when it is on — a filter that survives a relaunch
    /// and silently hides most of the shelf reads as lost books.
    var onlyWithNewChapters: Bool {
        didSet { defaults.set(onlyWithNewChapters, forKey: Keys.onlyWithNewChapters) }
    }

    /// Which screen a launch opens on. See `HomeScreen`.
    var home: HomeScreen {
        didSet { defaults.set(home.rawValue, forKey: Keys.home) }
    }

    /// Which shelf a launch opens on — novels or comics.
    ///
    /// The *default*, not the last one used, and that is the whole design: the mode
    /// switch is one tap away on the shelf itself, so remembering the last choice would
    /// leave this setting with nothing to do. What it says is "this is what I read", and
    /// every launch starting there is what makes that true. `AppEnvironment.mediaMode`
    /// is where the session's answer lives; nothing writes back to here.
    var defaultMediaMode: MediaMode {
        didSet { defaults.set(defaultMediaMode.rawValue, forKey: Keys.defaultMediaMode) }
    }

    /// How many books the reading history shows.
    ///
    /// Five by default: the history exists to answer "what was I reading", and that is
    /// a question about the two or three books someone is actually in — a longer list
    /// stops being an answer and becomes a second shelf. Fifteen is the ceiling for the
    /// same reason, and because the list is the app's first screen: it has to be
    /// readable without scrolling on the phone that shows the fewest rows.
    ///
    /// Clamped on the way in as well as in the UI. This is read straight out of
    /// `UserDefaults`, which a previous build — or a device restored from one — is free
    /// to have left anything in, and the value becomes a SQL `LIMIT`.
    ///
    /// Computed over a private store rather than written as `didSet`, the way every
    /// other setting here is, precisely *because* it clamps. Under `@Observable` these
    /// are no longer stored properties with observers: the macro turns each one into an
    /// accessor pair, so the rule that assigning inside `didSet` does not re-enter it no
    /// longer holds — it calls the setter again, and the clamp recursed until the stack
    /// ran out. Observation still reaches this: the getter reads a stored property, and
    /// the setter writes one.
    var recentReadingCount: Int {
        get { storedRecentReadingCount }
        set {
            storedRecentReadingCount = Self.clamp(newValue)
            defaults.set(storedRecentReadingCount, forKey: Keys.recentReadingCount)
        }
    }

    static let recentReadingRange = 1...15
    static let defaultRecentReadingCount = 5

    private var storedRecentReadingCount: Int

    private static func clamp(_ count: Int) -> Int {
        min(max(count, recentReadingRange.lowerBound), recentReadingRange.upperBound)
    }

    /// The books whose catalog runs newest chapter first, by book id.
    ///
    /// Per book rather than one setting for the whole app: the same shelf holds a novel
    /// being read from chapter one, where the top of the list is where reading starts,
    /// and a serial being followed for its updates, where the top of the list is the
    /// thing the reader came for. One answer would be wrong for one of them every time.
    ///
    /// One dictionary rather than a key per book, so that forgetting a deleted book's
    /// order is a single removal and nothing has to enumerate the defaults to find
    /// entries left behind.
    private(set) var catalogDescending: [String: Bool] {
        didSet { defaults.set(catalogDescending, forKey: Keys.catalogDescending) }
    }

    /// Which way a catalog runs before the reader has said anything about it.
    ///
    /// Newest first for a subscription, oldest first for everything else. A novel is read
    /// from chapter one, so the top of an ascending list is where reading starts. A feed is
    /// not read in an order at all — what the reader opened it for is whatever was
    /// published since they last looked, and ascending buries that at the bottom, past a
    /// thousand articles they have already seen.
    static func defaultDescending(for kind: SiteRule.Kind) -> Bool { kind == .feed }

    func isCatalogDescending(bookId: String, kind: SiteRule.Kind) -> Bool {
        catalogDescending[bookId] ?? Self.defaultDescending(for: kind)
    }

    /// The default is stored as *no entry*, not as its value: it is what a book that was
    /// never touched already answers, so keeping the row would leave one behind for
    /// every book whose order was changed and changed back.
    func setCatalogDescending(_ descending: Bool, bookId: String, kind: SiteRule.Kind) {
        catalogDescending[bookId] =
            descending == Self.defaultDescending(for: kind) ? nil : descending
    }

    /// Dropped along with the book. Nothing else clears these, and a book removed and
    /// added again would otherwise come back with an order the reader never chose for it.
    func forgetCatalogOrder(bookId: String) {
        catalogDescending[bookId] = nil
    }

    private enum Keys {
        static let sort = "library.sort"
        static let groupBySource = "library.groupBySource"
        static let onlyWithNewChapters = "library.onlyWithNewChapters"
        static let home = "library.home"
        static let defaultMediaMode = "library.defaultMediaMode"
        static let catalogDescending = "library.catalogDescending"
        static let recentReadingCount = "library.recentReadingCount"
    }

    private let defaults: UserDefaults

    /// The defaults reproduce the shelf as it was before these controls existed:
    /// grouped by source, newest bookmark first, nothing hidden. Someone who never
    /// opens the menu must not notice it was added.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sort = defaults.string(forKey: Keys.sort).flatMap(LibrarySort.init(rawValue:)) ?? .added
        groupBySource = defaults.object(forKey: Keys.groupBySource) as? Bool ?? true
        onlyWithNewChapters = defaults.object(forKey: Keys.onlyWithNewChapters) as? Bool ?? false
        home = defaults.string(forKey: Keys.home).flatMap(HomeScreen.init(rawValue:)) ?? .automatic
        defaultMediaMode =
            defaults.string(forKey: Keys.defaultMediaMode).flatMap(MediaMode.init(rawValue:)) ?? .novel
        catalogDescending = defaults.dictionary(forKey: Keys.catalogDescending) as? [String: Bool] ?? [:]
        // `integer(forKey:)` answers 0 for a key that was never written, which is not
        // a length anyone chose — hence the object check before the clamp.
        storedRecentReadingCount = Self.clamp(
            defaults.object(forKey: Keys.recentReadingCount) as? Int ?? Self.defaultRecentReadingCount
        )
    }
}
