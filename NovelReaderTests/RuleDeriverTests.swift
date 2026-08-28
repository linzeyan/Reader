import XCTest
@testable import NovelReader

/// What derivation decides before it touches the network.
///
/// The rest of `RuleDeriver` can only be judged against a live site — that is
/// `LiveSiteTests`, which is opt-in and skipped by default. This is the one
/// decision that needs no site at all, and it is the one a user meets first.
@MainActor
final class RuleDeriverTests: XCTestCase {
    /// A written rule for a real site, in the form rules actually arrive in.
    private static let installedJSON = """
    {
      "id": "69shuba",
      "name": "69書吧",
      "host": "www.69shuba.com",
      "urls": {
        "book": "https://www.69shuba.com/book/{bookId}.htm",
        "catalog": "https://www.69shuba.com/book/{bookId}/",
        "chapter": "https://www.69shuba.com/txt/{bookId}/{chapterId}"
      },
      "idPatterns": {
        "bookId": "/book/(\\\\d+)(?:\\\\.htm|/)",
        "chapterId": "/txt/\\\\d+/(\\\\d+)"
      },
      "book": { "title": { "meta": "og:novel:book_name" } },
      "catalog": {
        "container": "#catalog",
        "linkSelector": "a[href*='/txt/']",
        "order": "ascending"
      },
      "chapter": {
        "titleSelectors": ["h1"],
        "contentSelectors": [".txtnav"],
        "stripSelectors": ["script"]
      }
    }
    """

    private func deriver() throws -> RuleDeriver {
        RuleDeriver(
            fetcher: WebFetcher(),
            installed: [try JSONDecoder().decode(SiteRule.self, from: Data(Self.installedJSON.utf8))]
        )
    }

    /// A site that already has a source is refused, not derived a second time.
    ///
    /// It could never have been a merge: a derived rule is identified by its host
    /// and a written one names itself, so the second never replaces the first —
    /// both stay installed and the site is split. `SiteStore.rule(matching:)` then
    /// hands a pasted link to whichever name sorts first, and the same book added
    /// under each id becomes two books, with two reading positions and two sets of
    /// downloaded chapters. The report this comes from was a shelf holding a
    /// curated 69書吧 and a derived www.69shuba.com side by side, with no way to
    /// tell which one anything was using.
    ///
    /// Thrown before the first fetch, so the check costs nothing on a host that
    /// throttles — and so this test needs no network.
    func testASiteThatAlreadyHasASourceIsNotDerivedAgain() async throws {
        let url = try XCTUnwrap(URL(string: "https://www.69shuba.com/book/90442.htm"))
        do {
            _ = try await deriver().derive(from: url)
            XCTFail("a site with a source must not be derived a second time")
        } catch let error as RuleDeriver.DeriveError {
            guard case .alreadyCovered(let name) = error else {
                return XCTFail("expected .alreadyCovered, got \(error)")
            }
            // Named, because "you already have this" is useless if the user
            // cannot find the thing they already have.
            XCTAssertEqual(name, "69書吧")
        }
    }

    /// The refusal is by host, not by the shape of the pasted URL: a chapter page,
    /// a catalog page and the homepage are all the same site. Anything narrower
    /// would let the duplicate in through a page the user happened to be on.
    func testTheRefusalCoversEveryPageOfTheSameSite() async throws {
        for address in [
            "https://www.69shuba.com/txt/90442/41051913",
            "https://www.69shuba.com/book/90442/",
            "https://www.69shuba.com/",
        ] {
            let url = try XCTUnwrap(URL(string: address))
            do {
                _ = try await deriver().derive(from: url)
                XCTFail("\(address) belongs to a site that already has a source")
            } catch let error as RuleDeriver.DeriveError {
                guard case .alreadyCovered = error else {
                    return XCTFail("expected .alreadyCovered for \(address), got \(error)")
                }
            }
        }
    }
}
