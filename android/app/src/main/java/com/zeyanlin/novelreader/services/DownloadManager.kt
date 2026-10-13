package com.zeyanlin.novelreader.services

import com.zeyanlin.novelreader.data.Book
import com.zeyanlin.novelreader.data.Chapter
import com.zeyanlin.novelreader.describe
import com.zeyanlin.novelreader.network.WebFetcher
import com.zeyanlin.novelreader.siterules.SiteRule
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job as Task
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlin.random.Random

/**
 * Downloads chapters one at a time, politely — the iOS `DownloadManager`, ported rule for rule.
 *
 * One web view, so one chapter at a time. Hosts sit behind Cloudflare, so requests are paced
 * and a challenged host is stepped away from rather than retried. A paused queue keeps its
 * work, and the work outlives the process through [DownloadQueueStore] — written when the queue
 * gains work and when it comes to rest, never per chapter: the chapters already stored are the
 * truth for what is finished, so the file only has to be a superset of what is left.
 *
 * Books queue in the order they were asked for, and the queue works on the first one free to
 * go; a held book keeps its place and is stepped over. A wall holds every book on its host
 * (the next would only meet it again) and is put to the reader only once nothing else can go,
 * because the verification sheet takes the one web view.
 *
 * Everything runs on [scope]'s dispatcher — the main thread in the app — which is what lets
 * the state be read and changed without locks, as iOS's `@MainActor` does.
 */
