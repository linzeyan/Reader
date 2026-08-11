import SwiftUI

/// One book's saved positions, in reading order.
///
/// Reached from the book's own screen rather than from a control in the reader: the
/// reader's bottom bar is already the width of a thumb divided six ways, and coming
/// back to a saved place is something a reader does on the way *into* a book, from
/// the screen that also holds the catalog and the downloads.
struct BookmarkListView: View {
    let book: Book

    @Environment(AppEnvironment.self) private var env
    @State private var bookmarks: [ReadingBookmark] = []
    /// Chapter titles by index, so a row can name its chapter. Read from the stored
    /// catalog rather than denormalised into the bookmark: a title the site has since
    /// corrected should read correctly here too.
    @State private var chapterTitles: [Int: String] = [:]

    var body: some View {
        List {
            ForEach(bookmarks) { bookmark in
                NavigationLink(value: ReadingTarget(book: book, position: bookmark.position)) {
                    row(bookmark)
                }
                .accessibilityIdentifier("bookmarks.row")
                // No confirmation, unlike deleting an imported book: this throws away
                // a pointer, not the text it points at. See `LibraryView`, which draws
                // the same line.
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        delete(bookmark)
                    } label: {
                        Label("common.delete", systemImage: "trash")
                    }
                }
            }
        }
        .overlay { if bookmarks.isEmpty { emptyState } }
        .navigationTitle("bookmarks.title")
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
    }

    private func row(_ bookmark: ReadingBookmark) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            chapterName(bookmark)
                .font(.subheadline)
                .lineLimit(1)
            // The excerpt is what makes the list readable without opening anything,
            // so it gets the room: two lines of the paragraph the bookmark sits on.
            if let excerpt = bookmark.excerpt, !excerpt.isEmpty {
                Text(excerpt)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(bookmark.createdAt, format: .dateTime.year().month().day().hour().minute())
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    /// The chapter's own title when the catalog has one, and its number when it does
    /// not — a bookmark can outlive a chapter that a catalog refresh dropped, and a
    /// row with no name at all would be unreadable.
    private func chapterName(_ bookmark: ReadingBookmark) -> Text {
        if let title = chapterTitles[bookmark.chapterIndex] {
            return Text(title)
        }
        return Text("bookmarks.chapter \(bookmark.chapterIndex + 1)")
    }

    /// Says where bookmarks come from. Someone reaching an empty list has not found
    /// the button in the reader yet, and this is the only screen that can point at it.
    private var emptyState: some View {
        ContentUnavailableView {
            Label("bookmarks.empty", systemImage: "bookmark")
        } description: {
            Text("bookmarks.empty.hint")
        }
    }

    private func load() {
        bookmarks = (try? env.repo.readingBookmarks(bookId: book.id)) ?? []
        chapterTitles = Dictionary(
            uniqueKeysWithValues: ((try? env.repo.chapters(bookId: book.id)) ?? [])
                .map { ($0.index, $0.title) }
        )
    }

    /// Removed from the array as well as from the database rather than reloading:
    /// the row has to leave with the swipe's own animation.
    private func delete(_ bookmark: ReadingBookmark) {
        try? env.repo.removeReadingBookmark(id: bookmark.id)
        bookmarks.removeAll { $0.id == bookmark.id }
    }
}
