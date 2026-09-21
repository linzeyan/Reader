import GRDB
import XCTest
@testable import NovelReader

/// What the platform's SQLite will actually do with Chinese text.
///
/// This app ships no SQLite of its own — GRDB links the system library — so the
/// tokenizer the index is built on is whatever iOS happens to provide. FTS5's default
/// `unicode61` splits on whitespace and punctuation, which for a language that writes
/// without spaces means one token per paragraph: searching 「劍氣」 against it finds
/// nothing at all, because nothing in the index is shorter than a sentence. `trigram`
/// is the tokenizer that makes substring search of Chinese possible, and it only
/// arrived in SQLite 3.34.
///
/// So these run first, and the feature is built on top of what they prove. A red one
/// here is not a bug to fix upstairs — it means the whole approach is wrong for this
/// platform and something other than FTS5 has to carry the search.
final class SQLiteTrigramCapabilityTests: XCTestCase {
    private func queue() throws -> DatabaseQueue { try DatabaseQueue() }

    func testPlatformSQLiteAcceptsTheTrigramTokenizer() throws {
        let db = try queue()
        try db.write { db in
            let version = try String.fetchOne(db, sql: "SELECT sqlite_version()") ?? "?"
            try db.execute(sql: "CREATE VIRTUAL TABLE probe USING fts5(t, tokenize='trigram')")
            XCTAssertTrue(
                version.compare("3.34", options: .numeric) != .orderedAscending,
                "trigram needs SQLite 3.34; this platform reports \(version)"
            )
        }
    }

    /// The reason trigram is here at all: the default tokenizer cannot see inside a
    /// Chinese sentence.
    ///
    /// Asserted rather than assumed, because "FTS5 is available" and "FTS5 can search
    /// this app's text" are different claims and only the second one matters.
    func testDefaultTokenizerCannotFindAWordInsideAChineseSentence() throws {
        let db = try queue()
        try db.write { db in
            try db.execute(sql: "CREATE VIRTUAL TABLE plain USING fts5(t)")
            try db.execute(sql: "INSERT INTO plain(t) VALUES (?)", arguments: ["蕭炎握緊手中的玄重尺"])
            let hits = try Int.fetchOne(
                db, sql: "SELECT count(*) FROM plain WHERE plain MATCH ?", arguments: ["玄重尺"]
            )
            XCTAssertEqual(hits, 0, "unicode61 unexpectedly tokenised Chinese; re-read this design")
        }
    }

    func testTrigramFindsAWordInsideAChineseSentence() throws {
        let db = try queue()
        try db.write { db in
            try db.execute(sql: "CREATE VIRTUAL TABLE tri USING fts5(t, tokenize='trigram')")
            // Folded going in, exactly as the app's index stores it — a probe against raw
            // text would pass while the shipping arrangement failed.
            try db.execute(
                sql: "INSERT INTO tri(t) VALUES (?)",
                arguments: [FullTextQuery.folded("蕭炎握緊手中的玄重尺")]
            )
            for query in ["玄重尺", "握緊手中"] {
                let hits = try Int.fetchOne(
                    db, sql: "SELECT count(*) FROM tri WHERE tri MATCH ?",
                    arguments: [try XCTUnwrap(FullTextQuery.matchExpression(for: query))]
                )
                XCTAssertEqual(hits, 1, "trigram missed \(query)")
            }
            let miss = try Int.fetchOne(
                db, sql: "SELECT count(*) FROM tri WHERE tri MATCH ?",
                arguments: [try XCTUnwrap(FullTextQuery.matchExpression(for: "沒有這段"))]
            )
            XCTAssertEqual(miss, 0)
        }
    }

