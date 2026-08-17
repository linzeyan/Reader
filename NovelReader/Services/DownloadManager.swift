import Foundation

/// Downloads chapters in the background, one at a time, politely.
///
/// Four constraints shape this:
/// 1. The fetcher owns a single WKWebView, so concurrency is impossible anyway.
/// 2. These hosts sit behind Cloudflare. Hammering a challenged host is exactly
///    what gets an IP blocked, so fetches go through the shared `RequestPacer`
///    and the queue *stops* on a challenge rather than retrying.
/// 3. A paused queue must keep its remaining work, because the user resolving a
///    challenge and tapping resume is the normal path, not an error path.
/// 4. That work has to outlive the process. An 800-chapter book takes far longer
///    than iOS leaves a backgrounded app alive, so a queue that only existed in
///    memory was a download the user watched start and never saw again.
///
/// Hence the queue file, and hence *when* it is written: whenever the queue gains
/// work, and whenever it comes to rest. Deliberately not once per chapter. The
/// chapters `DownloadStore` has already written are the truth for what is
/// finished, so the file only has to be a *superset* of what is left — a stale
/// one costs nothing, because the restore drops what has since arrived. Writing
/// per chapter would put a synchronous file write inside the fetch loop to record
/// something the restore recomputes anyway.
@MainActor
@Observable
final class DownloadManager {
    enum Status: Equatable {
        case idle
        case running
        /// Stopped by the user, or by a challenge that needs a human.
        case paused
        case finished
    }

    struct Progress: Equatable {
        var bookId: String
        var bookTitle: String
        var completed: Int
        var total: Int

        var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
    }

    private(set) var status: Status = .idle
    private(set) var progress: Progress?
    /// Last failure, kept for display; cleared when a new run starts.
    private(set) var lastError: String?
    /// Set when a host escalated to an interactive challenge. The root view
    /// presents the fetcher's web view so the user can complete it.
    var pendingChallenge: URL?

    private let service: BookService
    private let downloads: DownloadStore
    /// Shared with the reader's read-ahead, so the two together still look like
    /// one person turning pages rather than two processes taking turns.
    private let pacer: RequestPacer
    private let queueStore: DownloadQueueStore
    private var task: Task<Void, Never>?

    /// Work not yet done, in order. Survives a pause so `resume()` picks up where
    /// it left off, and a process death so the next launch can.
    private(set) var remaining: [Chapter] = []
    private var context: (book: Book, rule: SiteRule)?
    /// Chapters that have failed since the last one that landed.
    ///
    /// Reset by every success and by every fresh `run`, so it counts a *streak* rather
    /// than a total: three bad chapters spread through an 800-chapter book is a site
    /// with three bad chapters, and the queue is right to walk past them.
    private var failureStreak = 0
    /// Set while the queue is meant to stop after the chapter on the wire.
    private(set) var isDraining = false
    private var drainReason: String?
    /// Whatever is being held open until the queue comes to rest — a background
    /// assertion, or a `BGTask` waiting to hand the system's time back.
    private var onStopped: (() -> Void)?
    /// Which run the queue is on.
    ///
    /// A cancelled run still executes: the task body is scheduled, runs once, and
    /// reaches its `defer`. Without this it would release a hold taken out by the
    /// run that *replaced* it — telling a background window its queue had come to
    /// rest before the first chapter had even been requested.
    private var runToken = 0

    init(
        service: BookService,
        downloads: DownloadStore,
        pacer: RequestPacer,
        queueStore: DownloadQueueStore
    ) {
        self.service = service
        self.downloads = downloads
        self.pacer = pacer
        self.queueStore = queueStore
    }

    /// How many chapters may fail one after another before the queue stops instead of
    /// eating itself. See the `catch` in `run` for what this is protecting.
    ///
    /// Three rather than one: a chapter that will not parse is a real and ordinary
    /// thing on these sites, and stopping the whole book for the first one would put
    /// the reader back to tapping resume every few chapters. Three in a row is no
    /// longer a claim about chapters.
    static let failureLimit = 3

    var isBusy: Bool { status == .running }
    var canResume: Bool { status == .paused && !remaining.isEmpty }
    /// How many chapters the queue still owes. Read by the background task, which
    /// has to be able to report how much a wake-up actually achieved — and whose
    /// whole purpose is to answer whether it achieved anything at all.
    var remainingCount: Int { remaining.count }

    // MARK: - Control

    /// Queues every chapter that is not already on disk.
    func start(book: Book, rule: SiteRule, chapters: [Chapter]) {
        cancel()
        let pending = chapters.filter { !$0.isDownloaded }
        guard !pending.isEmpty else {
            finish()
            return
        }
        context = (book, rule)
        remaining = pending
        lastError = nil
        progress = Progress(
            bookId: book.id, bookTitle: book.shownName, completed: 0, total: pending.count
        )
        persistQueue()
        run()
    }

