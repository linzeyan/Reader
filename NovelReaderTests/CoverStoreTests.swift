import XCTest
@testable import NovelReader

/// Where a book's cover lives on disk.
///
/// The failure worth a test is not "the file did not save" — that one is loud. It is
/// two different books resolving onto the same path, which is silent: the shelf simply
/// draws one book with another's cover, and nothing anywhere reports it. Ids come from
/// user-imported rule files and from remote URLs, so they can and do contain slashes
/// and dots.
final class CoverStoreTests: XCTestCase {
    private var root: URL!
    private var store: CoverStore!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CoverStoreTests-\(UUID().uuidString)")
        store = CoverStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testKeepsTheBytesItWasGiven() throws {
        let book = makeBook(siteId: "alpha", siteBookId: "1")
        XCTAssertFalse(store.has(book))
        XCTAssertNil(store.data(for: book))

        try store.save(Self.bytes, for: book)

        XCTAssertTrue(store.has(book))
        XCTAssertEqual(store.data(for: book), Self.bytes)
    }

    /// Two books, two covers. `ChapterFileStore.safeComponent` disambiguates with a
    /// hash whenever it has to replace a character, which is what stops these two ids
    /// — identical once sanitised — from collapsing onto one file.
    func testTwoBooksWhoseIdsSanitiseAlikeDoNotShareAFile() throws {
        let one = makeBook(siteId: "alpha", siteBookId: "a/b")
        let other = makeBook(siteId: "alpha", siteBookId: "a:b")
        XCTAssertNotEqual(store.fileURL(for: one), store.fileURL(for: other))

        try store.save(Self.bytes, for: one)
        try store.save(Data("different".utf8), for: other)

        XCTAssertEqual(store.data(for: one), Self.bytes)
        XCTAssertEqual(store.data(for: other), Data("different".utf8))
    }

    /// The same reason the ids are sanitised at all: an id is not trusted input, and
    /// `..` in one must not be a way to write outside the store.
    func testAnIdCannotClimbOutOfTheStore() {
        let book = makeBook(siteId: "../../etc", siteBookId: "../passwd")
        let path = store.fileURL(for: book).standardizedFileURL.path
        XCTAssertTrue(
            path.hasPrefix(root.standardizedFileURL.path),
            "\(path) escaped the store"
        )
    }

    /// Deletion is idempotent, like `ChapterFileStore.delete`: a retry after a partial
    /// failure has to converge rather than throw.
    func testRemovingIsIdempotent() throws {
        let book = makeBook(siteId: "alpha", siteBookId: "1")
        try store.save(Self.bytes, for: book)

        try store.remove(book)
        XCTAssertFalse(store.has(book))
        XCTAssertNoThrow(try store.remove(book))
    }

    /// A book whose cover changed — a site that republished it — must not be left
    /// showing the old one.
    func testSavingAgainReplacesWhatWasThere() throws {
        let book = makeBook(siteId: "alpha", siteBookId: "1")
        try store.save(Self.bytes, for: book)
        try store.save(Data("newer".utf8), for: book)
        XCTAssertEqual(store.data(for: book), Data("newer".utf8))
    }

    private static let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0])

    private func makeBook(siteId: String, siteBookId: String) -> Book {
        Book(
            id: "\(siteId)#\(siteBookId)", siteId: siteId, siteBookId: siteBookId,
            kind: .comic, title: "t", displayName: nil, author: nil, coverURL: nil,
            addedAt: Date(), updatedAt: Date(), lastReadSiteChapterId: nil,
            lastReadParagraph: nil, lastReadCharacterOffset: nil, lastReadFraction: nil,
            lastReadAt: nil, catalogUpdatedAt: nil
        )
    }
}
