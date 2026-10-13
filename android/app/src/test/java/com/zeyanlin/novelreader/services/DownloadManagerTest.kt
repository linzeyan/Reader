package com.zeyanlin.novelreader.services

import com.zeyanlin.novelreader.data.Book
import com.zeyanlin.novelreader.data.Chapter
import com.zeyanlin.novelreader.network.WebFetcher
import com.zeyanlin.novelreader.services.DownloadManager.Hold
import com.zeyanlin.novelreader.services.DownloadManager.Status
import com.zeyanlin.novelreader.siterules.SiteRule
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * The rules that keep a download queue from eating itself or hammering a walled host. Each is
 * driven through the public surface against a stand-in site, on runBlocking's single thread,
 * which is the main thread's ordering in miniature.
 */
class DownloadManagerTest {
    @get:Rule
    val folder = TemporaryFolder()

    private val queueFile by lazy { File(folder.root, "DownloadQueue.json") }
    private val store by lazy { DownloadQueueStore(queueFile) }

    /** What the stand-in site does with each chapter id: land it unless told otherwise. */
    private val site = mutableMapOf<String, suspend () -> Unit>()

    /** Pages the stand-in site would not give up, per chapter id. */
    private val missing = mutableMapOf<String, Int>()
    private val fetched = mutableListOf<String>()

    private fun CoroutineScope.manager() = DownloadManager(this, RequestPacer(0.0..0.001), store, { _, _, chapter ->
        fetched += chapter.siteChapterId
        site[chapter.siteChapterId]?.invoke()
        missing[chapter.siteChapterId] ?: 0
    }, rest = {})

    private suspend fun DownloadManager.settled() = state.first { !it.isBusy }

    @Test
    fun threeFailuresInARowHoldTheBookAndTheBooksBehindItCarryOn() = runBlocking {
        val a = book("a", "a.com")
        for (id in listOf("a1", "a2", "a3", "a4")) site[id] = { error("unreadable") }
        val queue = manager()
        queue.start(a, rule("a.com"), chapters(a, "a1", "a2", "a3", "a4"))
        queue.start(book("b", "b.com"), rule("b.com"), chapters(book("b", "b.com"), "b1", "b2"))
        val state = queue.settled()

        val held = state.job(a.id)!!
        assertEquals(Hold.PAUSED, held.hold)
        assertTrue(held.note!!.startsWith("連續多章下載失敗"))
        // Two dropped as ordinary bad chapters; the third, which tripped the limit, keeps its place.
        assertEquals(listOf("a3", "a4"), held.remaining.map { it.siteChapterId })
        assertNull("the next book went ahead", state.job("b|b"))
        assertEquals(listOf("a1", "a2", "a3", "b1", "b2"), fetched)
        // A streak is a judgement about this moment: the next launch gets a fresh attempt.
        assertFalse(persisted().single().paused)
    }

    @Test
    fun anOrdinaryBadChapterIsDroppedAndTheDownloadFinishes() = runBlocking {
        val a = book("a", "a.com")
        site["a2"] = { error("unreadable") }
        val queue = manager()
        queue.start(a, rule("a.com"), chapters(a, "a1", "a2", "a3"))
        val state = queue.settled()
        assertEquals(Status.FINISHED, state.status)
        assertTrue(state.jobs.isEmpty())
        assertFalse("a finished queue leaves no file to restore", queueFile.exists())
    }

    /**
     * A comic chapter short a page still lands — it is readable — but the gap is said on the
     * book's row while the download runs, not found later offline.
     */
    @Test
    fun aChapterShortOfPagesLandsAndSaysHowManyWereMissing() = runBlocking {
        val a = book("a", "a.com")
        missing["a1"] = 2
        val gate = CompletableDeferred<Unit>()
        site["a2"] = { gate.await() }
        val queue = manager()
        queue.start(a, rule("a.com"), chapters(a, "a1", "a2"))
        while (fetched.size < 2) yield()

        val state = queue.state.value
        val job = state.job(a.id)!!
        assertEquals(1, job.completed)
        assertEquals("a1：有 2 頁取不到，其餘已儲存。", state.describe(job))
        gate.complete(Unit)
        assertEquals(Status.FINISHED, queue.settled().status)
    }

