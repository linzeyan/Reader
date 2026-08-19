import SwiftUI

/// A source and the books the library holds from it.
///
/// Named rather than a tuple because it travels from `AppEnvironment` into
/// `LibraryShelf` and back out to two screens; a three-element tuple crossing
/// that many boundaries stops documenting itself.
struct LibrarySource: Identifiable {
    let siteId: String
    /// What the source is called on screen — a rule's name, the reserved name for
    /// imported files, or the raw id of a rule that has been removed.
    let name: String
    let books: [Book]

    var id: String { siteId }
}

/// One block of rows on the shelf.
struct LibrarySection: Identifiable {
    /// The id of the source this section shows, or `flatId` when grouping is off.
    let id: String
    /// `nil` when the shelf is one flat list, which is how the view knows not to
    /// draw a header — an empty header still costs vertical space in a `List`.
    let name: String?
    let books: [Book]

    /// Cannot collide with a real source id in practice, and could not matter if
    /// it did: the flat shelf is a single section.
    static let flatId = "__flat__"
}

/// How the shelf orders books.
///
/// Raw values are storage keys (see `LibrarySettings`), so they are not free to
/// be renamed.
enum LibrarySort: String, CaseIterable, Identifiable {
    /// Newest bookmark first. The default, and the order the shelf had before
    /// there was anything to choose.
    case added
    case title
    case recentlyRead

    var id: String { rawValue }

    var nameKey: LocalizedStringKey {
        switch self {
        case .added: return "library.sort.added"
        case .title: return "library.sort.title"
        case .recentlyRead: return "library.sort.recentlyRead"
        }
    }
}

/// Turns the library into the rows the shelf draws.
///
/// A pure function of the books, the reader's preferences and the new-chapter
/// counts, deliberately holding no state and reaching for nothing: sorting a
/// shelf of Chinese titles and deciding what a filter may hide are the two things
/// here most worth pinning with tests, and neither is testable through a view.
/// The view's whole job is to draw what comes out of this.
enum LibraryShelf {
    static func sections(
        from sources: [LibrarySource],
        sort: LibrarySort,
        groupBySource: Bool,
        onlyWithNewChapters: Bool,
        newChapterCounts: [String: Int]
    ) -> [LibrarySection] {
        // Filtering first, and per source rather than over one flat list: a
        // source whose every book is hidden must lose its header too, otherwise
        // the shelf shows named sections with nothing under them.
        let kept = onlyWithNewChapters ? sources.compactMap(withNewChapters(in: newChapterCounts)) : sources

        guard groupBySource else {
            // Sorted after flattening, not before: the point of turning grouping
            // off is one order across the whole library, and sorting each source
            // first would only interleave them per section.
            let books = sort.applied(to: kept.flatMap(\.books))
            return books.isEmpty ? [] : [LibrarySection(id: LibrarySection.flatId, name: nil, books: books)]
        }
        // Source order is the caller's: it is the order the settings screen
        // lists rules in, which is not this type's business to re-derive.
        return kept.map { LibrarySection(id: $0.siteId, name: $0.name, books: sort.applied(to: $0.books)) }
    }

    private static func withNewChapters(
        in counts: [String: Int]
    ) -> (LibrarySource) -> LibrarySource? {
        { source in
            let books = source.books.filter { (counts[$0.id] ?? 0) > 0 }
            return books.isEmpty ? nil : LibrarySource(siteId: source.siteId, name: source.name, books: books)
        }
    }
}

extension LibrarySort {
    /// Every case produces a total order, ties included. `sorted(by:)` makes no
    /// stability promise, so a predicate that leaves two books incomparable would
    /// let the shelf reshuffle them on an unrelated reload.
    func applied(to books: [Book]) -> [Book] {
        switch self {
        case .added:
            return books.sorted { ($0.addedAt, $0.id) > ($1.addedAt, $1.id) }
        case .title:
            // `localizedStandardCompare`, never `<`: Swift compares by Unicode
            // scalar, which files 第10章 before 第2章 and orders Han characters by
            // codepoint — an ordering that looks random to anyone reading it. This
            // is the same comparison Finder uses, and the one `SiteStore` already
            // sorts rule names with.
            return books.sorted {
                switch $0.shownName.localizedStandardCompare($1.shownName) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                // Two books with the same name are common — the same novel
                // bookmarked on two sites is the reason the shelf groups at all.
                case .orderedSame: return $0.id < $1.id
                }
            }
        case .recentlyRead:
            return books.sorted(by: readMoreRecently)
        }
    }

    /// Reading order rests on `lastReadAt`, which is written when — and only when —
    /// a reading position is recorded. It used to rest on `updatedAt` gated by "has a
    /// position at all", because that was the closest thing the row carried; but
    /// `updatedAt` is bumped by a rename and by a catalog refresh picking up a new
    /// site title, so it means "last touched", and the gate could only keep an
    /// untouched book down, not a renamed one. The column says the thing outright,
    /// and it is the same column the reading history is built from — one answer to
    /// "when did they last read this", not two that can disagree.
    ///
    /// A book with no `lastReadAt` has never been read, has nothing to be recent
    /// about, and drops below every book that has been — in the shelf's default
    /// order, which is the honest fallback. Clearing the reading history puts every
    /// book in that state, which is the coherent reading of what was asked for: the
    /// record of what was read is what the sort was sorting by.
    private func readMoreRecently(_ lhs: Book, _ rhs: Book) -> Bool {
        switch (lhs.lastReadAt, rhs.lastReadAt) {
        case (.some, .none): return true
        case (.none, .some): return false
        case (.some(let left), .some(let right)): return (left, lhs.id) > (right, rhs.id)
        case (.none, .none): return (lhs.addedAt, lhs.id) > (rhs.addedAt, rhs.id)
        }
    }
}
