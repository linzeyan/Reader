import Foundation
import QuartzCore
#if canImport(UIKit)
import UIKit
#endif

/// A record of what the reader did, written to a file its reader can hand over.
///
/// Everything the reader gained through September 2026 — looking a voice up once, saying a
/// paragraph at a time, giving back chapters nobody is reading, letting a comic sleep —
/// was measured on a simulator, and not one of those measurements can be *confirmed* where
/// it matters. Whether a phone gets warm being read to, whether an evening of listening
/// grows without bound, whether the screen actually sleeps: all three happen on a device
/// nobody working on this app can touch. This is how that device gets to answer.
///
/// Off for everyone who was not asked to turn it on, and cheap when off: one boolean read
/// per event, with nothing built, because `note` takes its message as an autoclosure.
///
/// Turning it off deletes everything it wrote, on the spot. There is no second way to
/// clear it, no retention window and no expiry — the switch is the whole policy. An expiry
/// was considered and rejected: a trace that quietly stops after some number of hours turns
/// "I left it recording all night" into a file that ends right before the answer, and the
/// size cap already bounds the cost of forgetting.
///
/// ## What may not go in it
///
/// The file leaves the phone through a share sheet, which is to say it can end up
/// anywhere. So it holds counts, durations, byte sizes, chapter indices and language
/// codes, and it never holds a book's title, an author, a URL, a search, or a line of
/// text. Every call to `note` is bound by that; there is no redaction pass to catch a
/// mistake afterwards.
@Observable
final class TraceLog {
    /// Whether anything is being recorded.
    ///
    /// Persisted, because the session worth recording is a whole evening and the app is
    /// relaunched several times inside one.
    var isOn: Bool {
        didSet {
            guard isOn != oldValue else { return }
            defaults.set(isOn, forKey: Keys.isOn)
            if isOn { begin() } else { erase() }
            refreshSize()
        }
    }

    /// Bytes on disk, for the row that says whether there is anything worth sending.
    ///
    /// Refreshed when somebody looks rather than kept live: the writes happen on
    /// `queue`, and publishing a count from there would be an observable property
    /// mutated off the main thread several times a second, to animate a number nobody
    /// is watching.
    private(set) var size = 0

    var isEmpty: Bool { size == 0 }

    // MARK: - Recording

    /// One line, if recording is on.
    ///
    /// - Parameter line: built only when it will be written. Callers sit on hot paths — a
    ///   sentence being spoken, a chapter arriving — and the point of this whole file is
    ///   to measure how warm a phone gets, so the instrument may not be the load.
    ///
    ///   Counts, timings and indices only. See the type's note on what a file that leaves
    ///   the phone may not contain.
    func note(_ line: @autoclosure () -> String) {
        guard isOn else { return }
        // Interpolated here and not inside the `async` block: the closure would capture
        // the caller's state and be read from another thread, and every caller of this is
        // on the main actor.
        let text = String(format: "%9.1f %@\n", CACurrentMediaTime() - startedAt, line())
        queue.async { [writer] in writer.write(text) }
    }

    /// The whole trace, oldest line first, for the export sheet.
    ///
    /// Synchronous on purpose: it runs once, when a finger is on the button, and the
    /// alternative is a share sheet that opens onto a file still being written.
    func contents() -> Data {
        queue.sync { writer.contents() }
    }

    func refreshSize() {
        size = queue.sync { writer.size() }
    }

    // MARK: - Sampling

    /// Adds a source of fields to the periodic sample, under a name it can be removed by.
    ///
    /// Installed rather than pulled, because the things worth sampling have different
    /// owners and different lifetimes: the loaded window belongs to a screen that comes
    /// and goes, and the voice belongs to the app. Returning nil says "nothing to report
    /// just now", and with every source silent no line is written at all — a phone left
    /// on the shelf overnight should produce an empty trace, not eight hours of evidence
    /// that nobody was reading.
    ///
    /// Sources are called on the main thread, because what they read is main-actor state.
    func watch(_ name: String, fields: @escaping () -> String?) {
        sources[name] = fields
    }

    func stopWatching(_ name: String) {
        sources.removeValue(forKey: name)
    }

    /// One evaluation of `ReaderView.body`.
    ///
    /// Counted, never written: this runs at frame rate whenever something in the body
    /// reads per-frame state, so a line each would be the load. The rate is what the
    /// sample reports, and it is the first fork in every reader stall — "the body is
    /// re-running" and "the container is busy" look identical from the outside.
    func noteBody() {
        guard isOn else { return }
        bodies += 1
    }