    /// The index this app builds stores no token positions, and that is the one thing a
    /// phrase query needs. FTS5 refuses rather than approximating, so a `matchExpression`
    /// that ever went back to emitting a phrase would not search badly — it would throw
    /// on every search. This is what pins the two halves of that decision together.
    func testTheIndexThisAppBuildsRefusesPhraseQueries() throws {
        let db = try queue()
        try db.write { db in
            try db.execute(
                sql: "CREATE VIRTUAL TABLE tri USING fts5(t, detail=none, tokenize='trigram')"
            )
            try db.execute(
                sql: "INSERT INTO tri(t) VALUES (?)",
                arguments: [FullTextQuery.folded("蕭炎握緊手中的玄重尺")]
            )
            XCTAssertThrowsError(
                try Int.fetchOne(
                    db, sql: "SELECT count(*) FROM tri WHERE tri MATCH ?",
                    arguments: ["\"握緊手中\""]
                ),
                "a multi-token phrase was accepted; detail=none may have stopped applying"
            )
            // And what the app actually sends does work against the same table.
            let hits = try Int.fetchOne(
                db, sql: "SELECT count(*) FROM tri WHERE tri MATCH ?",
                arguments: [try XCTUnwrap(FullTextQuery.matchExpression(for: "握緊手中"))]
            )
            XCTAssertEqual(hits, 1)
        }
    }

    /// The conjunction is allowed to bring back a chapter that does not really hold the
    /// phrase — `FullTextExcerpt` is the pass that drops those. What it must never do is
    /// lose one that does, because nothing downstream can recover a candidate that was
    /// never offered.
    func testTheConjunctionNeverLosesARealHit() throws {
        let db = try queue()
        try db.write { db in
            try db.execute(
                sql: "CREATE VIRTUAL TABLE tri USING fts5(t, detail=none, tokenize='trigram')"
            )
            let sentence = "蕭炎握緊手中的玄重尺，向前走去"
            try db.execute(
                sql: "INSERT INTO tri(t) VALUES (?)", arguments: [FullTextQuery.folded(sentence)]
            )
            // Every run of the sentence, at every length trigram can express.
            let characters = Array(sentence)
            for length in 3...characters.count {
                for start in 0...(characters.count - length) {
                    let run = String(characters[start ..< start + length])
                    let hits = try Int.fetchOne(
                        db, sql: "SELECT count(*) FROM tri WHERE tri MATCH ?",
                        arguments: [try XCTUnwrap(FullTextQuery.matchExpression(for: run))]
                    )
                    XCTAssertEqual(hits, 1, "the conjunction lost \(run)")
                }
            }
        }
    }

    /// Where trigram's floor is, stated as a test so the UI can be honest about it.
    ///
    /// A two-character query is the most ordinary search a Chinese reader makes — a name,
    /// a place — and trigram has no token short enough to answer it. Knowing this is a
    /// hard floor and not a bug is what the search field's minimum length is built on.
    func testTrigramCannotAnswerAQueryShorterThanThreeCharacters() throws {
        let db = try queue()
        try db.write { db in
            try db.execute(sql: "CREATE VIRTUAL TABLE tri USING fts5(t, tokenize='trigram')")
            try db.execute(sql: "INSERT INTO tri(t) VALUES (?)", arguments: ["蕭炎握緊手中的玄重尺"])
            let hits = try? Int.fetchOne(
                db, sql: "SELECT count(*) FROM tri WHERE tri MATCH ?", arguments: ["\"蕭炎\""]
            )
            XCTAssertNotEqual(hits, 1, "trigram answered a 2-character query; the floor moved")
        }
        // And the app does not ask: a query with no trigram in it has no expression, which
        // is what sends 「蕭炎」 down the scanning path instead of into the index.
        XCTAssertNil(FullTextQuery.matchExpression(for: "蕭炎"))
        XCTAssertNil(FullTextQuery.matchExpression(for: ""))
    }

