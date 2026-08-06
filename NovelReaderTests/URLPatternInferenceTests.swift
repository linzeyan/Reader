import XCTest
@testable import NovelReader

/// Pins the inference against the URL shapes of the six sites that were
/// reconnoitred by hand.
///
/// These are the ground truth: the hand-written rules in `sites/*.json` were
/// verified end-to-end against the live sites, so if the inference reproduces
/// their behaviour on these URLs it will produce a working rule for a site
/// nobody has looked at. Each case asserts on *behaviour* (does the derived
/// regex recover the right ids from real links) rather than on the exact regex
/// text, because there is more than one correct regex.
final class URLPatternInferenceTests: XCTestCase {
    /// One site's real URLs, plus what a working rule must be able to do with them.
    private struct Case {
        let name: String
        let book: String
        let chapters: [String]
        let expectedBookId: String
        let expectedChapterId: String
        let expectedBookTemplate: String
        let expectedChapterTemplate: String
        /// Whether the derived book pattern can also recover the book id from a
        /// chapter URL. False where the site files chapters under a different
        /// path prefix than book pages — a real limitation, asserted so it is a
        /// known property rather than a surprise.
        let bookIdReadableFromChapterURL: Bool
    }

    private let cases: [Case] = [
        Case(
            name: "69shuba",
            book: "https://www.69shuba.com/book/90442.htm",
            chapters: ["https://www.69shuba.com/txt/90442/41051913", "https://www.69shuba.com/txt/90442/41051914"],
            expectedBookId: "90442",
            expectedChapterId: "41051913",
            expectedBookTemplate: "https://www.69shuba.com/book/{bookId}.htm",
            expectedChapterTemplate: "https://www.69shuba.com/txt/{bookId}/{chapterId}",
            bookIdReadableFromChapterURL: false
        ),
        Case(
            name: "czbooks",
            book: "https://czbooks.net/n/s6ojkc",
            // Real czbooks catalog links carry a query string; it must not be
            // mistaken for the part that identifies the chapter.
            chapters: ["https://czbooks.net/n/s6ojkc/s6675fe9?chapterNumber=1",
                       "https://czbooks.net/n/s6ojkc/z51cc7l?chapterNumber=2"],
            expectedBookId: "s6ojkc",
            expectedChapterId: "s6675fe9",
            expectedBookTemplate: "https://czbooks.net/n/{bookId}",
            expectedChapterTemplate: "https://czbooks.net/n/{bookId}/{chapterId}",
            bookIdReadableFromChapterURL: true
        ),
        Case(
            name: "hetubook",
            book: "https://www.hetubook.com/book/5763/index.html",
            chapters: ["https://www.hetubook.com/book/5763/4327466.html",
                       "https://www.hetubook.com/book/5763/4327467.html"],
            expectedBookId: "5763",
            expectedChapterId: "4327466",
            expectedBookTemplate: "https://www.hetubook.com/book/{bookId}/index.html",
            expectedChapterTemplate: "https://www.hetubook.com/book/{bookId}/{chapterId}.html",
            bookIdReadableFromChapterURL: true
        ),
        Case(
            name: "hjwzw",
            book: "https://tw.hjwzw.com/Book/1889",
            chapters: ["https://tw.hjwzw.com/Book/Read/1889,41051", "https://tw.hjwzw.com/Book/Read/1889,41052"],
            expectedBookId: "1889",
            expectedChapterId: "41051",
            expectedBookTemplate: "https://tw.hjwzw.com/Book/{bookId}",
            expectedChapterTemplate: "https://tw.hjwzw.com/Book/Read/{bookId},{chapterId}",
            bookIdReadableFromChapterURL: false
        ),
        Case(
            name: "quanben5",
            book: "https://big5.quanben5.com/n/xinghedadi/",
            chapters: ["https://big5.quanben5.com/n/xinghedadi/29881.html",
                       "https://big5.quanben5.com/n/xinghedadi/29882.html"],
            expectedBookId: "xinghedadi",
            expectedChapterId: "29881",
            expectedBookTemplate: "https://big5.quanben5.com/n/{bookId}/",
            expectedChapterTemplate: "https://big5.quanben5.com/n/{bookId}/{chapterId}.html",
            bookIdReadableFromChapterURL: true
        ),
        Case(
            name: "twking",
            book: "https://www.twking.org/216_216497/",
            chapters: ["https://www.twking.org/216_216497/12345.html",
                       "https://www.twking.org/216_216497/12346.html"],
            // The underscore is part of the id, not a separator.
            expectedBookId: "216_216497",
            expectedChapterId: "12345",
            expectedBookTemplate: "https://www.twking.org/{bookId}/",
            expectedChapterTemplate: "https://www.twking.org/{bookId}/{chapterId}.html",
            bookIdReadableFromChapterURL: true
        ),
    ]

    func testTemplatesMatchTheHandWrittenRules() throws {
        for item in cases {
            let inferred = try XCTUnwrap(
                URLPatternInference.infer(bookURL: URL(string: item.book)!,
                                          chapterURLs: item.chapters.map { URL(string: $0)! }),
                item.name
            )
            XCTAssertEqual(inferred.bookId, item.expectedBookId, item.name)
            XCTAssertEqual(inferred.bookTemplate, item.expectedBookTemplate, item.name)
            XCTAssertEqual(inferred.chapterTemplate, item.expectedChapterTemplate, item.name)
        }
    }

