import XCTest
@testable import NovelReader

/// "Continue reading", asked from outside the app.
///
/// The whole feature is one decision — which book — made against a list the reader
/// cannot see at the moment they ask. There is no screen to check it against and no
/// second chance to offer: an Action Button that opens the wrong book, or opens nothing
/// and lands on the shelf, is indistinguishable from the button not working.
final class ContinueReadingTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    /// One history entry. `chapterIndex: nil` is the shape a book takes when the site
    /// has dropped the chapter the reader was on — `RecentReadingView` keeps the row and
    /// refuses to lead anywhere from it.
    private func entry(_ id: String, chapterIndex: Int?) -> RecentRead {
        var book = Book(
            id: id, siteId: "demo", siteBookId: id,
            kind: .novel, title: "書\(id)", displayName: nil, author: nil, coverURL: nil,
            addedAt: epoch, updatedAt: epoch,
            lastReadSiteChapterId: "\((chapterIndex ?? 0) + 1)", lastReadParagraph: 0,
            lastReadCharacterOffset: 0, lastReadFraction: 0.5,
            lastReadAt: epoch, catalogUpdatedAt: epoch
        )
        if chapterIndex == nil { book.lastReadSiteChapterId = "gone" }
        return RecentRead(
            book: book,
            chapterTitle: chapterIndex.map { "第\($0 + 1)章" },
            chapterIndex: chapterIndex,
            chapterCount: 400
        )
    }

    // MARK: - Which book

    func testContinuingGoesToTheBookTheReaderWasLastIn() throws {
        let target = try XCTUnwrap(
            ReadingTarget.continuing([entry("a", chapterIndex: 12), entry("b", chapterIndex: 3)])
        )
        XCTAssertEqual(target.book.id, "a", "the history is in order and the top of it is 'last'")
    }

    /// The rule that separates this from `history.first`. A site dropping the chapter
    /// somebody was on is ordinary — it is why `RecentRead.position` is optional at all —
    /// and when it happens to the newest book, the reader has not stopped having a book
    /// to continue. Answering nothing here sends someone who asked to read to the shelf.
    func testABookWhoseChapterTheSiteDroppedIsSteppedOverRatherThanEndingTheSearch() throws {
        let target = try XCTUnwrap(
            ReadingTarget.continuing([entry("a", chapterIndex: nil), entry("b", chapterIndex: 3)])
        )
        XCTAssertEqual(
            target.book.id, "b",
            "a dropped chapter has to be stepped over, not treated as 'nowhere to go'"
        )
    }

    /// A fresh install, and a reader who has just cleared their history. Nothing is the
    /// honest answer: the first chapter of whatever is on the shelf is not a lesser
    /// version of continuing, it is the wrong place for somebody four hundred chapters in.
    func testAHistoryWithNothingOpenableInItLeadsNowhereRatherThanGuessing() {
        XCTAssertNil(ReadingTarget.continuing([]))
        XCTAssertNil(
            ReadingTarget.continuing([entry("a", chapterIndex: nil), entry("b", chapterIndex: nil)]),
            "every entry dropped is the same as no entries, not a reason to invent one"
        )
    }

    // MARK: - An ask that outlived the launch it arrived in

    /// The intent can run against an app that has no object graph yet, so the ask is
    /// written down and the first view tree honours it.
    func testAnAskMadeBeforeTheAppWasUpSurvivesUntilThereIsSomewhereToPutIt() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defer { UserDefaults.standard.removePersistentDomain(forName: #function) }

        XCTAssertFalse(ContinueReadingRequest.take(from: defaults), "nobody has asked yet")
        ContinueReadingRequest.raise(in: defaults)
        XCTAssertTrue(ContinueReadingRequest.take(from: defaults))
    }

    /// The failure this guards is a book opening at every launch for ever. A reader with
    /// an empty history who presses the button once gets nothing — correctly — and the
    /// ask must not still be sitting there tomorrow morning, hijacking a launch they made
    /// to look at their shelf.
    func testAnAskIsHonouredOnceAndIsGoneEvenWhenNothingCameOfIt() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defer { UserDefaults.standard.removePersistentDomain(forName: #function) }

        ContinueReadingRequest.raise(in: defaults)
        XCTAssertTrue(ContinueReadingRequest.take(from: defaults))
        XCTAssertFalse(
            ContinueReadingRequest.take(from: defaults),
            "taking the ask has to clear it, whatever the caller managed to do with it"
        )
    }
}
