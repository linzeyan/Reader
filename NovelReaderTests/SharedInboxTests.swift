import XCTest
@testable import NovelReader

/// Pages shared from another app, on their way from the share extension to the app.
///
/// The one part of sharing that can go wrong silently: the extension leaves an address and
/// says it got there, and nothing else is shown until the app is opened — so a share
/// dropped or added twice on the way would only ever look like the app forgetting.
final class SharedInboxTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = URL.temporaryDirectory.appendingPathComponent("SharedInboxTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Several pages shared in a row come back as they were shared — byte for byte, in
    /// that order — and only once: taking them is what the app does on coming forward, and
    /// a page taken twice would be a second run of the same addition.
    func testSharesComeBackInOrderExactlyAndOnlyOnce() throws {
        let inbox = SharedInbox(directory: directory)
        let shared = [
            "https://a.example/book/1",
            "https://a.example/read.php?id=12&page=3#top",
            "https://例子.example/書/斗羅大陸",
        ]
        for address in shared { try inbox.put(try XCTUnwrap(URL(string: address))) }
        XCTAssertFalse(inbox.isEmpty)

        XCTAssertEqual(inbox.take(), shared.map { URL(string: $0)!.absoluteString })
        XCTAssertTrue(inbox.isEmpty)
        XCTAssertEqual(inbox.take(), [])
    }

    /// An inbox nobody has shared to yet has no folder at all, and that is "nothing
    /// waiting", not a failure — it is what every launch before the first share sees.
    func testAnInboxNeverSharedToIsEmpty() {
        let inbox = SharedInbox(directory: directory)
        XCTAssertTrue(inbox.isEmpty)
        XCTAssertEqual(inbox.take(), [])
    }

    /// The app has to reach the container the extension writes to, or every share is
    /// confirmed and then never added. The extension's half is only seen on a device.
    func testTheAppReachesTheSharedContainer() {
        XCTAssertNotNil(SharedInbox.shared, "the app group should be in the app's entitlements")
    }

    /// App Store Connect expects an extension's version to be its app's, and the release
    /// bump edits the app's Info.plist by hand. This is what notices the second one was
    /// forgotten, before an upload does.
    func testTheShareExtensionShipsInsideTheAppAtItsVersion() throws {
        let plugIns = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let share = try XCTUnwrap(
            Bundle(url: plugIns.appendingPathComponent("ShareExtension.appex")),
            "the share extension should be embedded in the app"
        )
        for key in ["CFBundleShortVersionString", "CFBundleVersion"] {
            let app = Bundle.main.object(forInfoDictionaryKey: key) as? String
            XCTAssertNotNil(app)
            XCTAssertEqual(share.object(forInfoDictionaryKey: key) as? String, app, key)
        }
    }
}