    /// Installs a queue read back from disk, paused.
    ///
    /// Paused rather than running, and that is the whole contract with the caller:
    /// the network policy has to be cleared again before a single request goes out,
    /// because permission to spend cellular data did not survive the process it was
    /// given to. See `DownloadQueueRestorer`.
    ///
    /// Only ever called at launch, on an idle queue — which is why it does not
    /// tear down a running one first, and must not start doing so: `cancel()`
    /// would erase the very file this was read from.
    func restore(book: Book, rule: SiteRule, chapters: [Chapter]) {
        guard !chapters.isEmpty, status == .idle else { return }
        context = (book, rule)
        remaining = chapters
        progress = Progress(
            bookId: book.id, bookTitle: book.shownName, completed: 0, total: chapters.count
        )
        status = .paused
        // Not written back. What is on disk is already a superset of this — the
        // restore only ever drops entries — and the next time the queue comes to
        // rest it writes the pruned version anyway.
    }

    /// - Parameter reason: shown where download failures are shown. Set when
    ///   something other than the user stopped the queue — a switch to cellular
    ///   under a Wi-Fi-only policy — because a queue that stops by itself with no
    ///   explanation reads as a bug.
    func pause(reason: String? = nil) {
        task?.cancel()
        task = nil
        if !remaining.isEmpty { status = .paused }
        if let reason { lastError = reason }
        clearDrain()
        persistQueue()
    }

    /// Stops the queue after the chapter already on the wire, rather than
    /// abandoning it.
    ///
    /// This exists for backgrounding. iOS grants roughly thirty seconds after the
    /// app leaves the screen: enough for one fetch in flight, nowhere near enough
    /// for a queue. Cancelling outright would throw away a request that is
    /// seconds from done and make the next run repeat it — slower for the user,
    /// and one more hit on a host that is already suspicious of us.
    ///
    /// - Parameter onStopped: called once the queue is at rest, so the caller can
    ///   release what it is holding open. Called immediately when nothing is
    ///   running, because an assertion held for a queue that already stopped is
    ///   time taken from the user for nothing.
    func stopAfterCurrentChapter(reason: String?, onStopped: @escaping () -> Void) {
        guard status == .running else {
            onStopped()
            return
        }
        // A second request supersedes the first; the first caller's hold is
        // released now rather than leaked until the system reclaims it.
        notifyStopped()
        isDraining = true
        drainReason = reason
        self.onStopped = onStopped
    }

    /// - Parameter onStopped: called once the queue comes back to rest, however it
    ///   ends — emptied, stuck on a challenge, or paused from outside. Set after
    ///   `run`, which clears any hold a previous drain request left behind.
    ///   `stopAfterCurrentChapter` uses the same slot: a background window wants
    ///   the whole queue rather than one chapter, but wants telling at the same
    ///   moment, because that is when it can hand the system's time back.
    func resume(onStopped: (() -> Void)? = nil) {
        guard canResume else { return }
        pendingChallenge = nil
        lastError = nil
        run()
        if let onStopped { self.onStopped = onStopped }
    }

    func cancel() {
        task?.cancel()
        task = nil
        remaining = []
        context = nil
        progress = nil
        pendingChallenge = nil
        status = .idle
        pacer.reset()
        clearDrain()
        persistQueue()
    }

    // MARK: - Queue

