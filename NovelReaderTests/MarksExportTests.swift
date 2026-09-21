import XCTest
@testable import NovelReader

/// What the marks a reader takes out of the app have to guarantee.
///
/// The document is the only copy of these passages that survives leaving this app, so
/// the failures worth catching are the ones its reader could not detect for themselves:
/// passages in the order they were tapped rather than the order of the book, a mark that
/// silently did not make it into the file, and words attributed to a reader who never
/// chose them. The marks go in through `LibraryRepo`, the way the screen's own do, so
/// these cover the whole path from stored row to finished text.
@MainActor
final class MarksExportTests: XCTestCase {
    private var repo: LibraryRepo!

    /// Noon UTC, so that the day the summary prints is the same day in every time zone a
    /// machine running this is plausibly set to.
    private let exportedAt = Date(timeIntervalSince1970: 1_789_992_000)

    private let chapterTitles = ["第一章 下山", "第二章 入城", "第三章 夜行"]

    override func setUpWithError() throws {
        repo = LibraryRepo(database: try AppDatabase.makeInMemory())
    }

    // MARK: - Order

    /// The point of the whole feature: a summary that can be read from the top.
    ///
    /// The fixture is built so that no wrong answer can pass it by luck. The five marks
    /// are made in one order, stamped in a third, and read in a fourth: sorting them by
    /// `createdAt` gives a different document, so does sorting by it backwards, and so
    /// does insert order. The first chapter holds a bookmark *between* two highlights,
    /// which is what fails a document that walks the two kinds one list after the other
    /// instead of merging them — the marks arrive from `LibraryRepo` already in reading
    /// order within each kind, so that mistake is invisible in a chapter holding only
    /// one kind.
    func testMarksRunInReadingOrderRatherThanTheOrderTheyWereMade() throws {
        let book = try makeBook()
        try highlight(book, chapter: 2, paragraph: 0, text: "夜裡的燈。", at: 20)
        try bookmark(book, chapter: 0, paragraph: 3, excerpt: "山路很長。", at: 50)
        try highlight(book, chapter: 0, paragraph: 5, text: "風也停了。", at: 10)
        try highlight(book, chapter: 0, paragraph: 1, text: "雪停了。", at: 30)
        try bookmark(book, chapter: 1, paragraph: 4, excerpt: "城門在傍晚關上。", at: 40)

        let text = try export(book).text(now: exportedAt)

        try assertInOrder(
            ["## 第一章 下山", "雪停了。", "山路很長。", "風也停了。",
             "## 第二章 入城", "城門在傍晚關上。",
             "## 第三章 夜行", "夜裡的燈。"],
            in: text
        )
    }

    // MARK: - Readable away from the app

    /// Everything the file has to carry for it to still mean something on a machine that
    /// has never heard of this app: which book, by whom, which chapter, and the passage
    /// itself — under the chapter it came from, which is the only part of a mark's stored
    /// position that means anything off this device (see `MarksExport`).
    func testTheDocumentNamesTheBookTheChapterAndTheMarkedPassage() throws {
        let book = try makeBook()
        try highlight(book, chapter: 1, paragraph: 2, text: "城門在傍晚關上。", at: 10)

        let text = try export(book).text(now: exportedAt)

        XCTAssertTrue(text.hasPrefix("# 山月記\n"), "the book's name opens the document")
        XCTAssertTrue(text.contains("\n中島敦\n"), "the author is named under it")
        try assertInOrder(["## 第二章 入城", "> 城門在傍晚關上。"], in: text)
        XCTAssertFalse(
            text.contains("第一章 下山"),
            "a chapter the reader marked nothing in is not a heading over nothing"
        )
    }

    /// The line that lets a reader tell a finished export from one they made halfway
    /// through marking the book — and tell two of them apart a year later. The date is
    /// written the same way in every locale on purpose: a file that outlives the device
    /// must not carry a day that reads as March in one country and April in another.
    func testTheSummarySaysHowMuchIsInTheFileAndWhenItWasTaken() throws {
        let book = try makeBook()
        try highlight(book, chapter: 0, paragraph: 0, text: "雪停了。", at: 10)
        try highlight(book, chapter: 1, paragraph: 0, text: "城門在傍晚關上。", at: 20)
        try highlight(book, chapter: 2, paragraph: 0, text: "夜裡的燈。", at: 30)
        try bookmark(book, chapter: 0, paragraph: 3, excerpt: "山路很長。", at: 40)
        try bookmark(book, chapter: 2, paragraph: 1, excerpt: "天亮之前。", at: 50)

        let text = try export(book).text(now: exportedAt)

        // Written out with the counts in the order the reader reads them, so that a
        // document naming two highlights and three bookmarks fails here.
        XCTAssertTrue(
            text.contains(String(localized: "marks.export.summary \(3) \(2) \("2026-09-21")")),
            "the summary line is missing or does not count what is in the file"
        )
    }

    /// A highlight can run across a paragraph break — `TextSelection` keeps the separator
    /// — and a quote whose second line lost its marker stops being a quote there, which
    /// silently turns half the passage into the document's own voice.
    func testAPassageSpanningParagraphsStaysInsideTheQuote() throws {
        let book = try makeBook()
        try highlight(book, chapter: 0, paragraph: 1, text: "雪停了。\n風也停了。", at: 10)

        let text = try export(book).text(now: exportedAt)

        XCTAssertTrue(text.contains("> 雪停了。\n> 風也停了。"), "got:\n\(text)")
    }

