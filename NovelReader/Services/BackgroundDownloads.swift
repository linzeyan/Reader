import BackgroundTasks
import Foundation

/// What one background download window achieved.
///
/// Persisted and shown in settings because this path is otherwise completely
/// unobservable: it runs when nobody is looking, and its one plausible fatal
/// flaw — iOS suspending the web content process, so a navigation never comes
/// back — looks exactly like "nothing happened". Recorded outcomes tell those
/// apart. `expired` with zero chapters *is* that flaw; `expired` with ten is the
/// feature working and simply running out of window.
struct BackgroundDownloadRun: Codable, Equatable {
    enum Outcome: String, Codable {
        /// The queue emptied inside the window.
        case completed
        /// iOS took the time back before the queue was done.
        case expired
        /// The queue came to rest early — a challenge, or chapters that will not
        /// parse. Needs a human, so no further window is asked for.
        case stalled
        /// Wi-Fi-only policy on a metered connection. Nothing was fetched.
        case blockedByPolicy
        /// Woken with nothing left to do, because the download had already been
        /// finished in the foreground.
        case nothingToDo
        /// Woken after iOS had terminated the app. The paused queue lived in that
        /// process and did not outlive it.
        case queueLost
    }

    var startedAt: Date
    var connection: NetworkMonitor.Connection
    var chapters: Int
    var outcome: Outcome
}

/// The slice of `BGTaskScheduler` this app uses.
///
/// Behind a protocol so the decisions around it can be tested: the real
/// scheduler never launches a task in a simulator, and the unit suite runs
/// inside the app process, which has already registered the identifier once.
protocol BackgroundTaskScheduling {
    /// Asks for one processing window. Replaces any request already queued under
    /// the same identifier.
    func submitProcessingRequest(identifier: String) throws
    func cancel(identifier: String)
}

struct SystemBackgroundTaskScheduler: BackgroundTaskScheduling {
    func submitProcessingRequest(identifier: String) throws {
        let request = BGProcessingTaskRequest(identifier: identifier)
        // A download is nothing but network, so a window without one is a wasted
        // wake-up — and wasted wake-ups are how an app earns fewer of them.
        request.requiresNetworkConnectivity = true
        // Not gated on charging: the case this feature exists for is a phone in
        // a pocket, and requiring power would mean it almost never ran.
        request.requiresExternalPower = false
        try BGTaskScheduler.shared.submit(request)
    }

    func cancel(identifier: String) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
}

/// The task iOS hands over, seen from the app's side.
///
/// `BGTask` cannot be constructed, so without this seam the entire background
/// path — including the expiration branch, which is the one most likely to be
/// wrong — would be untestable.
protocol BackgroundTaskHandle: AnyObject {
    var expirationHandler: (() -> Void)? { get set }
    func setTaskCompleted(success: Bool)
}

extension BGTask: BackgroundTaskHandle {}

/// Continues a paused chapter download while the app is not on screen.
///
/// Deliberately narrow: it resumes the queue `AppEnvironment.enterBackground`
/// paused, and does not reconstruct one. The fetching is done by the single
/// WKWebView in `WebFetcher`, which is warm and already past whatever challenge
/// the host set — a queue rebuilt in a freshly launched process would have to
/// clear that challenge again with nobody there to help. So a window that
/// arrives after iOS terminated the app records `queueLost` instead of guessing.
@MainActor
@Observable
final class BackgroundDownloads {
    /// Must match `BGTaskSchedulerPermittedIdentifiers` in Info.plist. A mismatch
    /// traps at registration, on launch, every time — which is the failure mode
    /// to want for a string that has to agree in two places.
    static let identifier = "com.zeyanlin.novelreader.downloads"

    private(set) var lastRun: BackgroundDownloadRun?
    /// Why the last request for a window was refused. Surfaced because the usual
    /// reason is Background App Refresh being switched off for the app, which is
    /// the whole explanation for "it never runs" and is not something the app can
    /// work around.
    private(set) var lastScheduleError: String?

    private let downloader: DownloadManager
    private let settings: DownloadSettings
    /// A closure rather than the monitor, so a test can pin the connection: the
    /// rule being protected here is about a connection type, and reading the real
    /// one would make the test say whatever the simulator's host is on.
    private let connection: @MainActor () -> NetworkMonitor.Connection
    private let scheduler: any BackgroundTaskScheduling
    private let defaults: UserDefaults

    /// The window in flight. Held because two paths end one — the queue coming to
    /// rest and iOS taking the time back — and `setTaskCompleted` raises the
    /// second time it is called.
    private var attempt: Attempt?

    private struct Attempt {
        let task: any BackgroundTaskHandle
        let startedAt: Date
        let connection: NetworkMonitor.Connection
        let remainingBefore: Int
    }

    private enum Keys {
        static let lastRun = "downloads.background.lastRun"
        static let scheduleError = "downloads.background.scheduleError"
    }

    init(
        downloader: DownloadManager,
        settings: DownloadSettings,
        connection: @escaping @MainActor () -> NetworkMonitor.Connection,
        scheduler: any BackgroundTaskScheduling = SystemBackgroundTaskScheduler(),
        defaults: UserDefaults = .standard
    ) {
        self.downloader = downloader
        self.settings = settings
        self.connection = connection
        self.scheduler = scheduler
        self.defaults = defaults
        lastRun = Self.loadRun(from: defaults)
        lastScheduleError = defaults.string(forKey: Keys.scheduleError)
    }

    // MARK: - Asking for a window

