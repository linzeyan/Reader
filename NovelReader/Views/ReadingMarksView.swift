import SwiftUI

/// One book's marks: the positions the reader saved, and the passages they drew a line
/// under.
///
/// Reached from the book's own screen rather than from a control in the reader: the
/// reader's bottom bar is already the width of a thumb divided six ways, and coming
/// back to a marked place is something a reader does on the way *into* a book, from the
/// screen that also holds the catalog and the downloads.
///
/// One screen with a switch rather than two rows on the book, and rather than two
/// sections in one list. To a reader these are one thing — what I left in this book —
/// looked at in the same moment, so two rows would be two near-identical screens; but
/// a book with two hundred highlights would bury the bookmarks underneath them, so
/// sections would not do either. The switch also gives the empty highlight state
/// somewhere to sit next to the bookmarks the reader already understands, which is the
/// only place in the app that can explain how a highlight is made at all — and that how
/// much of the text one covers depends on which reader made it.
struct ReadingMarksView: View {
    let book: Book

    /// Which list is on screen. Bookmarks first: they are the older feature and the one
    /// a reader opens this screen for most, since a highlight is already visible in the
    /// book itself.
    private enum Kind: String, CaseIterable, Identifiable {
        case bookmarks, highlights

        var id: String { rawValue }

        var nameKey: LocalizedStringKey {
            switch self {
            case .bookmarks: return "bookmarks.title"
            case .highlights: return "highlights.title"
            }
        }
    }

    @Environment(AppEnvironment.self) private var env
    @State private var kind: Kind = .bookmarks
    @State private var bookmarks: [ReadingBookmark] = []
    @State private var highlights: [TextHighlight] = []
    /// Chapter titles by chapter id, so a row can name its chapter. Read from the stored
    /// catalog rather than denormalised into the mark: a title the site has since
    /// corrected should read correctly here too.
    ///
    /// Doubles as the answer to "does this mark still point at anything" — a chapter the
    /// site has dropped is absent from the catalog, so it is absent from here.
    @State private var chapterTitles: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            // Above the list rather than inside it as a section header: the empty state
            // covers the list, and a switch buried under it would leave a reader with no
            // bookmarks unable to reach their highlights.
            Picker("marks.title", selection: $kind) {
                ForEach(Kind.allCases) { kind in
                    Text(kind.nameKey).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("marks.kind")
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            List {
                switch kind {
                case .bookmarks: bookmarkRows
                case .highlights: highlightRows
                }
            }
            .overlay { emptyState }
        }
        .navigationTitle("marks.title")
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
    }

    // MARK: - Bookmarks

    private var bookmarkRows: some View {
        ForEach(bookmarks) { bookmark in
            NavigationLink(value: target(for: bookmark.position)) {
                VStack(alignment: .leading, spacing: 4) {
                    chapterName(bookmark.siteChapterId)
                        .font(.subheadline)
                        .lineLimit(1)
                    // The excerpt is what makes the list readable without opening
                    // anything, so it gets the room: two lines of the paragraph the
                    // bookmark sits on.
                    if let excerpt = bookmark.excerpt, !excerpt.isEmpty {
                        Text(excerpt)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    timestamp(bookmark.createdAt)
                }
                .padding(.vertical, 2)
            }
            .accessibilityIdentifier("bookmarks.row")
            // No confirmation, unlike deleting an imported book: this throws away a
            // pointer, not the text it points at. See `LibraryView`, which draws the
            // same line.
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    try? env.repo.removeReadingBookmark(id: bookmark.id)
                    bookmarks.removeAll { $0.id == bookmark.id }
                } label: {
                    Label("common.delete", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Highlights

    private var highlightRows: some View {
        ForEach(highlights) { highlight in
            NavigationLink(value: target(for: highlight.position)) {
                VStack(alignment: .leading, spacing: 4) {
                    // The marked text leads, and the chapter follows it. A highlight is
                    // remembered by what it says, not by where it was; a bookmark is
                    // the other way round, which is why the two rows are not the same
                    // shape.
                    Text(highlight.excerpt)
                        .font(.subheadline)
                        .lineLimit(3)
                    chapterName(highlight.siteChapterId)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    timestamp(highlight.createdAt)
                }
                .padding(.vertical, 2)
            }
            .accessibilityIdentifier("highlights.row")
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    try? env.repo.removeHighlight(id: highlight.id)
                    highlights.removeAll { $0.id == highlight.id }
                } label: {
                    Label("common.delete", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Shared parts

    /// The chapter's own title, or a note that it is gone — a mark can outlive a chapter
    /// that a catalog refresh dropped, and a row with no name at all would be
    /// unreadable. It cannot fall back to a chapter *number*: the number was never
    /// stored, and the catalog that could work one out no longer has the chapter.
    private func chapterName(_ siteChapterId: String) -> Text {
        if let title = chapterTitles[siteChapterId] {
            return Text(title)
        }
        return Text("marks.chapter.missing")
    }

    /// Where a row leads, or nil for a mark whose chapter the site has dropped.
    ///
    /// Such a mark is kept and shown — the excerpt is the part the reader wrote down,
    /// and a chapter pulled from a catalog often comes back — but it is not offered as a
    /// destination: opening it could only land somewhere it does not point at, which is
    /// the exact failure that made these marks store a chapter id in the first place.
    /// The swipe to delete stays, so a mark the reader has given up on can still go.
    private func target(for position: ReadingPosition) -> ReadingTarget? {
        guard chapterTitles[position.siteChapterId] != nil else { return nil }
        return ReadingTarget(book: book, position: position)
    }

    private func timestamp(_ date: Date) -> some View {
        Text(date, format: .dateTime.year().month().day().hour().minute())
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    /// Says where marks come from. Someone reaching an empty list has not found the way
    /// to make one yet, and this is the only screen that can point at it — including how
    /// much each reader marks, which is a difference nobody discovers by trying.
    @ViewBuilder
    private var emptyState: some View {
        switch kind {
        case .bookmarks where bookmarks.isEmpty:
            ContentUnavailableView {
                Label("bookmarks.empty", systemImage: "bookmark")
            } description: {
                Text("bookmarks.empty.hint")
            }
        case .highlights where highlights.isEmpty:
            ContentUnavailableView {
                Label("highlights.empty", systemImage: "highlighter")
            } description: {
                Text("highlights.empty.hint")
            }
        default:
            EmptyView()
        }
    }

    private func load() {
        bookmarks = (try? env.repo.readingBookmarks(bookId: book.id)) ?? []
        highlights = (try? env.repo.highlights(bookId: book.id)) ?? []
        chapterTitles = Dictionary(
            uniqueKeysWithValues: ((try? env.repo.chapters(bookId: book.id)) ?? [])
                .map { ($0.siteChapterId, $0.title) }
        )
    }
}
