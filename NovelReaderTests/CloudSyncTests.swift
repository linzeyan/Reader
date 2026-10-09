import XCTest
@testable import NovelReader

/// Stands in for the real key-value store, which needs an iCloud account and a signed
/// app. One per device, as the real one is: what a device has not been sent yet is
/// exactly what the resurrection came from, so a single shared store would hide it.
private final class SpyStore: NSUbiquitousKeyValueStore {
    var values: [String: Any] = [:]
    override func set(_ aData: Data?, forKey aKey: String) { values[aKey] = aData }
    override func set(_ anObject: Any?, forKey aKey: String) { values[aKey] = anObject }
    override func object(forKey aKey: String) -> Any? { values[aKey] }
    override func removeObject(forKey aKey: String) { values.removeValue(forKey: aKey) }
    override func synchronize() -> Bool { true }
    override var dictionaryRepresentation: [String: Any] { values }
}

/// One device: its library, its sources, and the store it syncs through, wired the way
/// `AppEnvironment` wires them.
@MainActor
private final class Device {
    let repo: LibraryRepo
    let sites = SiteStore(directory: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let store = SpyStore()
    let sync: CloudSync

    init(syncing: Bool = true) throws {
        repo = LibraryRepo(database: try AppDatabase.makeInMemory())
        let defaults = UserDefaults(suiteName: "novelreader.tests.\(UUID().uuidString)")!
        defaults.set(syncing, forKey: CloudSync.enabledDefaultsKey)
        sync = CloudSync(repo: repo, sites: sites, store: store, defaults: defaults)
        // Minus the files a unit test has none of.
        sync.onRemoteRemoval = { [repo] in try? repo.removeBookmark(bookId: $0.id) }
        sites.onImport = { [sync] in sync.push($0) }
        sites.onRemove = { [sync] in sync.removedRule(id: $0) }
    }
}

/// A book taken off one shelf comes off the others, and stays off.
///
/// "Stays" is the half that used to fail. Every device publishes its whole library at
/// each launch, so a removal that only deleted the book's key lasted until the next
/// device opened the app, which put the book back everywhere — the removal itself did
/// travel, it just never won.
@MainActor
final class CloudRemovalTests: XCTestCase {
    func testARemovalReachesTheOtherShelfAndOutlastsItsRepublishing() throws {
        let a = try Device(), b = try Device()
        let book = try a.repo.bookmark(
            siteId: "alpha", siteBookId: "1", title: "Gone", now: Date(timeIntervalSinceNow: -60)
        )
        a.sync.pushAll()
        b.store.values = a.store.values
        b.sync.pull()
        XCTAssertNotNil(try b.repo.book(id: book.id), "the book reached the second shelf")

        try a.repo.removeBookmark(bookId: book.id)
        a.sync.removed(book)
        // Meanwhile the second device launches, not having heard, and publishes its
        // library — this book included — over the store the removal just left.
        b.sync.pushAll()
        a.store.values["book.\(book.id)"] = b.store.values["book.\(book.id)"]

        a.sync.pull()
        XCTAssertNil(try a.repo.book(id: book.id), "a stale copy must not undo the removal")
        XCTAssertNil(a.store.values["book.\(book.id)"], "and is cleared, not left to outlive it")

        b.store.values = a.store.values
        b.sync.pull()
        XCTAssertNil(try b.repo.book(id: book.id), "the removal reached the second shelf")
    }

