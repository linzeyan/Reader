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

        return migrator
    }
}
