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
    /// Real in both renderers. It was 0 for every scrolled position until the reader
    /// drew its own text: a lazy stack of `Text` knew only which paragraph had come
    /// into view, so a scrolled position always named the *top of a paragraph* — and in
    /// these books a paragraph routinely runs taller than a screen, which is how
    /// switching modes mid-paragraph threw the reader pages backwards. A laid-out
    /// column knows which character the top line of the window begins on.
    ///
    /// It is also the piece a paragraph index alone cannot express — a highlight is a
    /// pair of these, which is why the anchor is a value type of its own rather than
    /// two columns hung off `Book`.
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

    /// How far into a chapter this anchor sits, as a share of its text.
    ///
    /// Measured in UTF-16 units over the paragraphs themselves — the unit the offset is
    /// already stored in — so it means the same thing at every type size, which neither a
    /// scroll distance nor a page number does. Separators between paragraphs are not
    /// counted: how the text is joined is a property of the renderer, not of the chapter.
    ///
    /// Computed while the chapter is on screen and then stored, because the screens that
    /// want it hold no text: turning a paragraph index into a share needs the chapter,
    /// and the shelf has only the book row.
    ///
    /// Clamped rather than trusted, for the same reason `landingAnchor` clamps: a chapter
    /// refetched from the site can come back shorter than when the position was recorded,
    /// and an anchor past its end has read all of it.
    func fraction(in paragraphs: [String]) -> Double {
        let lengths = paragraphs.map { ($0 as NSString).length }
        let total = lengths.reduce(0, +)
        guard total > 0 else { return 0 }
        let before = lengths.prefix(max(0, paragraph)).reduce(0, +)
        let inside = lengths.indices.contains(paragraph)
            ? min(max(characterOffset, 0), lengths[paragraph])
            : 0
        return min(1, Double(before + inside) / Double(total))
    }

    /// The anchor at the far end of a paragraph — where a reader who can see the whole
    /// of it has read to.
    ///
    /// Used to turn "the bottom of the screen" into a share; `fraction(in:)` clamps the
    /// offset against the paragraph it is handed, so this is the honest end of it rather
    /// than a number that has to be trusted.
    static func endOfParagraph(_ index: Int, in paragraphs: [String]) -> TextAnchor {
        let length = paragraphs.indices.contains(index) ? (paragraphs[index] as NSString).length : 0
        return TextAnchor(paragraph: index, characterOffset: length)
    }

    /// A share of a chapter cut down to what the app is willing to claim it is.
    ///
    /// Rounded *down* to the whole percent it will be shown as, because "100%" with text
    /// still to come is the one number the reader could catch out — and because the
    /// reading history reads a full 100% as "this book is finished", which is a claim
    /// that must not be reachable one paragraph early.
    ///
    /// Here rather than in either renderer, next to `shareText`: both of them measure
    /// a share and both have to state it the same way, or one book would be finished in
    /// paged reading and not in scrolled.
    static func claimedShare(_ raw: Double) -> Double {
        min(1, max(0, (raw * 100).rounded(.down) / 100))
    }

    /// How a share of a chapter is written, wherever one is shown: the reader's floating
    /// capsule, the shelf row, the pinned row above a catalog.
    ///
    /// One place, because those three are read as one claim about where the reader is —
    /// a capsule saying 45% above a shelf that says 45.3% reads as two different numbers
    /// for the same thing. Whole percent: this is a position in a novel, and no reader
    /// has ever wanted the tenth of a percent.
    static func shareText(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
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

extension TextSelection {
    /// The whole of one paragraph — the finest span the scrolling reader can name.
    ///
    /// A choice rather than a limit, now that both renderers lay their own text out. A
    /// press while scrolling is a press on a *moving* surface — the same gesture that
    /// starts a drag — so the finest thing it can honestly claim to have picked out is
    /// the paragraph under the finger; a page is still, so a press there can be
    /// sentence-precise (`ChapterText.sentenceRange(from:to:)`).
    ///
    /// The index is the chapter's own paragraph index, the one a `TextAnchor` stores, so
    /// a mark made here lands on the same characters when the same chapter is composed
    /// for a page — where a chapter heading sits in front of paragraph 0 and belongs to
    /// no paragraph at all.
    ///
    /// Nil for an index the chapter does not have, and for a paragraph holding nothing
    /// but space: the excerpt is all the marks list can show, and a row quoting nothing
    /// is a row the reader cannot place.
    static func wholeParagraph(at index: Int, in paragraphs: [String]) -> TextSelection? {
        guard paragraphs.indices.contains(index) else { return nil }
        let text = paragraphs[index]
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return TextSelection(
            start: TextAnchor(paragraph: index, characterOffset: 0),
            // The paragraph's full UTF-16 length: `range(inParagraph:length:)` clamps
            // against whatever text it is handed, so this end covers the paragraph
            // whole in both renderers and runs past it in neither.
            end: TextAnchor(paragraph: index, characterOffset: (text as NSString).length),
            text: text
        )
    }
}

/// A place in a book: which chapter, and where inside it.
struct ReadingPosition: Codable, Hashable {
    /// The chapter, by the id the site gave it — never by its place in the catalog.
    ///
    /// A position is stored for weeks and read back against a catalog that has been
    /// refetched many times since; `Chapter.index` is recomputed on every one of those
    /// refreshes, so a stored index quietly starts naming the chapter *after* the one
    /// it was written for the first time the site inserts one. Turning the id back into
    /// a place in reading order is `Book.lastReadIndex(in:)`, and it needs a catalog to
    /// do it, which is the point: nothing can hold a reading-order number without
    /// holding the thing that defines it.
    var siteChapterId: String
    var anchor: TextAnchor

    /// Opening a chapter from the catalog, where the reader has expressed no
    /// opinion about a position within it.
    static func chapterStart(_ siteChapterId: String) -> ReadingPosition {
        ReadingPosition(siteChapterId: siteChapterId, anchor: .start)
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
    /// Which chapter, by the site's own id. See `ReadingPosition.siteChapterId` for why
    /// this is not the chapter's number: a bookmark that slid onto the next chapter's
    /// text because the site published one is a bookmark that lies.
    var siteChapterId: String
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
            siteChapterId: siteChapterId,
            anchor: TextAnchor(paragraph: paragraph, characterOffset: characterOffset)
        )
    }

    /// Identity is the position itself, the same way `Book.id` is derived from its
    /// source: bookmarking the same sentence twice has to collapse onto one row.
    /// With a UUID id, a reader tapping the button on a page they already saved
    /// would stack up rows that all jump to the same place, and the storage layer
    /// could not tell that they were duplicates.
    static func makeId(bookId: String, position: ReadingPosition) -> String {
        "\(bookId)|\(position.siteChapterId)|\(position.anchor.paragraph)|\(position.anchor.characterOffset)"
    }

    init(bookId: String, position: ReadingPosition, createdAt: Date, excerpt: String?) {
        self.id = Self.makeId(bookId: bookId, position: position)
        self.bookId = bookId
        self.siteChapterId = position.siteChapterId
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
    /// Which chapter, by the site's own id — see `ReadingBookmark.siteChapterId`. A
    /// highlight is drawn *over* text rather than pointed at it, so an identity that
    /// drifts does not merely jump to the wrong place: it paints the wrong sentence.
    var siteChapterId: String
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
        ReadingPosition(siteChapterId: siteChapterId, anchor: start)
    }

    /// Identity is the span, the same way `ReadingBookmark`'s is its position: drawing
    /// a line under the same sentence twice has to collapse onto one row, or the
    /// second tap would stack an invisible duplicate that takes two deletes to remove.
    static func makeId(bookId: String, siteChapterId: String, selection: TextSelection) -> String {
        [
            bookId, siteChapterId,
            String(selection.start.paragraph), String(selection.start.characterOffset),
            String(selection.end.paragraph), String(selection.end.characterOffset),
        ].joined(separator: "|")
    }

    init(bookId: String, siteChapterId: String, selection: TextSelection, createdAt: Date) {
        self.id = Self.makeId(bookId: bookId, siteChapterId: siteChapterId, selection: selection)
        self.bookId = bookId
        self.siteChapterId = siteChapterId
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
