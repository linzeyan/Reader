package com.zeyanlin.novelreader

import android.app.Application
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import android.util.Log
import android.webkit.WebSettings
import androidx.core.content.pm.PackageInfoCompat
import androidx.room.Room
import com.zeyanlin.novelreader.data.Book
import com.zeyanlin.novelreader.data.BookBytes
import com.zeyanlin.novelreader.data.Chapter
import com.zeyanlin.novelreader.data.LibraryBackup
import com.zeyanlin.novelreader.data.LibraryDao
import com.zeyanlin.novelreader.data.LibraryDatabase
import com.zeyanlin.novelreader.data.defaultMediaMode
import com.zeyanlin.novelreader.network.WebFetcher
import com.zeyanlin.novelreader.services.BookExporter
import com.zeyanlin.novelreader.services.BookService
import com.zeyanlin.novelreader.services.CacheLimit
import com.zeyanlin.novelreader.services.ComicArchiveImporter
import com.zeyanlin.novelreader.services.ComicPages
import com.zeyanlin.novelreader.services.CoverService
import com.zeyanlin.novelreader.services.DownloadManager
import com.zeyanlin.novelreader.services.DownloadQueueRestorer
import com.zeyanlin.novelreader.services.DownloadQueueStore
import com.zeyanlin.novelreader.services.FeedRetention
import com.zeyanlin.novelreader.services.FeedService
import com.zeyanlin.novelreader.services.OPML
import com.zeyanlin.novelreader.services.LibrarySearch
import com.zeyanlin.novelreader.services.LocalBookError
import com.zeyanlin.novelreader.services.LocalBookImporter
import com.zeyanlin.novelreader.services.NetworkMonitor
import com.zeyanlin.novelreader.services.NetworkPolicy
import com.zeyanlin.novelreader.services.RequestPacer
import com.zeyanlin.novelreader.services.RuleDeriver
import com.zeyanlin.novelreader.services.SearchResult
import com.zeyanlin.novelreader.services.SearchService
import com.zeyanlin.novelreader.services.SiteStore
import com.zeyanlin.novelreader.services.SpeechReader
import com.zeyanlin.novelreader.services.TraceLog
import com.zeyanlin.novelreader.services.nonBlank
import com.zeyanlin.novelreader.siterules.SiteRule
import com.zeyanlin.novelreader.ui.DownloadFocus
import com.zeyanlin.novelreader.ui.ReaderSettings
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import java.io.File
import java.net.URI
import java.text.Collator

/**
 * The app's one environment — the iOS `AppEnvironment`, reduced to what is ported so far.
 * Lives as long as the process, so a fetch or a batch of additions outlives the screen
 * that started it.
 */
class App : Application() {
    val library: LibraryDao by lazy {
        Room.databaseBuilder(this, LibraryDatabase::class.java, "library.db")
            .addMigrations(LibraryDatabase.MIGRATION_1_2, LibraryDatabase.MIGRATION_2_3, LibraryDatabase.MIGRATION_3_4, LibraryDatabase.MIGRATION_4_5).build().library()
    }
    val sites by lazy { SiteStore(File(filesDir, "sites")) }

    /** Created on first use, on the main thread, as WebView requires. */
    val fetcher by lazy { WebFetcher(this) }
    val books by lazy { BookService(fetcher) }
    val search by lazy { SearchService(fetcher) }
    val librarySearch by lazy { LibrarySearch(library) }
    val feeds by lazy { FeedService(this, library) }
    val comics by lazy { ComicPages(File(filesDir, "Pages"), File(cacheDir, CacheLimit.PAGES), { cacheLimit.added(it) }) { userAgent() } }
    val cacheLimit by lazy { CacheLimit(library, File(cacheDir, CacheLimit.PAGES), prefs) }
    val covers by lazy {
        CoverService(File(filesDir, "Covers"), File(cacheDir, "Covers"), scope) { address, siteId, siteBookId ->
            CoverService.request(address, sites.rule(siteId)?.bookUrl(siteBookId), userAgent())
        }
    }

    /** Files on their way out of the app: an export waiting for its save sheet, a file handed to a share. */
    val exports get() = File(cacheDir, CacheLimit.EXPORTS)
    val prefs by lazy { getSharedPreferences("app", MODE_PRIVATE)!! }

    /** One for the process, as iOS has `ReaderSettings.shared`: the reader and Settings edit the same answers. */
    val reader by lazy { ReaderSettings(prefs, filesDir) }
    val pacer = RequestPacer()