    /// The foreground/background boundary, which every other event is read against.
    ///
    /// The one thing a simulator cannot answer. It does not suspend the app, so a walk
    /// that presses Home and finds the voice still speaking proves nothing — taking
    /// `audio` out of `UIBackgroundModes` entirely leaves that walk green, measured, 47.4s
    /// against 47.2s (PITFALLS 2026-09-18). On a phone, `say` lines continuing past
    /// `phase bg` are the proof that background audio works, and their stopping dead is
    /// the failure.
    func notePhase(_ isForeground: Bool) {
        guard isOn else { return }
        guard isForeground else {
            leftAt = CACurrentMediaTime()
            note("phase bg")
            return
        }
        // No `after=` on the first activation of a launch, because there is no duration to
        // state: writing `after=0` there reads as "left and came straight back", which is
        // a different event and the wrong one to go looking for.
        //
        // A *second* foreground with nothing between it and the last one is the other
        // thing that gets here, and it reads identically without `from=`: the app
        // resigned active and came back without ever reaching the background. Control
        // Centre, a notification banner, the app switcher. The 2026-09-20 device trace
        // had three in under three seconds and they looked like three relaunches — while
        // being the exact transition PITFALLS 2026-09-06 is about, so this is the line
        // that says whether the app-switcher snapshot has started rebuilding columns
        // again.
        guard let away = leftAt.map({ CACurrentMediaTime() - $0 }) else {
            note(hasBeenForeground ? "phase fg from=inactive" : "phase fg")
            hasBeenForeground = true
            return
        }
        hasBeenForeground = true
        leftAt = nil
        note(String(format: "phase fg after=%.0f", away))
    }

    /// Writes one sample, if any source has something to say.
    ///
    /// Driven by the timer, and called directly by tests: waiting five seconds for a
    /// timer to prove that an idle app writes nothing is five seconds spent proving it
    /// slowly. Main thread only — sources read main-actor state, and so does `phase`.
    func sampleNow() {
        // Sorted so the fields land in the same order on every line. A trace is read by
        // eye, down a column.
        let extra = sources.keys.sorted().compactMap { sources[$0]?() }
        guard !extra.isEmpty else { return }
        let now = CACurrentMediaTime()
        let window = max(now - lastSampleAt, 0.001)
        let rate = Double(bodies - bodiesAtLastSample) / window
        lastSampleAt = now
        bodiesAtLastSample = bodies
        note(
            "sample rss=\(Self.residentMB()) foot=\(Self.footprintMB()) phase=\(Self.phase) "
                + String(format: "body=%.1f/s ", rate) + extra.joined(separator: " ")
        )
    }

