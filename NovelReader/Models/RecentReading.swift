import Foundation

/// One row of the reading history: a book, and where the reader stopped in it.
///
/// The chapter travels with the book rather than being looked up when the row is
/// drawn, for the reason the shelf's counts do: a book stores *which* chapter it
/// left off in, turning that into a title and a number takes the catalog, and this
/// screen holds no catalogs. `LibraryRepo.recentlyRead` resolves the whole list in
/// one query.
///
/// `chapterTitle` and `chapterIndex` are nil together, and mean the site has dropped
/// the chapter the position names — the same "no place in this catalog" that
/// `Book.lastReadIndex(in:)` returns nil for. The book stays in the history: it was
/// read, and only the exact spot is gone.
struct RecentRead: Identifiable, Equatable {
    let book: Book
    let chapterTitle: String?
    /// Its place in reading order, 0-based.
    let chapterIndex: Int?
    /// How many chapters the book's catalog currently holds. Zero for a book whose
    /// catalog has never been fetched.
    let chapterCount: Int

    var id: String { book.id }

    /// Where tapping the row goes: exactly where the reader left off.
    ///
    /// Nil only for a book whose stored position names a chapter the site has since
    /// dropped — there is no place left to send them, and inventing one (the first
    /// chapter, say) would take a reader four hundred chapters in back to the start.
    var position: ReadingPosition? { book.readingPosition }

    /// Whether there is nothing left of this book to come back to: the last chapter,
    /// read to the end.
    ///
    /// "The end" is the share the app has been showing all along — see
    /// `TextAnchor.shareText`, which rounds to a whole percent — so a book this calls
    /// finished is exactly a book whose row reads 100%. Any other threshold would put
    /// "已讀完" next to a number that says 99%, or withhold it from one that says 100.
    ///
    /// A book with no recorded share is not finished. Nil means "which chapter, and
    /// nothing finer" (`Book.lastReadFraction`), and reaching the last chapter is not
    /// the same as having read it.
    var isFinished: Bool {
        guard let chapterIndex, chapterCount > 0, chapterIndex == chapterCount - 1,
              let fraction = book.lastReadFraction
        else { return false }
        return fraction >= Self.finishedShare
    }

    /// The smallest share that `TextAnchor.shareText` prints as 100%.
    ///
    /// Both renderers now state their share through `TextAnchor.claimedShare`, which
    /// rounds down to a whole percent, so anything they write is either exactly 1 or at
    /// most 0.99. The gap is for shares recorded before that rule existed: those are raw
    /// measurements, and one at 0.998 was shown as 100% on every screen that has ever
    /// drawn it.
    private static let finishedShare = 0.995
}

/// The app's four screens, as the shell addresses them.
enum RootTab: Hashable {
    case recent
    case library
    case search
    case settings
}

extension RootTab {
    /// Which tab a launch opens on.
    ///
    /// The history first, because "carry on where I was" is what someone opens a
    /// reader for. But only while it has something to carry on with: a reader whose
    /// every recent book is finished would be shown a screen of dead ends, and what
    /// they came for is the next book — which is the bookshelf.
    ///
    /// - Parameter recent: the history *as the screen shows it*, already cut to the
    ///   reader's chosen length. A book pushed off the end of a five-row list is not
    ///   something they can tap, so it cannot be the reason the list counts as having
    ///   something left in it.
    static func home(recent: [RecentRead]) -> RootTab {
        recent.contains { !$0.isFinished } ? .recent : .library
    }
}