    /** Here rather than on the reader screen: listening outlives looking, as iOS keeps it in `AppEnvironment`. */
    val speech by lazy { SpeechReader(this) { banner.value = it } }

    private val scope = MainScope()

    val network by lazy { NetworkMonitor(this) }
    private val queueStore by lazy { DownloadQueueStore(File(filesDir, "DownloadQueue.json")) }
    val downloads by lazy {
        DownloadManager(
            scope, pacer, queueStore,
            download = { book, rule, chapter -> download(book, rule, chapter) },
            trace = { note("Downloads", it) },
        )
    }
    val focus by lazy { DownloadFocus(scope) }
    private val restorer by lazy {
        DownloadQueueRestorer(
            queueStore, downloads,
            book = { library.bookNow(it) }, chapters = { library.chaptersNow(it) }, rule = { sites.rule(it) },
            policy = { downloadNetwork.value }, connection = { network.connection.value },
        )
    }

    /** Which networks downloads may use. Per device, like iOS keeps it out of iCloud: it is a data plan's property. */
    val downloadNetwork by lazy { MutableStateFlow(NetworkPolicy.from(prefs.getString(DOWNLOAD_NETWORK, null))) }

    fun setDownloadNetwork(policy: NetworkPolicy) {
        downloadNetwork.value = policy
        prefs.edit().putString(DOWNLOAD_NETWORK, policy.raw).apply()
    }

    /**
     * The diagnostics trace — the iOS `env.trace`. In the no-backup directory, as iOS keeps it out
     * of iCloud backup and out of `Caches`: the system clears a cache under exactly the pressure
     * that produces the sessions worth reading.
     */
    val trace by lazy {
        val info = packageManager.getPackageInfo(packageName, 0)
        val stamp = "v=${info.versionName}(${PackageInfoCompat.getLongVersionCode(info)}) " +
            "hw=${Build.MODEL.replace(' ', '_')} android=${Build.VERSION.RELEASE}"
        TraceLog(File(noBackupFilesDir, "Trace"), prefs.getBoolean(TRACE_ON, false), stamp)
    }

    fun setTracing(on: Boolean) {
        trace.setOn(on)
        prefs.edit().putBoolean(TRACE_ON, on).apply()
    }

    /** A trace line: to logcat as always, and into the recording when one is on. */
    private fun note(tag: String, line: String) {
        Log.i(tag, line)
        trace.note(line)
    }

    override fun onCreate() {
        super.onCreate()
        scope.launch(Dispatchers.Default) { library.foldPending() }
        scope.launch {
            // The restore first: its decision waits on the first network report, which the
            // collection below delivers.
            restorer.restore()
            network.connection.collect { networkChanged() }
        }
        scope.launch {
            downloads.state.map { it.pendingChallenge }.distinctUntilChanged().collect { wall ->
                if (wall == null) return@collect
                if (wall.reload) fetcher.webView.loadUrl(wall.url)
                challenge.value = Challenge(wall.url, "App 正在下載《${wall.bookName}》。", wall.signIn)
            }
        }
    }

    /** A site check the reader has to complete by hand, shown over whatever screen is up. [signIn]: by signing in. */
    data class Challenge(val url: String, val doing: String, val signIn: Boolean = false)

    val challenge = MutableStateFlow<Challenge?>(null)

    /** A failure the screen that met it has no place to show. */
    val banner = MutableStateFlow<String?>(null)

    /** The library as a backup file — the iOS `backupData`. */
    suspend fun backupData(): ByteArray {
        val settings = LibraryBackup.Settings.capture(reader, downloadNetwork.value, prefs)
        return withContext(Dispatchers.IO) {
            LibraryBackup.capture(
                library.allBooksNow(), library.allBookmarksNow(), library.allHighlightsNow(), sites.rules.value, settings,
            ).encode()
        }
    }

    /** Merges a backup file into the library and counts what changed — the iOS `restoreBackup`. */
    suspend fun restoreBackup(uri: Uri): LibraryBackup.Outcome {
        val backup = withContext(Dispatchers.IO) {
            LibraryBackup.read(contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: throw LibraryBackup.Failure.Unreadable())
        }
        val known = library.allBookmarksNow().map { it.id } + library.allHighlightsNow().map { it.id }
        val plan = backup.plan(library.allBooksNow().associateBy { it.id }, known.toSet(), sites.rules.value.map { it.id }.toSet())
        library.restore(plan.books, plan.bookmarks, plan.highlights)
        // One malformed rule must not take the restore down: the shelf and the marks are what
        // the reader came for, and a source can be imported again by hand.
        val rules = withContext(Dispatchers.IO) {
            plan.rules.count { rule -> runCatching { sites.import(SiteRule.json.encodeToString(SiteRule.serializer(), rule)) }.isSuccess }
        }
        backup.settings?.apply(reader, ::setDownloadNetwork, reader.installedFaces, prefs)
        return LibraryBackup.Outcome(plan.books.size, plan.bookmarks.size + plan.highlights.size, rules, plan.skippedImports)
    }

