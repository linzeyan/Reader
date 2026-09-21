import GRDB
import XCTest
@testable import NovelReader

/// Searching the text the reader already has, end to end.
///
/// The promise a result row makes is narrow and total: this book, this chapter, these
/// words, and tapping it opens them. Every one of these tests is about a way that promise
/// could be broken — a row for a chapter that was deleted, a row for a chapter that was
/// never downloaded, a row that opens at the wrong place — because a search result that
/// leads nowhere is worse than no result at all.
final class LibrarySearchTests: XCTestCase {
    private var tempRoot: URL!
    private var database: AppDatabase!
    private var store: DownloadStore!
    private var library: LibraryRepo!
    private var search: LibrarySearch!

    private var novel: Book!
    private var other: Book!

    /// A traditional chapter and a simplified one, in two different books, so that every
    /// test can ask both "did it find the right chapter" and "did it leave the other one
    /// alone".
    private let traditional = [
        "夜色沉沉，風從山口灌進來。",
        "蕭炎握緊手中的玄重尺，向前走去。",
    ]
    private let simplified = [
        "他读的是斗破苍穹这本书。",
        "萧炎握紧手中的玄重尺，向前走去。",
    ]

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LibrarySearchTests-\(UUID().uuidString)")
        database = try AppDatabase.makeInMemory()
        library = LibraryRepo(database: database)
        let files = ChapterFileStore(root: tempRoot)
        store = DownloadStore(database: database, files: files)
        search = LibrarySearch(database: database, files: files, repo: library)

        novel = try library.bookmark(siteId: "alpha", siteBookId: "1", title: "長夜行")
        other = try library.bookmark(siteId: "beta", siteBookId: "1", title: "斗破")

        try library.replaceCatalog(bookId: novel.id, entries: [
            (siteChapterId: "c1", title: "第一章 出發", url: "https://x/1"),
            (siteChapterId: "c2", title: "第二章 玄重尺", url: "https://x/2"),
        ])
        try library.replaceCatalog(bookId: other.id, entries: [
            (siteChapterId: "d1", title: "第一话", url: "https://y/1"),
        ])
        // c1 is deliberately left undownloaded throughout: it is the control for
        // "only what is on the device".
        try store.save(paragraphs: traditional, book: novel, siteChapterId: "c2")
        try store.save(paragraphs: simplified, book: other, siteChapterId: "d1")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - Finding

    /// Success condition 1: which book, which chapter, and the words around the hit.
    func testAHitNamesItsBookItsChapterAndQuotesTheSentence() throws {
        let hits = try search.hits(for: "玄重尺")
        XCTAssertEqual(hits.count, 2, "both books hold the phrase")

        let fromNovel = try XCTUnwrap(hits.first { $0.book.id == novel.id })
        XCTAssertEqual(fromNovel.chapterTitle, "第二章 玄重尺")
        XCTAssertTrue(
            fromNovel.excerpt.text.contains("握緊手中的玄重尺"),
            "the row has to show the sentence, not just the chapter's name: \(fromNovel.excerpt.text)"
        )
    }

    /// Success condition 2, and rather more than it: the row opens the chapter *at the
    /// paragraph it quoted*. Landing on the chapter's first page would make the reader
    /// hunt for the thing they just searched for.
    func testAHitLeadsToTheChapterAndParagraphItQuoted() throws {
        let hit = try XCTUnwrap(
            try search.hits(for: "玄重尺").first { $0.book.id == novel.id }
        )
        XCTAssertEqual(hit.target.book.id, novel.id)
        XCTAssertEqual(hit.target.position.siteChapterId, "c2")
        XCTAssertEqual(hit.target.position.anchor.paragraph, 1)
        // The offset names the hit inside that paragraph, in the unit the reader's anchor
        // is stored in.
        let paragraph = traditional[1]
        let expected = try XCTUnwrap(paragraph.range(of: "玄重尺"))
            .lowerBound.utf16Offset(in: paragraph)
        XCTAssertEqual(hit.target.position.anchor.characterOffset, expected)
    }

    /// Success condition 5. The library holds books from sites of both scripts, and a
    /// reader types in one of them.
    func testEitherScriptFindsAChapterStoredInTheOther() throws {
        // 斗/鬥 and 蒼/苍 differ; the traditional query must reach the simplified book.
        // Unwrapped rather than subscripted: when this assertion is the one that breaks,
        // a subscript into the empty result takes the whole test process down with it and
        // every later test goes unreported.
        let fromTraditional = try XCTUnwrap(search.hits(for: "鬥破蒼穹").first)
        XCTAssertEqual(fromTraditional.book.id, other.id)
        XCTAssertTrue(
            fromTraditional.excerpt.text.contains("斗破苍穹"),
            "the quotation must stay in the book's own script"
        )

        // And a simplified query must reach the traditional book.
        let fromSimplified = try search.hits(for: "萧炎握紧")
        XCTAssertEqual(Set(fromSimplified.map(\.book.id)), [novel.id, other.id])
        let inNovel = try XCTUnwrap(fromSimplified.first { $0.book.id == novel.id })
        XCTAssertTrue(inNovel.excerpt.text.contains("蕭炎握緊"))
    }

