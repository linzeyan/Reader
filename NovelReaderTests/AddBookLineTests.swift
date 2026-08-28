import XCTest
@testable import NovelReader

/// Turning a paste into a list of books to add.
///
/// The part of batch adding that can be wrong silently. Everything past this point
/// announces itself — a bad address fails in front of the reader with a reason on its
/// own row — but a splitter that drops a line, reorders them, or hands the same
/// address over twice produces a run that looks entirely successful and is not the
/// one that was asked for.
final class AddBookLineTests: XCTestCase {
    /// The shape text arrives in: copied out of a notes app, with the indentation and
    /// trailing spaces that come with it, and a blank line where the reader hit return
    /// twice. None of that is an address, and none of it should become a failed row.
    func testALineIsAnAddressAndNothingElseIs() {
        let lines = AddBookLine.pasted("""
          https://a.example/book/1

        https://b.example/book/2\u{0020}\u{0020}

        """)

        XCTAssertEqual(
            lines.map(\.address),
            ["https://a.example/book/1", "https://b.example/book/2"]
        )
    }

    /// The order is the order they were pasted, and the ids run with it: the report the
    /// sheet draws is read against the list the reader is looking at, so a row that
    /// says "failed" has to be the line they can see failed.
    func testTheRunKeepsThePastedOrder() {
        let lines = AddBookLine.pasted("third\nfirst\nsecond")

        XCTAssertEqual(lines.map(\.address), ["third", "first", "second"])
        XCTAssertEqual(lines.map(\.id), [0, 1, 2])
    }

    /// A pasted list that mentions the same book twice is one book. The shelf would
    /// look the same either way — the row is keyed by site and book id — so the
    /// duplicate buys nothing and costs another two requests to a host behind a WAF,
    /// which is the currency this app is careful with.
    func testTheSameAddressTwiceIsAddedOnce() {
        let lines = AddBookLine.pasted("""
        https://a.example/book/1
        https://b.example/book/2
          https://a.example/book/1
        """)

        XCTAssertEqual(
            lines.map(\.address),
            ["https://a.example/book/1", "https://b.example/book/2"]
        )
    }

    /// The case this feature grew out of, still behaving as it always did: one address
    /// is one book, and the sheet that adds it is the sheet that always did.
    func testASingleAddressIsStillASingleAddress() {
        let lines = AddBookLine.pasted("  https://a.example/book/1  ")

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].address, "https://a.example/book/1")
    }

    /// Nothing usable in the box means nothing to run — the Add button reads this to
    /// decide whether it is available at all, so "only whitespace" must not come back
    /// as one empty address that fails in front of the reader for no reason.
    func testWhitespaceAloneIsNothingToAdd() {
        XCTAssertTrue(AddBookLine.pasted("   \n\n  \n").isEmpty)
        XCTAssertTrue(AddBookLine.pasted("").isEmpty)
    }
}
