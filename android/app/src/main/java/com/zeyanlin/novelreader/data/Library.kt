package com.zeyanlin.novelreader.data

import androidx.room.Dao
import androidx.room.Database
import androidx.room.Delete
import androidx.room.Embedded
import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.Insert
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.RoomDatabase
import androidx.room.Transaction
import androidx.room.Update
import androidx.room.Upsert
import com.zeyanlin.novelreader.services.BookService
import com.zeyanlin.novelreader.services.LibrarySearch
import com.zeyanlin.novelreader.services.SiteStore
import androidx.room.OnConflictStrategy
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase
import com.zeyanlin.novelreader.siterules.SiteRule
import kotlinx.coroutines.flow.Flow
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import java.time.Instant
import java.time.OffsetDateTime

/**
 * A bookmarked book — the iOS `Book`, at its final schema. Times are epoch milliseconds.
 * The reading position is a chapter, a paragraph and a UTF-16 offset into it, as on iOS.
 */
@Entity(tableName = "book")
data class Book(
    @PrimaryKey val id: String,
    val siteId: String,
    val siteBookId: String,
    val kind: SiteRule.Kind,
    val title: String,
    val displayName: String?,
    val author: String?,
    val coverURL: String?,
    val addedAt: Long,
    val updatedAt: Long,
    val lastReadSiteChapterId: String?,
    val lastReadParagraph: Int?,
    val lastReadCharacterOffset: Int?,
    val lastReadFraction: Double?,
    val lastReadAt: Long?,
    val catalogUpdatedAt: Long?,
) {
    val shownName: String get() = displayName?.takeIf { it.isNotEmpty() } ?: title

    /** Imported from a file: exists nowhere but here, so there is nothing to refetch it from. */
    val isLocal: Boolean get() = siteId == SiteStore.LOCAL_SITE_ID

    /**
     * A catalog older than a day is refetched when the book is opened; a subscription's after five
     * minutes, since being read is its whole reason to change — and opening one is the only time it is asked.
     */
    val catalogIsStale: Boolean
        get() = catalogUpdatedAt == null ||
            System.currentTimeMillis() - catalogUpdatedAt > if (kind == SiteRule.Kind.FEED) FEED_MAX_AGE_MS else CATALOG_MAX_AGE_MS

    /**
     * The reading position's place in [chapters] — the iOS `lastReadIndex(in:)`. Null when the book
     * was never opened, or the site has dropped the chapter it was left in: no place in this catalog.
     */
    fun lastReadIndex(chapters: List<Chapter>): Int? = chapters.firstOrNull { it.siteChapterId == lastReadSiteChapterId }?.index

    companion object {
        const val CATALOG_MAX_AGE_MS = 24 * 60 * 60 * 1000L
        const val FEED_MAX_AGE_MS = 5 * 60 * 1000L

        fun makeId(siteId: String, siteBookId: String) = "$siteId|$siteBookId"

        /** The reader's own name as stored: a blank one is none, or the shelf would draw an empty row. */
        fun customName(typed: String?) = typed?.trim()?.takeIf { it.isNotEmpty() }
    }
}

/**
 * One row of a book's chapter index. `addedAt` is null for chapters that came with the first
 * catalog, so only later arrivals read as new; `downloadedAt` is set by downloads only —
 * text kept from reading lives in [CachedChapter] and does not count.
 */
@Entity(
    tableName = "chapter",
    foreignKeys = [ForeignKey(Book::class, ["id"], ["bookId"], onDelete = ForeignKey.CASCADE)],
    // Not unique, unlike iOS: a catalog rewrite then needs no parking of moved rows.
    indices = [Index("bookId", "index")],
)
data class Chapter(
    @PrimaryKey val id: String,
    val bookId: String,
    val siteChapterId: String,
    val index: Int,
    val title: String,
    val url: String,
    val addedAt: Long?,
    val downloadedAt: Long?,
    /** A feed article's date, which its place in the catalog is ordered by; null for a novel's chapter. */
    val publishedAt: Long? = null,
    /** When a feed article was read; null is unread, which is what the shelf counts. Novels leave it null. */
    val readAt: Long? = null,
) {
    /**
     * Whether a catalog row wears 「新」 — the iOS `Chapter.isMarked`, which the shelf's count
     * restates in SQL (`LibraryDao.SHELF`), so the two move together. A subscription asks whether
     * the article was read. A novel or a comic asks whether the site published the chapter while the
     * reader was away: arrived in the last day, past [lastReadIndex] (null: no place in this catalog,
     * so everything is ahead). It expires because "new" is a claim about recency — last month's
     * chapter is simply one not reached yet, which the position already says.
     */
    fun isMarked(kind: SiteRule.Kind, lastReadIndex: Int?, now: Long = System.currentTimeMillis()): Boolean =
        if (kind == SiteRule.Kind.FEED) {
            readAt == null
        } else {
            addedAt != null && now - addedAt < NEW_WINDOW_MS && (lastReadIndex == null || index > lastReadIndex)
        }

    companion object {
        const val NEW_WINDOW_MS = 24 * 60 * 60 * 1000L

        fun makeId(bookId: String, siteChapterId: String) = "$bookId|$siteChapterId"

        /**
         * [candidate] when it is [stored] made whole: a chapter page often names the chapter
         * in full where the catalog truncated, and that name must survive later refreshes.
         */
        fun fullerTitle(candidate: String?, stored: String): String? =
            candidate?.takeIf { it.length > stored.length && it.startsWith(stored) }
    }
}

