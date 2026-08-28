import GRDB
import XCTest
@testable import NovelReader

/// What the library records about a comic.
///
/// A comic is a book like any other here: one row, one reading position, one iCloud
/// record. Only one thing about it is new — which of the two kinds it is — and the whole
/// value of that answer is that it has to survive to places the rule it came from never
/// reaches: an upgraded database, another device, a screen deciding which reader to open.
/// The rest of this file pins that widening the meaning of what was already there cost
/// the novels nothing.
final class ComicLibraryTests: XCTestCase {
    private func entries(_ count: Int) -> [(siteChapterId: String, title: String, url: String)] {
        (1...count).map {
            (siteChapterId: "\($0)", title: "第\($0)話", url: "https://comic.test/103/\($0)")
        }
    }

    // MARK: - The upgrade

    /// A library upgraded from before comics existed is a library of novels, and v9 says
    /// so about every row without having to ask anything.
    ///
    /// That is a fact being written down rather than a default standing in for an unknown:
    /// until this release a rule had no way to describe a comic, so a book already on the
    /// shelf could not be one. It is the opposite case from v2, v3 and v7, which left
    /// their new columns null precisely because the old rows had no answer.
    func testEveryBookFromBeforeComicsExistedReadsAsANovel() throws {
        let queue = try storeAtV8(bookIds: ["1", "2", "3"])

        try AppDatabase.migrator.migrate(queue)

        let repo = LibraryRepo(database: try AppDatabase(queue))
        XCTAssertEqual(try repo.allBooks().map(\.kind), [.novel, .novel, .novel])
        XCTAssertEqual(
            try repo.allBooks().map(\.readingPosition?.anchor.paragraph), [12, 12, 12],
            "and the positions are untouched: v9 adds a column, it does not rebuild the row"
        )
    }

