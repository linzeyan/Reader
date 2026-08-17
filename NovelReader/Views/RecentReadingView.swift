import SwiftUI

/// The app's first screen: the books the reader has been in, newest first, each one
/// a tap away from the sentence they stopped at.
///
/// First because it is the answer to why someone opens a reader at all. The shelf is
/// where a library is *managed* — renamed, filtered, deleted, added to — and it grows
/// until finding tonight's book among forty of them is itself a task. This list never
/// grows: it holds the two or three books anybody is actually reading.
///
/// It is deliberately not a fourth arrangement of the shelf. A shelf row leads to the
/// book's screen, where the catalog and the downloads are; a row here leads straight
/// into the text, because the only thing being asked is "carry on".
struct RecentReadingView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        NavigationStack {
            Group {
                let entries = env.visibleRecentReads
                if entries.isEmpty {
                    emptyState
                } else {
                    List(entries) { row($0) }
                        .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("tab.recent")
            .navigationDestination(for: ReadingTarget.self) { target in
                ReaderView(book: target.book, position: target.position)
            }
        }
    }

    private func row(_ entry: RecentRead) -> some View {
        NavigationLink(value: target(for: entry)) {
            HStack(spacing: 12) {
                CoverImage(urlString: entry.book.coverURL)
                    .frame(width: 44, height: 60)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.book.shownName).font(.body).lineLimit(2)
                    // Which chapter by name, not by number, and this is the one place in
                    // the app that says it that way. The shelf shows "第 12 章" because it
                    // is comparing forty books against each other; here there is one
                    // question — is this the bit I remember — and the chapter's own title
                    // answers it where a number never could.
                    chapterName(entry)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    detail(entry)
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityIdentifier("recent.book")
    }

    /// The chapter's own title, or a note that the site has dropped it — the same thing
    /// the marks list says, for the same reason: a row that names nothing is a row the
    /// reader cannot place.
    private func chapterName(_ entry: RecentRead) -> Text {
        guard let title = entry.chapterTitle else { return Text("marks.chapter.missing") }
        return Text(title)
    }

    /// How far in, and whether that is the end of the book.
    ///
    /// "已讀完" replaces the share rather than sitting beside it: a row reading
    /// "100% · 已讀完" says one thing twice, and the badge is the part worth reading —
    /// it is what tells someone scanning the list which books are still open to them.
    @ViewBuilder
    private func detail(_ entry: RecentRead) -> some View {
        if entry.isFinished {
            Text("recent.finished")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        } else if let index = entry.chapterIndex {
            progress(entry, chapterIndex: index)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
    }

    /// The chapter's number alongside the book's length, because "第 340 章" means
    /// nothing on its own and "第 340 / 1302 章" is how much is left — which is the
    /// question a list of half-read books raises. The share comes with it only where one
    /// was recorded; see `Book.lastReadFraction`.
    private func progress(_ entry: RecentRead, chapterIndex: Int) -> Text {
        guard let fraction = entry.book.lastReadFraction else {
            return Text("recent.progress \(chapterIndex + 1) \(entry.chapterCount)")
        }
        return Text(
            "recent.progress.share \(chapterIndex + 1) \(entry.chapterCount) \(TextAnchor.shareText(fraction))"
        )
    }

    /// Where a row leads, or nil for a book whose chapter the site has dropped.
    ///
    /// The same line `ReadingMarksView` draws: the entry stays, because the reader did
    /// read this book, but it is not offered as a destination — there is nowhere left to
    /// send them, and the first chapter is not a lesser answer, it is the wrong one for
    /// somebody four hundred chapters in.
    private func target(for entry: RecentRead) -> ReadingTarget? {
        guard entry.chapterTitle != nil, let position = entry.position else { return nil }
        return ReadingTarget(book: entry.book, position: position)
    }

    /// Reached by a fresh install, and by a reader who has just cleared the history.
    /// Both need pointing at the shelf, which is the only place a book can come from.
    private var emptyState: some View {
        ContentUnavailableView {
            Label("recent.empty", systemImage: "clock")
        } description: {
            Text("recent.empty.hint")
        }
    }
}