    /// The two-character case the index cannot answer, which falls through to a scan.
    /// A reader looking for a character by name is the commonest search there is, and an
    /// answer of "too short" would read as the feature being broken.
    func testATwoCharacterNameIsFound() throws {
        let hits = try search.hits(for: "蕭炎")
        XCTAssertEqual(
            Set(hits.map(\.book.id)), [novel.id, other.id],
            "a two-character name must be searchable in both scripts"
        )
    }

    /// One character is not a search, it is a slow way to list the library.
    func testASingleCharacterIsNotSearchedFor() throws {
        XCTAssertTrue(try search.hits(for: "蕭").isEmpty)
        XCTAssertTrue(try search.hits(for: " ").isEmpty)
    }

    // MARK: - Only what is on the device (success condition 3)

    /// c1 is in the catalog and has never been fetched, so this device holds no text for
    /// it at all. Nothing may ever name it — not as a hit, and not as an empty row.
    ///
    /// Checked by writing c1's text to disk *behind* the store, which is the state a
    /// chapter would be in if the index and the files could drift apart. The file being
    /// there is not what makes a chapter searchable; the flag is.
    func testAChapterThatWasNeverDownloadedIsNeverSearched() throws {
        try store.files.write(
            paragraphs: ["這一段只存在於檔案裡，沒有人下載過它。"],
            siteId: "alpha", siteBookId: "1", siteChapterId: "c1"
        )
        XCTAssertTrue(
            try search.hits(for: "只存在於檔案裡").isEmpty,
            "text on disk for a chapter nobody downloaded was offered as a result"
        )
        XCTAssertFalse(
            try search.hits(for: "玄重尺").contains { $0.target.position.siteChapterId == "c1" }
        )
    }

    /// The flag is the app's definition of "there is a chapter here to read", so a row
    /// whose flag has been cleared must not be offered even if its text is still indexed.
    /// This is the guarantee that makes a stale index harmless rather than dangerous.
    func testAChapterWhoseDownloadFlagIsClearedDisappearsFromSearch() throws {
        try database.writer.write { db in
            try db.execute(sql: "UPDATE chapter SET downloadedAt = NULL WHERE siteChapterId = 'c2'")
        }
        XCTAssertTrue(try search.hits(for: "玄重尺").allSatisfy { $0.book.id != novel.id })
    }

    /// A file that went missing under the index — the crash window every chapter write
    /// has always had — must drop the row rather than offer a chapter that opens onto
    /// nothing.
    func testAHitWhoseFileHasVanishedIsDroppedRatherThanOffered() throws {
        try FileManager.default.removeItem(
            at: store.files.fileURL(siteId: "alpha", siteBookId: "1", siteChapterId: "c2")
        )
        XCTAssertEqual(try search.hits(for: "玄重尺").map(\.book.id), [other.id])
    }

    // MARK: - Deleting (success condition 4)

    /// All four delete levels, each checked for what it takes *and* what it leaves.
    /// A scope that quietly widened would silently make other books unsearchable; one
    /// that narrowed would leave deleted text findable.
    func testEveryDeleteLevelTakesItsChaptersOutOfSearch() throws {
        let levels: [(DownloadStore.Scope, Set<String>)] = [
            (.chapter(book: novel, siteChapterId: "c2"), [other.id]),
            (.book(novel), [other.id]),
            (.site(siteId: "alpha"), [other.id]),
            (.everything, []),
        ]
        for (level, survivors) in levels {
            try store.save(paragraphs: traditional, book: novel, siteChapterId: "c2")
            try store.save(paragraphs: simplified, book: other, siteChapterId: "d1")
            XCTAssertEqual(try Set(search.hits(for: "玄重尺").map(\.book.id)), [novel.id, other.id])

            try store.delete(level)

            XCTAssertEqual(
                try Set(search.hits(for: "玄重尺").map(\.book.id)), survivors,
                "\(level) left the wrong set of books searchable"
            )
        }
    }

