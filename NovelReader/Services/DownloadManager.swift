import Foundation

/// Downloads chapters in the background, one at a time, politely.
///
/// Four constraints shape this:
/// 1. The fetcher owns a single WKWebView, so concurrency is impossible anyway.
/// 2. These hosts sit behind Cloudflare. Hammering a challenged host is exactly
///    what gets an IP blocked, so fetches go through the shared `RequestPacer`
///    and a challenged host is *stepped away from* rather than retried.
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
///
/// Several books queue in the order they were asked for, each with a state of its own,
/// and the queue works on the first one that is free to go. A book the reader paused,
/// or one stuck behind a wall, keeps its place and is stepped over: one book that
/// cannot move must not hold up every book behind it. Still one book at a time, for
/// constraint 1 — a second book does not make the single web view any faster.
///
/// Walls follow from the same web view. The verification sheet hands it to the reader,
/// so while the sheet is up nothing else can be fetched; it is therefore put up only
/// once nothing else in the queue can go. Until then, every book on the challenged
/// host waits — the next one would only meet the same wall — and the rest carry on.
@MainActor
@Observable
final class DownloadManager {
    enum Status: Equatable {
        case idle
        case running
        /// Nothing being fetched, with books still queued: stopped from outside, or
        /// every book left is held.
        case paused
        case finished
    }

    /// One book's share of the queue.
    struct Job: Identifiable {
        enum Hold: Equatable {
            /// Waits for a tap: the reader paused it, or the queue gave up on it for now.
            case paused
            /// Waits for the verification sheet, which comes once nothing else can go.
            case wall
        }

        var book: Book
        var rule: SiteRule
        /// Not yet fetched, in order.
        var remaining: [Chapter]
        var completed = 0
        var total: Int
        var hold: Hold?
        /// What the reader needs to know about this book: pages a chapter came down
        /// without, the wall it is waiting on, why the queue gave up on it.
        var note: String?
        /// Set when the reader closed a verification sheet for this book's host. A
        /// wall again straight after means the check did not take.
        var retryingWall = false

        var id: String { book.id }
        var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }

