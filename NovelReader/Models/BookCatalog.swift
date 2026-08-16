import Foundation

/// What a book's chapter list shows: the chapter to pin above it, and the rows
/// themselves in the order this reader wants this book in.
///
/// A pure function of the catalog and the two things the reader changes about it, for
/// the same reason `LibraryShelf` is one: the rules worth pinning down here — that the
/// pinned chapter is the same one in either order, and that a search shows matches and
/// nothing besides — are decisions, not drawing, and neither is testable through a view.
struct BookCatalog {
    /// The chapter the reader left off in, shown above the list whatever order the list
    /// is in: it is the row they came back for, and hunting for it through thirteen
    /// hundred others is the reason it is pinned rather than merely marked.
    ///
    /// Nil while a search is running — the list is being used to find something, and a
    /// row that does not match what was typed is not a result. Nil too when the site has
    /// dropped that chapter, which is the same "no place in this catalog" that
    /// `Book.lastReadIndex(in:)` reports and every other screen already handles.
    let lastRead: Chapter?
    /// The rows, filtered and ordered.
    let chapters: [Chapter]

    init(chapters: [Chapter], query: String, descending: Bool, lastReadSiteChapterId: String?) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let matched = trimmed.isEmpty
            ? chapters
            : chapters.filter { $0.title.localizedStandardContains(trimmed) }
        // Reversed after filtering rather than before: the order is over what ends up on
        // screen, and reversing the whole catalog first would reach the same list by
        // touching every chapter the search already threw away.
        self.chapters = descending ? Array(matched.reversed()) : matched
        // Resolved against the whole catalog, not against `matched`: the pinned row is
        // not a search result, and it is not the order's to move.
        lastRead = trimmed.isEmpty
            ? lastReadSiteChapterId.flatMap { id in chapters.first { $0.siteChapterId == id } }
            : nil
    }
}
