import Foundation
import GRDB

/// One chapter of one book that holds what the reader searched for.
struct LibraryTextHit: Identifiable {
    let book: Book
    /// The chapter's own title, read from the catalog rather than stored beside the
    /// index — a title the site has since corrected should read correctly here too, the
    /// same way `ReadingMarksView` resolves it.
    let chapterTitle: String
    let siteChapterId: String
    let excerpt: FullTextExcerpt

    var id: String { Chapter.makeId(bookId: book.id, siteChapterId: siteChapterId) }

    /// Where tapping the row goes: not merely the chapter, but the paragraph the
    /// sentence is in.
    ///
    /// The excerpt already had to find the passage in order to quote it, so the anchor
    /// costs nothing extra — and landing on the chapter's first page would make the
    /// reader hunt for the thing they just searched for.
    var target: ReadingTarget {
        ReadingTarget(
            book: book,
            position: ReadingPosition(
                siteChapterId: siteChapterId,
                anchor: TextAnchor(
                    paragraph: excerpt.paragraph, characterOffset: excerpt.characterOffset
                )
            )
        )
    }
}

/// Searching the text of the chapters this device has actually downloaded.
///
/// The app's three other search fields all ask a *site* something — for books, or for a
/// chapter by its name. This one asks the device, and it is the only one that can answer
/// the question a reader of a four-hundred-chapter novel actually has: I remember a
/// sentence, which chapter was it in.
///
/// Strictly what is on the device, and that is a feature rather than a limitation. A
/// result is only worth offering if tapping it opens text, so the index is joined to
/// `Chapter.downloadedAt` and every hit is confirmed by opening the file it names. A
/// chapter that was deleted between the two is simply not in the answer.
struct LibrarySearch {
    let database: AppDatabase
    let files: ChapterFileStore
    let repo: LibraryRepo

    /// Below this a search is not worth running. One character matches most chapters of
    /// most books, so it is not a search — it is a slow way to list the library — and
    /// the screen shows its prompt instead.
    static let minimumQueryLength = 2

    /// How many rows the list is willing to show.
    ///
    /// A reader scanning results is looking for one passage, and a search that answers
    /// with six hundred chapters has not narrowed anything down. Capping also caps the
    /// work: the confirming pass opens one file per candidate, and it stops as soon as
    /// the list is full.
    static let maximumResults = 50

    /// How many chapters the confirming pass is willing to open before giving up.
    ///
    /// Generous, because the index rarely proposes a chapter that does not hold the
    /// phrase — the conjunction of overlapping trigrams is a tight filter, measured at no
    /// false positives over a three-thousand-chapter library. This is the ceiling for
    /// when it is wrong, not the expected cost.
    static let candidateLimit = 400

    /// The chapters holding `query`, in reading order within each book.
    ///
    /// Two passes. The database narrows a whole library down to a handful of candidates,
    /// then each candidate's file is opened to find the passage, quote it in the script
    /// it was stored in, and say which paragraph it is in. The second pass is what makes
    /// the answer honest: a candidate whose file is missing, or whose text no longer
    /// holds the words, produces no excerpt and is dropped rather than offered as a row
    /// that opens onto nothing.
    func hits(for query: String) throws -> [LibraryTextHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.minimumQueryLength else { return [] }

        let candidates = try database.writer.read { db in
            try FullTextIndex.candidates(for: trimmed, limit: Self.candidateLimit, in: db)
        }
        guard !candidates.isEmpty else { return [] }

        // One lookup for the whole answer rather than one per row: a search that spans
        // six books should not be six round trips, and the shelf is already small.
        let books = Dictionary(
            uniqueKeysWithValues: try repo.allBooks().map { ($0.id, $0) }
        )

        var hits: [LibraryTextHit] = []
        for candidate in candidates {
            guard hits.count < Self.maximumResults else { break }
            guard let book = books[candidate.bookId] else { continue }
            guard let paragraphs = try? files.readParagraphs(
                siteId: book.siteId, siteBookId: book.siteBookId,
                siteChapterId: candidate.siteChapterId
            ) else { continue }
            guard let excerpt = FullTextExcerpt.first(of: trimmed, in: paragraphs) else {
                continue
            }
            hits.append(
                LibraryTextHit(
                    book: book, chapterTitle: candidate.title,
                    siteChapterId: candidate.siteChapterId, excerpt: excerpt
                )
            )
        }
        return hits
    }
}