    fun report(error: Throwable, doing: String) {
        when (error) {
            is CancellationException -> Unit
            // One sheet for both, on the one web view: a sign-in only helps in the browser whose
            // cookies the next fetch carries.
            is WebFetcher.FetchError.NeedsTheUser ->
                challenge.value = Challenge(error.url, doing, error is WebFetcher.FetchError.SignInRequired)
            else -> banner.value = describe(error)
        }
    }

    /**
     * The sheet closed. If it was the wall that stopped the download queue, the queue goes
     * again: closing it is the reader saying the check is dealt with, and resuming is why they
     * dealt with it. Dismissed unsolved, the queue meets the wall again and pauses that host.
     */
    fun closeChallenge() {
        challenge.value = null
        if (downloads.state.value.pendingChallenge != null) downloads.retryAfterWall()
    }

    // Downloads

    /** The download waiting on an answer about cellular data. */
    val meteredPrompt = MutableStateFlow<(() -> Unit)?>(null)

    /** Consent to spend cellular data, for the run it was given in and no longer. */
    private var meteredConsent = false
    private var resumeWhenActive = false

    /** The one way a download starts, so the network policy is checked in one place. */
    fun requestDownload(book: Book, rule: SiteRule, chapters: List<Chapter>) {
        // A new run gets a new decision; a book joining a running one joins its consent too.
        if (!downloads.state.value.isBusy) meteredConsent = false
        request { downloads.start(book, rule, chapters) }
    }

    /** Resuming is a start as far as the data plan is concerned. [bookId] null: the whole queue. */
    fun requestResume(bookId: String? = null) = request {
        if (bookId != null) downloads.resumeBook(bookId) else downloads.resume()
    }

    fun confirmMeteredDownload() {
        val work = meteredPrompt.value ?: return
        meteredPrompt.value = null
        meteredConsent = true
        work()
    }

    fun cancelMeteredDownload() {
        meteredPrompt.value = null
    }

    private fun request(work: () -> Unit) {
        if (!meteredConsent && downloadNetwork.value.needsConfirmation(network.connection.value)) {
            meteredPrompt.value = work
        } else {
            work()
        }
    }

    /**
     * Leaving the app finishes the chapter on the wire and pauses, as iOS does: the web view is
     * throttled once nothing shows it, and a queue that stalls silently reads as a bug.
     */
    fun enterBackground() {
        note("Downloads", "bg enter busy=${if (downloads.state.value.isBusy) 1 else 0}")
        focus.stop()
        if (!downloads.state.value.isBusy) return
        resumeWhenActive = true
        downloads.stopAfterCurrentChapter("App 進入背景，下載已暫停；回到 App 會自動繼續。")
    }

    /**
     * Coming back continues it — through the policy check, since the network may have changed.
     * Back before it came to rest, it simply carries on: a resume would find it still running
     * and do nothing, and the drain would then stop it with the reader looking at the screen.
     * (A metered network meanwhile has already paused it, so carrying on cannot spend data.)
     */
    fun becomeActive() {
        note("Downloads", "bg leave resume=${if (resumeWhenActive) 1 else 0}")
        // Coming back is opening the app as far as a subscription is concerned — the commonest
        // way it is opened at all. Launch arrives here too.
        refreshFeedsOnOpen()
        if (!resumeWhenActive) return
        resumeWhenActive = false
        if (downloads.state.value.isBusy) downloads.keepRunning() else requestResume()
    }

    /**
     * A restored queue waits on the first report; after that, walking out of Wi-Fi mid-download
     * under a Wi-Fi-only policy pauses rather than spending data nobody agreed to.
     */
    private fun networkChanged() {
        restorer.connectionChanged()
        val state = downloads.state.value
        if (state.isBusy && !meteredConsent && downloadNetwork.value.needsConfirmation(network.connection.value)) {
            downloads.pause(DownloadQueueRestorer.CELLULAR_PAUSED)
        }
    }