    /// Asks iOS for a window when, and only when, there is a queue that a window
    /// could actually finish.
    ///
    /// Both refusals matter. A schedule left behind for an empty queue wakes the
    /// app to do nothing, and iOS answers repeated pointless wake-ups by granting
    /// fewer of them. A queue stopped by a challenge cannot be finished without
    /// the user, so a window spent on it would fail identically and cost the same
    /// budget.
    func scheduleIfNeeded() {
        guard downloader.canResume, downloader.pendingChallenge == nil else {
            scheduler.cancel(identifier: Self.identifier)
            store(scheduleError: nil)
            return
        }
        do {
            try scheduler.submitProcessingRequest(identifier: Self.identifier)
            store(scheduleError: nil)
        } catch {
            store(scheduleError: error.localizedDescription)
        }
    }

    // MARK: - Using one

    /// Runs the queue for as long as iOS allows.
    func run(task: any BackgroundTaskHandle) {
        let startedAt = Date()
        let connection = connection()

        guard downloader.canResume else {
            complete(
                task,
                run: BackgroundDownloadRun(
                    startedAt: startedAt, connection: connection,
                    chapters: 0, outcome: .nothingToDo
                )
            )
            return
        }
        // A background task cannot ask a question, because nobody is there to
        // answer it. So under the Wi-Fi-only policy a metered connection means
        // "not now" rather than "prompt": quietly spending a data plan while the
        // phone is in a pocket is the one failure this feature must not have, and
        // the cost of waiting for another window is nothing.
        guard settings.network.allowsUnattendedDownload(on: connection) else {
            complete(
                task,
                run: BackgroundDownloadRun(
                    startedAt: startedAt, connection: connection,
                    chapters: 0, outcome: .blockedByPolicy
                )
            )
            return
        }

        attempt = Attempt(
            task: task, startedAt: startedAt, connection: connection,
            remainingBefore: downloader.remainingCount
        )
        task.expirationHandler = { [weak self] in
            // iOS calls this on its own queue, and everything it has to touch —
            // the queue, the fetcher's web view — lives on the main actor.
            Task { @MainActor in self?.expire() }
        }
        // Through the ordinary resume, at the ordinary pace. A background window
        // is not a licence to hit a Cloudflare-fronted host harder than a user
        // turning pages would.
        downloader.resume { [weak self] in self?.settle() }
    }

    /// The queue came to rest by itself. Whether that means "done" or "stuck" is
    /// the difference between not needing another window and not being able to
    /// use one.
    private func settle() {
        guard let attempt = take() else { return }
        complete(
            attempt.task,
            run: result(of: attempt, outcome: downloader.remainingCount == 0 ? .completed : .stalled)
        )
    }

    /// iOS wants the time back, with seconds of notice.
    private func expire() {
        // Taken out first: the pause below releases the queue's stop callback,
        // and `settle` would otherwise report this window as having ended of its
        // own accord — recording `completed` for a run iOS cut short.
        guard let attempt = take() else { return }
        // The same pause backgrounding already uses, for the same reason: the
        // queue keeps its remaining chapters, and the explanation on screen is
        // one the user has seen before.
        downloader.pause(reason: String(localized: "downloads.paused.background"))
        complete(attempt.task, run: result(of: attempt, outcome: .expired))
    }

    /// Records the window, asks for another if one could help, and hands the time
    /// back.
    ///
    /// `success` is not decoration: iOS uses it to decide how generous to be with
    /// the next window, so a run that was cut short or refused must not claim to
    /// have done what it was woken for.
    private func complete(_ task: any BackgroundTaskHandle, run: BackgroundDownloadRun) {
        store(run: run)
        scheduleIfNeeded()
        task.setTaskCompleted(success: run.outcome == .completed || run.outcome == .nothingToDo)
    }

    private func result(
        of attempt: Attempt, outcome: BackgroundDownloadRun.Outcome
    ) -> BackgroundDownloadRun {
        BackgroundDownloadRun(
            startedAt: attempt.startedAt,
            connection: attempt.connection,
            chapters: attempt.remainingBefore - downloader.remainingCount,
            outcome: outcome
        )
    }

    private func take() -> Attempt? {
        defer { attempt = nil }
        return attempt
    }

    // MARK: - The record

    /// Records a window that arrived after iOS had terminated the app.
    ///
    /// Static because there is no object graph to reach: a background launch
    /// connects no scene, so no view has ever built an `AppEnvironment`. Saying so
    /// is the point — this is the evidence that would justify keeping the queue on
    /// disk, and until it shows up in the field there is no reason to build that.
    static func recordQueueLost(defaults: UserDefaults = .standard, now: Date = Date()) {
        store(
            BackgroundDownloadRun(
                startedAt: now, connection: .unknown, chapters: 0, outcome: .queueLost
            ),
            in: defaults
        )
    }

    private func store(run: BackgroundDownloadRun) {
        lastRun = run
        Self.store(run, in: defaults)
    }

    private func store(scheduleError: String?) {
        lastScheduleError = scheduleError
        if let scheduleError {
            defaults.set(scheduleError, forKey: Keys.scheduleError)
        } else {
            defaults.removeObject(forKey: Keys.scheduleError)
        }
    }

    private static func store(_ run: BackgroundDownloadRun, in defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(run) else { return }
        defaults.set(data, forKey: Keys.lastRun)
    }

    private static func loadRun(from defaults: UserDefaults) -> BackgroundDownloadRun? {
        guard let data = defaults.data(forKey: Keys.lastRun) else { return nil }
        return try? JSONDecoder().decode(BackgroundDownloadRun.self, from: data)
    }
}
