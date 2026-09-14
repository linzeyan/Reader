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

/// Books by one author, under one section.
///
/// A level below `LibrarySection` rather than a second kind of section, because that is
/// what it is on screen: a source is a heading with an inset card under it, and the
/// authors inside one are rows in that card that open.
struct LibraryGroup: Identifiable {
    /// The section's id and the author together. The same author read on two sites is
    /// two groups, and a reader who folds one of them has said nothing about the other.
    let id: String
    let name: String
    let books: [Book]

    static func id(inSection sectionId: String, author: String) -> String {
        // A separator no author's name can contain, so that two sections cannot collide
        // by having names that run together the same way.
        "\(sectionId)\u{1}\(author)"
    }
}

/// One block of rows on the shelf.
struct LibrarySection: Identifiable {
    /// The id of the source this section shows, the author when the shelf divides by
    /// author, or `flatId` for the books that belong under no heading at all. Also what
    /// the reader's folded/unfolded choice is remembered against.
    let id: String
    /// `nil` when the section has no header, which is how the view knows not to draw one
    /// — an empty header still costs vertical space in a `List` — and also what says the
    /// section cannot be folded: there would be nothing to tap.
    let name: String?
    /// The authors inside this section, drawn above its loose books. Empty unless the
    /// shelf is divided by source *and* author, which is the only arrangement with two
    /// levels to draw.
    let groups: [LibraryGroup]
    /// The books under this section that are in no group of their own.
    let books: [Book]

    /// Cannot collide with a real source id in practice, and could not matter if
    /// it did: the flat shelf is a single section.
    static let flatId = "__flat__"

    init(id: String, name: String?, groups: [LibraryGroup] = [], books: [Book]) {
        self.id = id
        self.name = name
        self.groups = groups
        self.books = books
    }

    /// Everything under the heading, at both levels. What the heading says it is
    /// holding — a folded section that does not is one nobody opens twice.
    var bookCount: Int { groups.reduce(books.count) { $0 + $1.books.count } }
}

/// How the shelf divides the books up.
///
/// Raw values are storage keys (see `LibrarySettings`), so they are not free to be
/// renamed.
enum LibraryGrouping: String, CaseIterable, Identifiable {
    case none
    /// One block per site. The default, and what the shelf did before there was anything
    /// to choose — see `LibraryView` for why a library is worth dividing this way at all.
    case source
    case author
    case sourceThenAuthor

    var id: String { rawValue }

    var nameKey: LocalizedStringKey {
        switch self {
        case .none: return "library.grouping.none"
        case .source: return "library.grouping.source"
        case .author: return "library.grouping.author"
        case .sourceThenAuthor: return "library.grouping.sourceThenAuthor"
        }
    }

    /// Whether this arrangement divides books by who wrote them. False for both of the
    /// arrangements a subscription shelf can use — see `AppEnvironment.shelfGrouping`.
    var reachesAuthors: Bool { self == .author || self == .sourceThenAuthor }

