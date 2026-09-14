import XCTest
@testable import NovelReader

/// The sheet that hands a Cloudflare wall to the reader has to say what asked for it.
///
/// It arrives at a moment that need not have anything to do with what the reader was
/// doing — a chapter fetched by scrolling across a seam, a catalog refreshing itself
/// behind the book screen, a download queue resuming when the app comes back — and
/// "which of those was it" is the one question the reader cannot answer from the screen.
/// A case with no words for it would show a raw key, which is worse than saying nothing.
final class ChallengeWordingTests: XCTestCase {
    private let everyCase: [ChallengeRequest.Doing] = [
        .chapter("長夜行"), .catalog("長夜行"), .download("長夜行"), .adding, .search, .source,
    ]

    func testEveryActivityTheSheetCanNameHasWordsForIt() {
        for doing in everyCase {
            let sentence = String(localized: doing.activity)
            XCTAssertFalse(
                sentence.hasPrefix("challenge.doing"),
                "\(doing) falls back to its key, which is what an untranslated string looks like"
            )
            XCTAssertFalse(sentence.isEmpty)
        }
    }

    /// The three that name a book have to actually name it. A format specifier that
    /// drifted in one language — or a translation that dropped it — reads as the app
    /// verifying on behalf of nothing in particular, which is the very thing this says.
    func testTheActivitiesThatNameABookPutItInTheSentence() {
        for doing: ChallengeRequest.Doing in [.chapter("長夜行"), .catalog("長夜行"), .download("長夜行")] {
            XCTAssertTrue(
                String(localized: doing.activity).contains("長夜行"),
                "\(doing) should say which book it is about"
            )
        }
    }
}
