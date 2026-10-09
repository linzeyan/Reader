import SwiftUI

/// Every book in the download queue, in the order they will be fetched.
///
/// No reordering, by design: the order is the order the reader asked in. What the
/// reader can do is what a stuck queue needs — hold a book so the rest go first, let
/// it go again, or take it out.
struct DownloadQueueView: View {
    @Environment(AppEnvironment.self) private var env
    /// How the last focus ended, said on this screen once the black lifts.
    @State private var ending: FocusEnding?

    private enum FocusEnding { case finished, stopped }

    var body: some View {
        let downloader = env.downloader
        let focus = env.downloadFocus
        List {
            if ending == .stopped {
                Section {
                    Label("downloads.focus.stopped", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("downloads.focus.stopped")
                }
            }
            // A queue stopped by something other than a book — the app leaving the
            // screen, a metered connection — has no book's button that answers it.
            if downloader.canResume {
                Section {
                    Button("downloads.queue.resumeAll") { env.requestResume() }
                        .accessibilityIdentifier("downloads.queue.resumeAll")
                } footer: {
                    if let reason = downloader.lastError { Text(reason) }
                }
            }
            ForEach(downloader.jobs) { job in
                DownloadJobRow(job: job)
            }
        }
        .overlay {
            if downloader.jobs.isEmpty {
                if ending == .finished {
                    ContentUnavailableView("downloads.focus.finished", systemImage: "checkmark.circle")
                        .accessibilityIdentifier("downloads.focus.finished")
                } else {
                    ContentUnavailableView("downloads.queue.empty", systemImage: "arrow.down.circle")
                }
            }
        }
        .navigationTitle("downloads.queue.title")
        .navigationBarTitleDisplayMode(.inline)
        // At the bottom, where the countdown and its stop button then take its place: the
        // phone is put down and picked up again by the same thumb.
        .safeAreaInset(edge: .bottom) {
            switch focus.phase {
            case .counting(let left):
                HStack {
                    Text("downloads.focus.countdown \(left)")
                        .font(.footnote)
                        .monospacedDigit()
                    Spacer()
                    Button("downloads.focus.stop") { focus.stop() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("downloads.focus.stop")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)
            // Only over a running queue. A stopped one is resumed first, where the
            // metered-connection prompt can still be answered with the screen lit.
            case .off where downloader.isBusy:
                Button {
                    ending = nil
                    focus.start()
                } label: {
                    Label("downloads.focus", systemImage: "moon.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("downloads.focus")
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)
            case .off, .dark:
                EmptyView()
            }
        }
        // Everything that could go is done, or held — paused, behind a wall, out of
        // network. Nothing is left that keeping the app on screen would move along.
        .onChange(of: downloader.isBusy) { _, busy in
            if busy {
                ending = nil
            } else if focus.phase != .off {
                focus.stop()
                switch downloader.status {
                case .finished: ending = .finished
                case .paused: ending = .stopped
                // Every book cancelled by hand: nothing to report.
                case .idle, .running: ending = nil
                }
            }
        }
        .onDisappear { focus.stop() }
    }
}

/// Keeps the app on screen while the queue runs, with the screen black — the phone
/// left on a table to download, without locking it and stopping the queue.
///
/// Counts down before going dark so the reader sees the queue first, both when it is
/// turned on and each time a tap lights the screen again.
@MainActor
@Observable
final class DownloadFocus {
    enum Phase: Equatable {
        case off
        case counting(Int)
        case dark
    }

    private(set) var phase = Phase.off
    @ObservationIgnored private var ticker: Task<Void, Never>?
    /// The reader's own brightness, put back when the screen lights again.
    @ObservationIgnored private var brightness: CGFloat?
    @ObservationIgnored private let trace: TraceLog
    @ObservationIgnored private let seconds: Int

    /// - Parameter seconds: how long the countdown runs. A parameter only for tests.
    init(trace: TraceLog, seconds: Int = 10) {
        self.trace = trace
        self.seconds = seconds
    }

    func start() {
        guard phase == .off else { return }
        trace.note("focus on")
        ScreenWake.holdForDownload(trace: trace)
        countDown()
    }

    /// A tap on the black: the queue comes back, and the countdown starts over.
    func wake() {
        guard phase == .dark else { return }
        trace.note("focus wake")
        light()
        countDown()
    }

    func stop() {
        guard phase != .off else { return }
        trace.note("focus off")
        ticker?.cancel()
        ticker = nil
        light()
        phase = .off
        ScreenWake.release(trace: trace)
    }

    private func countDown() {
        ticker?.cancel()
        phase = .counting(seconds)
        let steps = (0..<seconds).reversed()
        ticker = Task { [weak self] in
            for left in steps {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                if left > 0 {
                    phase = .counting(left)
                } else {
                    darken()
                }
            }
        }
    }

    /// Black alone still lights an LCD's backlight, so the brightness goes down as well.
    private func darken() {
        phase = .dark
        guard let screen else { return }
        brightness = screen.brightness
        screen.brightness = 0
        trace.note(String(format: "focus dark brightness=%.2f", brightness ?? -1))
    }

    private func light() {
        guard let brightness else { return }
        // Read before it is put back, not after: the setter lands a moment later, so this
        // is the reading that shows the dark really took. "My screen stayed dim" is the
        // report this feature is most likely to earn, and the trace is the only witness.
        let dimmed = screen?.brightness ?? -1
        screen?.brightness = brightness
        self.brightness = nil
        trace.note(String(format: "focus light brightness=%.2f→%.2f", dimmed, brightness))
    }

    private var screen: UIScreen? {
        UIApplication.shared.connectedScenes.lazy.compactMap { ($0 as? UIWindowScene)?.screen }.first
    }
}

/// One book's share of the queue: how far it has got, what it is waiting for, and
/// its two controls. Shared by the queue screen and the book screen, so the two can
/// never describe the same book differently.
struct DownloadJobRow: View {
    let job: DownloadManager.Job
    var showsTitle = true
    /// Run after a cancel, for a screen that has to reload its chapters.
    var onCancel: () -> Void = {}

    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let downloader = env.downloader
        VStack(alignment: .leading, spacing: 8) {
            if showsTitle {
                Text(job.book.shownName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
            ProgressView(value: job.fraction) {
                Text("book.download.progress \(job.completed) \(job.total)")
                    .font(.footnote)
            }
            if let state = downloader.describe(job) {
                Text(state)
                    .font(.caption)
                    .foregroundStyle(job.hold == nil ? Color.secondary : Color.orange)
            }
            HStack {
                // Pause only means something while the queue is going; a stopped queue,
                // or a held book, is asked to go instead.
                if job.hold == nil, downloader.isBusy {
                    Button("book.download.pause") { downloader.pause(bookId: job.id) }
                } else {
                    Button("book.download.resume") { env.requestResume(bookId: job.id) }
                }
                Spacer()
                Button("common.cancel", role: .destructive) {
                    downloader.cancel(bookId: job.id)
                    onCancel()
                }
            }
            .font(.footnote)
            // Not decoration. A `List` row is one tappable control, so two
            // buttons sharing a row both fire on any tap in it: "pause" ran
            // `pause()` and then `cancel()`, and the download queue the reader
            // meant to keep was gone — with the row that would have explained it.
            // `.borderless` is what gives each button its own hit area back.
            .buttonStyle(.borderless)
        }
        // A container, so the identifier names the row and its buttons stay its own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("downloads.job")
    }
}

extension DownloadManager {
    /// The line under a book's progress bar, or nil when the bar says it all.
    func describe(_ job: Job) -> String? {
        switch job.hold {
        case .paused:
            return job.note ?? String(localized: "downloads.state.paused")
        case .wall:
            return String(localized: "downloads.state.wall")
        case nil where job.id == activeBookId && isBusy:
            return job.note
        case nil where isBusy:
            return String(localized: "downloads.state.queued")
        case nil:
            return lastError ?? String(localized: "downloads.state.paused")
        }
    }
}