    /// What iOS actually charges the app, in megabytes.
    ///
    /// `rss` is resident size, and resident counts every page mapped into the process —
    /// including the shared, read-only text of UIKit, WebKit and CoreText, which every
    /// app on the phone maps and none of them is billed for. `phys_footprint` is the
    /// number jetsam decides by and the one Xcode's memory gauge shows; it is dirty and
    /// compressed memory, which is to say the memory this app is responsible for.
    ///
    /// Recorded beside `rss` rather than instead of it because the *gap* is a reading in
    /// its own right: a large one says the resident number was never the app's to answer
    /// for, and the 2026-09-20 device trace's 190 MB was read as a problem before anyone
    /// had asked which of the two it was.
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Int(info.phys_footprint / (1024 * 1024))
    }

    /// Resident size in megabytes.
    ///
    /// Shared with `ReaderProbe` rather than copied into it: there is one right way to ask
    /// this and two of them would drift.
    static func residentMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Int(info.resident_size / (1024 * 1024))
    }

    /// Which of the three states the app is in, as the sample sees it.
    ///
    /// The dividing line every other event is read against: whether the voice is still
    /// speaking after `phase=bg` is the only evidence that background audio works at all,
    /// and it is not a question a simulator can answer.
    ///
    /// Three, not two. `.inactive` — a notification banner, Control Centre, the app
    /// switcher — used to be folded in with `.background`, which was invisible until
    /// `notePhase` learned to say `from=inactive` and the 2026-09-20 device trace put the
    /// two a tenth of a second apart: `phase fg from=inactive` on one line and
    /// `phase=bg` on the next. Both were describing the same moment, and a trace that
    /// contradicts itself inside a second is worse than one that says less.
    private static var phase: String {
        #if canImport(UIKit)
        MainActor.assumeIsolated {
            switch UIApplication.shared.applicationState {
            case .active: "fg"
            case .inactive: "inactive"
            case .background: "bg"
            @unknown default: "?"
            }
        }
        #else
        "fg"
        #endif
    }

    // MARK: - Lifetime

    private func begin() {
        let started = Date.now.formatted(.iso8601)
        queue.async { [writer] in
            writer.open()
            // Without this line a trace cannot be attributed to anything. A heat report
            // from an A12 and one from an A19 are different findings, and "which build
            // was this?" has no other answer once the file is out of the app.
            writer.write("      0.0 boot \(Self.stamp) at=\(started)\n")
        }
        startSampling()
    }

    private func erase() {
        ticker?.invalidate()
        ticker = nil
        queue.async { [writer] in writer.erase() }
    }

    private func startSampling() {
        guard ticker == nil else { return }
        lastSampleAt = CACurrentMediaTime()
        bodiesAtLastSample = bodies
        let timer = Timer(timeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            self?.sampleNow()
        }
        // `.common`, not the default mode: a timer in the default mode does not fire at
        // all while a scroll view is tracking a finger, so the samples would go silent
        // exactly while the reader is scrolling — which is the half of the session worth
        // sampling. `ReaderProbe` learned this the same way.
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    /// Version, build, hardware and system — the four things a file needs to mean
    /// anything once it is somewhere else.
    private static var stamp: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        var system = "?"
        #if canImport(UIKit)
        system = UIDevice.current.systemVersion
        #endif
        return "v=\(short)(\(build)) hw=\(hardware) ios=\(system)"
    }

    /// The model identifier, e.g. `iPhone11,8`.
    ///
    /// `UIDevice.model` answers "iPhone" for every iPhone ever made, which is useless for
    /// the question this file exists to settle: a thermal complaint from an XR and one
    /// from a current phone are not the same report. Under the simulator `hw.machine` is
    /// the *host's* architecture, so the simulated device comes from the environment
    /// instead — otherwise every simulator trace would claim to be an arm64 Mac.
    private static var hardware: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return "sim:\(simulated)"
        }
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return "?" }
        var value = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &value, &size, nil, 0)
        return String(cString: value)
    }

    // MARK: - Storage

    /// Beside the rules and the chapters, not in `Caches`.
    ///
    /// `Caches` is where a log belongs by convention and it is the wrong place here: the
    /// system empties it while the app is not running, under exactly the disk and memory
    /// pressure that produces the sessions worth reading. The one trace we most want is
    /// the one from the evening the app was killed, and `Caches` is where that one would
    /// not survive.
    ///
    /// A failure here must not stop the app launching — a diagnostics file is the last
    /// thing that should — so the fallback is the temporary directory, where a trace is
    /// worth less but costs nothing.
    static func makeShared() -> TraceLog {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? .temporaryDirectory
        return TraceLog(directory: base.appendingPathComponent("Trace", isDirectory: true))
    }

    init(directory: URL, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        writer = Writer(directory: directory)
        isOn = defaults.bool(forKey: Keys.isOn)
        // Recording survives a relaunch, so a launch that finds the switch on is the
        // second half of somebody's evening and has to pick the file back up.
        if isOn { begin() }
        refreshSize()
    }

    /// Five seconds, the interval `ReaderProbe`'s summary line has always used — so that
    /// a number read out of a trace and one read out of a probe run mean the same thing.
    private static let sampleInterval: TimeInterval = 5

    private let defaults: UserDefaults
    private let writer: Writer

    // Bookkeeping, and every one of them `@ObservationIgnored` on purpose. `@Observable`
    // makes *every* stored `var` observable, private ones included, so `bodies += 1` —
    // which happens on every evaluation of `ReaderView.body` — would otherwise fire an
    // observation mutation at frame rate. Nothing observes these, so nothing would
    // re-render; it would simply be the instrument charging rent on the hot path it was
    // brought in to measure. Only `isOn` and `size` are watched, by the settings screen.
    @ObservationIgnored private var sources: [String: () -> String?] = [:]
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var bodies = 0
    @ObservationIgnored private var bodiesAtLastSample = 0
    @ObservationIgnored private var lastSampleAt: Double = 0
    /// When the app last went to the background — see `notePhase`.
    @ObservationIgnored private var leftAt: Double?
    /// Whether this trace has recorded a foreground before. What tells a launch's first
    /// activation apart from a return that never reached the background — see `notePhase`.
    @ObservationIgnored private var hasBeenForeground = false
    /// Times are seconds since this launch, not wall clock: a `DateFormatter` per line is
    /// real work on a path that runs several times a second, and the `boot` line carries
    /// the one absolute time needed to place the rest.
    private let startedAt = CACurrentMediaTime()
    /// `.utility` rather than the main queue's priority: nothing waits on a trace line,
    /// and a diagnostics file that competes with the voice would change the thing it was
    /// brought in to measure.
    private let queue = DispatchQueue(label: "com.zeyanlin.novelreader.trace", qos: .utility)

    private enum Keys {
        static let isOn = "trace.isOn"
    }
}