        init(book: Book, rule: SiteRule, chapters: [Chapter], hold: Hold? = nil) {
            self.book = book
            self.rule = rule
            remaining = chapters
            total = chapters.count
            self.hold = hold
        }
    }

    private(set) var status: Status = .idle
    /// Every queued book, in the order they were asked for. A finished book leaves.
    private(set) var jobs: [Job] = []
    /// The book the run is on.
    private(set) var activeBookId: String?
    /// Why the whole queue stopped, when something other than a book stopped it — the
    /// app leaving the screen, a metered connection. A book's own reasons are its `note`.
    private(set) var lastError: String?
    /// Counts chapters as they come off the queue, for screens that redraw their
    /// chapter list when one lands.
    private(set) var landed = 0
    /// Set when a host escalated to an interactive challenge, or turned a
    /// signed-out reader away. The root view presents the fetcher's web view so
    /// the user can deal with it.
    ///
    /// The whole request rather than its URL, because the two cases need different
    /// words on the sheet and only the moment they are caught knows which one this
    /// is — by the time the root view sees it, an address is just an address.
    var pendingChallenge: ChallengeRequest?
    /// The wall held books are waiting on, kept back until nothing else can go.
    private var wall: ChallengeRequest?

    private let service: BookService
    private let downloads: DownloadStore
    /// How a comic chapter's pages come down. The addresses still come out of the web
    /// view like everything else; only the bytes take the other road.
    private let images: ImageFetcher
    /// Shared with the reader's read-ahead, so the two together still look like
    /// one person turning pages rather than two processes taking turns.
    private let pacer: RequestPacer
    private let queueStore: DownloadQueueStore
    /// The diagnostics trace.
    ///
    /// Held because downloading is the one thing this app does that nobody is watching:
    /// it runs with the phone in a pocket, and once the moment has passed there is no
    /// other way to answer whether a queue started, what stopped it, or how much of it
    /// was left.
    private let trace: TraceLog
    private var task: Task<Void, Never>?

    /// Chapters that have failed since the last one that landed.
    ///
    /// Reset by every success, every fresh `run` and every change of book, so it counts
    /// a *streak* rather than a total: three bad chapters spread through an 800-chapter
    /// book is a site with three bad chapters, and the queue is right to walk past them.
    private var failureStreak = 0
    /// Set while the queue is meant to stop after the chapter on the wire.
    private(set) var isDraining = false
    private var drainReason: String?
    /// The background assertion being held open until the queue comes to rest.
    private var onStopped: (() -> Void)?
    /// Which run the queue is on.
    ///
    /// A cancelled run still executes: the task body is scheduled, runs once, and
    /// reaches its `defer`. Without this it would release a hold taken out by the
    /// run that *replaced* it — ending the background assertion of a drain asked of
    /// the new run before that run had fetched anything.
    private var runToken = 0
    /// Chapters left before the run takes a longer rest. See `restIsDue`.
    private var chaptersUntilRest = 0

    init(
        service: BookService,
        downloads: DownloadStore,
        images: ImageFetcher,
        pacer: RequestPacer,
        queueStore: DownloadQueueStore,
        trace: TraceLog = .makeShared()
    ) {
        self.service = service
        self.downloads = downloads
        self.images = images
        self.pacer = pacer
        self.queueStore = queueStore
        self.trace = trace
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
    /// Whether the queue is stopped with a book free to go — what a resume would start.
    var canResume: Bool { status == .paused && jobs.contains { $0.hold == nil } }
    /// How many chapters the queue still owes, every book's.
    var remainingCount: Int { jobs.reduce(0) { $0 + $1.remaining.count } }

    /// The book at the front: the one being fetched, or the first in line.
    var current: Job? { activeJob ?? jobs.first }

    func job(for bookId: String) -> Job? {
        jobs.first { $0.id == bookId }
    }

    private var activeIndex: Int? { activeBookId.flatMap(index(of:)) }
    private var activeJob: Job? { activeIndex.map { jobs[$0] } }

    private func index(of bookId: String) -> Int? {
        jobs.firstIndex { $0.id == bookId }
    }

    // MARK: - Control

    /// Queues every chapter that is not already on disk, and sets the queue going.
    ///
    /// Behind whatever is already queued, never in place of it: a paused book is
    /// still the reader's download. Asking again for a book already queued adds the
    /// new chapters to its share and lifts whatever held it — the tap is the reader
    /// asking for this book now.
    func start(book: Book, rule: SiteRule, chapters: [Chapter]) {
        let pending = chapters.filter { !$0.isDownloaded }
        // Both numbers, because "nothing happened" has two different causes here and the
        // reader reports them identically: a tap that queued nothing because every chapter
        // was already on disk, and a tap that queued work which then stopped somewhere.
        trace.note("dl start n=\(pending.count) of=\(chapters.count) books=\(jobs.count)")
        if let i = index(of: book.id) {
            if book.id == activeBookId, status == .running {
                // Appended only: the head is the chapter on the wire, and taking it
                // out from under its fetch would end the run without a word.
                let before = jobs[i].remaining.count
                jobs[i].remaining = Self.merge(pending, into: jobs[i].remaining)
                jobs[i].total += jobs[i].remaining.count - before
            } else {
                // Against the catalog it was tapped with, so chapters that have landed
                // since drop out, and a book with nothing left leaves the queue.
                let landedIds = Set(chapters.filter(\.isDownloaded).map(\.id))
                jobs[i].remaining = Self.merge(
                    pending, into: jobs[i].remaining.filter { !landedIds.contains($0.id) }
                )
                jobs[i].total = jobs[i].completed + jobs[i].remaining.count
                jobs[i].hold = nil
                jobs[i].note = nil
                jobs[i].retryingWall = false
                if jobs[i].remaining.isEmpty { jobs.remove(at: i) }
            }
        } else if !pending.isEmpty {
            jobs.append(Job(book: book, rule: rule, chapters: pending))
        }
        if status == .running {
            persistQueue()
        } else {
            lastError = nil
            run()
        }
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
    func restore(_ restored: [Job]) {
        guard status == .idle, jobs.isEmpty else { return }
        jobs = restored.filter { !$0.remaining.isEmpty }
        guard !jobs.isEmpty else { return }
        status = .paused
        // Not written back. What is on disk is already a superset of this — the
        // restore only ever drops entries — and the next time the queue comes to
        // rest it writes the pruned version anyway.
    }

    /// Stops the whole queue, every book keeping its place and its chapters.
    ///
    /// - Parameter reason: shown where download failures are shown. Set when
    ///   something other than the user stopped the queue — a switch to cellular
    ///   under a Wi-Fi-only policy — because a queue that stops by itself with no
    ///   explanation reads as a bug.
    func pause(reason: String? = nil) {
        // `auto` separates the two callers that matter: a reason means something other
        // than the user stopped this — backgrounding, a metered connection, a window
        // expiring — which is the case nobody can see happen.
        trace.note("dl pause left=\(remainingCount) auto=\(reason == nil ? 0 : 1)")
        task?.cancel()
        task = nil
        activeBookId = nil
        if !jobs.isEmpty { status = .paused }
        if let reason { lastError = reason }
        clearDrain()
        persistQueue()
    }

    /// Holds one book where it is; the books behind it go first.
    func pause(bookId: String) {
        guard let i = index(of: bookId) else { return }
        trace.note("dl pause book left=\(jobs[i].remaining.count)")
        jobs[i].hold = .paused
        jobs[i].note = nil
        if bookId == activeBookId, status == .running {
            stopRun()
            run()
        } else {
            persistQueue()
        }
    }

    /// Lets a held book go again, at its own place in the queue. Sets the queue
    /// going if it was stopped, because that is what the tap is for.
    func resume(bookId: String) {
        guard let i = index(of: bookId) else { return }
        trace.note("dl resume book left=\(jobs[i].remaining.count)")
        jobs[i].hold = nil
        jobs[i].note = nil
        jobs[i].retryingWall = false
        if status == .running {
            persistQueue()
        } else {
            lastError = nil
            run()
        }
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
        trace.note("dl drain running=\(status == .running ? 1 : 0) left=\(remainingCount)")
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

    /// Sets a stopped queue going again, at the first book free to go.
    func resume() {
        // Before the guard: a resume that refuses is exactly the shape of "I pressed it
        // and nothing happened", and after the guard it would leave no line at all.
        trace.note("dl resume can=\(canResume ? 1 : 0) left=\(remainingCount)")
        guard canResume else { return }
        lastError = nil
        run()
    }

    /// The reader closed the verification sheet: the books it held go again, the
    /// one that hit the wall first.
    ///
    /// Closing the sheet is the user saying the challenge is dealt with. Dismissed
    /// without solving, the retry meets the wall again — and that second wall is the
    /// queue's cue to give up on the host for now rather than put the sheet straight
    /// back. See `hitWall`.
    func retryAfterWall() {
        trace.note("dl wall retry")
        pendingChallenge = nil
        wall = nil
        for i in jobs.indices where jobs[i].hold == .wall {
            jobs[i].hold = nil
            jobs[i].note = nil
            jobs[i].retryingWall = true
        }
        if status == .running {
            persistQueue()
        } else {
            lastError = nil
            run()
        }
    }

    /// Empties the whole queue, every book in it.
    func cancel() {
        // Only when there was something to lose. A line per call would put a "cancel"
        // in every test teardown and every launch with nothing queued.
        if remainingCount > 0 { trace.note("dl cancel left=\(remainingCount)") }
        stopRun()
        jobs = []
        pendingChallenge = nil
        wall = nil
        status = .idle
        pacer.reset()
        clearDrain()
        persistQueue()
    }

    /// Takes one book out of the queue. When it was the one downloading, the next
    /// book free to go carries on in its place.
    func cancel(bookId: String) {
        guard let i = index(of: bookId) else { return }
        trace.note("dl cancel book left=\(jobs[i].remaining.count)")
        jobs.remove(at: i)
        if !jobs.contains(where: { $0.hold == .wall }) { wall = nil }
        if bookId == activeBookId, status == .running {
            stopRun()
            run()
        } else if jobs.isEmpty {
            stopRun()
            status = .idle
            persistQueue()
        } else {
            persistQueue()
        }
    }

    private func stopRun() {
        task?.cancel()
        task = nil
        activeBookId = nil
    }

    /// `extra`'s chapters appended to `queued`, minus any already there.
    private static func merge(_ extra: [Chapter], into queued: [Chapter]) -> [Chapter] {
        let ids = Set(queued.map(\.id))
        return queued + extra.filter { !ids.contains($0.id) }
    }

    // MARK: - Queue

    private func run() {
        // A drain request belongs to the run it was made for. Carried into the
        // next one it would stop that run after a single chapter, with nothing
        // on screen to explain why.
        clearDrain()
        // So does a failure streak. Resuming is the user saying they have dealt with
        // whatever stopped the queue — cleared a challenge, changed network — and the
        // new run has to be allowed to find that out for itself.
        failureStreak = 0
        chaptersUntilRest = Self.sampleRestBlock()
        // Not while the sheet is up: it has the web view, and a fetch would navigate
        // it out from under the reader. Closing the sheet runs the queue again.
        guard pendingChallenge == nil, pickNext() else {
            settle()
            return
        }
        status = .running
        persistQueue()
        runToken += 1
        let token = runToken
        task = Task { [weak self] in
            guard let self else { return }
            // Released on every exit — normal end, cancellation, every book held,
            // drain. A background assertion held past the point where the queue
            // stopped is time iOS took from the user for nothing. Only for this
            // run, though: see `runToken`.
            defer { if self.runToken == token { self.notifyStopped() } }
            // The book read afresh each chapter: it changes under this loop when one
            // finishes, is paused, or hits a wall.
            while !Task.isCancelled, let job = self.activeJob, let chapter = job.remaining.first {
                do {
                    let missing = try await self.download(chapter, of: job.book, from: job.rule)
                    self.noteChapterSucceeded()
                    guard self.completeIfStillQueued(chapter) else { return }
                    self.wallCleared(on: job.rule.host)
                    // Said out loud, because this is the one thing a chapter on the
                    // device can now be that it could not be before: there, readable,
                    // and short a page. Silence would make the gap a surprise found
                    // offline, which is the whole reason the all-or-nothing rule was
                    // there in the first place.
                    if missing > 0 {
                        self.setNote(
                            String(localized: "downloads.chapter.missingPages \(chapter.title) \(missing)"),
                            on: job.id
                        )
                    }
                    // After the removal, so the count is what is genuinely left. One line
                    // per chapter is the rate of the queue itself — paced, seconds apart —
                    // not a hot loop, and it is the only record of how far a window got.
                    self.trace.note("dl ok left=\(self.remainingCount) missing=\(missing)")
                } catch is CancellationError {
                    return
                } catch WebFetcher.FetchError.challengePresented(let url) {
                    // The chapter stays at the head of its book, so the retry after
                    // the sheet is the chapter that hit the wall.
                    self.hitWall(
                        ChallengeRequest(url: url, doing: .download(job.book.shownName)),
                        because: WebFetcher.FetchError.challengePresented(url)
                    )
                } catch WebFetcher.FetchError.signInRequired(let url) {
                    // The same hold for the same reason: nothing the queue can do by
                    // itself will get this host's next chapter, and grinding through
                    // the rest of the book collecting identical failures would only
                    // bury the one message that matters.
                    self.hitWall(
                        ChallengeRequest(
                            url: url, reason: .signIn, doing: .download(job.book.shownName)
                        ),
                        because: WebFetcher.FetchError.signInRequired(url)
                    )
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
                    // So a streak holds the book instead, with its chapters intact and
                    // the reason on its row, and the books behind it carry on. The
                    // chapter that hit the limit keeps its place at the head — it was
                    // never given a fair attempt.
                    if self.noteChapterFailed() {
                        self.trace.note("dl streak left=\(job.remaining.count)")
                        self.holdActive(
                            note: String(
                                localized: "downloads.paused.repeatedFailures \(error.localizedDescription)"
                            )
                        )
                    } else {
                        guard self.completeIfStillQueued(chapter) else { return }
                        self.setNote(error.localizedDescription, on: job.id)
                        self.trace.note("dl fail left=\(self.remainingCount)")
                    }
                }
                // Checked after every outcome: a chapter that failed is still a
                // chapter this run is done with.
                if self.haltIfDraining() { return }
                // The next book in the same loop rather than through `run()`, which
                // would clear the run's drain and failure state at every hand-over.
                guard self.pickNext() else { break }
                await self.pacer.pace(host: self.activeJob?.rule.host ?? job.rule.host)
                if self.restIsDue() {
                    try? await Task.sleep(for: .seconds(Double.random(in: 15...45)))
                    // A drain asked for during the rest must not wait through one
                    // more fetch: backgrounding grants seconds, and the rest may
                    // already have spent most of them.
                    if self.haltIfDraining() { return }
                }
            }
            if !Task.isCancelled { self.settle() }
        }
    }

    /// Settles which book the run is on: the current one while it has work and
    /// nothing holds it, otherwise the first book free to go. Returns false when no
    /// book is.
    private func pickNext() -> Bool {
        if let i = activeIndex, jobs[i].remaining.isEmpty {
            jobs.remove(at: i)
            activeBookId = nil
        }
        if let job = activeJob, job.hold == nil { return true }
        guard let next = jobs.first(where: { $0.hold == nil }) else {
            activeBookId = nil
            return false
        }
        activeBookId = next.id
        // A streak of the last book's failures says nothing about this one.
        failureStreak = 0
        // Another book means another page in the web view, so the one that put up the
        // wall will not be there by the time the sheet is.
        wall?.reload = true
        trace.note("dl next n=\(next.remaining.count) books=\(jobs.count)")
        persistQueue()
        return true
    }

    /// Holds every book on the host that put up a wall, and keeps the wall for later.
    ///
    /// Every book on the host, not just this one: the next would only meet the same
    /// wall, and each attempt is one more request at a host already suspicious of us.
    ///
    /// A wall straight after the reader closed the sheet means the check did not
    /// take — dismissed unsolved, or a clearance the host would not honour. Putting the
    /// sheet straight back would make the reader fight the same wall again before any
    /// other book could move, so the host's books are paused with the reason instead,
    /// and a tap on resume tries them again.
    private func hitWall(_ request: ChallengeRequest, because error: WebFetcher.FetchError) {
        guard let job = activeJob else { return }
        let host = job.rule.host
        let gaveUp = job.retryingWall
        // The wall's kind, not its address: a queue parked on a sign-in and one parked on
        // a verification look the same from outside and need opposite things from the user.
        trace.note(
            "dl held signIn=\(request.reason == .signIn ? 1 : 0) gaveUp=\(gaveUp ? 1 : 0) "
                + "left=\(job.remaining.count)"
        )
        for i in jobs.indices where jobs[i].rule.host == host && jobs[i].hold != .paused {
            if gaveUp {
                jobs[i].hold = .paused
                jobs[i].note = String(localized: "downloads.wall.gaveUp")
                jobs[i].retryingWall = false
            } else {
                jobs[i].hold = .wall
                jobs[i].note = error.localizedDescription
            }
        }
        if !gaveUp { wall = request }
        persistQueue()
    }

    /// A chapter from `host` landed, so whatever check its books were retrying after
    /// has taken.
    private func wallCleared(on host: String) {
        for i in jobs.indices where jobs[i].rule.host == host && jobs[i].retryingWall {
            jobs[i].retryingWall = false
        }
    }

    private func holdActive(note: String) {
        guard let i = activeIndex else { return }
        jobs[i].hold = .paused
        jobs[i].note = note
        persistQueue()
    }

    private func setNote(_ note: String, on bookId: String) {
        guard let i = index(of: bookId) else { return }
        jobs[i].note = note
    }

    /// Brings the queue to rest: finished when no book is left, paused otherwise.
    ///
    /// This is also where a kept-back wall is finally put to the reader — once no
    /// book is free to go, the sheet can have the web view without taking it from
    /// anything.
    private func settle(reason: String? = nil) {
        task = nil
        activeBookId = nil
        pacer.reset()
        guard !jobs.isEmpty else {
            finish()
            return
        }
        status = .paused
        if let reason { lastError = reason }
        if pendingChallenge == nil, let wall,
           !jobs.contains(where: { $0.hold == nil }),
           jobs.contains(where: { $0.hold == .wall }) {
            pendingChallenge = wall
        }
        trace.note("dl rest books=\(jobs.count) held=\(jobs.filter { $0.hold != nil }.count)")
        persistQueue()
    }

    /// Fetches one chapter and puts it on the device.
    ///
    /// The only thing about downloading that a comic changes. Everything around this —
    /// the queue, pausing, stopping dead on a challenge, the failure streak, the rest
    /// blocks, the background drain — is about chapters rather than about what is in
    /// them, and none of it needed to know.
    ///
    /// Both paths end in a store call that writes the files first and sets
    /// `downloadedAt` second, so the flag never claims a chapter that is not there.
    ///
    /// - Returns: how many of the chapter's pages the site would not give up. Always
    ///   zero for a novel, which has no unit smaller than the chapter to lose.
    private func download(_ chapter: Chapter, of book: Book, from rule: SiteRule) async throws -> Int {
        switch book.kind {
        case .novel:
            let paragraphs = try await service.chapterParagraphs(rule: rule, chapter: chapter)
            try downloads.save(
                paragraphs: paragraphs, book: book, siteChapterId: chapter.siteChapterId
            )
            return 0
        case .comic:
            guard let page = URL(string: chapter.url) else { throw BookService.ServiceError.badURL }
            // The addresses first, through the web view, because only a real engine
            // runs the packed scripts these lists hide in — and that read is what a
            // challenge or a sign-in wall interrupts, which is why it stays on the same
            // path the novels take and reaches the same `catch` above.
            let urls = try await service.chapterImageURLs(rule: rule, chapter: chapter)
            let bytes = try await images.chapterImages(
                at: urls, chapterPage: page, cookies: await ImageFetcher.siteCookies()
            )
            try downloads.save(pages: bytes, book: book, siteChapterId: chapter.siteChapterId)
            return bytes.lazy.filter { $0 == nil }.count
        case .feed:
            // A subscription has nothing to download: an article is written to the device
            // by the refresh that discovered it, so every one of them is already here.
            // No screen offers this, which is why it throws rather than quietly
            // succeeding — a queue that reported progress against a book it never wrote
            // a byte for would be a download the reader cannot tell from a real one.
            throw QueueError.nothingToDownload
        }
    }

    enum QueueError: LocalizedError {
        case nothingToDownload

        var errorDescription: String? {
            switch self {
            case .nothingToDownload: return String(localized: "downloads.error.feed")
            }
        }
    }

    /// A completed run leaves nothing behind.
    ///
    /// Keeping the last book around left a full bar and a "cancel" button sitting
    /// on the book screen after the download had finished — and it stayed there
    /// through deleting the downloads, offering to cancel a run that had been over
    /// for minutes. The chapter list already shows what is on disk; the progress
    /// row exists only while there is progress.
    private func finish() {
        trace.note("dl done")
        status = .finished
        activeBookId = nil
        wall = nil
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
        // The count here is the queue the app will come back to.
        trace.note("dl drained left=\(remainingCount)")
        if let i = activeIndex, jobs[i].remaining.isEmpty { jobs.remove(at: i) }
        settle(reason: drainReason)
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
    ///
    /// Only the reader's own pause is written down. A wall or a failure streak is a
    /// judgement about this moment, and the next launch deserves a fresh attempt.
    private func persistQueue() {
        let books = jobs.filter { !$0.remaining.isEmpty }.map {
            PersistedDownloadQueue.Entry(
                bookId: $0.id, siteChapterIds: $0.remaining.map(\.siteChapterId),
                paused: $0.hold == .paused && $0.note == nil
            )
        }
        if books.isEmpty { queueStore.clear() } else { queueStore.save(books) }
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

    /// Whether the run has earned its longer pause, counting down the block and
    /// sampling the next one when it has.
    ///
    /// The pacer's one-to-three-second gaps keep requests from *bursting*, but a
    /// run still asks for pages far faster than anyone reads them, and the hosts'
    /// WAF answers that with a verification wall at around the twenty-chapter
    /// mark. So the run breathes: a dozen-odd chapters, then long enough away for
    /// the sustained rate to stop looking like a crawler. Both numbers are drawn
    /// fresh each time because a rest every Nth chapter on the dot is itself a
    /// fingerprint. The threshold sits under the cadence the wall was observed
    /// at; whether that is enough slack is empirical, and this is the first lever
    /// to adjust if the wall still comes.
    private func restIsDue() -> Bool {
        chaptersUntilRest -= 1
        guard chaptersUntilRest <= 0 else { return false }
        chaptersUntilRest = Self.sampleRestBlock()
        return true
    }

    private static func sampleRestBlock() -> Int {
        Int.random(in: 10...15)
    }

    /// Takes `chapter` off the head of the book being fetched. Returns false when it
    /// is no longer there, and the caller must then stop.
    ///
    /// A fetch takes seconds, and `cancel()` empties the queue the moment the
    /// user taps — so by the time a fetch returns, the chapter it was for may be
    /// gone. The unguarded `removeFirst()` this replaces trapped on the empty
    /// array and took the whole app down, which is what "download all, then
    /// cancel" did every time.
    func completeIfStillQueued(_ chapter: Chapter) -> Bool {
        guard let i = activeIndex, jobs[i].remaining.first?.id == chapter.id else { return false }
        jobs[i].remaining.removeFirst()
        jobs[i].completed += 1
        landed += 1
        return true
    }
}