/**
 * A chapter's paragraphs as JSON, kept from reading so going back costs no fetch. [folded] is
 * the same JSON in one script, what library search scans; null only until the launch backfill
 * reaches a text kept before search existed. [blocks] is a feed article's structure (the iOS
 * `.json` beside its `.txt`), whose plain text [paragraphs] still is, so search and export need
 * not know about it. [usedAt] is when it was last read or written, what the cache limit drops
 * the oldest of; it means nothing for a download.
 */
@Entity(
    tableName = "chapter_text",
    foreignKeys = [ForeignKey(Chapter::class, ["id"], ["chapterId"], onDelete = ForeignKey.CASCADE)],
)
data class CachedChapter(
    @PrimaryKey val chapterId: String,
    val paragraphs: String,
    val folded: String? = null,
    val blocks: String? = null,
    val usedAt: Long? = System.currentTimeMillis(),
)

/** A text kept from reading alone, as the cache limit weighs it. */
data class CachedText(val id: String, val bytes: Long, val usedAt: Long)

/**
 * What this device remembers about its last request for a feed, so the next one can ask whether
 * anything changed — the iOS `FeedFetchState`. Local and never in a backup: an ETag means nothing
 * to a device that never made the request. The validators go back out exactly as they arrived.
 */
@Entity(
    tableName = "feedFetchState",
    foreignKeys = [ForeignKey(Book::class, ["id"], ["bookId"], onDelete = ForeignKey.CASCADE)],
)
data class FeedFetchState(
    @PrimaryKey val bookId: String,
    val etag: String?,
    val lastModified: String?,
    /** When this device last asked, a 304 included. */
    val checkedAt: Long?,
    /** The oldest article the publisher's document still listed: the line retention will not delete past. */
    val windowOldestAt: Long? = null,
)

/** A downloaded chapter whose folded text holds a search's needle. */
data class TextCandidate(val chapterId: String, val bookId: String, val siteChapterId: String, val title: String)

/**
 * A place the reader saved to come back to — the iOS `ReadingBookmark`, row and backup record
 * at once, as there. The id is the place itself, so saving one sentence twice is one row.
 */
@Serializable
@Entity(
    tableName = "readingBookmark",
    foreignKeys = [ForeignKey(Book::class, ["id"], ["bookId"], onDelete = ForeignKey.CASCADE)],
    indices = [Index("bookId")],
)
data class ReadingBookmark(
    @PrimaryKey val id: String,
    val bookId: String,
    val siteChapterId: String,
    val paragraph: Int,
    val characterOffset: Int,
    @Serializable(IsoDate::class) val createdAt: Long,
    /** The anchored paragraph's opening, taken when it was made: a chapter read online may have no text here later. */
    val excerpt: String? = null,
) {
    companion object {
        fun id(bookId: String, siteChapterId: String, paragraph: Int, characterOffset: Int) =
            "$bookId|$siteChapterId|$paragraph|$characterOffset"

        fun make(bookId: String, siteChapterId: String, paragraph: Int, characterOffset: Int, excerpt: String?, now: Long) =
            ReadingBookmark(id(bookId, siteChapterId, paragraph, characterOffset), bookId, siteChapterId, paragraph, characterOffset, now, excerpt)

        /** The paragraph's opening rather than the text at the offset: a sentence is easier to place than a fragment. */
        fun excerpt(paragraphs: List<String>, paragraph: Int, limit: Int = 60): String? {
            val text = paragraphs.getOrNull(paragraph)?.trim()?.takeIf { it.isNotEmpty() } ?: return null
            return if (text.length <= limit) text else text.take(limit) + "…"
        }
    }
}