    /**
     * One chapter onto the device. A chapter already kept from reading is the same text, so it
     * is stamped rather than fetched again — one request fewer at a host that counts them.
     */
    private suspend fun download(book: Book, rule: SiteRule, chapter: Chapter): Int {
        if (book.kind == SiteRule.Kind.COMIC) {
            val pages = comics.fetchAll(liveImages(rule, chapter), chapter.url)
            withContext(Dispatchers.IO) { comics.write(pages, comics.downloaded(book.id, chapter.siteChapterId)) }
            library.markDownloaded(chapter.id)
            return pages.count { it == null }
        }
        if (library.stampIfKept(chapter.id) > 0) return 0
        val fetched = books.chapterParagraphs(rule, chapter.url)
        Chapter.fullerTitle(fetched.title, chapter.title)?.let { runCatching { library.updateChapterTitle(chapter.id, it) } }
        library.storeDownload(chapter.id, Json.encodeToString(fetched.paragraphs))
        return 0
    }

    /** Off the shelf, and out of the queue: a download of a book that is gone fetches for nobody. */
    fun deleteBook(id: String) {
        downloads.cancelBook(id)
        reader.forgetOverrides(id)
        scope.launch {
            library.deleteBook(id)
            withContext(Dispatchers.IO) {
                comics.deleteBook(id)
                covers.delete(id)
            }
        }
    }

    // A comic's pages are files beside the database: they go first, so a flag never claims pages
    // that are gone for long — and a flag left by a crash between reads as a chapter to fetch again.

    suspend fun deleteDownloads(chapters: List<Chapter>) {
        withContext(Dispatchers.IO) { chapters.forEach { comics.downloaded(it.bookId, it.siteChapterId).deleteRecursively() } }
        library.deleteDownloads(chapters.map { it.id })
    }

    /** One book's downloads, or every book's when [bookId] is null. */
    suspend fun deleteBookDownloads(bookId: String?) {
        withContext(Dispatchers.IO) { comics.deleteDownloads(bookId) }
        library.deleteBookDownloads(bookId)
    }

    /** One book's chapter cache, or every book's when [bookId] is null; downloads stay. */
    suspend fun clearCache(bookId: String?) {
        withContext(Dispatchers.IO) { comics.clearCache(bookId) }
        library.clearCache(bookId)
        cacheLimit.forget()
    }

    /**
     * Downloaded bytes per book: text from the database, a comic's pages from the disk — counted
     * again whenever a chapter's download flag moves, which every download and deletion does.
     */
    fun downloadSizes(): Flow<List<BookBytes>> = library.downloadSizes().map { text ->
        text + library.allBooksNow().filter { it.kind == SiteRule.Kind.COMIC }
            .mapNotNull { b -> comics.downloadedBytes(b.id).takeIf { it > 0 }?.let { BookBytes(b.id, it) } }
    }.flowOn(Dispatchers.IO)

    // Adding books. Held here rather than in the sheet, so hiding the sheet does not stop it.

    /** [title] is what a subscription list named the feed, kept under it if its own document will not answer. */
    data class Addition(val url: String, val state: State, val note: String? = null, val title: String? = null) {
        enum class State { WAITING, RUNNING, ADDED, FAILED }
    }

    /** What a run turns addresses into, which also decides how it runs. */
    enum class AddKind { BOOK, SUBSCRIPTION, SUBSCRIPTION_LIST }

    val additions = MutableStateFlow<List<Addition>>(emptyList())
    val addKind = MutableStateFlow(AddKind.BOOK)

    /**
     * What the shelf is about. Not remembered across launches, as on iOS: each starts on the reader's
     * default shelf, and the switch changes it for the session. Lazy, as preferences need the context.
     */
    val mediaMode by lazy { MutableStateFlow(prefs.defaultMediaMode()) }
    private var adding: Job? = null

    /** @return false while another batch runs: two would race for the same hosts, reported in two places. */
    fun add(urls: List<String>, kind: AddKind = AddKind.BOOK, titles: List<String?> = emptyList()): Boolean {
        if (adding?.isActive == true) return false
        additions.value = urls.mapIndexed { i, url -> Addition(url, Addition.State.WAITING, title = titles.getOrNull(i)) }
        addKind.value = kind
        adding = scope.launch { if (kind == AddKind.BOOK) addBooksInTurn(urls) else subscribeSiteBySite(kind) }
        return true
    }