// MARK: - Writer

/// The file on disk. Every member is touched on `TraceLog.queue` and nowhere else.
///
/// Two files rather than one, rolled: a trace that is truncated when it fills keeps the
/// beginning of an evening, and a trace that is overwritten keeps only the last minutes.
/// What is wanted is the last several hours, which is what a roll gives — between one and
/// two full files at any moment.
///
/// `@unchecked Sendable` because that serial queue is the whole of the synchronisation:
/// nothing here is reachable from anywhere else, and the compiler cannot see a confinement
/// that lives in a convention.
private final class Writer: @unchecked Sendable {
    /// Four megabytes at the widest. At a sample every five seconds plus the events of a
    /// book being read aloud, a trace runs about 120 KB an hour, so this is more than a
    /// week of evenings — the cap is here to bound a switch left on and forgotten, not to
    /// ration anything anybody would actually record.
    private static let fileLimit = 2 * 1024 * 1024

    private let directory: URL
    private let current: URL
    private let rolled: URL
    private var handle: FileHandle?
    private var written = 0

    init(directory: URL) {
        self.directory = directory
        current = directory.appendingPathComponent("trace.log")
        rolled = directory.appendingPathComponent("trace-1.log")
    }

    func open() {
        guard handle == nil else { return }
        var folder = directory
        try? FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true
        )
        // Not in the reader's iCloud backup: this is a few megabytes of diagnostics with
        // a lifetime of days, and a backup is for things that would hurt to lose.
        var keepOut = URLResourceValues()
        keepOut.isExcludedFromBackup = true
        try? folder.setResourceValues(keepOut)

        if !FileManager.default.fileExists(atPath: current.path) {
            // Explicit protection because of *when* this file is written. The session
            // this exists to capture is a book being read aloud with the phone locked in
            // somebody's pocket, and under `.complete` protection every write in that
            // session would fail — silently producing an empty trace from precisely the
            // hour that was asked for.
            FileManager.default.createFile(
                atPath: current.path, contents: nil,
                attributes: [
                    .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
                ]
            )
        }
        guard let opened = try? FileHandle(forWritingTo: current) else { return }
        handle = opened
        // Appends rather than starting over: a relaunch inside a recorded evening is
        // part of the same trace, and losing the run before a crash would lose the run
        // that mattered.
        written = Int((try? opened.seekToEnd()) ?? 0)
    }

    func write(_ text: String) {
        if handle == nil { open() }
        guard let handle, let data = text.data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
        written += data.count
        guard written >= Self.fileLimit else { return }
        roll()
    }

    /// The whole trace, oldest first.
    func contents() -> Data {
        flush()
        var data = (try? Data(contentsOf: rolled)) ?? Data()
        data.append((try? Data(contentsOf: current)) ?? Data())
        return data
    }

    func size() -> Int {
        flush()
        return bytes(of: rolled) + bytes(of: current)
    }

    /// `FileManager` rather than `URL.resourceValues`, which caches.
    ///
    /// These two URLs are held for the lifetime of the writer and asked their size every
    /// couple of seconds while the diagnostics screen is open, so a cached answer is not a
    /// stale read once — it is permanent. Measured as a failing test: after `erase`, a size
    /// read through `resourceValues` still reported the bytes of the file that had just
    /// been deleted, which is the one moment the number has to be right.
    private func bytes(of url: URL) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        else {
            return 0
        }
        return attributes[.size] as? Int ?? 0
    }

    /// Everything, gone. What the switch means when it is turned off.
    func erase() {
        close()
        try? FileManager.default.removeItem(at: directory)
    }

    private func roll() {
        close()
        try? FileManager.default.removeItem(at: rolled)
        try? FileManager.default.moveItem(at: current, to: rolled)
        open()
    }

    /// What is buffered, on disk — so that a size or an export reports the trace as it
    /// stands rather than as it was at the last flush the system felt like doing.
    private func flush() {
        guard let handle else { return }
        try? handle.synchronize()
    }

    private func close() {
        if let handle { try? handle.close() }
        handle = nil
        written = 0
    }
}
