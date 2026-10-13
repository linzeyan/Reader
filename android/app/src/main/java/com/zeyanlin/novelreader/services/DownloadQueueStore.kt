package com.zeyanlin.novelreader.services

import com.zeyanlin.novelreader.data.Book
import com.zeyanlin.novelreader.data.Chapter
import com.zeyanlin.novelreader.siterules.SiteRule
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/**
 * The pending download queue as it sits on disk — the iOS `PersistedDownloadQueue`. Chapter
 * ids rather than rows: the catalog is the truth for a chapter's title and address, and one the
 * site has since removed must leave the queue rather than come back from a stale copy.
 *
 * Deliberately without consent to spend cellular data: that belongs to the run it was given for.
 */
@Serializable
data class PersistedDownloadQueue(val version: Int = CURRENT_VERSION, val books: List<Entry>) {
    @Serializable
    data class Entry(
        val bookId: String,
        /** Site chapter ids, in queue order. */
        val siteChapterIds: List<String>,
        /** Paused by the reader, and to stay that way until they say otherwise. */
        val paused: Boolean = false,
    )

    companion object {
        /** A version this build does not know is dropped like a corrupt file. */
        const val CURRENT_VERSION = 2
    }
}

/**
 * The one file the pending queue lives in, in app storage rather than the cache directory,
 * which the system may empty behind the reader's back.
 */
class DownloadQueueStore(private val file: File) {
    // The version is written even at its default, or a later default would misread this file.
    private val json = Json { encodeDefaults = true }

    sealed interface Stored {
        data object Empty : Stored
        data class Queue(val queue: PersistedDownloadQueue) : Stored

        /** Present but unreadable, and already deleted: half a queue would fetch the wrong thing. */
        data object Unreadable : Stored
    }

    fun load(): Stored {
        if (!file.exists()) return Stored.Empty
        val queue = runCatching { json.decodeFromString<PersistedDownloadQueue>(file.readText()) }.getOrNull()
        if (queue == null || queue.version != PersistedDownloadQueue.CURRENT_VERSION) {
            clear()
            return Stored.Unreadable
        }
        return Stored.Queue(queue)
    }

    /** Atomic, so the file is the previous queue or the new one and never a truncated mixture. */
    fun save(books: List<PersistedDownloadQueue.Entry>) {
        runCatching {
            file.parentFile?.mkdirs()
            val temporary = File(file.path + ".tmp")
            temporary.writeText(json.encodeToString(PersistedDownloadQueue(books = books)))
            Files.move(temporary.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
        }
    }

    fun clear() {
        file.delete()
    }
}

/**
 * Brings a queue that outlived its process back — or throws it away. The iOS
 * `DownloadQueueRestorer`; the lookups are functions so a test can pin them.
 */
class DownloadQueueRestorer(
    private val store: DownloadQueueStore,
    private val downloader: DownloadManager,
    private val book: suspend (String) -> Book?,
    private val chapters: suspend (String) -> List<Chapter>,
    private val rule: (String) -> SiteRule?,
    private val policy: () -> NetworkPolicy,
    private val connection: () -> Connection,
) {
    /** Set while a restored queue is still waiting to be told whether it may run. */
    private var awaitingConnection = false

    /** Reads the queue back and installs whatever of it is still real. Once, at launch. */
    suspend fun restore() {
        val stored = store.load() as? DownloadQueueStore.Stored.Queue ?: return
        val jobs = stored.queue.books.mapNotNull { job(it) }
        if (jobs.isEmpty()) {
            store.clear()
            return
        }
        downloader.restore(jobs)
        awaitingConnection = true
        decide()
    }

    /** Re-offers the launch decision whenever the connection changes; a no-op once made. */
    fun connectionChanged() = decide()

    /**
     * One book's entry, or null when nothing of it is left: a deleted book, a removed rule,
     * chapters the site dropped or that have landed since — judged per book, so one cannot
     * take the books behind it down.
     */
    private suspend fun job(entry: PersistedDownloadQueue.Entry): DownloadManager.Job? {
        val book = book(entry.bookId) ?: return null
        val rule = rule(book.siteId) ?: return null
        val byId = chapters(book.id).associateBy { it.siteChapterId }
        val left = entry.siteChapterIds.mapNotNull { byId[it] }.filter { it.downloadedAt == null }
        if (left.isEmpty()) return null
        return DownloadManager.Job(book, rule, left, hold = if (entry.paused) DownloadManager.Hold.PAUSED else null)
    }

    /**
     * The unattended rule rather than the foreground's: nobody asked for a download during this
     * launch, so an unreported connection is no evidence of Wi-Fi — which is also why this waits
     * for the first report instead of resolving [Connection.UNKNOWN].
     */
    private fun decide() {
        if (!awaitingConnection) return
        val connection = connection()
        if (connection == Connection.UNKNOWN) return
        awaitingConnection = false
        // A queue already dealt with by hand since launch is the reader's now.
        val state = downloader.state.value
        if (!state.canResume || state.pendingChallenge != null) return
        val policy = policy()
        if (!policy.allowsUnattendedDownload(connection)) {
            // Only the metered case is said: it is the one a tap on resume answers.
            if (policy.needsConfirmation(connection)) downloader.pause(CELLULAR_PAUSED)
            return
        }
        downloader.resume()
    }

    companion object {
        const val CELLULAR_PAUSED = "已切換到行動網路，下載暫停（設定為僅 Wi-Fi 下載）。"
    }
}