    private suspend fun addBooksInTurn(urls: List<String>) {
        // More than one address is unattended work, paced like a download; a single one is
        // somebody waiting on a tap.
        val paced = urls.size > 1
        try {
            for (i in urls.indices) {
                setAddition(i) { it.copy(state = Addition.State.RUNNING) }
                if (paced) pacer.pace(runCatching { URI(urls[i]).host?.lowercase() }.getOrNull() ?: urls[i])
                val done = try {
                    Addition(urls[i], Addition.State.ADDED, addBook(urls[i]))
                } catch (e: CancellationException) {
                    throw e
                } catch (e: WebFetcher.FetchError.NeedsTheUser) {
                    // Answered by the reader; carrying on would spend the rest of the
                    // batch on a host that is going to refuse all of it.
                    setAddition(i) { it.copy(state = Addition.State.FAILED, note = describe(e)) }
                    report(e, "App 正在加入書籍。")
                    markUnfinished("已停止")
                    return
                } catch (e: Exception) {
                    Addition(urls[i], Addition.State.FAILED, describe(e))
                }
                setAddition(i) { done }
            }
        } finally {
            if (paced) pacer.reset()
        }
    }

    /**
     * Subscriptions several at once, never two on one host. No challenge path: nothing a feed's
     * plain request meets can be handed to the reader to solve, so a dead one fails its own line
     * and the other nineteen carry on.
     */
    private suspend fun subscribeSiteBySite(kind: AddKind) {
        val lines = additions.value
        byHost(lines.indices.toList(), { FeedService.host(lines[it].url) }) { i ->
            setAddition(i) { it.copy(state = Addition.State.RUNNING) }
            val done = try {
                val book = feeds.subscribe(lines[i].url) { progress ->
                    // "0 / 0" says less than the spinner alone.
                    if (progress.total > 0) setAddition(i) { it.copy(note = "已取 ${progress.stored} / ${progress.total} 篇") }
                }
                lines[i].copy(state = Addition.State.ADDED, note = book.shownName)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // From a list the file is the evidence the reader subscribed: a bad minute on a
                // train must not drop a feed silently out of a file they may have deleted since.
                val kept = if (kind == AddKind.SUBSCRIPTION_LIST) keepUnreadableFeed(lines[i].url, lines[i].title) else null
                lines[i].copy(state = if (kept != null) Addition.State.ADDED else Addition.State.FAILED, note = kept ?: describe(e))
            }
            setAddition(i) { done }
        }
    }

    /** On the shelf unread, under the name the file gave it; the next refresh fills it in. Null if the address was never one. */
    private suspend fun keepUnreadableFeed(address: String, title: String?): String? {
        val url = FeedService.url(address) ?: return null
        val name = title.nonBlank() ?: FeedService.host(url)
        library.bookmark(FeedService.FEED_SITE_ID, url, SiteRule.Kind.FEED, name, null, null)
        return name
    }

    /** @return how many subscriptions the file listed. One already on the shelf is re-read, not duplicated: its id is its address. */
    suspend fun importSubscriptions(uri: Uri): Int {
        val data = withContext(Dispatchers.IO) { contentResolver.openInputStream(uri)?.use { it.readBytes() } }
            ?: throw Refusal("無法讀取這個檔案。")
        val subscriptions = OPML.subscriptions(data)
        if (subscriptions.isEmpty()) throw Refusal("這個檔案裡沒有訂閱源。")
        if (!add(subscriptions.map { it.address }, AddKind.SUBSCRIPTION_LIST, subscriptions.map { it.title })) {
            throw Refusal("已經有一批正在加入，請等它完成後再試。")
        }
        return subscriptions.size
    }

    /**
     * The shelf's subscriptions as OPML, under the reader's own names and by name: the file is read
     * by people as often as by programs, and "most recently subscribed first" means nothing outside.
     */
    suspend fun subscriptionsDocument(): String {
        val collator = Collator.getInstance()
        val feeds = library.allBooksNow().filter { it.kind == SiteRule.Kind.FEED }
            .map { OPML.Subscription(it.shownName, it.siteBookId) }
            .sortedWith { a, b -> collator.compare(a.title ?: a.address, b.title ?: b.address) }
        return OPML.document("訂閱", feeds)
    }

    // Subscriptions

    private var feedSweep: Job? = null
    private var imagesSwept = false

