import SwiftUI

/// Searching the text of the books already on this device.
///
/// The other side of the search tab. Where that one asks sites for books the reader does
/// not have yet, this one asks the device about the ones they do — and answers the
/// question a reader four hundred chapters into a novel actually has, which is not "what
/// shall I read" but "which chapter was that in".
///
/// A row quotes the sentence rather than naming the chapter, and the chapter follows
/// underneath. That is `ReadingMarksView`'s highlight row and it is the same reasoning: a
/// passage is remembered by what it says, not by where it was, so the words have to lead
/// or the list cannot be scanned at all.
struct LibraryTextSearchView: View {
    @Environment(AppEnvironment.self) private var env

    /// Owned by the search tab, which holds the one search field both modes type into —
    /// so switching modes carries the query across instead of making the reader type it
    /// again.
    let query: String

    @State private var hits: [LibraryTextHit] = []
    @State private var searching = false
    /// Whether the query on screen has actually been answered, so "no results" is only
    /// ever shown about a finished search rather than about one still running.
    @State private var answered = false

    var body: some View {
        List {
            ForEach(hits) { hit in
                row(hit)
            }
        }
        .overlay { status }
        // Keyed on the query, so a new keystroke cancels the search in flight — which is
        // what makes the pause below a debounce rather than a delay added to every
        // search.
        .task(id: query) { await run() }
    }

    private func row(_ hit: LibraryTextHit) -> some View {
        Button {
            // The same handoff the reading history uses, and for the same reason: books
            // live in the library tab, and opening one here would make the search tab a
            // second home for them — so backing out of the reader would land on a search
            // instead of on the shelf. See `AppEnvironment.readingHandoff`.
            env.readingHandoff = hit.target
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(quotation(hit))
                    .font(.subheadline)
                    .lineLimit(3)
                HStack(spacing: 4) {
                    // Which medium, because this list mixes novels and subscriptions —
                    // the shelf's own mode has not narrowed anything here.
                    Image(systemName: hit.book.kind.icon)
                    Text(hit.book.shownName)
                    Text(verbatim: "·")
                    Text(hit.chapterTitle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .padding(.vertical, 2)
        }
        .tint(.primary)
        .accessibilityIdentifier("library.text.result")
    }

    /// The quoted sentence with the searched-for run picked out.
    ///
    /// Assembled from the three pieces rather than by searching the quotation for the
    /// query: the two need not be in the same script — a traditional query matches a
    /// simplified chapter through the fold — so looking for the query as typed would
    /// emphasise nothing. `FullTextExcerpt` already knows exactly where it is.
    private func quotation(_ hit: LibraryTextHit) -> AttributedString {
        let source = hit.excerpt.text
        var result = AttributedString(source[source.startIndex ..< hit.excerpt.match.lowerBound])
        var matched = AttributedString(source[hit.excerpt.match])
        matched.font = .subheadline.weight(.semibold)
        result += matched
        result += AttributedString(source[hit.excerpt.match.upperBound...])
        return result
    }

    /// What the list says when it has no rows.
    ///
    /// The empty result deliberately explains the boundary rather than just reporting
    /// nothing. "Not found" and "not downloaded, so never looked at" are different
    /// answers, and a reader who does not know this only searches what is on the device
    /// would read the first as the second and conclude the feature is broken.
    @ViewBuilder
    private var status: some View {
        if searching && hits.isEmpty {
            ProgressView()
        } else if query.trimmingCharacters(in: .whitespacesAndNewlines).count
            < LibrarySearch.minimumQueryLength {
            ContentUnavailableView {
                Label("library.text.search.title", systemImage: "text.magnifyingglass")
            } description: {
                Text("library.text.search.hint")
            }
        } else if answered && hits.isEmpty {
            ContentUnavailableView {
                Label("library.text.search.none", systemImage: "text.magnifyingglass")
            } description: {
                Text("library.text.search.none.hint")
            }
        }
    }

    private func run() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= LibrarySearch.minimumQueryLength else {
            hits = []
            answered = false
            return
        }
        // Someone typing 「玄重尺」 produces three queries in about as many tenths of a
        // second, and only the last one is a question. Cancellation does the rest.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }

        searching = true
        defer { searching = false }
        let search = env.librarySearch
        // Off the main actor: the index query is fast, but the pass that confirms each
        // hit opens one file per candidate, and this runs while the reader is still
        // typing into the field above it.
        let found = await Task.detached(priority: .userInitiated) {
            (try? search.hits(for: trimmed)) ?? []
        }.value
        guard !Task.isCancelled else { return }
        hits = found
        answered = true
    }
}
