import XCTest
@testable import NovelReader

/// A chapter is named by its catalog, and some sites truncate their own catalog's
/// link text — 69shuba cuts at 27 characters, mid-word. The chapter's own page
/// carries the whole name, so the fetch that reads the text repairs the row.
///
/// Two things have to hold for that to be a repair rather than a rename: only a
/// name that *completes* the stored one may replace it, and the next catalog
/// refresh must not put the truncation straight back.
final class ChapterTitleRepairTests: XCTestCase {
    /// The reported case, verbatim from the site.
    private let truncated = "第363章 爆發之二，逆天刷子，啓動！魔帝之"
    private let whole = "第363章 爆發之二，逆天刷子，啓動！魔帝之邀！"

    func testAPageTitleThatCompletesTheCatalogsIsTaken() {
        XCTAssertEqual(Chapter.fullerTitle(whole, extending: truncated), whole)
    }

    /// The guard that keeps this a repair. Several of these sites head a chapter
    /// page with the book's name in front of the chapter's; that names the same
    /// chapter but is not the same name, and swapping it in would rewrite every
    /// title in the catalog to something longer and worse.
    func testANameThatIsNotACompletionIsRefused() {
        XCTAssertNil(Chapter.fullerTitle("某本書 \(whole)", extending: truncated))
        XCTAssertNil(Chapter.fullerTitle("第364章 下一章", extending: truncated))
        XCTAssertNil(Chapter.fullerTitle(nil, extending: truncated))
    }

    func testANameThatIsNotLongerIsRefused() {
        XCTAssertNil(Chapter.fullerTitle(truncated, extending: truncated))
        XCTAssertNil(Chapter.fullerTitle("第363章", extending: truncated))
    }

    /// Without this the repair lasts until the next catalog refresh — which runs
    /// daily, in the background — and the reader watches the whole title turn back
    /// into a truncated one for no reason they can see.
    func testACatalogRefreshDoesNotUndoTheRepair() throws {
        let repo = LibraryRepo(database: try AppDatabase.makeInMemory())
        let book = try repo.bookmark(siteId: "demo", siteBookId: "1", title: "t")
        let url = "https://demo.test/txt/1/363"
        try repo.replaceCatalog(
            bookId: book.id, entries: [(siteChapterId: "363", title: truncated, url: url)]
        )
        let chapter = try XCTUnwrap(repo.chapters(bookId: book.id).first)
        try repo.updateChapterTitle(chapterId: chapter.id, to: whole)

        // The site still serves the same truncated catalog it always did.
        try repo.replaceCatalog(
            bookId: book.id, entries: [(siteChapterId: "363", title: truncated, url: url)]
        )

        XCTAssertEqual(try repo.chapters(bookId: book.id).first?.title, whole)
    }

    /// The other half: a catalog that genuinely renames a chapter still wins. The
    /// stored name is only protected while it is the same name made whole.
    func testACatalogThatRenamesAChapterStillWins() throws {
        let repo = LibraryRepo(database: try AppDatabase.makeInMemory())
        let book = try repo.bookmark(siteId: "demo", siteBookId: "1", title: "t")
        let url = "https://demo.test/txt/1/363"
        try repo.replaceCatalog(
            bookId: book.id, entries: [(siteChapterId: "363", title: truncated, url: url)]
        )
        let chapter = try XCTUnwrap(repo.chapters(bookId: book.id).first)
        try repo.updateChapterTitle(chapterId: chapter.id, to: whole)

        try repo.replaceCatalog(
            bookId: book.id,
            entries: [(siteChapterId: "363", title: "第363章 改了名字", url: url)]
        )

        XCTAssertEqual(try repo.chapters(bookId: book.id).first?.title, "第363章 改了名字")
    }
}