    private func run() {
        guard let context else { return }
        status = .running
        // A drain request belongs to the run it was made for. Carried into the
        // next one it would stop that run after a single chapter, with nothing
        // on screen to explain why.
        clearDrain()
        // So does a failure streak. Resuming is the user saying they have dealt with
        // whatever stopped the queue — cleared a challenge, changed network — and the
        // new run has to be allowed to find that out for itself.
        failureStreak = 0
        runToken += 1
        let token = runToken
        task = Task { [weak self] in
            guard let self else { return }
            // Released on every exit — normal end, cancellation, challenge,
            // drain. A background assertion held past the point where the queue
            // stopped is time iOS took from the user for nothing. Only for this
            // run, though: see `runToken`.
            defer { if self.runToken == token { self.notifyStopped() } }
            while !Task.isCancelled, let chapter = self.remaining.first {
                do {
                    let paragraphs = try await self.service.chapterParagraphs(
                        rule: context.rule, chapter: chapter
                    )
                    try self.downloads.save(
                        paragraphs: paragraphs,
                        book: context.book,
                        siteChapterId: chapter.siteChapterId
                    )
                    self.noteChapterSucceeded()
                    guard self.completeIfStillQueued(chapter) else { return }
                } catch is CancellationError {
                    return
                } catch WebFetcher.FetchError.challengePresented(let url) {
                    // Stop dead. The chapter stays at the head of the queue, so
                    // resuming after the user clears the challenge retries it.
                    self.pendingChallenge = url
                    self.lastError = WebFetcher.FetchError.challengePresented(url).localizedDescription
                    self.status = .paused
                    self.persistQueue()
                    return
                } catch {
                    // A single unreadable chapter must not strand the rest of the
                    // book, so it is dropped from the queue and reported.
                    //
                    // But dropping is only right while the failure is *about the
                    // chapter*. When it is not — a Cloudflare clearance that did not
                    // take, a host that has started refusing us, a web view that has
                    // stopped navigating — every chapter fails, and dropping each one
                    // in turn walks the queue to nothing and reports it as a finished
                    // download. That is what "I cleared the verification, pressed
                    // resume, and my download queue vanished" is: the queue was not
                    // lost, it was eaten, one failing chapter at a time.
                    //
                    // So a streak stops the run instead, with the queue intact and the
                    // reason on screen. The chapter that hit the limit keeps its place
                    // at the head — it was never given a fair attempt.
                    if self.noteChapterFailed() {
                        self.lastError = String(
                            localized: "downloads.paused.repeatedFailures \(error.localizedDescription)"
                        )
                        self.status = .paused
                        self.persistQueue()
                        return
                    }
                    self.lastError = error.localizedDescription
                    guard self.completeIfStillQueued(chapter) else { return }
                }
                // Checked after both outcomes: a chapter that failed is still a
                // chapter this run is done with.
                if self.haltIfDraining() { return }
                if self.remaining.isEmpty { break }
                await self.pacer.pace()
            }
            if !Task.isCancelled && self.remaining.isEmpty {
                self.finish()
            }
        }
    }

    /// A completed run leaves nothing behind.
    ///
    /// Keeping the last `progress` around left a full bar and a "cancel" button
    /// sitting on the book screen after the download had finished — and it stayed
    /// there through deleting the downloads, offering to cancel a run that had
    /// been over for minutes. The chapter list already shows what is on disk;
    /// the progress row exists only while there is progress.
    private func finish() {
        status = .finished
        progress = nil
        pacer.reset()
        persistQueue()
    }

    /// Brings a draining queue to rest. Returns true when the caller must stop.
    ///
    /// A drain that happens to empty the queue is a finished download, not a
    /// paused one — there is nothing left to resume, and leaving a paused row on
    /// the book screen would offer to continue a download that is over.
    private func haltIfDraining() -> Bool {
        guard isDraining else { return false }
        task = nil
        if remaining.isEmpty {
            finish()
        } else {
            status = .paused
            lastError = drainReason
            pacer.reset()
            persistQueue()
        }
        clearDrain()
        return true
    }

    /// Mirrors the queue to disk, or removes the file when there is no queue left
    /// to mirror.
    ///
    /// Called where the queue gains work and at every point it comes to rest —
    /// never per chapter; see the type comment for why that is enough. An
    /// 800-chapter queue is a few kilobytes of short strings, so doing it on the
    /// main actor costs less than the layout pass that follows the status change.
    private func persistQueue() {
        guard let context, !remaining.isEmpty else {
            queueStore.clear()
            return
        }
        queueStore.save(bookId: context.book.id, siteChapterIds: remaining.map(\.siteChapterId))
    }

    private func clearDrain() {
        isDraining = false
        drainReason = nil
        notifyStopped()
    }

    private func notifyStopped() {
        guard let onStopped else { return }
        self.onStopped = nil
        onStopped()
    }

    /// A chapter landed, so whatever was going wrong is no longer going wrong.
    ///
    /// Not private, like `noteChapterFailed` and for the same reason: the two together
    /// are the rule, and half a rule is not something a test can pin.
    func noteChapterSucceeded() {
        failureStreak = 0
    }

    /// Records a chapter this run could not fetch.
    ///
    /// - Returns: true when the caller must stop the run and leave the queue alone,
    ///   because the failures have stopped being about individual chapters.
    ///
    /// Not private: what matters is what this answers on the *third* call in a row, and
    /// there is no way to reach that through the public surface without three real
    /// fetches against a real host — which is to say, no way to pin the behaviour that
    /// keeps a download queue from eating itself.
    func noteChapterFailed() -> Bool {
        failureStreak += 1
        return failureStreak >= Self.failureLimit
    }

    /// Takes `chapter` off the head of the queue. Returns false when it is no
    /// longer there, and the caller must then stop.
    ///
    /// A fetch takes seconds, and `cancel()` empties the queue the moment the
    /// user taps — so by the time a fetch returns, the chapter it was for may be
    /// gone. The unguarded `removeFirst()` this replaces trapped on the empty
    /// array and took the whole app down, which is what "download all, then
    /// cancel" did every time.
    func completeIfStillQueued(_ chapter: Chapter) -> Bool {
        guard remaining.first?.id == chapter.id else { return false }
        remaining.removeFirst()
        progress?.completed += 1
        return true
    }
}