    /// The first sync of a device is a union: a book it kept while not syncing is part of
    /// what it brings. Removing it there would delete downloads nobody asked to lose.
    func testADeviceTurningSyncOnKeepsABookRemovedBeforeItJoined() throws {
        let a = try Device(), c = try Device(syncing: false)
        let book = try a.repo.bookmark(
            siteId: "alpha", siteBookId: "1", title: "Kept", now: Date(timeIntervalSinceNow: -60)
        )
        _ = try c.repo.bookmark(
            siteId: "alpha", siteBookId: "1", title: "Kept", now: Date(timeIntervalSinceNow: -60)
        )
        a.sync.pushAll()
        try a.repo.removeBookmark(bookId: book.id)
        a.sync.removed(book)

        c.store.values = a.store.values
        c.sync.isEnabled = true

        XCTAssertNotNil(try c.repo.book(id: book.id), "a joining device keeps its own books")
        XCTAssertNotNil(c.store.values["book.\(book.id)"], "and publishes them, removal or not")
        XCTAssertNil(
            c.store.values["removed.\(book.id)"],
            "the removal is lifted, or every other device would take it off again"
        )
    }
}

/// A source installed or removed on one device is installed or removed on the others —
/// the same as the subscriptions listed beside it, which have always synced as books.
@MainActor
final class CloudSourceSyncTests: XCTestCase {
    private static let ruleJSON = """
    {
      "id": "demo-novel",
      "name": "Demo Novel",
      "host": "novel.test",
      "urls": {
        "book": "https://novel.test/n/{bookId}",
        "catalog": "https://novel.test/n/{bookId}",
        "chapter": "https://novel.test/n/{bookId}/{chapterId}"
      },
      "idPatterns": { "bookId": "/n/([0-9a-z]+)", "chapterId": "/n/[0-9a-z]+/([0-9a-z]+)" },
      "book": { "title": { "meta": "og:title" } },
      "catalog": { "container": "#catalog", "linkSelector": "a", "order": "ascending" },
      "chapter": {
        "titleSelectors": ["h1"], "contentSelectors": [".content"], "stripSelectors": ["script"]
      },
      "notes": ["for whoever maintains the rule, and too big to spend the store on"]
    }
    """