    @Test
    fun aWallHoldsItsHostWaitsForTheRestAndGivesUpIfTheCheckDidNotTake() = runBlocking {
        val a = book("a", "a.com")
        val sibling = book("a2", "a.com")
        val b = book("b", "b.com")
        val walls = mutableListOf<DownloadManager.Wall?>()
        site["a1"] = { throw WebFetcher.FetchError.ChallengePresented("https://a.com/check") }
        val queue = manager()
        site["b1"] = { walls += queue.state.value.pendingChallenge }
        site["b2"] = { walls += queue.state.value.pendingChallenge }
        queue.start(a, rule("a.com"), chapters(a, "a1"))
        queue.start(sibling, rule("a.com"), chapters(sibling, "s1"))
        queue.start(b, rule("b.com"), chapters(b, "b1", "b2"))
        val state = queue.settled()

        // The sibling was never tried: it would only have met the same wall.
        assertEquals(listOf("a1", "b1", "b2"), fetched)
        assertEquals(listOf(Hold.WALL, Hold.WALL), state.jobs.map { it.hold })
        // The sheet takes the one web view, so it waited until the other host's book was done.
        assertEquals(listOf(null, null), walls)
        assertEquals("https://a.com/check", state.pendingChallenge!!.url)
        assertTrue("the web view moved on, so the sheet must reload the page", state.pendingChallenge!!.reload)
        assertTrue(persisted().none { it.paused })

        // Closed without solving: the same wall again pauses the host rather than reopening the sheet.
        queue.retryAfterWall()
        val after = queue.settled()
        assertNull(after.pendingChallenge)
        assertEquals(listOf(Hold.PAUSED, Hold.PAUSED), after.jobs.map { it.hold })
        assertTrue(after.jobs.all { it.note == "驗證沒有通過，這本已暫停。按「繼續」再試一次。" })
    }

    /**
     * A sign-in is the same wall to the queue — nothing it does alone gets the next chapter, and
     * grinding through the book would bury the one message that matters — but the sheet it puts
     * up has to ask for a sign-in, on the site's form.
     */
    @Test
    fun aSignInHoldsItsHostAndPutsUpTheSignInForm() = runBlocking {
        val a = book("a", "a.com")
        site["a1"] = { throw WebFetcher.FetchError.SignInRequired("https://a.com/member/login") }
        val queue = manager()
        queue.start(a, rule("a.com"), chapters(a, "a1", "a2"))
        val state = queue.settled()

        assertEquals(listOf("a1"), fetched)
        assertEquals(listOf("a1", "a2"), state.job(a.id)!!.remaining.map { it.siteChapterId })
        assertEquals(Hold.WALL, state.job(a.id)!!.hold)
        assertEquals("https://a.com/member/login", state.pendingChallenge!!.url)
        assertTrue(state.pendingChallenge.signIn)
    }

    @Test
    fun leavingTheAppFinishesTheChapterOnTheWireThenPauses() = runBlocking {
        val a = book("a", "a.com")
        val gate = CompletableDeferred<Unit>()
        site["a1"] = { gate.await() }
        val queue = manager()
        queue.start(a, rule("a.com"), chapters(a, "a1", "a2", "a3"))
        while (fetched.isEmpty()) yield()
        var released = false
        queue.stopAfterCurrentChapter("App 進入背景") { released = true }
        gate.complete(Unit)
        val state = queue.settled()

        assertEquals(listOf("a1"), fetched)
        assertEquals(Status.PAUSED, state.status)
        assertEquals("App 進入背景", state.lastError)
        assertEquals(listOf("a2", "a3"), state.job(a.id)!!.remaining.map { it.siteChapterId })
        assertTrue(released)
        assertTrue(state.canResume)
    }

    /** Back in the app mid-rest or mid-chapter: the queue must not stop on arrival. */
    @Test
    fun comingBackBeforeTheDrainLandedKeepsTheQueueGoing() = runBlocking {
        val a = book("a", "a.com")
        val gate = CompletableDeferred<Unit>()
        site["a1"] = { gate.await() }
        val queue = manager()
        queue.start(a, rule("a.com"), chapters(a, "a1", "a2"))
        while (fetched.isEmpty()) yield()
        queue.stopAfterCurrentChapter("App 進入背景")
        queue.keepRunning()
        gate.complete(Unit)
        val state = queue.settled()
        assertEquals(Status.FINISHED, state.status)
        assertEquals(listOf("a1", "a2"), fetched)
    }

