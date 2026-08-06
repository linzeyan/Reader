import Foundation

/// Downloads chapters in the background, one at a time, politely.
///
/// Three constraints shape this:
/// 1. The fetcher owns a single WKWebView, so concurrency is impossible anyway.
/// 2. These hosts sit behind Cloudflare. Hammering a challenged host is exactly
///    what gets an IP blocked, so fetches go through the shared `RequestPacer`
///    and the queue *stops* on a challenge rather than retrying.
/// 3. A paused queue must keep its remaining work, because the user resolving a
///    challenge and tapping resume is the normal path, not an error path.
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
    private var task: Task<Void, Never>?

    /// Work not yet done. Survives a pause so `resume()` picks up where it left off.
    private var remaining: [Chapter] = []
    private var context: (book: Book, rule: SiteRule)?

    init(service: BookService, downloads: DownloadStore, pacer: RequestPacer) {
        self.service = service
        self.downloads = downloads
        self.pacer = pacer
    }

    var isBusy: Bool { status == .running }
    var canResume: Bool { status == .paused && !remaining.isEmpty }

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
        run()
    }

    func pause() {
        task?.cancel()
        task = nil
        if !remaining.isEmpty { status = .paused }
    }

    func resume() {
        guard canResume else { return }
        pendingChallenge = nil
        lastError = nil
        run()
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
    }

    // MARK: - Queue

    private func run() {
        guard let context else { return }
        status = .running
        task = Task { [weak self] in
            guard let self else { return }
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
                    guard self.completeIfStillQueued(chapter) else { return }
                } catch is CancellationError {
                    return
                } catch WebFetcher.FetchError.challengePresented(let url) {
                    // Stop dead. The chapter stays at the head of the queue, so
                    // resuming after the user clears the challenge retries it.
                    self.pendingChallenge = url
                    self.lastError = WebFetcher.FetchError.challengePresented(url).localizedDescription
                    self.status = .paused
                    return
                } catch {
                    // A single unreadable chapter must not strand the rest of the
                    // book, so it is dropped from the queue and reported.
                    self.lastError = error.localizedDescription
                    guard self.completeIfStillQueued(chapter) else { return }
                }
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