    func testASourceArrivesOnTheOtherDeviceAndIsNotSentBack() throws {
        let a = try Device(), b = try Device()
        try a.sites.importRule(data: Data(Self.ruleJSON.utf8))
        XCTAssertNotNil(a.store.values["rule.demo-novel"], "installing publishes")
        // Installed a minute ago, so that arriving is visibly later than being installed —
        // within one second the two times are the same and the test would prove nothing.
        let file = try XCTUnwrap(a.sites.fileURL(forRuleId: "demo-novel"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: file.path
        )
        a.sync.pushAll()
        let sent = try XCTUnwrap(a.store.values["rule.demo-novel"] as? Data)

        b.store.values = a.store.values
        b.sync.pull()
        let arrived = try XCTUnwrap(b.sites.rule(id: "demo-novel"), "the source reached the other device")
        XCTAssertNil(arrived.notes, "notes stay behind: they can be ten times the rule")

        // Stamped with the time it arrived, the copy would look newer than the one it came
        // from, and the two devices would trade it back and forth at every launch.
        b.sync.pushAll()
        let resent = try XCTUnwrap(b.store.values["rule.demo-novel"] as? Data)
        XCTAssertEqual(try publishedAt(resent), try publishedAt(sent))
    }

    /// Read off the wire rather than compared as bytes, which an encoder is free to order
    /// differently for the same record.
    private func publishedAt(_ data: Data) throws -> Double {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(json["updatedAt"] as? Double)
    }

    func testRemovingASourceRemovesItOnTheOtherDevice() throws {
        let a = try Device(), b = try Device()
        try a.sites.importRule(data: Data(Self.ruleJSON.utf8))
        b.store.values = a.store.values
        b.sync.pull()
        XCTAssertNotNil(b.sites.rule(id: "demo-novel"))

        try a.sites.remove(id: "demo-novel")
        b.store.values = a.store.values
        b.sync.pull()
        XCTAssertNil(b.sites.rule(id: "demo-novel"), "the removal reached the other device")
    }
}

/// How far a subscription was read reaches the other device as one date.
@MainActor
final class CloudFeedReadTests: XCTestCase {
    func testReadingOnOneDeviceReadsEverythingUpToItOnTheOther() throws {
        let a = try Device(), b = try Device()
        let address = "https://demo.test/feed.xml"
        let first = Date(timeIntervalSinceNow: -10 * 24 * 3600)
        for device in [a, b] {
            let feed = try device.repo.bookmark(
                siteId: Book.feedSiteId, siteBookId: address, kind: .feed, title: "feed", now: first
            )
            try device.repo.mergeCatalog(
                bookId: feed.id,
                entries: ["a", "b", "c"].enumerated().map { offset, id in
                    (
                        siteChapterId: id, title: id, url: "https://demo.test/\(id)",
                        publishedAt: first.addingTimeInterval(Double(offset) * 24 * 3600)
                    )
                },
                now: first
            )
        }
        let id = Book.makeId(siteId: Book.feedSiteId, siteBookId: address)
        // "a" skipped past, "b" read, "c" not reached.
        try a.repo.setArticlesRead(true, bookId: id, siteChapterIds: ["b"])
        a.sync.pushAll()

        b.store.values = a.store.values
        b.sync.pull()

        XCTAssertEqual(
            try b.repo.chapters(bookId: id).filter(\.isUnread).map(\.siteChapterId), ["c"]
        )
    }
}

/// The two ways a write can fail to reach the store, neither of which the store reports as
/// an error to the code that wrote it.
@MainActor
final class CloudSyncLimitTests: XCTestCase {
    /// Apple raises an exception for a key past 128 UTF-16 units, and a subscription's key
    /// carries its address. A long one travels under its digest instead — there, and off
    /// again — while a short one keeps the very key a device on an older build reads.
    func testASubscriptionWhoseAddressIsTooLongForAKeyStillSyncs() throws {
        let a = try Device(), b = try Device()
        let long = "https://news.example/rss/search?q=" + String(repeating: "%E5%8A%8D", count: 12)
        let tooLong = try a.repo.bookmark(
            siteId: Book.feedSiteId, siteBookId: long, kind: .feed, title: "long",
            now: Date(timeIntervalSinceNow: -60)
        )
        let fine = try a.repo.bookmark(
            siteId: Book.feedSiteId, siteBookId: "https://demo.test/feed.xml", kind: .feed, title: "fine"
        )
        func noKeyTooLong(_ device: Device) -> Bool {
            !device.store.values.keys.contains { $0.utf16.count > 128 }
        }

        a.sync.pushAll()
        XCTAssertTrue(noKeyTooLong(a), "no key Apple would refuse with an exception is written")
        XCTAssertNotNil(a.store.values["book.\(fine.id)"], "a short address keeps its plain key")

        b.store.values = a.store.values
        b.sync.pull()
        XCTAssertEqual(try b.repo.book(id: tooLong.id)?.title, "long", "the long one arrives")

        try a.repo.removeBookmark(bookId: tooLong.id)
        a.sync.removed(tooLong)
        XCTAssertTrue(noKeyTooLong(a), "nor by its removal")
        b.store.values = a.store.values
        b.sync.pull()
        XCTAssertNil(try b.repo.book(id: tooLong.id), "and so does taking it off the shelf")
        XCTAssertNotNil(try b.repo.book(id: fine.id))
    }

    /// The store reports a write that did not fit as a change notification, not an error.
    /// Taken for a change, it was a pull that found nothing, and the reader never learned
    /// that part of their shelf had stopped syncing.
    func testAWriteThatDidNotFitIsShownAndARemovalClearsIt() throws {
        let device = try Device()
        NotificationCenter.default.post(
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: device.store,
            userInfo: [NSUbiquitousKeyValueStoreChangeReasonKey: NSUbiquitousKeyValueStoreQuotaViolationChange]
        )
        let shown = expectation(for: NSPredicate { _, _ in device.sync.lastError != nil }, evaluatedWith: nil)
        wait(for: [shown], timeout: 5)

        let book = try device.repo.bookmark(siteId: "alpha", siteBookId: "1", title: "Gone")
        device.sync.removed(book)
        XCTAssertNil(device.sync.lastError, "removing is what makes room, so the warning goes")
    }
}
