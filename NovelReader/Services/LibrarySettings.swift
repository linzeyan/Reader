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

    func isCatalogDescending(bookId: String) -> Bool { catalogDescending[bookId] ?? false }

    /// Ascending is stored as *no entry*, not as `false`: it is what a book that was
    /// never touched already answers, so keeping the row would leave one behind for
    /// every book whose order was changed and changed back.
    func setCatalogDescending(_ descending: Bool, bookId: String) {
        catalogDescending[bookId] = descending ? true : nil
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
        static let catalogDescending = "library.catalogDescending"
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
        catalogDescending = defaults.dictionary(forKey: Keys.catalogDescending) as? [String: Bool] ?? [:]
    }
}