    /**
     * Subscriptions are read when the app is opened and at no other time — no timer, no background
     * schedule: "what is new since I last looked" is only asked by looking. Staleness keeps a quick
     * switch away and back from asking again. Silent: the shelf's rows say what arrived.
     */
    private fun refreshFeedsOnOpen() {
        if (feedSweep?.isActive == true) return
        feedSweep = scope.launch {
            // Before anything this launch writes a picture, so the sweep cannot take one mid-store.
            if (!imagesSwept) {
                imagesSwept = true
                feeds.sweepImages()
            }
            refreshFeeds()
            // After the refresh: what the publisher still lists is the line retention will not
            // delete past, and the refresh is what re-draws it.
            val policy = retentionPolicy()
            for (book in library.allBooksNow()) {
                if (book.kind == SiteRule.Kind.FEED) runCatching { feeds.purge(book, policy) }
            }
        }
    }

    /** [force] is a pull on the shelf: the reader saying "now", which "you already have it" would only get pulled again. */
    suspend fun refreshFeeds(force: Boolean = false) {
        val due = library.allBooksNow().filter { it.kind == SiteRule.Kind.FEED && (force || it.catalogIsStale) }
        byHost(due, { FeedService.host(it.siteBookId) }) { book ->
            try {
                feeds.refresh(book)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // A banner per unreachable feed would bury the app the first time a train goes into a tunnel.
                // Logcat only, never the trace: the line names the feed's address.
                Log.i("Feeds", "refresh failed ${book.siteBookId}: ${describe(e)}")
            }
        }
    }

    /** How much of each subscription this device keeps. Per device, as iOS keeps it: how much room there is is the device's own fact. */
    fun retentionPolicy() = FeedRetention.Policy(
        prefs.retention(FEED_KEEP),
        prefs.retention(FEED_GRACE) * DAY_MS,
        prefs.retention(FEED_UNREAD).takeIf { it > 0 }?.let { it * DAY_MS },
    )

    fun stopAdding() {
        adding?.cancel()
        markUnfinished("已停止")
    }

    private fun markUnfinished(note: String) {
        additions.update { list ->
            list.map {
                if (it.state == Addition.State.WAITING || it.state == Addition.State.RUNNING) {
                    it.copy(state = Addition.State.FAILED, note = note)
                } else {
                    it
                }
            }
        }
    }

    fun clearAdditions() {
        additions.value = emptyList()
    }

    private fun setAddition(index: Int, change: (Addition) -> Addition) {
        additions.update { list -> list.mapIndexed { i, a -> if (i == index) change(a) else a } }
    }

    /**
     * One pasted address, turned into a book — the iOS `addPastedBook`. An address no installed
     * rule claims gets a rule worked out from its own page, installed only once that rule has
     * also found this book's id and details: the book stands in for the settings screen's
     * preview, and the line names the source it made so the reader knows there is one.
     *
     * @return what the line says: the title the site published.
     */
    private suspend fun addBook(url: String): String {
        val installed = sites.ruleMatching(url)
        val rule = installed ?: derivedRule(url)
        val siteBookId = rule.bookId(url) ?: throw Refusal("無法從這個網址辨識書籍，請改用書籍頁的網址。")
        val info = books.info(rule, siteBookId)
        val source = installed ?: sites.import(SiteRule.json.encodeToString(SiteRule.serializer(), rule))
        val book = library.bookmark(source.id, siteBookId, source.kind, info.title, info.author, info.cover)
        // The book is on the shelf either way; its screen refetches a missing catalog.
        try {
            refreshCatalog(book)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (e is WebFetcher.FetchError.NeedsTheUser) report(e, "App 正在加入書籍。")
        }
        return if (installed == null) "${info.title} · 已自動建立來源「${source.name}」" else info.title
    }

    /**
     * A search hit straight onto the shelf: the row already has the title, author and cover, so
     * there is no page to open first. Awaits the catalog, so the book reads on its first open.
     */
    suspend fun add(result: SearchResult) {
        val rule = sites.rule(result.siteId) ?: return
        val book = library.bookmark(rule.id, result.siteBookId, rule.kind, result.title, result.author, result.coverURL)
        refreshCatalog(book)
    }

    /** A challenge passes through untouched: the batch stops on it to put it in front of the reader. */
    private suspend fun derivedRule(url: String): SiteRule = try {
        RuleDeriver(fetcher, sites.rules.value).derive(url).rule
    } catch (e: CancellationException) {
        throw e
    } catch (e: WebFetcher.FetchError.ChallengePresented) {
        throw e
    } catch (e: Exception) {
        throw Refusal("這個網站沒有來源，自動建立也失敗了：${describe(e)}")
    }

    // Importing files. Here for the same reason as additions: leaving the shelf must not stop it.

    /** How far the running import is, 0…1; null when none is running. */
    val importProgress = MutableStateFlow<Double?>(null)
    private var importing: Job? = null