    /// Deleting has to *remove* the text, not merely stop finding it.
    ///
    /// Worth its own test because the search is already safe without it: a hit is joined
    /// to the download flag, so text left behind would be invisible either way. What is
    /// at stake here is the storage — a reader who deletes a four-hundred-chapter novel
    /// to get space back would otherwise still be carrying the whole of it, and the
    /// storage screen would go on reporting space it has already handed over.
    func testDeletingDownloadsReclaimsTheStoredText() throws {
        try store.delete(.everything)
        let rows = try database.writer.read { db in
            try Int.fetchOne(db, sql: #"SELECT count(*) FROM "chapterText""#)
        }
        XCTAssertEqual(rows, 0, "the searchable copy of deleted text is still on disk")
    }

    /// And the index itself has to let go too.
    ///
    /// An external-content FTS5 index is not maintained by SQLite — it is kept in step by
    /// triggers — so this is the one thing that says those triggers are still there and
    /// still firing. Without them the index grows for ever and never shrinks, which on
    /// this feature's measurements is over half the size of the text again.
    func testDeletedTextLeavesNothingBehindInTheIndex() throws {
        try store.delete(.everything)
        let indexed = try database.writer.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT count(*) FROM "chapterTextIndex"
                    WHERE "chapterTextIndex" MATCH ?
                    """,
                arguments: [FullTextQuery.matchExpression(for: "玄重尺")]
            )
        }
        XCTAssertEqual(indexed, 0, "the index kept entries for text that is gone")
    }

    /// Deleting a book from the shelf runs no code of this feature's at all — it deletes
    /// a row, and the cascade does the rest. Without the index's delete trigger the text
    /// would stay searchable for ever, pointing at a book that is gone.
    func testRemovingABookFromTheShelfTakesItsTextOutOfSearch() throws {
        try library.removeBookmark(bookId: novel.id)
        XCTAssertEqual(try search.hits(for: "玄重尺").map(\.book.id), [other.id])
    }

    /// The same cascade one level down: retention drops individual articles, and their
    /// text has to go with the row.
    func testRemovingAChapterRowTakesItsTextOutOfSearch() throws {
        try library.removeChapters(bookId: novel.id, siteChapterIds: ["c2"])
        XCTAssertEqual(try search.hits(for: "玄重尺").map(\.book.id), [other.id])
    }

    /// A chapter fetched again — because the site corrected it — must not leave its old
    /// words behind to be found.
    func testRedownloadingAChapterReplacesWhatIsSearchable() throws {
        try store.save(
            paragraphs: ["這一段完全不同了。"], book: novel, siteChapterId: "c2"
        )
        XCTAssertEqual(try search.hits(for: "玄重尺").map(\.book.id), [other.id])
        XCTAssertEqual(try search.hits(for: "完全不同").map(\.book.id), [novel.id])
    }

    // MARK: - Backfilling

    /// The upgrade path. A reader who already had a library gets an empty index over a
    /// full shelf, and this is what closes the gap — so a test that only ever searched
    /// freshly-written chapters would not be testing the case every existing user is in.
    func testChaptersDownloadedBeforeTheIndexExistedBecomeSearchable() throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM chapterText")
        }
        XCTAssertTrue(try search.hits(for: "玄重尺").isEmpty, "precondition: the index is empty")

        XCTAssertEqual(try store.indexPendingText(), 2)
        XCTAssertEqual(try Set(search.hits(for: "玄重尺").map(\.book.id)), [novel.id, other.id])
        // And it is finished: a second pass has nothing left to do.
        XCTAssertEqual(try store.indexPendingText(), 0)
    }

    /// A chapter whose flag says it is downloaded but whose file is gone must not be
    /// offered to the backfill for ever — the pending query finds work by the *absence*
    /// of a row, so skipping one would loop on every launch until the end of time.
    func testTheBackfillDoesNotOfferAnUnreadableChapterForEver() throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM chapterText")
        }
        try FileManager.default.removeItem(
            at: store.files.fileURL(siteId: "alpha", siteBookId: "1", siteChapterId: "c2")
        )
        XCTAssertEqual(try store.indexPendingText(), 2)
        XCTAssertEqual(
            try store.indexPendingText(), 0,
            "the unreadable chapter came back round; this loop would never end"
        )
    }

    /// A comic's chapter is a directory of pictures. Asking the file store for its
    /// paragraphs would be a wasted read per chapter on every launch, for ever.
    func testAComicIsNeverOfferedToTheBackfill() throws {
        let comic = try library.bookmark(
            siteId: "alpha", siteBookId: "9", kind: .comic, title: "畫本"
        )
        try library.replaceCatalog(bookId: comic.id, entries: [
            (siteChapterId: "p1", title: "第一卷", url: "https://z/1"),
        ])
        try store.save(pages: [Data("page".utf8)], book: comic, siteChapterId: "p1")
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM chapterText")
        }
        XCTAssertEqual(
            try store.indexPendingText(), 2, "the comic should not be among the pending work"
        )
    }
}

/// The three languages this app ships, for the screen this feature adds.
///
/// A key with no translation renders as the key itself — 「library.text.search.hint」 in
/// the middle of a sentence — which is the one failure a reader cannot work around and
/// nobody on the team sees, because the development language always resolves.
final class LibrarySearchWordingTests: XCTestCase {
    func testEveryStringThisScreenShowsHasWordsForIt() {
        let keys: [String.LocalizationValue] = [
            "search.mode", "search.mode.sites", "search.mode.library",
            "library.text.search.prompt", "library.text.search.title",
            "library.text.search.hint", "library.text.search.none",
            "library.text.search.none.hint",
        ]
        for key in keys {
            let sentence = String(localized: key)
            XCTAssertFalse(sentence.isEmpty)
            XCTAssertFalse(
                sentence.hasPrefix("search.mode") || sentence.hasPrefix("library.text"),
                "\(key) falls back to its key, which is what an untranslated string looks like"
            )
        }
    }
}