    /// Punctuation in a query must not be read as FTS5 syntax.
    ///
    /// A reader searching 「"他說" - 沒有」 is searching for those characters, not composing a
    /// boolean expression; unquoted, FTS5 would parse the quotes and the minus and either
    /// throw or silently answer a different question.
    func testQueryPunctuationIsSearchedRatherThanParsed() throws {
        let db = try queue()
        try db.write { db in
            try db.execute(sql: "CREATE VIRTUAL TABLE tri USING fts5(t, tokenize='trigram')")
            try db.execute(
                sql: "INSERT INTO tri(t) VALUES (?)", arguments: [FullTextQuery.folded("他說：「不要」")]
            )
            let hits = try Int.fetchOne(
                db, sql: "SELECT count(*) FROM tri WHERE tri MATCH ?",
                arguments: [try XCTUnwrap(FullTextQuery.matchExpression(for: "：「不要」"))]
            )
            XCTAssertEqual(hits, 1)
        }
    }
}

/// Folding is what makes one index answer both scripts, and the offsets that locate a
/// hit rest on it not changing any string's length. Both halves are asserted here
/// because a regression in either is silent: the first loses half the library's matches,
/// the second misquotes every one it finds.
final class FullTextFoldingTests: XCTestCase {
    /// The whole point: a reader in Taiwan typing the title they know must reach a
    /// chapter a simplified site served, and the other way round. One folded form is how
    /// that happens without searching twice.
    func testBothScriptsOfOneTitleFoldOntoOneString() {
        XCTAssertEqual(FullTextQuery.folded("鬥破蒼穹"), FullTextQuery.folded("斗破苍穹"))
        XCTAssertEqual(FullTextQuery.folded("他讀的書"), FullTextQuery.folded("他读的书"))
    }

    /// Every hit is sliced out of the *original* paragraph at an offset found in its
    /// folded twin, so a fold that moved a character would quote the wrong words.
    func testFoldingNeverMovesAnOffset() {
        let samples = [
            "蕭炎握緊手中的玄重尺，向前走去。",
            "他读的是斗破苍穹这本书。",
            "Mixed 中文 and ASCII, 123.",
            "頭髮 鼠標 軟體 這裡著實",
        ]
        for sample in samples {
            XCTAssertEqual(
                FullTextQuery.folded(sample).utf16.count, sample.utf16.count,
                "fold changed the length of \(sample)"
            )
        }
    }

    /// Text with no Han in it is not a Chinese problem, and running a transform over
    /// every English article in the library would be paying for nothing.
    func testTextWithoutHanIsLeftAlone() {
        XCTAssertEqual(FullTextQuery.folded("plain english"), "plain english")
        XCTAssertEqual(FullTextQuery.folded(""), "")
    }
}

/// How a typed query becomes something the database can be asked, on both paths: the
/// index for anything with a trigram in it, and a scan for the two-character floor.
final class FullTextQueryBuildingTests: XCTestCase {
    private func queue() throws -> DatabaseQueue { try DatabaseQueue() }

    /// The index holds folded text, so trigrams cut from the query *as typed* would be
    /// looked up in a script the index never wrote. It is a silent failure — no error,
    /// just an empty result for every cross-script search — so it is pinned here rather
    /// than trusted to stay right.
    func testTrigramsAreCutFromTheFoldedQuery() {
        XCTAssertEqual(
            FullTextQuery.matchExpression(for: "鬥破蒼穹"),
            FullTextQuery.matchExpression(for: "斗破苍穹")
        )
    }

    /// The whole cross-script promise, end to end against a real index: a chapter stored
    /// in one script, found by a query typed in the other.
    func testAQueryInEitherScriptReachesAChapterStoredInTheOther() throws {
        let db = try queue()
        try db.write { db in
            try db.execute(
                sql: "CREATE VIRTUAL TABLE tri USING fts5(t, detail=none, tokenize='trigram')"
            )
            try db.execute(
                sql: "INSERT INTO tri(t) VALUES (?)",
                arguments: [FullTextQuery.folded("他讀的是鬥破蒼穹這本書")]
            )
            for query in ["鬥破蒼穹", "斗破苍穹"] {
                let hits = try Int.fetchOne(
                    db, sql: "SELECT count(*) FROM tri WHERE tri MATCH ?",
                    arguments: [try XCTUnwrap(FullTextQuery.matchExpression(for: query))]
                )
                XCTAssertEqual(hits, 1, "a traditional chapter was unreachable from \(query)")
            }
        }
    }