    /** [comic] by the shelf it was picked from, as on iOS: the picker offered only that shelf's types. */
    fun importFile(uri: Uri, comic: Boolean = mediaMode.value == SiteRule.Kind.COMIC) {
        if (importing?.isActive == true) return
        importProgress.value = 0.0
        importing = scope.launch {
            try {
                val name = contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                    ?.use { if (it.moveToFirst()) it.getString(0) else null }
                    ?: uri.lastPathSegment.orEmpty()
                val open = { contentResolver.openInputStream(uri) }
                val report = { fraction: Double -> importProgress.value = fraction }
                if (comic) ComicArchiveImporter(this@App, library, comics, covers).import(open, name, report)
                else LocalBookImporter(this@App, library).import(open, name, report)
            } catch (e: Exception) {
                // A cancel is the reader's own doing; the banner going away is the answer.
                report(e, "App 正在匯入檔案。")
            } finally {
                importProgress.value = null
            }
        }
    }

    fun cancelImport() {
        importing?.cancel()
    }

    /** Set when another app hands over a file; the shell takes the reader to the shelf it lands on. */
    val showShelf = MutableStateFlow(false)

    /**
     * A TXT or EPUB another app handed over — the iOS `RootView.open` — through the shelf's own
     * import, so it shows, cancels and fails the same way. Always a novel, as on iOS, whichever
     * shelf was up: so the novel shelf is the one shown.
     */
    fun open(uri: Uri) {
        mediaMode.value = SiteRule.Kind.NOVEL
        showShelf.value = true
        // Behind an import still running, which would otherwise turn this one away unseen.
        scope.launch {
            importing?.join()
            importFile(uri, comic = false)
        }
    }

    /** Fire and forget, so a position taken as the reader closes outlives the screen. */
    fun updateProgress(bookId: String, siteChapterId: String, paragraph: Int, characterOffset: Int, fraction: Double?) {
        scope.launch {
            library.updateProgress(bookId, siteChapterId, paragraph, characterOffset, fraction, System.currentTimeMillis())
        }
    }

    suspend fun refreshCatalog(book: Book) {
        if (book.kind == SiteRule.Kind.FEED) return feeds.refresh(book)
        val rule = sites.rule(book.siteId) ?: return
        library.replaceCatalog(book.id, books.catalog(rule, book.siteBookId))
    }

    /** [book] as a file from its downloaded text, off the main thread — the iOS `BookExporter` call. */
    suspend fun export(book: Book, format: BookExporter.Format, progress: (Double) -> Unit): BookExporter.Export {
        val chapters = library.chaptersNow(book.id)
        // Fetched if need be: a cover never drawn, or drawn from memory after its file was cleared,
        // is not on the disk, and a file leaving the app is no place to go without one.
        val cover = covers.cover(book.id, book.siteId, book.siteBookId, book.coverURL)
        return withContext(Dispatchers.IO) {
            BookExporter({ c -> ComicPages.stored(comics.downloaded(c.bookId, c.siteChapterId)) }, cover?.readBytes()) { c ->
                library.cachedParagraphs(c.id)?.let { Json.decodeFromString<List<String>>(it) }
            }.export(book, chapters, format, exports, progress)
        }
    }

    /**
     * A comic chapter's pages, as the iOS `ComicReaderModel` opens one: the downloaded pages where
     * there are any — with or without a rule — else the site's, each found in the cache before it
     * is fetched. A downloaded chapter's gaps are filled from the site only when it still has as
     * many pages: a list that has changed length may not number its pages the same way.
     */
    suspend fun comicPages(book: Book, chapter: Chapter): List<ComicPages.Page> {
        val directory = comics.downloaded(book.id, chapter.siteChapterId)
        val stored = withContext(Dispatchers.IO) { ComicPages.stored(directory) }
        val rule = sites.rule(book.siteId)
        if (stored.isNotEmpty()) {
            val live = if (rule != null && stored.any(ComicPages::isGap)) {
                try {
                    liveImages(rule, chapter).takeIf { it.size == stored.size }
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    null
                }
            } else {
                null
            }
            return stored.mapIndexed { i, file ->
                if (ComicPages.isGap(file)) ComicPages.Page(i, File(directory, ComicPages.name(i)), live?.get(i)) else ComicPages.Page(i, file, null)
            }
        }
        // A file has no site to fall back to: its pages are gone, and only the file brings them back.
        if (book.isLocal) throw LocalBookError.ContentDeleted()
        rule ?: throw Refusal("這本書的來源規則已被移除，重新加入後即可繼續閱讀。")
        val cached = comics.cached(book.id, chapter.siteChapterId)
        // The chapter, not the page, is what was read: its pages live and die together under the cache limit.
        withContext(Dispatchers.IO) { cached.setLastModified(System.currentTimeMillis()) }
        return liveImages(rule, chapter).mapIndexed { i, url -> ComicPages.Page(i, File(cached, ComicPages.name(i)), url) }
    }

