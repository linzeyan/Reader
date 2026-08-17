import Foundation
import GRDB

/// Owns the SQLite connection and schema.
///
/// SQLite (not SwiftData) because the hot query is "which chapters of this book
/// are downloaded" over indexes that can run to thousands of rows per book, and
/// because the download index has to stay usable independently of any CloudKit
/// schema constraints.
final class AppDatabase {
    let writer: any DatabaseWriter

    init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// On-disk database in Application Support. Marked as excluded from iCloud
    /// backup is *not* wanted here: bookmarks are cheap and users expect a
    /// restored device to keep its library even before iCloud sync is enabled.
    static func makeShared() throws -> AppDatabase {
        let folder = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: folder.appendingPathComponent("library.sqlite").path)
        return try AppDatabase(queue)
    }

    /// In-memory instance for tests.
    static func makeInMemory() throws -> AppDatabase {
        try AppDatabase(try DatabaseQueue())
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1.library") { db in
            try db.create(table: Book.databaseTableName) { t in
                t.primaryKey("id", .text)
                t.column("siteId", .text).notNull().indexed()
                t.column("siteBookId", .text).notNull()
                t.column("title", .text).notNull()
                t.column("displayName", .text)
                t.column("author", .text)
                t.column("coverURL", .text)
                t.column("addedAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("lastReadChapterIndex", .integer)
                t.column("lastReadOffset", .integer)
            }

            try db.create(table: Chapter.databaseTableName) { t in
                t.primaryKey("id", .text)
                // Deleting a book must take its whole chapter index with it —
                // orphaned rows would corrupt every "downloaded count" query.
                t.column("bookId", .text)
                    .notNull()
                    .indexed()
                    .references(Book.databaseTableName, onDelete: .cascade)
                t.column("siteChapterId", .text).notNull()
                t.column("index", .integer).notNull()
                t.column("title", .text).notNull()
                t.column("url", .text).notNull()
                t.column("downloadedAt", .datetime)
            }

            // Reading order lookups and "next undownloaded chapter" scans both
            // hit this pair.
            try db.create(
                index: "chapter_book_index",
                on: Chapter.databaseTableName,
                columns: ["bookId", "index"],
                unique: true
            )
        }

        // When the chapter index was last fetched from the site. Without it the
        // app cannot tell "this book has no catalog yet" from "this catalog was
        // read a week ago", so it either refetches every time a book is opened
        // or never notices new chapters. Nullable: books bookmarked before this
        // migration genuinely have no answer, and guessing one would be a lie.
        migrator.registerMigration("v2.catalogFreshness") { db in
            try db.alter(table: Book.databaseTableName) { t in
                t.add(column: "catalogUpdatedAt", .datetime)
            }
        }

        // When a catalog refresh first saw a chapter, so the site adding chapter
        // 431 can be told apart from the reader simply not having reached it.
        // Nullable, and deliberately left null for everything already indexed:
        // there is no honest answer for those rows, and calling them new would
        // light up every book in the library on the first launch after an update.
        migrator.registerMigration("v3.chapterAddedAt") { db in
            try db.alter(table: Chapter.databaseTableName) { t in
                t.add(column: "addedAt", .datetime)
            }
        }

        // The reading position becomes a text anchor (see `TextAnchor`), and saved
        // positions get a table of their own.
        //
        // `lastReadOffset` is *copied*, not discarded: despite the name it already
        // held a paragraph index — the scroll view recorded which paragraph came
        // into view — so carrying it over under its true name is the honest
        // conversion, where resetting it would throw away a position the app really
        // does know and drop every reader back at the top of their chapter.
        //
        // The character offset stays null. Nothing has ever recorded one, and
        // deriving a plausible value would claim precision the old data never had.
        //
        // The old column is dropped rather than left in place: two columns for one
        // number is how the two of them end up disagreeing.
        migrator.registerMigration("v4.readingAnchors") { db in
            try db.alter(table: Book.databaseTableName) { t in
                t.add(column: "lastReadParagraph", .integer)
                t.add(column: "lastReadCharacterOffset", .integer)
            }
            try db.execute(sql: """
                UPDATE "book" SET "lastReadParagraph" = "lastReadOffset"
                WHERE "lastReadOffset" IS NOT NULL
                """)
            try db.alter(table: Book.databaseTableName) { t in
                t.drop(column: "lastReadOffset")
            }

            // No unique index on the position: `ReadingBookmark.makeId` derives the
            // primary key from it, so a duplicate cannot be inserted in the first
            // place. Deleting a book takes its saved positions with it — a bookmark
            // into a book that is no longer on the shelf has nowhere to jump.
            try db.create(table: ReadingBookmark.databaseTableName) { t in
                t.primaryKey("id", .text)
                t.column("bookId", .text)
                    .notNull()
                    .indexed()
                    .references(Book.databaseTableName, onDelete: .cascade)
                t.column("chapterIndex", .integer).notNull()
                t.column("paragraph", .integer).notNull()
                t.column("characterOffset", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("excerpt", .text)
            }
        }

        // Highlights: a pair of anchors instead of one, in a table of their own.
        //
        // Not columns hung off `readingBookmark` with a nullable end: a bookmark and a
        // highlight are read back for different screens, ordered differently and
        // deleted independently, and a table where half the rows leave half the
        // columns null is a table every query has to remember to filter.
        //
        // The excerpt is `notNull` where the bookmark's is not: a highlight is made out
        // of text that was on screen, so there is always something honest to store,
        // and the list would be unreadable without it.
        migrator.registerMigration("v5.highlights") { db in
            try db.create(table: TextHighlight.databaseTableName) { t in
                // No unique index on the span: `TextHighlight.makeId` derives the
                // primary key from it, so marking the same passage twice cannot insert
                // a second row. Deleting a book takes its highlights with it, for the
                // same reason its bookmarks go — they point into text that is gone.
                t.primaryKey("id", .text)
                t.column("bookId", .text)
                    .notNull()
                    .indexed()
                    .references(Book.databaseTableName, onDelete: .cascade)
                t.column("chapterIndex", .integer).notNull()
                t.column("startParagraph", .integer).notNull()
                t.column("startCharacterOffset", .integer).notNull()
                t.column("endParagraph", .integer).notNull()
                t.column("endCharacterOffset", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("excerpt", .text).notNull()
            }
        }

        // Everything that points at a chapter names it the way the site does.
        //
        // `chapterIndex` was the chapter's place in the catalog, which
        // `LibraryRepo.replaceCatalog` recomputes on every refresh — so the site
        // inserting a chapter mid-book slid every mark after it onto the following
        // chapter's text: bookmarks jumped a chapter late, highlights painted the wrong
        // sentence, and the reading position moved a chapter back. `siteChapterId` is
        // what the site itself calls the chapter and survives the renumbering.
        //
        // The number is not kept alongside it. Reading order lives in `chapter."index"`,
        // one row per chapter, and the handful of queries that need to compare positions
        // join for it (`newChapterCounts`, `lastReadChapterIndexes`, and the ordering of
        // both mark lists). A cached copy next to every mark is precisely the arrangement
        // being deleted here, and it would have to be re-synced by every future writer of
        // the catalog — one missed sync and the marks drift again.
        //
        // Backfilled through the catalog as it stands: the index a mark holds names a
        // chapter *today*, and that chapter's id is the only honest reading of it.
        //
        // A mark whose index names no chapter — the catalog shrank, or the book has none
        // — is dropped. It never had a stable identity to convert, so there is nothing
        // to carry across, and a row that can never resolve would be dead weight in
        // every query that touches the table. This is not the same case as a chapter the
        // site removes *later*: such a row keeps a perfectly good id, stays, and starts
        // resolving again if the site puts the chapter back (see `ReadingMarksView`).
        // The book's own position is nullable, so it simply becomes null and the book
        // reads as unopened, the way v3 and v4 left what they could not derive.
        migrator.registerMigration("v6.stableChapterIdentity") { db in
            try db.alter(table: Book.databaseTableName) { t in
                t.add(column: "lastReadSiteChapterId", .text)
            }
            try db.execute(sql: """
                UPDATE "book" SET "lastReadSiteChapterId" = (
                    SELECT "siteChapterId" FROM "chapter"
                    WHERE "chapter"."bookId" = "book"."id"
                      AND "chapter"."index" = "book"."lastReadChapterIndex"
                )
                """)
            // No chapter to name means no position at all: a paragraph hanging under a
            // null chapter is a half-position that every later reader of this schema
            // would have to work out the meaning of.
            try db.execute(sql: """
                UPDATE "book"
                SET "lastReadParagraph" = NULL, "lastReadCharacterOffset" = NULL
                WHERE "lastReadSiteChapterId" IS NULL
                """)
            try db.alter(table: Book.databaseTableName) { t in
                t.drop(column: "lastReadChapterIndex")
            }

            // The two mark tables are rebuilt rather than altered in place. Chapter
            // identity is part of the row id (`ReadingBookmark.makeId`), so every id has
            // to be rewritten with the column — and rewriting a unique key in place can
            // fail halfway: the new id of a mark in chapter 5 is the old id of a mark in
            // chapter 6 at the same anchor, and SQLite checks uniqueness row by row.
            // Building the new table beside the old one has no such ordering problem,
            // and it gets `siteChapterId` the `NOT NULL` that `ALTER TABLE ADD COLUMN`
            // cannot give without inventing a default chapter id.
            //
            // The `JOIN` is what drops the marks that cannot be converted: no chapter at
            // that index means nothing to name.
            //
            // The id format is spelled out in SQL rather than taken from the model on
            // purpose. A migration has to keep converting to the shape it converted to
            // the day it shipped; calling `makeId` would silently rewrite this backfill
            // the next time that format changes.
            try db.create(table: "readingBookmark_v6") { t in
                t.primaryKey("id", .text)
                t.column("bookId", .text)
                    .notNull()
                    .references(Book.databaseTableName, onDelete: .cascade)
                t.column("siteChapterId", .text).notNull()
                t.column("paragraph", .integer).notNull()
                t.column("characterOffset", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("excerpt", .text)
            }
            try db.execute(sql: """
                INSERT INTO "readingBookmark_v6"
                    ("id", "bookId", "siteChapterId", "paragraph", "characterOffset",
                     "createdAt", "excerpt")
                SELECT "readingBookmark"."bookId" || '|' || "chapter"."siteChapterId" || '|'
                           || "readingBookmark"."paragraph" || '|'
                           || "readingBookmark"."characterOffset",
                       "readingBookmark"."bookId", "chapter"."siteChapterId",
                       "readingBookmark"."paragraph", "readingBookmark"."characterOffset",
                       "readingBookmark"."createdAt", "readingBookmark"."excerpt"
                FROM "readingBookmark"
                JOIN "chapter" ON "chapter"."bookId" = "readingBookmark"."bookId"
                              AND "chapter"."index" = "readingBookmark"."chapterIndex"
                """)
            try db.drop(table: ReadingBookmark.databaseTableName)
            try db.rename(table: "readingBookmark_v6", to: ReadingBookmark.databaseTableName)
            // Named explicitly, and created after the rename, so the schema an upgrade
            // ends up with is the one a fresh install gets — an index carried over from
            // the table's temporary name would differ between the two.
            try db.create(
                index: "readingBookmark_book",
                on: ReadingBookmark.databaseTableName,
                columns: ["bookId"]
            )

            try db.create(table: "textHighlight_v6") { t in
                t.primaryKey("id", .text)
                t.column("bookId", .text)
                    .notNull()
                    .references(Book.databaseTableName, onDelete: .cascade)
                t.column("siteChapterId", .text).notNull()
                t.column("startParagraph", .integer).notNull()
                t.column("startCharacterOffset", .integer).notNull()
                t.column("endParagraph", .integer).notNull()
                t.column("endCharacterOffset", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("excerpt", .text).notNull()
            }
            try db.execute(sql: """
                INSERT INTO "textHighlight_v6"
                    ("id", "bookId", "siteChapterId", "startParagraph", "startCharacterOffset",
                     "endParagraph", "endCharacterOffset", "createdAt", "excerpt")
                SELECT "textHighlight"."bookId" || '|' || "chapter"."siteChapterId" || '|'
                           || "textHighlight"."startParagraph" || '|'
                           || "textHighlight"."startCharacterOffset" || '|'
                           || "textHighlight"."endParagraph" || '|'
                           || "textHighlight"."endCharacterOffset",
                       "textHighlight"."bookId", "chapter"."siteChapterId",
                       "textHighlight"."startParagraph", "textHighlight"."startCharacterOffset",
                       "textHighlight"."endParagraph", "textHighlight"."endCharacterOffset",
                       "textHighlight"."createdAt", "textHighlight"."excerpt"
                FROM "textHighlight"
                JOIN "chapter" ON "chapter"."bookId" = "textHighlight"."bookId"
                              AND "chapter"."index" = "textHighlight"."chapterIndex"
                """)
            try db.drop(table: TextHighlight.databaseTableName)
            try db.rename(table: "textHighlight_v6", to: TextHighlight.databaseTableName)
            try db.create(
                index: "textHighlight_book",
                on: TextHighlight.databaseTableName,
                columns: ["bookId"]
            )

            // Every stored position now resolves through this pair — once per book for
            // the shelf, once per mark for the two lists — where the existing index on
            // `("bookId", "index")` answers the opposite question. Unique because it
            // already is: `Chapter.id` is built out of exactly these two columns.
            try db.create(
                index: "chapter_book_siteChapterId",
                on: Chapter.databaseTableName,
                columns: ["bookId", "siteChapterId"],
                unique: true
            )
        }

        // How far into the chapter the stored position sits, as a share of its text.
        //
        // A column rather than something the shelf derives: turning a paragraph index
        // into a share needs the chapter's text, and the shelf holds a row per book and
        // no text at all. So the reader — the one place that has the chapter open —
        // writes the number down alongside the anchor it belongs to.
        //
        // Nullable and deliberately not backfilled. The text of a chapter read online is
        // held nowhere on the device, so for most existing positions there is no
        // denominator to divide by, and a share guessed from the paragraph index alone
        // would be a number with no chapter behind it. Null means what the shelf said
        // before this column existed: which chapter, and nothing finer.
        migrator.registerMigration("v7.readingShare") { db in
            try db.alter(table: Book.databaseTableName) { t in
                t.add(column: "lastReadFraction", .double)
            }
        }

        // When the reader was last in a book, so "recently read" can be answered
        // rather than approximated. See `Book.lastReadAt` for why `updatedAt` is not
        // that answer.
        //
        // Backfilled from `updatedAt` for books that have a reading position, and
        // deliberately left null for the rest. That is exactly the approximation
        // `LibrarySort.recentlyRead` has been shipping — position as the gate,
        // `updatedAt` as the order — so an upgrade keeps the shelf it had and the new
        // history opens with the books the reader would expect in it, rather than
        // empty. Every write from here on is the real thing, and each one replaces a
        // backfilled guess the first time that book is opened.
        migrator.registerMigration("v8.lastReadAt") { db in
            try db.alter(table: Book.databaseTableName) { t in
                t.add(column: "lastReadAt", .datetime)
            }
            try db.execute(sql: """
                UPDATE "book" SET "lastReadAt" = "updatedAt"
                WHERE "lastReadSiteChapterId" IS NOT NULL
                """)
        }

        return migrator
    }
}