    /// A database as v8 shipped it, written in raw SQL: these rows have to be the shape
    /// the released app wrote, which the current model can no longer express — it has a
    /// column they do not.
    private func storeAtV8(bookIds: [String]) throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v8.lastReadAt")
        try queue.write { db in
            for id in bookIds {
                try db.execute(
                    sql: """
                        INSERT INTO "book"
                        ("id", "siteId", "siteBookId", "title", "addedAt", "updatedAt",
                         "lastReadSiteChapterId", "lastReadParagraph", "lastReadCharacterOffset")
                        VALUES (?, 'demo', ?, '書', '2024-01-01', '2024-01-01', '7', 12, 34)
                        """,
                    arguments: ["demo|\(id)", id]
                )
            }
        }
        return queue
    }

    // MARK: - The kind on a row

    /// A comic added from its rule comes back a comic. This is the answer that picks the
    /// reader, so a round trip that loses it opens a comic in the text reader — which
    /// has nothing to show, because a comic chapter stores no text at all.
    func testAComicKeepsItsKindThroughTheDatabase() throws {
        let database = try AppDatabase.makeInMemory()
        let repo = LibraryRepo(database: database)

        let added = try repo.bookmark(
            siteId: "comic.test", siteBookId: "103", kind: .comic, title: "漫畫"
        )

        XCTAssertEqual(added.kind, .comic)
        XCTAssertEqual(
            try XCTUnwrap(repo.book(id: added.id)).kind, .comic,
            "read back out of SQLite, not off the value the insert handed back"
        )
        XCTAssertEqual(
            try database.writer.read { db in
                try String.fetchOne(
                    db, sql: #"SELECT "kind" FROM "book" WHERE "id" = ?"#, arguments: [added.id]
                )
            },
            "comic",
            """
            Stored as the plain word the enum spells, not as JSON wrapped around it. v9's
            own backfill writes 'novel' in SQL, and the two spellings have to be the same
            one for any query — or any later migration — to compare them.
            """
        )
    }

    /// Re-adding a book under a corrected rule fixes what it is. The kind is the source's
    /// to say, like the title, and adding the book again is the one gesture a reader has
    /// for saying "this source got better" — leaving the row misfiled would make that
    /// gesture do nothing, permanently.
    func testReAddingABookUnderACorrectedRuleChangesItsKind() throws {
        let repo = LibraryRepo(database: try AppDatabase.makeInMemory())
        let misfiled = try repo.bookmark(siteId: "comic.test", siteBookId: "103", title: "漫畫")
        try repo.updateProgress(bookId: misfiled.id, position: .chapterStart("3"))

        try repo.bookmark(siteId: "comic.test", siteBookId: "103", kind: .comic, title: "漫畫")

        let stored = try XCTUnwrap(repo.book(id: misfiled.id))
        XCTAssertEqual(stored.kind, .comic)
        XCTAssertEqual(
            stored.readingPosition?.siteChapterId, "3",
            "where the reader got to is theirs, and no re-add may reset it"
        )
    }

    // MARK: - The reading position

    /// A comic's position travels in the columns a novel's paragraph uses, under the
    /// widened reading of them: the block is a page, and there is nothing finer than a
    /// page to name.
    ///
    /// This is what the widening buys, and why it is not a pair of comic columns: the
    /// shelf's progress line, the reading history and the iCloud record all read the
    /// position they already read, and a comic appears in every one of them without a
    /// query being touched — with no second position to keep in step with the first.
    func testAComicsPagePositionUsesTheColumnsANovelsParagraphUses() throws {
        let repo = LibraryRepo(database: try AppDatabase.makeInMemory())
        let comic = try repo.bookmark(
            siteId: "comic.test", siteBookId: "103", kind: .comic, title: "漫畫"
        )
        try repo.replaceCatalog(bookId: comic.id, entries: entries(3))

        // Page 8 of the third chapter, three quarters of the way through its pages.
        try repo.updateProgress(
            bookId: comic.id,
            position: ReadingPosition(
                siteChapterId: "3", anchor: TextAnchor(paragraph: 7, characterOffset: 0)
            ),
            fraction: 0.75
        )

        let entry = try XCTUnwrap(try repo.recentlyRead(limit: 5).first)
        XCTAssertEqual(entry.book.kind, .comic)
        XCTAssertEqual(entry.position?.anchor.paragraph, 7, "the page the reader stopped on")
        XCTAssertEqual(
            entry.position?.anchor.characterOffset, 0,
            "a page has no offset inside it, and 0 is what says so"
        )
        XCTAssertEqual(entry.book.lastReadFraction, 0.75)
        XCTAssertEqual(
            entry.chapterIndex, 2,
            "resolved through the catalog exactly as a novel's is, by the same query"
        )
    }

    // MARK: - iCloud

    /// A record written before comics existed carries no kind, and the book it describes
    /// could not have been anything but a novel — so it arrives as one.
    ///
    /// Arriving matters as much as the value: a skipped record is a book missing from
    /// this device's shelf, and the reader has no way to know it was ever there.
    @MainActor
    func testARecordWrittenBeforeComicsExistedArrivesAsANovel() throws {
        let origin = try makeDevice()
        let novel = try origin.repo.bookmark(siteId: "novels.test", siteBookId: "1", title: "小說")
        origin.sync.push(novel)

        let arriving = try makeDevice()
        arriving.store.values["book.\(novel.id)"] =
            try recordWithoutKind(origin.store.values["book.\(novel.id)"])
        arriving.sync.pull()

        XCTAssertEqual(try XCTUnwrap(arriving.repo.book(id: novel.id)).kind, .novel)
    }

    /// A comic reaches the other device as a comic — on a device with no rule for the
    /// site, which is the ordinary case rather than an edge: a merge *creates* book rows,
    /// while rule files travel by hand one at a time, so a library routinely syncs before
    /// its sources do. Nothing here installs a rule, and nothing in the path may want one.
    ///
    /// Looked up locally instead, the kind would come back nothing on this device, and the
    /// comic would sit under the novels — opening in the text reader — until the day its
    /// rule file happened to arrive.
    @MainActor
    func testAComicArrivesAsAComicOnADeviceWithNoRuleForIt() throws {
        let origin = try makeDevice()
        let comic = try origin.repo.bookmark(
            siteId: "comic.test", siteBookId: "103", kind: .comic, title: "漫畫"
        )
        try origin.repo.updateProgress(
            bookId: comic.id,
            position: ReadingPosition(
                siteChapterId: "3", anchor: TextAnchor(paragraph: 7, characterOffset: 0)
            ),
            fraction: 0.75
        )
        origin.sync.pushAll()

        let arriving = try makeDevice()
        arriving.store.values = origin.store.values
        arriving.sync.pull()

        let arrived = try XCTUnwrap(arriving.repo.book(id: comic.id))
        XCTAssertEqual(arrived.kind, .comic)
        XCTAssertEqual(
            arrived.readingPosition?.anchor.paragraph, 7,
            "and the page it stopped on came with it, in the column a paragraph uses"
        )
    }

    /// Stands in for the real key-value store, which needs an iCloud account and a signed
    /// app — neither of which a unit test has. Only the members `CloudSync` uses are
    /// overridden; the dictionary is the wire, so what one device leaves in it is exactly
    /// what the other one finds.
    private final class SpyStore: NSUbiquitousKeyValueStore {
        var values: [String: Any] = [:]
        // Both setters: the store has a typed `Data` overload, and a record is encoded
        // JSON, so that is the one the sync path actually calls.
        override func set(_ aData: Data?, forKey aKey: String) { values[aKey] = aData }
        override func set(_ anObject: Any?, forKey aKey: String) { values[aKey] = anObject }
        override func removeObject(forKey aKey: String) { values.removeValue(forKey: aKey) }
        override func synchronize() -> Bool { true }
        override var dictionaryRepresentation: [String: Any] { values }
    }

    /// One device: its library, and the store it syncs through.
    @MainActor
    private func makeDevice() throws -> (repo: LibraryRepo, store: SpyStore, sync: CloudSync) {
        let repo = LibraryRepo(database: try AppDatabase.makeInMemory())
        let store = SpyStore()
        let defaults = UserDefaults(suiteName: "novelreader.tests.\(UUID().uuidString)")!
        defaults.set(true, forKey: CloudSync.enabledDefaultsKey)
        return (repo, store, CloudSync(repo: repo, store: store, defaults: defaults))
    }

    /// The record an older build would have written: this one, minus the field it had no
    /// way to write.
    ///
    /// Built by removing the key rather than by hand, so the rest of the payload is
    /// exactly what the app produces today and cannot drift from it — and so the removal
    /// itself asserts that the field is really being sent, without which the absence
    /// proves nothing.
    private func recordWithoutKind(_ value: Any?) throws -> Data {
        let data = try XCTUnwrap(value as? Data)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(
            json.removeValue(forKey: "kind"), "a push that never sent the kind proves nothing"
        )
        return try JSONSerialization.data(withJSONObject: json)
    }
}