/** A passage the reader drew a line under — the iOS `TextHighlight`. The id is the span. */
@Serializable
@Entity(
    tableName = "textHighlight",
    foreignKeys = [ForeignKey(Book::class, ["id"], ["bookId"], onDelete = ForeignKey.CASCADE)],
    indices = [Index("bookId")],
)
data class TextHighlight(
    @PrimaryKey val id: String,
    val bookId: String,
    val siteChapterId: String,
    val startParagraph: Int,
    val startCharacterOffset: Int,
    val endParagraph: Int,
    val endCharacterOffset: Int,
    @Serializable(IsoDate::class) val createdAt: Long,
    val excerpt: String,
) {
    companion object {
        /** Long enough to recognise a passage in a list, short enough that marking half a chapter does not copy it. */
        private const val EXCERPT_LIMIT = 120

        fun make(bookId: String, siteChapterId: String, start: Pair<Int, Int>, end: Pair<Int, Int>, text: String, now: Long): TextHighlight {
            val trimmed = text.trim()
            val excerpt = if (trimmed.length <= EXCERPT_LIMIT) trimmed else trimmed.take(EXCERPT_LIMIT) + "…"
            return TextHighlight(
                "$bookId|$siteChapterId|${start.first}|${start.second}|${end.first}|${end.second}",
                bookId, siteChapterId, start.first, start.second, end.first, end.second, now, excerpt,
            )
        }
    }
}

/**
 * Epoch milliseconds as ISO 8601 in whole seconds — the iOS backup's date form. A fractional
 * second would be refused there: Swift's `.iso8601` strategy reads none.
 */
object IsoDate : KSerializer<Long> {
    override val descriptor = PrimitiveSerialDescriptor("IsoDate", PrimitiveKind.STRING)

    override fun serialize(encoder: Encoder, value: Long) =
        encoder.encodeString(Instant.ofEpochSecond(Math.floorDiv(value, 1000L)).toString())

    override fun deserialize(decoder: Decoder): Long = OffsetDateTime.parse(decoder.decodeString()).toInstant().toEpochMilli()
}

/** A book with what its shelf row and its recent-reading row say about it. */
data class ShelfRow(
    @Embedded val book: Book,
    val chapterTitle: String?,
    val chapterIndex: Int?,
    val chapterCount: Int,
    /** What the badge counts: a subscription's articles nobody has read, a novel's or comic's new chapters ([Chapter.isMarked]). */
    val unread: Int = 0,
)

/** One article a feed document lists, as the catalog takes it. */
data class FeedEntry(val siteChapterId: String, val title: String, val url: String, val publishedAt: Long?)

data class BookBytes(val bookId: String, val bytes: Long)

data class CatalogChanges(val removed: List<Chapter>, val added: List<Chapter>, val changed: List<Chapter>)

/**
 * What writing [entries] over [current] changes — the iOS `replaceCatalog`, minus the
 * database. Only what changed is written: a refresh nearly always finds the catalog it
 * already had, a chapter or two longer.
 */
fun catalogChanges(
    bookId: String,
    current: List<Chapter>,
    entries: List<BookService.CatalogEntry>,
    isFirstCatalog: Boolean,
    now: Long,
): CatalogChanges {
    // A repeated id takes its last place.
    val places = LinkedHashMap<String, Pair<Int, BookService.CatalogEntry>>()
    entries.forEachIndexed { index, entry -> places[Chapter.makeId(bookId, entry.siteChapterId)] = index to entry }
    val kept = current.associateBy { it.id }
    val added = mutableListOf<Chapter>()
    val changed = mutableListOf<Chapter>()
    for ((id, place) in places) {
        val (index, entry) = place
        val chapter = kept[id]
        if (chapter == null) {
            // Nothing is new on the first fetch: a book whose every chapter is flagged is a
            // book with no flags worth reading.
            added += Chapter(id, bookId, entry.siteChapterId, index, entry.title, entry.url, if (isFirstCatalog) null else now, null)
            continue
        }
        val title = Chapter.fullerTitle(chapter.title, entry.title) ?: entry.title
        if (chapter.index == index && chapter.title == title && chapter.url == entry.url) continue
        // addedAt stays: rewriting it every refresh would clear or re-raise the new marker.
        changed += chapter.copy(index = index, title = title, url = entry.url)
    }
    return CatalogChanges(current.filter { it.id !in places }, added, changed)
}

@Dao
abstract class LibraryDao {
    @Query("$SHELF ORDER BY book.addedAt DESC")
    abstract fun shelf(): Flow<List<ShelfRow>>

    @Query("$SHELF WHERE book.lastReadAt IS NOT NULL ORDER BY book.lastReadAt DESC")
    abstract fun recent(): Flow<List<ShelfRow>>