    /// Whether this arrangement keeps each site's books together.
    var keepsSources: Bool { self == .source || self == .sourceThenAuthor }
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
        grouping: LibraryGrouping,
        onlyWithNewChapters: Bool,
        newChapterCounts: [String: Int]
    ) -> [LibrarySection] {
        // Filtering first, and per source rather than over one flat list: a
        // source whose every book is hidden must lose its header too, otherwise
        // the shelf shows named sections with nothing under them.
        let kept = onlyWithNewChapters ? sources.compactMap(withNewChapters(in: newChapterCounts)) : sources

        switch grouping {
        case .none:
            // Sorted after flattening, not before: the point of turning grouping
            // off is one order across the whole library, and sorting each source
            // first would only interleave them per section.
            return loose(sort.applied(to: kept.flatMap(\.books)), id: LibrarySection.flatId)

        case .source:
            return bySource(kept, sort: sort) { source, books in
                LibrarySection(id: source.siteId, name: source.name, books: books)
            }

        case .author:
            // The authors become the headings, which is what picking this arrangement
            // asked for: the top of the shelf reads the same way whether it is divided
            // by who published a book or by who wrote it.
            let books = sort.applied(to: kept.flatMap(\.books))
            let divided = divide(books, inSection: LibrarySection.flatId)
            return divided.groups.map {
                LibrarySection(id: $0.id, name: $0.name, books: $0.books)
            } + loose(divided.rest, id: LibrarySection.flatId)

        case .sourceThenAuthor:
            return bySource(kept, sort: sort) { source, books in
                let divided = divide(books, inSection: source.siteId)
                return LibrarySection(
                    id: source.siteId,
                    name: source.name,
                    groups: divided.groups,
                    books: divided.rest
                )
            }
        }
    }

    /// One section per source, each built by the caller — and ordered by what it holds
    /// rather than by the rule list.
    ///
    /// That ordering is new. The headers used to sit in the order the settings screen
    /// lists rules in, which meant the sort reached the books and stopped: with
    /// "recently read" chosen, the book read this morning could be three folded headings
    /// down. Each source now stands for the book of its own that sorts first, so the
    /// arrangement the reader picked is the one the whole shelf is in.
    private static func bySource(
        _ sources: [LibrarySource],
        sort: LibrarySort,
        build: (LibrarySource, [Book]) -> LibrarySection
    ) -> [LibrarySection] {
        sources
            // A kept source always has books — an empty one is dropped by the filter, and
            // one was never built — so the first is a representative and not a guess.
            .compactMap { source -> (LibrarySource, [Book])? in
                let books = sort.applied(to: source.books)
                return books.isEmpty ? nil : (source, books)
            }
            .sorted { sort.precedes($0.1[0], $1.1[0]) }
            .map(build)
    }

    /// A section with no heading, or nothing at all where there is nothing to put in it.
    private static func loose(_ books: [Book], id: String) -> [LibrarySection] {
        books.isEmpty ? [] : [LibrarySection(id: id, name: nil, books: books)]
    }

    /// Splits books that are already in the reader's order into author groups and the
    /// rest, keeping that order in both.
    ///
    /// Only an author with more than one book here gets a group. A shelf of forty books
    /// by forty people would otherwise become forty groups of one, and a group of one is
    /// a row with a disclosure triangle in front of it and nothing to disclose. Books
    /// whose author the source never gave up are in the rest for the same reason: they
    /// are not a cohort, they are the books nothing is known about.
    ///
    /// The groups come out in the order their first book does, so the reader's sort
    /// decides which cohort is at the top as well as which book is at the top of each.
    private static func divide(
        _ books: [Book], inSection sectionId: String
    ) -> (groups: [LibraryGroup], rest: [Book]) {
        var counts: [String: Int] = [:]
        for book in books {
            guard let author = book.author?.nonBlank else { continue }
            counts[author, default: 0] += 1
        }
        var groups: [LibraryGroup] = []
        var started: Set<String> = []
        var rest: [Book] = []
        for book in books {
            guard let author = book.author?.nonBlank, counts[author, default: 0] > 1 else {
                rest.append(book)
                continue
            }
            guard started.insert(author).inserted else { continue }
            groups.append(
                LibraryGroup(
                    id: LibraryGroup.id(inSection: sectionId, author: author),
                    name: author,
                    books: books.filter { $0.author?.nonBlank == author }
                )
            )
        }
        return (groups, rest)
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
        books.sorted(by: precedes)
    }

    /// The order itself, exposed because the shelf now orders more than books with it:
    /// a section and a group each stand for the book of theirs that sorts first, and
    /// comparing those means asking this question about two books that are not
    /// neighbours in any one list.
    func precedes(_ lhs: Book, _ rhs: Book) -> Bool {
        switch self {
        case .added:
            return (lhs.addedAt, lhs.id) > (rhs.addedAt, rhs.id)
        case .title:
            // `localizedStandardCompare`, never `<`: Swift compares by Unicode
            // scalar, which files 第10章 before 第2章 and orders Han characters by
            // codepoint — an ordering that looks random to anyone reading it. This
            // is the same comparison Finder uses, and the one `SiteStore` already
            // sorts rule names with.
            switch lhs.shownName.localizedStandardCompare(rhs.shownName) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            // Two books with the same name are common — the same novel
            // bookmarked on two sites is the reason the shelf groups at all.
            case .orderedSame: return lhs.id < rhs.id
            }
        case .recentlyRead:
            return readMoreRecently(lhs, rhs)
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
