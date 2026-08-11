import Foundation
import GRDB

/// Where something sits inside one chapter's text.
///
/// Paragraph index plus a character offset inside that paragraph — never a scroll
/// distance. Type size, line spacing and the theme's padding all change how far
/// down a chapter a given sentence lands, so a stored distance quietly starts
/// naming a different sentence the moment any of them is adjusted. Paragraph
/// coordinates survive all three, and they survive the move to paginated TextKit 2
/// layout, where there is no scroll distance left to store at all.
struct TextAnchor: Codable, Hashable {
    /// Index into the chapter's paragraph array, as the site rule split it.
    var paragraph: Int
    /// Offset from the start of that paragraph, in UTF-16 code units.
    ///
    /// UTF-16 rather than a `Character` count because the text engine this is being
    /// aimed at works in `NSRange`; changing the unit later would mean re-resolving
    /// every stored anchor against text the app may no longer be able to fetch.
    ///
    /// A scroll view can only report which paragraph came into view, so today this
    /// is always 0. It is persisted anyway, because the anchor *is* the storage
    /// format: adding the field later means a second migration over positions
    /// nothing can re-derive. It is also the piece a paragraph index alone cannot
    /// express — a highlight is a pair of these, which is why the anchor is a value
    /// type of its own rather than two columns hung off `Book`.
    var characterOffset: Int

    static let start = TextAnchor(paragraph: 0, characterOffset: 0)
}

extension TextAnchor {
    /// The view identity of one paragraph.
    ///
    /// Shared by the reader's `ForEach` ids and by the scroll target derived from an
    /// anchor, so the two cannot drift apart and leave a jump silently landing
    /// nowhere.
    static func paragraphID(chapterId: String, paragraph: Int) -> String {
        "\(chapterId)#\(paragraph)"
    }

    /// Where a jump to this anchor should scroll to.
    ///
    /// The first paragraph resolves to the chapter itself so its heading stays on
    /// screen: arriving at a chapter with the title already scrolled off reads as
    /// having landed in the wrong place.
    func scrollID(chapterId: String) -> String {
        paragraph <= 0 ? chapterId : Self.paragraphID(chapterId: chapterId, paragraph: paragraph)
    }

    /// A short lead-in from the anchored paragraph, for a list that has to say
    /// *where* a saved position points without opening the chapter.
    ///
    /// Taken from the start of the paragraph rather than from `characterOffset`: the
    /// excerpt is there to be recognised, and a fragment beginning mid-sentence is
    /// harder to place than the sentence itself.
    func excerpt(in paragraphs: [String], limit: Int = 60) -> String? {
        guard paragraphs.indices.contains(paragraph) else { return nil }
        let text = paragraphs[paragraph].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }
}

/// A span of one chapter the reader picked out, before it becomes a stored mark.
///
/// Carries the quoted text alongside the two anchors because the text is only
/// available at the moment of selection: a chapter read online is held in memory
/// only, and the list that has to say *what* was marked cannot go back for it.
struct TextSelection: Equatable {
    var start: TextAnchor
    var end: TextAnchor
    /// Exactly the characters between the two anchors, separators included.
    var text: String

    /// Long enough to recognise a passage in a list, short enough that marking half
    /// a chapter does not put half a chapter in the database. The list is an index
    /// into the book, not a second copy of it.
    private static let excerptLimit = 120

    var excerpt: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= Self.excerptLimit
            ? trimmed
            : String(trimmed.prefix(Self.excerptLimit)) + "…"
    }
}

/// A place in a book: which chapter, and where inside it.
struct ReadingPosition: Codable, Hashable {
    var chapterIndex: Int
    var anchor: TextAnchor

    /// Opening a chapter from the catalog, where the reader has expressed no
    /// opinion about a position within it.
    static func chapterStart(_ index: Int) -> ReadingPosition {
        ReadingPosition(chapterIndex: index, anchor: .start)
    }
}