    @Query("SELECT * FROM book WHERE id = :id")
    abstract fun book(id: String): Flow<Book?>

    @Query("SELECT * FROM book WHERE id = :id")
    abstract suspend fun bookNow(id: String): Book?

    @Query("SELECT * FROM chapter WHERE bookId = :bookId ORDER BY `index`")
    abstract fun chapters(bookId: String): Flow<List<Chapter>>

    @Query("SELECT * FROM chapter WHERE bookId = :bookId ORDER BY `index`")
    abstract suspend fun chaptersNow(bookId: String): List<Chapter>

    @Query("DELETE FROM book WHERE id = :id")
    abstract suspend fun deleteBook(id: String)

    @Query("UPDATE chapter SET title = :title WHERE id = :id")
    abstract suspend fun updateChapterTitle(id: String, title: String)

    @Query("SELECT paragraphs FROM chapter_text WHERE chapterId = :chapterId")
    abstract suspend fun cachedParagraphs(chapterId: String): String?

    @Upsert
    protected abstract suspend fun upsert(chapter: CachedChapter)

    /**
     * Kept with its folded twin. Every text goes through here — a chapter kept from reading
     * becomes a download by a stamp alone — so search never meets one without it.
     */
    open suspend fun cache(chapterId: String, paragraphs: String) =
        upsert(CachedChapter(chapterId, paragraphs, LibrarySearch.folded(paragraphs)))

    /** Read again: what keeps a book someone keeps coming back to ahead of one abandoned in an evening. */
    @Query("UPDATE chapter_text SET usedAt = :now WHERE chapterId = :chapterId")
    abstract suspend fun touchText(chapterId: String, now: Long = System.currentTimeMillis())

    /** Texts kept from reading alone — never a download — with what each holds and when it was last used. */
    @Query(
        """SELECT t.chapterId AS id, length(CAST(t.paragraphs AS BLOB)) + COALESCE(length(CAST(t.folded AS BLOB)), 0) AS bytes,
           COALESCE(t.usedAt, 0) AS usedAt FROM chapter_text AS t JOIN chapter AS c ON c.id = t.chapterId WHERE c.downloadedAt IS NULL""",
    )
    abstract suspend fun cachedTexts(): List<CachedText>

    /** Guarded on the flag in the statement itself: a chapter downloaded since it was listed stays. */
    @Query("DELETE FROM chapter_text WHERE chapterId IN (:ids) AND chapterId IN (SELECT id FROM chapter WHERE downloadedAt IS NULL)")
    abstract suspend fun evictTexts(ids: List<String>)

    @Query("SELECT * FROM chapter_text WHERE folded IS NULL LIMIT :limit")
    protected abstract suspend fun unfolded(limit: Int): List<CachedChapter>

    // `folded IS NULL`: a text rewritten meanwhile already carries its own, newer twin.
    @Query("UPDATE chapter_text SET folded = :folded WHERE chapterId = :chapterId AND folded IS NULL")
    protected abstract suspend fun setFolded(chapterId: String, folded: String)

    /** Texts kept before search existed, folded a batch at a time; run once per launch, off the main thread. */
    open suspend fun foldPending() {
        while (true) {
            val batch = unfolded(20).ifEmpty { return }
            for (text in batch) setFolded(text.chapterId, LibrarySearch.folded(text.paragraphs))
        }
    }

    /**
     * Downloaded chapters only: a chapter kept from reading alone was never offered as searchable,
     * and the join on the flag means a row whose download was deleted can never be named.
     */
    @Query(
        """SELECT c.id AS chapterId, c.bookId AS bookId, c.siteChapterId AS siteChapterId, c.title AS title
           FROM chapter_text AS t JOIN chapter AS c ON c.id = t.chapterId
           WHERE c.downloadedAt IS NOT NULL AND instr(t.folded, :needle) > 0
           ORDER BY c.bookId, c.`index` LIMIT :limit""",
    )
    abstract suspend fun textCandidates(needle: String, limit: Int): List<TextCandidate>

    // Downloads. A download is a kept text with `downloadedAt` stamped on its chapter, so
    // reading finds it the way it finds any kept text, and deleting one takes both.

    @Query("UPDATE chapter SET downloadedAt = :now WHERE id = :chapterId")
    abstract suspend fun markDownloaded(chapterId: String, now: Long = System.currentTimeMillis())