    /// Someone searching for 「100%」 means those four characters. Left alone the `%`
    /// would match the rest of the chapter, and the search would answer with every
    /// chapter containing "100".
    func testWildcardsInAQueryAreSearchedForRatherThanHonoured() throws {
        XCTAssertEqual(FullTextQuery.likePattern(for: "100%"), "%100\\%%")
        XCTAssertEqual(FullTextQuery.likePattern(for: "a_b"), "%a\\_b%")
        XCTAssertEqual(FullTextQuery.likePattern(for: "c\\d"), "%c\\\\d%")

        // And the escape clause the pattern is written for really does behave that way —
        // the pattern is only half the arrangement.
        let db = try queue()
        try db.write { db in
            try db.execute(sql: "CREATE TABLE t(x TEXT)")
            for line in ["折扣 100% 的書", "折扣 100 元的書"] {
                try db.execute(sql: "INSERT INTO t VALUES (?)", arguments: [line])
            }
            let hits = try Int.fetchOne(
                db, sql: "SELECT count(*) FROM t WHERE x LIKE ? ESCAPE '\\'",
                arguments: [FullTextQuery.likePattern(for: "100%")]
            )
            XCTAssertEqual(hits, 1, "the per-cent sign acted as a wildcard")
        }
    }

    /// The scan answers the same two scripts the index does, or the floor would be a
    /// place where cross-script search silently stops working.
    func testTheScanningPathFoldsTheWayTheIndexDoes() {
        XCTAssertEqual(
            FullTextQuery.likePattern(for: "鬥破"), FullTextQuery.likePattern(for: "斗破")
        )
    }
}

/// What a result row shows and where it jumps to.
///
/// These pin the two promises a row makes: the words around the hit are the reader's own
/// text in the script it was stored in, and the place it jumps to is the paragraph that
/// sentence is really in.
final class FullTextExcerptTests: XCTestCase {
    private let chapter = [
        "第一段沒有東西。",
        "蕭炎握緊手中的玄重尺，向前走去。",
    ]

    func testFindsTheParagraphAndOffsetTheHitIsIn() throws {
        let found = try XCTUnwrap(FullTextExcerpt.first(of: "玄重尺", in: chapter))
        XCTAssertEqual(found.paragraph, 1, "a jump into paragraph 0 would land a page early")
        XCTAssertEqual(found.characterOffset, 7)
        XCTAssertEqual(String(found.text[found.match]), "玄重尺")
    }

    func testAQueryThatIsNotThereFindsNothing() {
        XCTAssertNil(FullTextExcerpt.first(of: "根本沒有這句", in: chapter))
    }

    /// Text holding characters that are two UTF-16 units each, which is where the two
    /// units this code measures in come apart.
    ///
    /// A hit is located as a UTF-16 offset into a folded copy and then sliced out of the
    /// original, while the window around it is counted in `Character`s. With a CJK
    /// Extension B ideograph and an emoji in the paragraph, every offset past them
    /// differs from the character count, so a slice taken in the wrong unit lands inside
    /// a surrogate pair — and slicing a `String` there traps. A reader who crashes the
    /// app by searching for a word is the worst failure this feature has available to it,
    /// which is why the offsets are checked against real character boundaries before
    /// anything is sliced.
    func testTextWithSurrogatePairsIsQuotedWithoutTrapping() throws {
        let paragraphs = ["𠀀𠀁 蕭炎握緊手中的玄重尺 🗡️ 向前走去"]
        let found = try XCTUnwrap(FullTextExcerpt.first(of: "玄重尺", in: paragraphs))
        XCTAssertEqual(String(found.text[found.match]), "玄重尺")
        // The anchor is UTF-16, so it must count the surrogate pairs ahead of the hit —
        // a Character count here would send the reader several code units short.
        let expected = try XCTUnwrap(paragraphs[0].range(of: "玄重尺"))
            .lowerBound.utf16Offset(in: paragraphs[0])
        XCTAssertEqual(found.characterOffset, expected)
    }

