import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// One book's bookmarks and highlights, written out as a document the reader can take
/// out of the app.
///
/// Markdown, decided by where the file is going rather than by what is easiest to write:
/// a reader who has drawn two hundred lines under a novel is taking them to a notes app
/// — Obsidian, Bear, Craft and Notion all read Markdown — and there the chapter names
/// become an outline and every marked passage becomes a quotation. Being wrong about
/// that costs nothing, which is the other half of the reason: Markdown nothing parses is
/// still the text with two hash marks in front of a chapter name, so the same file reads
/// perfectly well pasted into a message or opened in any editor.
///
/// What a mark's *position* may honestly be called is the one thing this had to decide
/// for itself. A mark stores a paragraph index and a character offset, and those mean
/// something only under the site rule version that split that chapter into those
/// paragraphs — which is why marks are not synced between devices at all (see
/// `CloudSync`). Writing such a number into a file that leaves the device would hand the
/// reader a coordinate nothing can resolve afterwards, this app included. So a mark is
/// placed by its chapter — whose id came from the site and is stored for exactly this
/// reason, see `ReadingBookmark.siteChapterId` — and by where it falls in a document
/// that runs in reading order. Anything finer is the quoted text itself, which a reader
/// can search for.
///
/// Holds the rows rather than the finished string, so that the screen can build one of
/// these every time it draws without doing the work: the document is written when the
/// share sheet actually asks for it. See the `Transferable` conformance below.
struct MarksExport {
    let book: Book
    /// The book's stored catalog, in reading order. What puts the marks in the order the
    /// book runs in — see `sections()`.
    let chapters: [Chapter]
    let bookmarks: [ReadingBookmark]
    let highlights: [TextHighlight]

    /// Whether there is anything to take away.
    ///
    /// The one definition of it, read by the screen to disable its own share button: a
    /// file with a title and no passages under it looks like an export that went wrong,
    /// and the reader would have no way to tell that from one that did.
    var isEmpty: Bool { bookmarks.isEmpty && highlights.isEmpty }

    /// `<book> <marks>.md`.
    ///
    /// The book's part goes through the book exporter's own cleaner: this name lands in
    /// a share sheet exactly the way a book export's does, and a title made of characters
    /// a filesystem refuses is the same problem in both places. The suffix is appended
    /// afterwards rather than cleaned with it, so that a title long enough to hit the
    /// cleaner's length cap cannot eat the word that says what the file is.
    var filename: String {
        "\(BookExporter.filename(from: book.shownName)) \(String(localized: "marks.title")).md"
    }