    /** A chapter kept from reading, stamped as a download in one statement: the cache limit cannot drop its text between the look and the stamp. */
    @Query("UPDATE chapter SET downloadedAt = :now WHERE id = :chapterId AND id IN (SELECT chapterId FROM chapter_text)")
    abstract suspend fun stampIfKept(chapterId: String, now: Long = System.currentTimeMillis()): Int

    /** The text first, the flag second, together: the flag never claims a chapter that is not there. */
    @Transaction
    open suspend fun storeDownload(chapterId: String, paragraphs: String) {
        cache(chapterId, paragraphs)
        markDownloaded(chapterId)
    }

    @Query("DELETE FROM chapter_text WHERE chapterId IN (:chapterIds)")
    protected abstract suspend fun deleteTexts(chapterIds: List<String>)

    @Query("UPDATE chapter SET downloadedAt = NULL WHERE id IN (:chapterIds)")
    protected abstract suspend fun clearDownloaded(chapterIds: List<String>)

    @Query("SELECT id FROM chapter WHERE downloadedAt IS NOT NULL AND (:bookId IS NULL OR bookId = :bookId)")
    protected abstract suspend fun downloadedIds(bookId: String?): List<String>

    /** Deletes these chapters' downloads. Chunked under SQLite's limit on bound variables. */
    @Transaction
    open suspend fun deleteDownloads(chapterIds: List<String>) {
        for (chunk in chapterIds.chunked(500)) {
            deleteTexts(chunk)
            clearDownloaded(chunk)
        }
    }

    /** One book's downloads, or every book's when [bookId] is null. */
    @Transaction
    open suspend fun deleteBookDownloads(bookId: String?) = deleteDownloads(downloadedIds(bookId))

    /** Bytes of downloaded text per book, for the storage screens — with the folded twin, which deleting gives back too. */
    @Query(
        """SELECT c.bookId AS bookId, SUM(length(CAST(t.paragraphs AS BLOB)) + COALESCE(length(CAST(t.folded AS BLOB)), 0)) AS bytes
           FROM chapter AS c JOIN chapter_text AS t ON t.chapterId = c.id
           WHERE c.downloadedAt IS NOT NULL GROUP BY c.bookId""",
    )
    abstract fun downloadSizes(): Flow<List<BookBytes>>

    /** Bytes of text kept from reading alone per book — the chapter cache, which downloads are not part of. */
    @Query(
        """SELECT c.bookId AS bookId, SUM(length(CAST(t.paragraphs AS BLOB)) + COALESCE(length(CAST(t.folded AS BLOB)), 0)) AS bytes
           FROM chapter AS c JOIN chapter_text AS t ON t.chapterId = c.id
           WHERE c.downloadedAt IS NULL GROUP BY c.bookId""",
    )
    abstract fun cacheSizes(): Flow<List<BookBytes>>

    /** One book's cached text, or every book's when [bookId] is null; downloads stay. */
    @Query("DELETE FROM chapter_text WHERE chapterId IN (SELECT id FROM chapter WHERE downloadedAt IS NULL AND (:bookId IS NULL OR bookId = :bookId))")
    abstract suspend fun clearCache(bookId: String?)

    @Query(
        """UPDATE book SET lastReadSiteChapterId = :siteChapterId, lastReadParagraph = :paragraph,
           lastReadCharacterOffset = :characterOffset, lastReadFraction = :fraction,
           lastReadAt = :now, updatedAt = :now WHERE id = :bookId""",
    )
    abstract suspend fun updateProgress(
        bookId: String, siteChapterId: String, paragraph: Int, characterOffset: Int, fraction: Double?, now: Long,
    )

    @Query("SELECT * FROM book ORDER BY addedAt DESC")
    abstract suspend fun allBooksNow(): List<Book>

    @Query("UPDATE book SET displayName = :name, updatedAt = :now WHERE id = :bookId")
    protected abstract suspend fun setDisplayName(bookId: String, name: String?, now: Long)

    /** The reader's own name for a book; a blank one goes back to the site's title. */
    open suspend fun rename(bookId: String, name: String?, now: Long = System.currentTimeMillis()) =
        setDisplayName(bookId, Book.customName(name), now)

    /**
     * Forgets when each book was last read, and nothing else — the iOS `clearReadingHistory`. Where the
     * reader got to stays: dropping a dozen positions would answer a much larger question than "clear
     * the list". `updatedAt` stays too: a restore merges on it, and nothing about the book changed.
     */
    @Query("UPDATE book SET lastReadAt = NULL")
    abstract suspend fun clearReadingHistory()

    // Marks, in reading order: by their chapter's place in the catalog, a chapter the site has
    // since dropped last.