    /// The point of the derived regexes: a rule built from them must be able to
    /// take a real catalog link and say which chapter of which book it is. Every
    /// downstream stage — bookmarking, catalog filtering, download paths — is
    /// built on those two answers.
    func testDerivedRegexesRecoverIdsFromRealLinks() throws {
        for item in cases {
            let inferred = try XCTUnwrap(
                URLPatternInference.infer(bookURL: URL(string: item.book)!,
                                          chapterURLs: item.chapters.map { URL(string: $0)! }),
                item.name
            )
            let rule = makeRule(host: URL(string: item.book)!.host!, inferred: inferred)

            XCTAssertEqual(rule.bookId(from: URL(string: item.book)!), item.expectedBookId,
                           "\(item.name): book URL")
            XCTAssertEqual(rule.chapterId(from: URL(string: item.chapters[0])!), item.expectedChapterId,
                           "\(item.name): chapter URL")

            // A book page is not a chapter. If it were, `refreshCatalog` would
            // list the book's own page as chapter one.
            XCTAssertNil(rule.chapterId(from: URL(string: item.book)!),
                         "\(item.name): book URL must not read as a chapter")

            let ownerOfChapter = rule.bookId(from: URL(string: item.chapters[0])!)
            if item.bookIdReadableFromChapterURL {
                XCTAssertEqual(ownerOfChapter, item.expectedBookId, "\(item.name): owner of chapter")
            } else {
                // nil is the safe answer here: `BookService.refreshCatalog` only
                // rejects an entry whose owner is *known and different*, so an
                // unreadable owner keeps every chapter instead of dropping them.
                XCTAssertNil(ownerOfChapter, "\(item.name): owner of chapter")
            }
        }
    }

    func testAllChaptersOfABookSurviveCatalogFiltering() throws {
        for item in cases {
            let inferred = try XCTUnwrap(
                URLPatternInference.infer(bookURL: URL(string: item.book)!,
                                          chapterURLs: item.chapters.map { URL(string: $0)! }),
                item.name
            )
            let rule = makeRule(host: URL(string: item.book)!.host!, inferred: inferred)
            let ids = item.chapters.compactMap { rule.chapterId(from: URL(string: $0)!) }
            XCTAssertEqual(ids.count, item.chapters.count, "\(item.name): some chapter links were unreadable")
            XCTAssertEqual(Set(ids).count, item.chapters.count, "\(item.name): chapter ids collided")
        }
    }

    // MARK: - Degenerate inputs

    func testSingleChapterLinkStillYieldsATemplate() throws {
        let inferred = try XCTUnwrap(URLPatternInference.infer(
            bookURL: URL(string: "https://www.hetubook.com/book/5763/index.html")!,
            chapterURLs: [URL(string: "https://www.hetubook.com/book/5763/4327466.html")!]
        ))
        XCTAssertEqual(inferred.bookId, "5763")
        XCTAssertEqual(inferred.chapterTemplate, "https://www.hetubook.com/book/{bookId}/{chapterId}.html")
    }

    func testNoChapterLinksIsUndecidable() {
        XCTAssertNil(URLPatternInference.infer(
            bookURL: URL(string: "https://example.com/book/1")!, chapterURLs: []
        ))
    }

    /// Chapter links belonging to some *other* book carry none of this book's id,
    /// so there is nothing to anchor on. Guessing here would produce a rule that
    /// silently mixes books together.
    func testUnrelatedChapterLinksAreRejected() {
        XCTAssertNil(URLPatternInference.infer(
            bookURL: URL(string: "https://example.com/book/1234")!,
            chapterURLs: [URL(string: "https://example.com/txt/9999/1.html")!,
                          URL(string: "https://example.com/txt/8888/2.html")!]
        ))
    }

    // MARK: - Helper

    private func makeRule(host: String, inferred: URLPatternInference.Inferred) -> SiteRule {
        SiteRule(
            id: host, name: host, host: host,
            urls: SiteRule.URLTemplates(
                book: inferred.bookTemplate,
                catalog: inferred.bookTemplate,
                chapter: inferred.chapterTemplate
            ),
            idPatterns: SiteRule.IDPatterns(
                bookId: inferred.bookIdPattern,
                chapterId: inferred.chapterIdPattern
            ),
            search: nil,
            book: SiteRule.BookFields(
                title: SiteRule.Field(meta: "og:title", selector: "h1", attribute: nil),
                author: nil, cover: nil, category: nil, status: nil, intro: nil, latestChapter: nil
            ),
            catalog: SiteRule.Catalog(container: "body", linkSelector: "a", order: .ascending),
            chapter: SiteRule.Chapter(
                titleSelectors: ["h1"], contentSelectors: [], stripSelectors: [],
                dropParagraphPatterns: nil, prevSelector: nil, nextSelector: nil
            ),
            notes: nil
        )
    }
}