    /// The document.
    ///
    /// - Parameter now: what the summary line is stamped with; a parameter so a test can
    ///   pin it.
    func text(now: Date = Date()) -> String {
        var blocks = ["# \(book.shownName)"]
        // A blank author is not an absent one until it is made so here — sites whose
        // author element exists with nothing in it store `""`, the case
        // `BookExporter.author(of:)` folds away for the same reason — and an empty
        // byline under the title reads as a book whose author we lost.
        if let author = book.author?.trimmingCharacters(in: .whitespacesAndNewlines),
           !author.isEmpty {
            blocks.append(author)
        }
        blocks.append(summary(now: now))
        for section in sections() {
            blocks.append("## \(section.title)")
            blocks.append(contentsOf: section.marks.map(Self.block))
        }
        // Blocks joined by a blank line because that is what separates them in Markdown,
        // and a trailing newline so the last line is a line rather than a fragment — the
        // same ending the book's own text export writes.
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// What the file says about itself: how much is in it, and when it was taken.
    ///
    /// The count is there so a reader can tell a whole export from one made before they
    /// finished marking the book. The date is written `2026-09-21` rather than in the
    /// reader's short local format, because a file that outlives the device it came from
    /// must not carry a date that reads as March in one country and April in another —
    /// the same stamp, for the same reason, that the diagnostics log is named with. Their
    /// time zone is the reader's own: this is the day they pressed the button, not the
    /// day it was in Greenwich.
    private func summary(now: Date) -> String {
        let day = now.formatted(
            Date.ISO8601FormatStyle(timeZone: .current).year().month().day().dateSeparator(.dash)
        )
        return String(
            localized: "marks.export.summary \(highlights.count) \(bookmarks.count) \(day)"
        )
    }

    /// The chapters that have marks, in reading order, each with its own marks in the
    /// order they sit in the chapter.
    ///
    /// The order comes from the catalog rather than from the marks: a reader asked for a
    /// summary they can read from the top, not the log of when they tapped, and only the
    /// catalog knows which chapter comes first. It is the order the list on screen runs
    /// in too — `LibraryRepo.highlights(bookId:)` sorts through the same join — so the
    /// file cannot disagree with the screen it was made from.
    ///
    /// A mark whose chapter the site has dropped keeps a section of its own at the end,
    /// under the name the marks list gives it. Grouped per chapter rather than pooled
    /// into one run, because two dropped chapters are two chapters and one heading over
    /// both would interleave passages from different parts of the book. Their sections
    /// can only be put in id order: the thing that knew their reading order is the
    /// catalog that no longer lists them.
    private func sections() -> [(title: String, marks: [Mark])] {
        let bookmarksByChapter = Dictionary(grouping: bookmarks, by: \.siteChapterId)
        let highlightsByChapter = Dictionary(grouping: highlights, by: \.siteChapterId)
        let marks = { (chapterId: String) in
            Self.ordered(
                bookmarks: bookmarksByChapter[chapterId] ?? [],
                highlights: highlightsByChapter[chapterId] ?? []
            )
        }

        var sections = chapters
            .map { chapter in (title: chapter.title, marks: marks(chapter.siteChapterId)) }
            .filter { !$0.marks.isEmpty }

        let listed = Set(chapters.map(\.siteChapterId))
        let dropped = Set(bookmarksByChapter.keys)
            .union(highlightsByChapter.keys)
            .subtracting(listed)
        let droppedTitle: String.LocalizationValue =
            book.kind == .feed ? "marks.article.missing" : "marks.chapter.missing"
        sections += dropped.sorted().map {
            (title: String(localized: droppedTitle), marks: marks($0))
        }
        return sections
    }

    /// One chapter's marks of both kinds, in the order the chapter is read.
    ///
    /// Both kinds in one run rather than a section each, for the reason the screen shows
    /// them on one screen: to a reader they are one thing — what I left in this book —
    /// and somebody following a chapter down the page wants the passage and the place
    /// they saved where they meet them, not in two passes over the same chapter.
    private static func ordered(
        bookmarks: [ReadingBookmark], highlights: [TextHighlight]
    ) -> [Mark] {
        (highlights.map(Mark.highlight) + bookmarks.map(Mark.bookmark))
            .sorted { $0.order.lexicographicallyPrecedes($1.order) }
    }

    /// A mark of either kind, so that one chapter's worth of them can be put in one
    /// order.
    private enum Mark {
        case highlight(TextHighlight)
        case bookmark(ReadingBookmark)

        /// Where the mark begins, then where it ends, then which kind it is — compared in
        /// that order.
        ///
        /// A *total* order, because `sorted` is not stable and a document that shuffles
        /// two passages between exports is one nobody can diff against their last copy.
        /// The far end separates two highlights that begin on the same character, and the
        /// kind separates a highlight from a bookmark sitting on it: the highlight goes
        /// first, because it carries words the reader picked out and the bookmark only a
        /// place. A bookmark points rather than covers, so both its ends are the same.
        var order: [Int] {
            switch self {
            case .highlight(let highlight):
                return [
                    highlight.startParagraph, highlight.startCharacterOffset,
                    highlight.endParagraph, highlight.endCharacterOffset, 0,
                ]
            case .bookmark(let bookmark):
                return [
                    bookmark.paragraph, bookmark.characterOffset,
                    bookmark.paragraph, bookmark.characterOffset, 1,
                ]
            }
        }
    }

    /// One mark as a block of the document.
    ///
    /// A highlight is quoted and a bookmark is labelled, which is not decoration: a
    /// highlight's excerpt is the text the reader themselves drew a line under, while a
    /// bookmark's was taken automatically from the head of the paragraph it landed on
    /// (`TextAnchor.excerpt(in:)`). Quoting both the same way would put words in the
    /// reader's mouth that they never chose.
    private static func block(_ mark: Mark) -> String {
        switch mark {
        case .highlight(let highlight):
            return quoted(highlight.excerpt)
        case .bookmark(let bookmark):
            // A bookmark can have no excerpt at all — a chapter read online and never
            // downloaded has no text on the device to take one from. The line still goes
            // in, saying only that a bookmark was here: dropping it would quietly lose
            // one of the marks the reader asked to take with them.
            let excerpt = bookmark.excerpt?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let excerpt, !excerpt.isEmpty else {
                return "- \(String(localized: "marks.export.bookmark"))"
            }
            return "- \(String(localized: "marks.export.bookmark \(excerpt)"))"
        }
    }

    /// A blockquote, with the marker repeated on every line.
    ///
    /// A highlight can run across paragraphs — `TextSelection.text` keeps the separators
    /// between them — and a second line without the marker falls out of the quote.
    ///
    /// The passage itself goes in exactly as it was marked, with no Markdown escaping. A
    /// backslash in front of every `*` would protect the rendering at the cost of putting
    /// characters into the reader's own words, and those words are the whole of what this
    /// file is for; the worst an unescaped one costs is a run of emphasis in a viewer.
    private static func quoted(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? ">" : "> \($0)" }
            .joined(separator: "\n")
    }
}

/// How the marks leave the app: the system share sheet, and nothing else. There is no
/// account and no server to send them to, and there must never be one.
///
/// A share sheet rather than the save sheet a book export gets, because these are not
/// the same errand. A novel is a document somebody files away, which is what
/// `BookExportDocument` says; two hundred highlights are something somebody sends —
/// into a notes app, into a message, onto a computer — and only the share sheet reaches
/// those. The objection that kept a `ShareLink` away from the book export does not hold
/// here: it needs its contents when the button is *drawn*, which would mean writing out
/// a whole novel on the chance somebody taps it, while this representation is asked for
/// the bytes only once a share is actually happening — and by then the marks are already
/// in memory, because the screen offering the button is displaying them.
///
/// `.plainText` because the type that names Markdown exactly, `net.daringfireball
/// .markdown`, arrived in iOS 27 and this app is built back to 17. It is not a lie:
/// Markdown is declared as conforming to plain text, every receiver can open it, and the
/// `.md` on the suggested name is what a notes app reads to decide how to render it.
extension MarksExport: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { export in
            Data(export.text().utf8)
        }
        .suggestedFileName { $0.filename }
    }
}