    @Query(
        """SELECT m.* FROM readingBookmark AS m LEFT JOIN chapter AS c ON c.id = m.bookId || '|' || m.siteChapterId
           WHERE m.bookId = :bookId ORDER BY c.`index` IS NULL, c.`index`, m.paragraph, m.characterOffset""",
    )
    abstract fun readingBookmarks(bookId: String): Flow<List<ReadingBookmark>>

    @Query(
        """SELECT m.* FROM textHighlight AS m LEFT JOIN chapter AS c ON c.id = m.bookId || '|' || m.siteChapterId
           WHERE m.bookId = :bookId ORDER BY c.`index` IS NULL, c.`index`, m.startParagraph, m.startCharacterOffset""",
    )
    abstract fun highlights(bookId: String): Flow<List<TextHighlight>>

    @Query("SELECT id FROM readingBookmark WHERE bookId = :bookId")
    abstract fun bookmarkIds(bookId: String): Flow<List<String>>

    @Query("SELECT * FROM readingBookmark")
    abstract suspend fun allBookmarksNow(): List<ReadingBookmark>

    @Query("SELECT * FROM textHighlight")
    abstract suspend fun allHighlightsNow(): List<TextHighlight>

    /** Idempotent, as on iOS: the id is the place, and saving it again keeps the first. */
    @Insert(onConflict = OnConflictStrategy.IGNORE)
    abstract suspend fun addReadingBookmark(bookmark: ReadingBookmark)

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    abstract suspend fun addHighlight(highlight: TextHighlight)

    @Query("DELETE FROM readingBookmark WHERE id = :id")
    abstract suspend fun removeReadingBookmark(id: String)

    @Query("DELETE FROM textHighlight WHERE id = :id")
    abstract suspend fun removeHighlight(id: String)

    /** Writes what [LibraryBackup.plan] decided, all of it or none. */
    @Transaction
    open suspend fun restore(books: List<LibraryBackup.BookRecord>, bookmarks: List<ReadingBookmark>, highlights: List<TextHighlight>) {
        for (r in books) {
            bookmark(r.siteId, r.siteBookId, r.kind, r.title, r.author, r.coverURL, now = r.updatedAt)
            rename(r.id, r.displayName, now = r.updatedAt)
            // Stamped with when the reading happened: the history is this column ordered, and
            // "now" would report a night spent reading forty books at once.
            r.position?.let {
                updateProgress(r.id, it.siteChapterId, it.anchor.paragraph, it.anchor.characterOffset, r.fraction, r.lastReadAt ?: r.updatedAt)
            }
        }
        bookmarks.forEach { addReadingBookmark(it) }
        highlights.forEach { addHighlight(it) }
    }

    @Insert
    protected abstract suspend fun insert(book: Book)

    @Update
    protected abstract suspend fun update(book: Book)

    @Insert
    protected abstract suspend fun insert(chapters: List<Chapter>)

    @Update
    protected abstract suspend fun update(chapters: List<Chapter>)

    @Delete
    protected abstract suspend fun delete(chapters: List<Chapter>)

    /** Adds the book, or refreshes what the site says about one already on the shelf. */
    @Transaction
    open suspend fun bookmark(
        siteId: String, siteBookId: String, kind: SiteRule.Kind, title: String, author: String?, coverURL: String?,
        now: Long = System.currentTimeMillis(),
    ): Book {
        val id = Book.makeId(siteId, siteBookId)
        bookNow(id)?.let { existing ->
            val book = existing.copy(
                kind = kind, title = title, author = author ?: existing.author,
                coverURL = coverURL ?: existing.coverURL, updatedAt = now,
            )
            update(book)
            return book
        }
        val book = Book(
            id, siteId, siteBookId, kind, title, null, author, coverURL, now, now,
            null, null, null, null, null, null,
        )
        insert(book)
        return book
    }

    /** Writes a fetched catalog over the book's chapter index and stamps it fresh. */
    @Transaction
    open suspend fun replaceCatalog(
        bookId: String, entries: List<BookService.CatalogEntry>, now: Long = System.currentTimeMillis(),
    ) {
        val stored = bookNow(bookId) ?: return
        val changes = catalogChanges(bookId, chaptersNow(bookId), entries, stored.catalogUpdatedAt == null, now)
        delete(changes.removed)
        update(changes.changed)
        insert(changes.added)
        update(stored.copy(catalogUpdatedAt = now))
    }

    // Subscriptions

    @Query("UPDATE chapter SET `index` = :index WHERE id = :id")
    protected abstract suspend fun setIndex(id: String, index: Int)