    /// A bookmark's excerpt was taken automatically from the head of the paragraph it
    /// landed on; the reader chose the place, not those words. Quoting it the way a
    /// highlight is quoted would put a sentence in their mouth — in a file whose whole
    /// purpose is to carry what they did pick out.
    func testABookmarkIsLabelledRatherThanQuotedLikeAHighlight() throws {
        let book = try makeBook()
        try bookmark(book, chapter: 0, paragraph: 3, excerpt: "山路很長。", at: 10)
        try highlight(book, chapter: 0, paragraph: 4, text: "雪停了。", at: 20)

        let text = try export(book).text(now: exportedAt)

        let bookmarkLine = try XCTUnwrap(
            text.split(separator: "\n").first { $0.contains("山路很長。") }
        )
        XCTAssertTrue(bookmarkLine.hasPrefix("- "), "got: \(bookmarkLine)")
        XCTAssertTrue(
            bookmarkLine.contains(String(localized: "marks.export.bookmark")),
            "a bookmark says what it is: \(bookmarkLine)"
        )
        XCTAssertTrue(text.contains("> 雪停了。"), "a highlight is still quoted")
    }

    /// A mark can outlive the chapter it points at — a catalog refresh drops chapters the
    /// site has removed, which is why the list on screen keeps showing such marks and
    /// only refuses to open them. The words are still the reader's, so they still leave
    /// with them; they go last, because the catalog that knew where they belonged is the
    /// one that no longer lists the chapter.
    func testAMarkWhoseChapterTheSiteDroppedIsStillCarried() throws {
        let book = try makeBook()
        try highlight(book, chapter: 0, paragraph: 0, text: "雪停了。", at: 10)
        try highlight(book, chapter: 2, paragraph: 0, text: "夜裡的燈。", at: 20)
        // The site withdrew the third chapter; the first two are still published.
        try repo.replaceCatalog(
            bookId: book.id,
            entries: (0..<2).map {
                (siteChapterId: chapterId($0), title: chapterTitles[$0], url: "https://e.com/\($0)")
            }
        )

        let text = try export(book).text(now: exportedAt)

        try assertInOrder(
            ["## 第一章 下山", "> 雪停了。",
             "## " + String(localized: "marks.chapter.missing"), "> 夜裡的燈。"],
            in: text
        )
    }

    // MARK: - Nothing to take

    /// A book nobody has marked must not produce a file at all. One with a title, a
    /// byline and nothing under them looks exactly like an export that went wrong, and a
    /// reader holding it has no way to tell which it was — so the screen asks this before
    /// offering the button, and this is the answer it reads.
    func testABookWithNoMarksHasNothingToExport() throws {
        let book = try makeBook()

        XCTAssertTrue(try export(book).isEmpty)

        try bookmark(book, chapter: 0, paragraph: 0, excerpt: "山路很長。", at: 10)
        XCTAssertFalse(
            try export(book).isEmpty, "a saved position on its own is still worth taking"
        )
    }

    // MARK: - Naming

    /// The name the share sheet offers. It has to say which book these came from — a
    /// folder of `marks.md` files is a folder of files nobody can tell apart — and it
    /// keeps the extension a notes app reads to decide how to render the file.
    func testTheFileIsNamedAfterTheBook() throws {
        let book = try makeBook()

        let filename = try export(book).filename

        XCTAssertTrue(filename.hasPrefix("山月記 "), "got: \(filename)")
        XCTAssertTrue(filename.hasSuffix(".md"), "got: \(filename)")
    }

    // MARK: - Fixtures

    private func makeBook() throws -> Book {
        let book = try repo.bookmark(
            siteId: "alpha", siteBookId: "1", title: "山月記", author: "中島敦"
        )
        try repo.replaceCatalog(
            bookId: book.id,
            entries: chapterTitles.enumerated().map { offset, title in
                (siteChapterId: chapterId(offset), title: title, url: "https://e.com/\(offset)")
            }
        )
        return book
    }

    private func chapterId(_ index: Int) -> String { String(format: "%05d", index) }

    /// - Parameter at: seconds into the fixture's day, which is what makes "the order
    ///   they were made" a different order from "the order they are read".
    private func highlight(
        _ book: Book, chapter: Int, paragraph: Int, text: String, at second: TimeInterval
    ) throws {
        try repo.addHighlight(
            bookId: book.id,
            siteChapterId: chapterId(chapter),
            selection: TextSelection(
                start: TextAnchor(paragraph: paragraph, characterOffset: 0),
                end: TextAnchor(paragraph: paragraph, characterOffset: (text as NSString).length),
                text: text
            ),
            now: exportedAt.addingTimeInterval(second)
        )
    }

    private func bookmark(
        _ book: Book, chapter: Int, paragraph: Int, excerpt: String, at second: TimeInterval
    ) throws {
        try repo.addReadingBookmark(
            bookId: book.id,
            position: ReadingPosition(
                siteChapterId: chapterId(chapter),
                anchor: TextAnchor(paragraph: paragraph, characterOffset: 0)
            ),
            excerpt: excerpt,
            now: exportedAt.addingTimeInterval(second)
        )
    }

    /// Everything the screen hands the exporter, read back the way the screen reads it.
    private func export(_ book: Book) throws -> MarksExport {
        MarksExport(
            book: book,
            chapters: try repo.chapters(bookId: book.id),
            bookmarks: try repo.readingBookmarks(bookId: book.id),
            highlights: try repo.highlights(bookId: book.id)
        )
    }

    /// Asserts the pieces appear in the document in the order given, which is how every
    /// claim about reading order here is checked.
    private func assertInOrder(
        _ pieces: [String], in text: String, line: UInt = #line
    ) throws {
        var searched = text.startIndex
        for piece in pieces {
            guard let found = text.range(of: piece, range: searched ..< text.endIndex) else {
                XCTFail("\"\(piece)\" is missing or out of order in:\n\(text)", line: line)
                return
            }
            searched = found.upperBound
        }
    }
}