class DownloadManager(
    private val scope: CoroutineScope,
    private val pacer: RequestPacer,
    private val queueStore: DownloadQueueStore,
    /**
     * Fetches one chapter and stores it, answering how many of its pages the site would not give
     * up — always 0 for a novel. A parameter so a test can stand in for the site.
     */
    private val download: suspend (Book, SiteRule, Chapter) -> Int,
    /** The longer pause between blocks of chapters; see [restIsDue]. */
    private val rest: suspend () -> Unit = { delay(Random.nextLong(15_000, 45_001)) },
    /**
     * The iOS trace, as one line per event: downloading runs with nobody watching, and once the
     * moment has passed this is the only way to tell whether a queue started, what stopped it,
     * and how much was left.
     */
    private val trace: (String) -> Unit = {},
) {
    enum class Status {
        IDLE,
        RUNNING,

        /** Nothing being fetched with books still queued: stopped from outside, or every book held. */
        PAUSED,
        FINISHED,
    }

    enum class Hold {
        /** Waits for a tap: the reader paused it, or the queue gave up on it for now. */
        PAUSED,

        /** Waits for the verification sheet, which comes once nothing else can go. */
        WALL,
    }

    /** One book's share of the queue. */
    data class Job(
        val book: Book,
        val rule: SiteRule,
        /** Not yet fetched, in order. */
        val remaining: List<Chapter>,
        val completed: Int = 0,
        val total: Int = remaining.size,
        val hold: Hold? = null,
        /** What the reader needs to know about this book: the wall, why the queue gave up on it. */
        val note: String? = null,
        /** Set when the reader closed a verification sheet; a wall again straight after means it did not take. */
        val retryingWall: Boolean = false,
    ) {
        val id: String get() = book.id
        val fraction: Float get() = if (total > 0) completed.toFloat() / total else 0f
    }

    /**
     * A verification a held host is waiting on. [reload]: the web view has moved on since. [signIn]:
     * the site wants the reader signed in, and [url] is its form — the same hold, other words.
     */
    data class Wall(val url: String, val bookName: String, val reload: Boolean = false, val signIn: Boolean = false)

    data class State(
        val status: Status = Status.IDLE,
        /** Every queued book, in the order asked for. A finished book leaves. */
        val jobs: List<Job> = emptyList(),
        val activeBookId: String? = null,
        /** Why the whole queue stopped, when something other than a book stopped it. */
        val lastError: String? = null,
        /** Counts chapters as they land, for screens that redraw their chapter list when one does. */
        val landed: Int = 0,
        /** The wall put to the reader. Closing its sheet calls [retryAfterWall]. */
        val pendingChallenge: Wall? = null,
    ) {
        val isBusy: Boolean get() = status == Status.RUNNING

        /** Whether the queue is stopped with a book free to go — what a resume would start. */
        val canResume: Boolean get() = status == Status.PAUSED && jobs.any { it.hold == null }
        val remainingCount: Int get() = jobs.sumOf { it.remaining.size }

        fun job(bookId: String): Job? = jobs.firstOrNull { it.id == bookId }

        /** The line under a book's progress bar, or null when the bar says it all. */
        fun describe(job: Job): String? = when {
            job.hold == Hold.PAUSED -> job.note ?: "已暫停"
            job.hold == Hold.WALL -> "需要驗證。先下載其他書，完成後會請你驗證。"
            job.id == activeBookId && isBusy -> job.note
            isBusy -> "等待中"
            else -> lastError ?: "已暫停"
        }
    }

    private val mutableState = MutableStateFlow(State())
    val state: StateFlow<State> = mutableState
    private var s: State
        get() = mutableState.value
        set(value) {
            mutableState.value = value
        }

    /** The wall held books are waiting on, kept back until nothing else can go. */
    private var wall: Wall? = null
    private var task: Task? = null

    /** Chapters failed since the last one landed: a streak, not a total. */
    private var failureStreak = 0
    private var draining = false
    private var drainReason: String? = null
    private var onStopped: (() -> Unit)? = null

    /** Which run the queue is on, so a cancelled run's cleanup cannot release its replacement's drain. */
    private var runToken = 0

    /** Chapters left before the run takes a longer rest. */
    private var chaptersUntilRest = 0

    private val activeIndex: Int? get() = s.activeBookId?.let(::index)
    private val activeJob: Job? get() = activeIndex?.let { s.jobs[it] }

    private fun index(bookId: String) = s.jobs.indexOfFirst { it.id == bookId }.takeIf { it >= 0 }

    private fun jobs(change: (MutableList<Job>) -> Unit) {
        s = s.copy(jobs = s.jobs.toMutableList().also(change))
    }

    private fun job(i: Int, change: (Job) -> Job) = jobs { it[i] = change(it[i]) }

    // Control

    /**
     * Queues every chapter not already on the device, behind whatever is queued. Asking again
     * for a queued book adds the new chapters to its share and lifts whatever held it.
     */
    fun start(book: Book, rule: SiteRule, chapters: List<Chapter>) {
        val pending = chapters.filter { it.downloadedAt == null }
        trace("dl start n=${pending.size} of=${chapters.size} books=${s.jobs.size}")
        val i = index(book.id)
        if (i != null) {
            if (book.id == s.activeBookId && s.isBusy) {
                // Appended only: the head is the chapter on the wire.
                job(i) {
                    val merged = merge(pending, it.remaining)
                    it.copy(remaining = merged, total = it.total + merged.size - it.remaining.size)
                }
            } else {
                // Against the catalog it was tapped with, so chapters landed since drop out.
                val landed = chapters.filter { it.downloadedAt != null }.map { it.id }.toSet()
                job(i) {
                    val merged = merge(pending, it.remaining.filter { c -> c.id !in landed })
                    it.copy(remaining = merged, total = it.completed + merged.size, hold = null, note = null, retryingWall = false)
                }
                if (s.jobs[i].remaining.isEmpty()) jobs { it.removeAt(i) }
            }
        } else if (pending.isNotEmpty()) {
            jobs { it += Job(book, rule, pending) }
        }
        if (s.isBusy) {
            persistQueue()
        } else {
            s = s.copy(lastError = null)
            run()
        }
    }

    /**
     * Installs a queue read back from disk, paused: the network policy has to be cleared again
     * before a request goes out, because consent to spend data did not survive its process.
     */
    fun restore(restored: List<Job>) {
        if (s.status != Status.IDLE || s.jobs.isNotEmpty()) return
        val jobs = restored.filter { it.remaining.isNotEmpty() }
        if (jobs.isEmpty()) return
        s = s.copy(jobs = jobs, status = Status.PAUSED)
    }

    /** Stops the whole queue, every book keeping its place. [reason] is said where failures are. */
    fun pause(reason: String? = null) {
        trace("dl pause left=${s.remainingCount} auto=${if (reason == null) 0 else 1}")
        stopRun()
        if (s.jobs.isNotEmpty()) s = s.copy(status = Status.PAUSED)
        if (reason != null) s = s.copy(lastError = reason)
        clearDrain()
        persistQueue()
    }

    /** Holds one book where it is; the books behind it go first. */
    fun pauseBook(bookId: String) {
        val i = index(bookId) ?: return
        job(i) { it.copy(hold = Hold.PAUSED, note = null) }
        if (bookId == s.activeBookId && s.isBusy) {
            stopRun()
            run()
        } else {
            persistQueue()
        }
    }

    /** Lets a held book go again, at its own place, and sets a stopped queue going. */
    fun resumeBook(bookId: String) {
        val i = index(bookId) ?: return
        job(i) { it.copy(hold = null, note = null, retryingWall = false) }
        if (s.isBusy) {
            persistQueue()
        } else {
            s = s.copy(lastError = null)
            run()
        }
    }

    /** Sets a stopped queue going again, at the first book free to go. */
    fun resume() {
        trace("dl resume can=${if (s.canResume) 1 else 0} left=${s.remainingCount}")
        if (!s.canResume) return
        s = s.copy(lastError = null)
        run()
    }

    /**
     * Stops after the chapter already on the wire rather than throwing it away — for leaving
     * the app. [onStopped] runs once the queue is at rest; at once when nothing is running.
     */
    fun stopAfterCurrentChapter(reason: String?, onStopped: () -> Unit = {}) {
        trace("dl drain running=${if (s.isBusy) 1 else 0} left=${s.remainingCount}")
        if (!s.isBusy) {
            onStopped()
            return
        }
        notifyStopped()
        draining = true
        drainReason = reason
        this.onStopped = onStopped
    }

    /**
     * Withdraws a drain not yet carried out: the reader came back before the queue came to rest
     * — a chapter still on the wire, or a rest between blocks, which a drain waits out.
     */
    fun keepRunning() {
        if (!draining) return
        trace("dl drain withdrawn left=${s.remainingCount}")
        clearDrain()
    }

    /**
     * The reader closed the verification sheet: the books it held go again. Dismissed
     * unsolved, the retry meets the wall again and [hitWall] gives up on the host for now.
     */
    fun retryAfterWall() {
        s = s.copy(pendingChallenge = null)
        wall = null
        jobs { list -> list.replaceAll { if (it.hold == Hold.WALL) it.copy(hold = null, note = null, retryingWall = true) else it } }
        if (s.isBusy) {
            persistQueue()
        } else {
            s = s.copy(lastError = null)
            run()
        }
    }

    /** Empties the whole queue. */
    fun cancel() {
        stopRun()
        s = s.copy(jobs = emptyList(), pendingChallenge = null, status = Status.IDLE)
        wall = null
        pacer.reset()
        clearDrain()
        persistQueue()
    }

    /** Takes one book out; when it was the one downloading, the next free book carries on. */
    fun cancelBook(bookId: String) {
        val i = index(bookId) ?: return
        jobs { it.removeAt(i) }
        if (s.jobs.none { it.hold == Hold.WALL }) wall = null
        when {
            bookId == s.activeBookId && s.isBusy -> {
                stopRun()
                run()
            }
            s.jobs.isEmpty() -> {
                stopRun()
                s = s.copy(status = Status.IDLE)
                persistQueue()
            }
            else -> persistQueue()
        }
    }

    private fun stopRun() {
        task?.cancel()
        task = null
        s = s.copy(activeBookId = null)
    }

    // The queue

    private fun run() {
        // A drain and a failure streak belong to the run they were met in; resuming is the
        // reader saying they have dealt with whatever stopped it.
        clearDrain()
        failureStreak = 0
        chaptersUntilRest = sampleRestBlock()
        // Not while the sheet is up: it has the web view.
        if (s.pendingChallenge != null || !pickNext()) {
            settle()
            return
        }
        s = s.copy(status = Status.RUNNING)
        persistQueue()
        val token = ++runToken
        task = scope.launch {
            try {
                loop()
            } finally {
                if (runToken == token) notifyStopped()
            }
        }
    }

    private suspend fun loop() {
        while (true) {
            // Read afresh each chapter: the book changes under this loop when one finishes,
            // is paused, or hits a wall.
            val job = activeJob ?: break
            val chapter = job.remaining.firstOrNull() ?: break
            try {
                val missing = download(job.book, job.rule, chapter)
                noteChapterSucceeded()
                if (!completeIfStillQueued(chapter)) return
                wallCleared(job.rule.host)
                // Said out loud: a chapter on the device can now be there, readable, and short a
                // page, and found offline that gap would be a surprise.
                if (missing > 0) setNote("${chapter.title}：有 $missing 頁取不到，其餘已儲存。", job.id)
                trace("dl ok left=${s.remainingCount} missing=$missing")
            } catch (e: CancellationException) {
                throw e
            } catch (e: WebFetcher.FetchError.NeedsTheUser) {
                // The chapter stays at the head, so the retry after the sheet is the one that hit it.
                // A sign-in holds the host too: nothing the queue does alone gets its next chapter.
                hitWall(Wall(e.url, job.book.shownName, signIn = e is WebFetcher.FetchError.SignInRequired), e)
            } catch (e: Exception) {
                // One unreadable chapter is dropped and reported, but a streak is no longer
                // about chapters — a clearance that did not take fails every one, and dropping
                // each in turn eats the queue and calls it finished. So the book is held,
                // chapters intact, and the books behind it carry on.
                if (noteChapterFailed()) {
                    trace("dl streak left=${job.remaining.size}")
                    holdActive("連續多章下載失敗，已暫停：${describe(e)}")
                } else {
                    if (!completeIfStillQueued(chapter)) return
                    setNote(describe(e), job.id)
                    trace("dl fail left=${s.remainingCount} ${e.javaClass.simpleName}")
                }
            }
            if (haltIfDraining()) return
            // The next book in the same loop rather than through run(), which would clear the
            // run's drain and failure state at every hand-over.
            if (!pickNext()) break
            pacer.pace(activeJob?.rule?.host ?: job.rule.host)
            if (restIsDue()) {
                trace("dl rest")
                rest()
                if (haltIfDraining()) return
            }
        }
        settle()
    }

    /** Settles which book the run is on; false when none is free to go. */
    private fun pickNext(): Boolean {
        activeIndex?.let { i ->
            if (s.jobs[i].remaining.isEmpty()) {
                jobs { it.removeAt(i) }
                s = s.copy(activeBookId = null)
            }
        }
        activeJob?.let { if (it.hold == null) return true }
        val next = s.jobs.firstOrNull { it.hold == null }
        if (next == null) {
            s = s.copy(activeBookId = null)
            return false
        }
        s = s.copy(activeBookId = next.id)
        // A streak of the last book's failures says nothing about this one.
        failureStreak = 0
        // Another book means another page in the web view; the wall will not be there by the time the sheet is.
        wall = wall?.copy(reload = true)
        persistQueue()
        return true
    }

    /**
     * Holds every book on the walled host and keeps the wall for later. A wall straight after
     * the reader closed the sheet means the check did not take, so the host's books are paused
     * with the reason instead of the sheet coming straight back.
     */
    private fun hitWall(request: Wall, error: Exception) {
        val job = activeJob ?: return
        val host = job.rule.host
        val gaveUp = job.retryingWall
        trace("dl held signIn=${if (request.signIn) 1 else 0} gaveUp=${if (gaveUp) 1 else 0} left=${job.remaining.size}")
        jobs { list ->
            list.replaceAll {
                when {
                    it.rule.host != host || it.hold == Hold.PAUSED -> it
                    gaveUp -> it.copy(hold = Hold.PAUSED, note = "驗證沒有通過，這本已暫停。按「繼續」再試一次。", retryingWall = false)
                    else -> it.copy(hold = Hold.WALL, note = describe(error))
                }
            }
        }
        if (!gaveUp) wall = request
        persistQueue()
    }

    /** A chapter from [host] landed, so whatever check its books were retrying after has taken. */
    private fun wallCleared(host: String) {
        jobs { list -> list.replaceAll { if (it.rule.host == host && it.retryingWall) it.copy(retryingWall = false) else it } }
    }

    private fun holdActive(note: String) {
        val i = activeIndex ?: return
        job(i) { it.copy(hold = Hold.PAUSED, note = note) }
        persistQueue()
    }

    private fun setNote(note: String, bookId: String) {
        val i = index(bookId) ?: return
        job(i) { it.copy(note = note) }
    }

    /** Brings the queue to rest; this is also where a kept-back wall is finally put to the reader. */
    private fun settle(reason: String? = null) {
        task = null
        s = s.copy(activeBookId = null)
        pacer.reset()
        if (s.jobs.isEmpty()) {
            finish()
            return
        }
        s = s.copy(status = Status.PAUSED, lastError = reason ?: s.lastError)
        val wall = wall
        if (s.pendingChallenge == null && wall != null && s.jobs.none { it.hold == null } && s.jobs.any { it.hold == Hold.WALL }) {
            s = s.copy(pendingChallenge = wall)
        }
        trace("dl rest books=${s.jobs.size} held=${s.jobs.count { it.hold != null }}")
        persistQueue()
    }

    /** A completed run leaves nothing behind: the progress row exists only while there is progress. */
    private fun finish() {
        trace("dl done")
        s = s.copy(status = Status.FINISHED, activeBookId = null)
        wall = null
        pacer.reset()
        persistQueue()
    }

    /** Brings a draining queue to rest; true when the caller must stop. */
    private fun haltIfDraining(): Boolean {
        if (!draining) return false
        trace("dl drained left=${s.remainingCount}")
        activeIndex?.let { i -> if (s.jobs[i].remaining.isEmpty()) jobs { it.removeAt(i) } }
        settle(drainReason)
        clearDrain()
        return true
    }

    /**
     * Mirrors the queue to disk, or removes the file when nothing is left. Only the reader's own
     * pause is written down: a wall or a streak is a judgement about this moment.
     */
    private fun persistQueue() {
        val books = s.jobs.filter { it.remaining.isNotEmpty() }.map {
            PersistedDownloadQueue.Entry(it.id, it.remaining.map { c -> c.siteChapterId }, it.hold == Hold.PAUSED && it.note == null)
        }
        if (books.isEmpty()) queueStore.clear() else queueStore.save(books)
    }

    private fun clearDrain() {
        draining = false
        drainReason = null
        notifyStopped()
    }

    private fun notifyStopped() {
        val callback = onStopped ?: return
        onStopped = null
        callback()
    }

    private fun noteChapterSucceeded() {
        failureStreak = 0
    }

    /** True on the [FAILURE_LIMIT]th failure in a row: the failures have stopped being about chapters. */
    private fun noteChapterFailed(): Boolean = ++failureStreak >= FAILURE_LIMIT

    /**
     * Whether the run has earned its longer pause. The pacer keeps requests from bursting,
     * but the hosts' WAF still walls a run at around the twentieth chapter; a dozen-odd and a
     * rest keeps the sustained rate from looking like a crawler. Drawn fresh each time, since
     * a rest every Nth chapter on the dot is itself a fingerprint.
     */
    private fun restIsDue(): Boolean {
        if (--chaptersUntilRest > 0) return false
        chaptersUntilRest = sampleRestBlock()
        return true
    }

    private fun sampleRestBlock() = Random.nextInt(10, 16)

    /**
     * Takes [chapter] off the head of the active book; false when it is no longer there — a
     * cancel can empty the queue while its fetch is still out.
     */
    private fun completeIfStillQueued(chapter: Chapter): Boolean {
        val i = activeIndex ?: return false
        if (s.jobs[i].remaining.firstOrNull()?.id != chapter.id) return false
        job(i) { it.copy(remaining = it.remaining.drop(1), completed = it.completed + 1) }
        s = s.copy(landed = s.landed + 1)
        return true
    }

    companion object {
        /** Three, not one: a chapter that will not parse is ordinary on these sites. */
        const val FAILURE_LIMIT = 3

        private fun merge(extra: List<Chapter>, queued: List<Chapter>): List<Chapter> {
            val ids = queued.map { it.id }.toSet()
            return queued + extra.filter { it.id !in ids }
        }
    }
}