    /**
     * Adds a feed's newly published articles and removes nothing — the iOS `mergeCatalog`. A feed
     * document is a window, not an index: run through [replaceCatalog], the reader's archive would
     * go every time the publisher posted. Oldest first, so a feed reads like a book gaining
     * chapters; ties by id, because a stable order matters more than an exact one when every mark
     * resolves through the index.
     *
     * @return the ids this merge inserted. An article whose text the reader deleted looks like one
     * that never had any, so only these may have their text fetched.
     */
    @Transaction
    open suspend fun mergeCatalog(bookId: String, entries: List<FeedEntry>, now: Long = System.currentTimeMillis()): Set<String> {
        val stored = bookNow(bookId)
        val existing = chaptersNow(bookId).associateBy { it.id }
        val inserted = LinkedHashSet<String>()
        for (entry in entries) {
            val id = Chapter.makeId(bookId, entry.siteChapterId)
            val chapter = existing[id]
            if (chapter != null) {
                // A stored date wins over an absent one: it is the arrival time recorded the first time.
                val merged = chapter.copy(
                    title = Chapter.fullerTitle(chapter.title, entry.title) ?: entry.title, url = entry.url,
                    publishedAt = entry.publishedAt ?: chapter.publishedAt,
                )
                if (merged != chapter) update(listOf(merged))
            } else if (inserted.add(entry.siteChapterId)) {
                // An undated article holds the moment it first arrived, rather than marching up the list on every refresh.
                insert(listOf(Chapter(id, bookId, entry.siteChapterId, Int.MAX_VALUE, entry.title, entry.url, now, null, entry.publishedAt ?: now)))
            }
        }
        chaptersNow(bookId).sortedWith(compareBy({ it.publishedAt }, { it.siteChapterId })).forEachIndexed { index, chapter ->
            if (chapter.index != index) setIndex(chapter.id, index)
        }
        stored?.let { update(it.copy(catalogUpdatedAt = now)) }
        return inserted
    }

    /** A 304: the index was read and found unchanged, which is as fresh as a merge. */
    @Query("UPDATE book SET catalogUpdatedAt = :now WHERE id = :bookId")
    abstract suspend fun touchCatalog(bookId: String, now: Long = System.currentTimeMillis())

    @Query("SELECT * FROM feedFetchState WHERE bookId = :bookId")
    abstract suspend fun feedFetchState(bookId: String): FeedFetchState?

    @Upsert
    abstract suspend fun saveFeedFetchState(state: FeedFetchState)

    @Query("SELECT blocks FROM chapter_text WHERE chapterId = :chapterId")
    abstract suspend fun articleBlocks(chapterId: String): String?

    /** An article onto the device: its structure, and its plain text block for block so every index still names the same place. */
    @Transaction
    open suspend fun storeArticle(chapterId: String, blocks: String, paragraphs: String) {
        upsert(CachedChapter(chapterId, paragraphs, LibrarySearch.folded(paragraphs), blocks))
        markDownloaded(chapterId)
    }

    /**
     * Read state is the article's own flag, never the reading position: skipping past one is not
     * reading it. Only rows whose state changes are written, so re-reading keeps the first reading's time.
     */
    @Query("UPDATE chapter SET readAt = :readAt WHERE id IN (:chapterIds) AND (readAt IS NULL) != (:readAt IS NULL)")
    abstract suspend fun setArticlesRead(chapterIds: List<String>, readAt: Long?)

    @Query("UPDATE chapter SET readAt = :now WHERE bookId = :bookId AND readAt IS NULL")
    abstract suspend fun markAllRead(bookId: String, now: Long = System.currentTimeMillis())

    @Query("UPDATE chapter SET readAt = :now WHERE readAt IS NULL AND bookId IN (SELECT id FROM book WHERE kind = 'FEED')")
    abstract suspend fun markAllFeedsRead(now: Long = System.currentTimeMillis())

    /** Rows, not just their text: for a feed the row is the article, and the publisher's window moved past it long ago. */
    @Query("DELETE FROM chapter WHERE id IN (:chapterIds)")
    abstract suspend fun removeChapters(chapterIds: List<String>)

    /** Articles a bookmark or a highlight points into, which retention never takes: the mark would go with the row. */
    @Query("SELECT siteChapterId FROM readingBookmark WHERE bookId = :bookId UNION SELECT siteChapterId FROM textHighlight WHERE bookId = :bookId")
    abstract suspend fun markedChapters(bookId: String): List<String>

    @Query("SELECT chapterId FROM chapter_text WHERE blocks IS NOT NULL")
    abstract suspend fun articleIds(): List<String>