/// A position the reader saved to come back to.
///
/// Named `ReadingBookmark` because "bookmark" was already taken: `LibraryRepo`
/// uses it for putting a *book* on the shelf (see `Book`), and two unrelated
/// meanings of one word in one repository is how the wrong one gets called.
///
/// Deliberately not synced to iCloud — the reasoning lives in `CloudSync`.
struct ReadingBookmark: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "readingBookmark"

    /// Derived from the position, not from insert order — see `makeId`.
    var id: String
    var bookId: String
    var chapterIndex: Int
    var paragraph: Int
    var characterOffset: Int
    var createdAt: Date
    /// The opening of the anchored paragraph, captured when the bookmark was made.
    /// Optional because a chapter read online and never downloaded can have no text
    /// on the device by the time the list is drawn, and an empty row is a better
    /// answer than a fabricated one.
    var excerpt: String?

    var position: ReadingPosition {
        ReadingPosition(
            chapterIndex: chapterIndex,
            anchor: TextAnchor(paragraph: paragraph, characterOffset: characterOffset)
        )
    }

    /// Identity is the position itself, the same way `Book.id` is derived from its
    /// source: bookmarking the same sentence twice has to collapse onto one row.
    /// With a UUID id, a reader tapping the button on a page they already saved
    /// would stack up rows that all jump to the same place, and the storage layer
    /// could not tell that they were duplicates.
    static func makeId(bookId: String, position: ReadingPosition) -> String {
        "\(bookId)|\(position.chapterIndex)|\(position.anchor.paragraph)|\(position.anchor.characterOffset)"
    }

    init(bookId: String, position: ReadingPosition, createdAt: Date, excerpt: String?) {
        self.id = Self.makeId(bookId: bookId, position: position)
        self.bookId = bookId
        self.chapterIndex = position.chapterIndex
        self.paragraph = position.anchor.paragraph
        self.characterOffset = position.anchor.characterOffset
        self.createdAt = createdAt
        self.excerpt = excerpt
    }
}

/// A passage the reader drew a line under.
///
/// A *pair* of anchors, which is what a bookmark is not: a bookmark says "come back
/// here", a highlight says "these characters". That is why `TextAnchor` carries a
/// character offset at all — half of a highlight is meaningless without one.
///
/// The anchors are stored flat rather than as two embedded `TextAnchor`s so the two
/// ends can be ordered in SQL; the list is read back in reading order, and a JSON
/// blob cannot be sorted by.
///
/// Deliberately not synced to iCloud — the reasoning lives in `CloudSync`.
struct TextHighlight: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "textHighlight"

    /// Derived from the span, not from insert order — see `makeId`.
    var id: String
    var bookId: String
    var chapterIndex: Int
    var startParagraph: Int
    var startCharacterOffset: Int
    var endParagraph: Int
    var endCharacterOffset: Int
    var createdAt: Date
    /// The marked text, captured when the mark was made, so the list can say what was
    /// marked without opening the chapter. Never optional, unlike a bookmark's
    /// excerpt: a highlight can only be made out of text that was on screen.
    var excerpt: String

    var start: TextAnchor {
        TextAnchor(paragraph: startParagraph, characterOffset: startCharacterOffset)
    }

    var end: TextAnchor {
        TextAnchor(paragraph: endParagraph, characterOffset: endCharacterOffset)
    }

    /// Where a jump from the marks list lands: the start of the passage, which is the
    /// only end of it the reader is looking for.
    var position: ReadingPosition {
        ReadingPosition(chapterIndex: chapterIndex, anchor: start)
    }

    /// Identity is the span, the same way `ReadingBookmark`'s is its position: drawing
    /// a line under the same sentence twice has to collapse onto one row, or the
    /// second tap would stack an invisible duplicate that takes two deletes to remove.
    static func makeId(bookId: String, chapterIndex: Int, selection: TextSelection) -> String {
        [
            bookId, String(chapterIndex),
            String(selection.start.paragraph), String(selection.start.characterOffset),
            String(selection.end.paragraph), String(selection.end.characterOffset),
        ].joined(separator: "|")
    }

    init(bookId: String, chapterIndex: Int, selection: TextSelection, createdAt: Date) {
        self.id = Self.makeId(bookId: bookId, chapterIndex: chapterIndex, selection: selection)
        self.bookId = bookId
        self.chapterIndex = chapterIndex
        self.startParagraph = selection.start.paragraph
        self.startCharacterOffset = selection.start.characterOffset
        self.endParagraph = selection.end.paragraph
        self.endCharacterOffset = selection.end.characterOffset
        self.createdAt = createdAt
        self.excerpt = selection.excerpt
    }
}

extension TextHighlight {
    /// Which characters of one paragraph this highlight covers, or nil when it does
    /// not reach that paragraph.
    ///
    /// The single place both renderers ask, which is what makes them agree. The
    /// paginated reader paints bands behind laid-out glyphs and the scrolling reader
    /// tints a run of an `AttributedString`; they share no drawing code at all, so the
    /// only way one highlight can look like one passage in both is for both to be
    /// told the same character ranges.
    ///
    /// Clamped against the paragraph it is given rather than trusted: a chapter
    /// re-fetched from the site can come back with shorter paragraphs, and a range
    /// past the end of the text would crash the renderer that is handed it.
    func range(inParagraph index: Int, length: Int) -> NSRange? {
        guard index >= startParagraph, index <= endParagraph, length > 0 else { return nil }
        let from = index == startParagraph ? min(max(startCharacterOffset, 0), length) : 0
        let to = index == endParagraph ? min(max(endCharacterOffset, 0), length) : length
        guard to > from else { return nil }
        return NSRange(location: from, length: to - from)
    }
}