    @Test
    fun onlyTheReadersOwnPauseIsWrittenDown() = runBlocking {
        val a = book("a", "a.com")
        val b = book("b", "b.com")
        val gate = CompletableDeferred<Unit>()
        site["a1"] = { gate.await() }
        val queue = manager()
        queue.start(a, rule("a.com"), chapters(a, "a1"))
        queue.start(b, rule("b.com"), chapters(b, "b1"))
        queue.pauseBook(b.id)
        assertEquals(listOf(false, true), persisted().map { it.paused })
        queue.cancel()
        assertFalse(queueFile.exists())
    }

    @Test
    fun aRestoredQueueDropsWhatLandedAndWaitsForAnUnmeteredConnection() = runBlocking {
        val a = book("a", "a.com")
        val stored = chapters(a, "a1", "a2", "a3").mapIndexed { i, c -> if (i == 1) c.copy(downloadedAt = 1) else c }
        store.save(
            listOf(
                PersistedDownloadQueue.Entry("gone|1", listOf("x")),
                PersistedDownloadQueue.Entry(a.id, listOf("a1", "a2", "a3")),
            ),
        )
        var connection = Connection.UNKNOWN
        val queue = manager()
        val restorer = DownloadQueueRestorer(
            store, queue,
            book = { if (it == a.id) a else null }, chapters = { stored }, rule = { rule("a.com") },
            policy = { NetworkPolicy.WIFI_ONLY }, connection = { connection },
        )
        restorer.restore()
        // A deleted book and a chapter that has since landed are dropped; nothing goes out yet.
        assertEquals(listOf("a1", "a3"), queue.state.value.jobs.single().remaining.map { it.siteChapterId })
        assertEquals(Status.PAUSED, queue.state.value.status)

        // Cellular under Wi-Fi only: consent did not survive the process, so it stays put and says why.
        connection = Connection.CELLULAR
        restorer.connectionChanged()
        assertEquals(DownloadQueueRestorer.CELLULAR_PAUSED, queue.state.value.lastError)
        assertTrue(fetched.isEmpty())
    }

    @Test
    fun aRestoredQueueOnWifiResumesButKeepsTheReadersPause() = runBlocking {
        val a = book("a", "a.com")
        val c = book("c", "c.com")
        store.save(
            listOf(
                PersistedDownloadQueue.Entry(a.id, listOf("a1"), paused = true),
                PersistedDownloadQueue.Entry(c.id, listOf("c1")),
            ),
        )
        val queue = manager()
        val books = listOf(a, c).associateBy { it.id }
        DownloadQueueRestorer(
            store, queue,
            book = { books[it] }, chapters = { id -> chapters(books.getValue(id), if (id == a.id) "a1" else "c1") },
            rule = { rule("$it.com") }, policy = { NetworkPolicy.WIFI_ONLY }, connection = { Connection.WIFI },
        ).restore()
        val state = queue.settled()
        assertEquals(listOf("c1"), fetched)
        assertEquals(Hold.PAUSED, state.job(a.id)!!.hold)
    }

    private fun persisted() = (store.load() as DownloadQueueStore.Stored.Queue).queue.books

    private fun book(id: String, host: String) = Book(
        Book.makeId(host.substringBefore('.'), id), host.substringBefore('.'), id, SiteRule.Kind.NOVEL, id, null, null, null,
        0, 0, null, null, null, null, null, null,
    )

    private fun chapters(book: Book, vararg ids: String) =
        ids.mapIndexed { i, id -> Chapter(Chapter.makeId(book.id, id), book.id, id, i, id, "https://x/$id", null, null) }

    private fun rule(host: String) = SiteRule(
        id = host.substringBefore('.'), name = host, host = host,
        urls = SiteRule.UrlTemplates("https://$host/{bookId}", "https://$host/{bookId}", "https://$host/{bookId}/{chapterId}"),
        idPatterns = SiteRule.IdPatterns("/(\\w+)", "/\\w+/(\\w+)"),
        book = SiteRule.BookFields(title = SiteRule.Field(meta = "og:title", selector = "h1")),
        catalog = SiteRule.Catalog(container = "body", linkSelector = "a", order = SiteRule.Catalog.Order.ASCENDING),
        chapter = SiteRule.Chapter(titleSelectors = listOf("h1"), contentSelectors = emptyList(), stripSelectors = emptyList()),
    )
}