    private companion object {
        // `unread` is `Chapter.isMarked` in SQL, with `c` the reading position's row. SQLite's own
        // clock rather than a bound `now`: the flow re-queries whenever the library changes, and a
        // cutoff fixed when the shelf was opened would keep every badge on it for as long as it stays
        // open. A null addedAt fails `>`, as it must: a chapter from the first catalog is never news.
        const val SHELF = """SELECT book.*, c.title AS chapterTitle, c.`index` AS chapterIndex,
            (SELECT COUNT(*) FROM chapter WHERE chapter.bookId = book.id) AS chapterCount,
            (SELECT COUNT(*) FROM chapter WHERE chapter.bookId = book.id AND CASE WHEN book.kind = 'FEED'
                THEN chapter.readAt IS NULL
                ELSE chapter.addedAt > strftime('%s', 'now') * 1000 - ${Chapter.NEW_WINDOW_MS}
                    AND (c.`index` IS NULL OR chapter.`index` > c.`index`) END) AS unread
            FROM book LEFT JOIN chapter AS c ON c.id = book.id || '|' || book.lastReadSiteChapterId"""
    }
}

@Database(
    entities = [Book::class, Chapter::class, CachedChapter::class, ReadingBookmark::class, TextHighlight::class, FeedFetchState::class],
    version = 5,
    exportSchema = false,
)
abstract class LibraryDatabase : RoomDatabase() {
    abstract fun library(): LibraryDao

    companion object {
        /** Marks arrive. A migration rather than a rebuild: the test devices' downloads took hours. */
        val MIGRATION_1_2 = object : Migration(1, 2) {
            override fun migrate(db: SupportSQLiteDatabase) {
                // Room's own statements, from the generated LibraryDatabase_Impl: Room validates the
                // migrated schema against them, so hand-written DDL would fail on the first open.
                db.execSQL("CREATE TABLE IF NOT EXISTS `readingBookmark` (`id` TEXT NOT NULL, `bookId` TEXT NOT NULL, `siteChapterId` TEXT NOT NULL, `paragraph` INTEGER NOT NULL, `characterOffset` INTEGER NOT NULL, `createdAt` INTEGER NOT NULL, `excerpt` TEXT, PRIMARY KEY(`id`), FOREIGN KEY(`bookId`) REFERENCES `book`(`id`) ON UPDATE NO ACTION ON DELETE CASCADE )")
                db.execSQL("CREATE INDEX IF NOT EXISTS `index_readingBookmark_bookId` ON `readingBookmark` (`bookId`)")
                db.execSQL("CREATE TABLE IF NOT EXISTS `textHighlight` (`id` TEXT NOT NULL, `bookId` TEXT NOT NULL, `siteChapterId` TEXT NOT NULL, `startParagraph` INTEGER NOT NULL, `startCharacterOffset` INTEGER NOT NULL, `endParagraph` INTEGER NOT NULL, `endCharacterOffset` INTEGER NOT NULL, `createdAt` INTEGER NOT NULL, `excerpt` TEXT NOT NULL, PRIMARY KEY(`id`), FOREIGN KEY(`bookId`) REFERENCES `book`(`id`) ON UPDATE NO ACTION ON DELETE CASCADE )")
                db.execSQL("CREATE INDEX IF NOT EXISTS `index_textHighlight_bookId` ON `textHighlight` (`bookId`)")
            }
        }

        /** Library search's folded copy; the launch backfill fills it for texts already kept. */
        val MIGRATION_2_3 = object : Migration(2, 3) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE `chapter_text` ADD COLUMN `folded` TEXT")
            }
        }

        /** Subscriptions arrive: article dates and read state, article structure, and the conditional-request memory. */
        val MIGRATION_3_4 = object : Migration(3, 4) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE `chapter` ADD COLUMN `publishedAt` INTEGER")
                db.execSQL("ALTER TABLE `chapter` ADD COLUMN `readAt` INTEGER")
                db.execSQL("ALTER TABLE `chapter_text` ADD COLUMN `blocks` TEXT")
                db.execSQL("CREATE TABLE IF NOT EXISTS `feedFetchState` (`bookId` TEXT NOT NULL, `etag` TEXT, `lastModified` TEXT, `checkedAt` INTEGER, `windowOldestAt` INTEGER, PRIMARY KEY(`bookId`), FOREIGN KEY(`bookId`) REFERENCES `book`(`id`) ON UPDATE NO ACTION ON DELETE CASCADE )")
            }
        }

        /** The cache limit's clock. Texts kept before it have none, and so are the first to go. */
        val MIGRATION_4_5 = object : Migration(4, 5) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE `chapter_text` ADD COLUMN `usedAt` INTEGER")
            }
        }
    }
}