    private suspend fun liveImages(rule: SiteRule, chapter: Chapter): List<String> {
        val fetched = books.chapterImages(rule, chapter.url)
        // Swallowed on failure, as for text: a tidier name is never worth failing a chapter for.
        Chapter.fullerTitle(fetched.title, chapter.title)?.let { runCatching { library.updateChapterTitle(chapter.id, it) } }
        return fetched.imageURLs
    }

    private var agent: String? = null

    /** The web view's own agent: the pictures are asked for as the page that shows them would ask. */
    private suspend fun userAgent(): String =
        agent ?: withContext(Dispatchers.Main) { WebSettings.getDefaultUserAgent(this@App) }.also { agent = it }

    /** A chapter's text: the kept copy if there is one, else the site's, kept for next time. */
    suspend fun paragraphs(book: Book, chapter: Chapter): List<String> {
        library.cachedParagraphs(chapter.id)?.let {
            library.touchText(chapter.id)
            return Json.decodeFromString(it)
        }
        // A file has no site to fall back to: its text is gone, and only the file brings it back.
        if (book.isLocal) throw LocalBookError.ContentDeleted()
        // An article's text arrives with the feed or not at all; the reader offers the page instead.
        if (book.kind == SiteRule.Kind.FEED) throw FeedService.EmptyArticle()
        val rule = sites.rule(book.siteId) ?: throw Refusal("這本書的來源規則已被移除，重新加入後即可繼續閱讀。")
        val fetched = books.chapterParagraphs(rule, chapter.url)
        // Swallowed on failure: a chapter must not fail to open because its title could not be tidied up.
        Chapter.fullerTitle(fetched.title, chapter.title)?.let { runCatching { library.updateChapterTitle(chapter.id, it) } }
        val json = Json.encodeToString(fetched.paragraphs)
        library.cache(chapter.id, json)
        // Twice: the folded twin search reads is about the same size again.
        cacheLimit.added(json.toByteArray().size * 2L)
        return fetched.paragraphs
    }
}

private const val DOWNLOAD_NETWORK = "downloads.network"
private const val TRACE_ON = "trace.isOn"
const val FEED_KEEP = "feeds.retention.keep"
const val FEED_GRACE = "feeds.retention.grace"
const val FEED_UNREAD = "feeds.retention.unread"

/** A retention answer as stored, falling back to iOS's: ten articles, a week's grace, a month for the unread. */
fun android.content.SharedPreferences.retention(key: String) =
    getInt(key, mapOf(FEED_KEEP to 10, FEED_GRACE to 7, FEED_UNREAD to 30).getValue(key))
private const val DAY_MS = 24 * 60 * 60 * 1000L

/**
 * Several hosts at once, one request at a time per host: a feed is published to be polled, but four
 * connections to one blog is rude. Four lanes, because each feed in flight also holds a web view.
 * ponytail: a lane keeps its slot through its whole host queue; iOS frees it between items.
 */
private suspend fun <T> byHost(items: List<T>, host: (T) -> String, work: suspend (T) -> Unit) = coroutineScope {
    val lanes = Semaphore(4)
    for (queue in items.groupBy(host).values) launch { lanes.withPermit { queue.forEach { work(it) } } }
}

/** A failure whose message is already written for the reader. */
class Refusal(message: String) : Exception(message)

fun describe(error: Throwable): String = when (error) {
    is WebFetcher.FetchError.ChallengePresented -> "此站台需要通過驗證，請點一下完成。"
    is WebFetcher.FetchError.SignInRequired -> "這個網站只給登入的讀者看，請點一下登入。"
    is WebFetcher.FetchError.TimedOut -> "頁面載入逾時。"
    is WebFetcher.FetchError.NavigationFailed -> "無法開啟頁面（${error.message}）。"
    is BookService.ServiceError.NoTitle -> "讀不到書名，這個頁面可能不是書籍頁。"
    is BookService.ServiceError.EmptyCatalog -> "目錄沒有可用的章節連結。"
    is BookService.ServiceError.EmptyChapter -> "讀不到章節內容。"
    else -> error.message ?: error.javaClass.simpleName
}