    /// The same, for a hit that sits *after* an emoji in a paragraph long enough to be
    /// cut at both ends — so the window arithmetic, not just the anchor, runs past a
    /// surrogate pair.
    func testAWindowCutAroundASurrogatePairStaysWhole() throws {
        let filler = String(repeating: "雲🗡️", count: 30)
        let found = try XCTUnwrap(
            FullTextExcerpt.first(of: "玄重尺", in: [filler + "玄重尺" + filler])
        )
        XCTAssertEqual(String(found.text[found.match]), "玄重尺")
        XCTAssertTrue(found.text.hasPrefix("…"))
        XCTAssertTrue(found.text.hasSuffix("…"))
    }

    /// The reader is shown their own book, not the index's working copy.
    ///
    /// A hit is found through the folded form, so the lazy thing to quote is the folded
    /// form — and a reader in Taiwan would then see every result rewritten into
    /// simplified, including results from books that are entirely traditional. The
    /// quotation has to come back out of the stored text.
    func testTheQuotationIsInTheScriptTheChapterWasStoredIn() throws {
        let simplified = ["他读的是斗破苍穹这本书。"]
        let fromTraditionalQuery = try XCTUnwrap(
            FullTextExcerpt.first(of: "鬥破蒼穹", in: simplified)
        )
        XCTAssertEqual(String(fromTraditionalQuery.text[fromTraditionalQuery.match]), "斗破苍穹")
        XCTAssertFalse(fromTraditionalQuery.text.contains("鬥"))

        let traditional = ["他讀的是鬥破蒼穹這本書。"]
        let fromSimplifiedQuery = try XCTUnwrap(
            FullTextExcerpt.first(of: "斗破苍穹", in: traditional)
        )
        XCTAssertEqual(String(fromSimplifiedQuery.text[fromSimplifiedQuery.match]), "鬥破蒼穹")
        XCTAssertFalse(fromSimplifiedQuery.text.contains("斗"))
    }

    /// A short paragraph is quoted whole. Eliding one that was never cut would tell the
    /// reader there is more of the sentence to come back to when there is not.
    func testAShortParagraphIsQuotedWithoutElision() throws {
        let found = try XCTUnwrap(FullTextExcerpt.first(of: "玄重尺", in: chapter))
        XCTAssertEqual(found.text, chapter[1])
    }

    /// A long paragraph is cut down to the sentence around the hit, and says so at each
    /// end it cut.
    func testALongParagraphIsCutAroundTheHitAndSaysSo() throws {
        let filler = String(repeating: "雲", count: 60)
        let found = try XCTUnwrap(
            FullTextExcerpt.first(of: "玄重尺", in: [filler + "玄重尺" + filler])
        )
        XCTAssertTrue(found.text.hasPrefix("…"))
        XCTAssertTrue(found.text.hasSuffix("…"))
        XCTAssertEqual(String(found.text[found.match]), "玄重尺")
        XCTAssertEqual(
            found.text.count, FullTextExcerpt.context * 2 + 3 + 2,
            "the window grew; a result row is a list item, not a paragraph"
        )
        // The anchor still names the hit in the *paragraph*, not in the quotation — the
        // reader is sent to the sentence, and the elision is only what the row shows.
        XCTAssertEqual(found.characterOffset, 60)
    }
}
