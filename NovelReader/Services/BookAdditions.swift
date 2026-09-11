import Foundation

/// The books and subscriptions being added right now, and how far each has got.
///
/// Owned by `AppEnvironment` rather than by the sheet that starts it, which is the whole
/// point of it existing. Pasting twenty addresses used to pin the reader to a modal that
/// refused to be dismissed until the last one landed — because dismissing it *was*
/// abandoning the run. Here the run outlives every screen: the sheet is one way to watch
/// it, the shelf's banner is another, and closing both changes nothing about what is
/// being fetched.
///
/// At most one run at a time. Two batches would be two sets of requests racing for the
/// same web view and the same hosts, reported in two places, for a gesture nobody makes
/// twice on purpose.
@MainActor
@Observable
final class BookAdditions {
    /// What a run is turning addresses into, which is also what decides how it is run.
    enum Kind {
        /// Novels and comics, matched against the installed rules.
        case book
        /// Subscriptions, pasted one per line.
        case subscription
        /// Subscriptions read out of a list exported from another reader. Runs exactly as
        /// `subscription` does, and differs in one rule: a feed that will not answer is
        /// still kept, under the name the file gave it. The alternative is losing
        /// subscriptions to a bad minute on a train, silently, out of a file the reader
        /// may well have deleted by then — and a row with no articles yet is a row the
        /// next refresh fills in.
        case subscriptionList

        var isFeed: Bool { self != .book }
        var keepsUnreachable: Bool { self == .subscriptionList }
    }

    /// What this needs from the rest of the app.
    ///
    /// Closures rather than a reference back to the `AppEnvironment` that owns this: the
    /// cycle would be real, and the scheduling below — the one part of this with a failure
    /// mode of its own — is then pinnable without a database, a web view or a network.
    struct Work {
        /// Subscribes to one address, and hands back the name it ended up under.
        var subscribe: (String, @escaping FeedService.ProgressHandler) async throws -> String
        /// Adds one address as a novel or a comic, by whatever installed rule it matches,
        /// and hands back its title.
        var addBook: (String) async throws -> String
        /// Puts a subscription on the shelf without reading it, under `title` or whatever
        /// its own address suggests. Nil if the address is not one at all.
        var keep: (String, String?) -> String?
        /// Called once when a run comes to rest, however it ended.
        var settled: () -> Void
        /// A failure only the reader can clear — a challenge, or a sign-in wall.
        var report: (any Error) -> Void
    }

    /// How many subscriptions are read at once, and never two from the same host.
    ///
    /// Feeds are the one medium this app can genuinely fetch in parallel: a subscription
    /// is a document off `URLSession` and its articles are pictures off a CDN, so twelve
    /// blogs are twelve unrelated servers with nothing to say to each other. Measured on a
    /// shelf of thirteen, a cold subscribe spent ninety-odd per cent of its wall clock
    /// waiting on picture downloads, one feed at a time, with the network otherwise idle.
    ///
    /// Four rather than all of them because the *cheap* half is only cheap in isolation:
    /// each feed in flight also holds a place in the queue behind the one web view that
    /// turns markup into paragraphs, and a reader who opened a book while this ran would
    /// be waiting behind however many are lined up there.
    ///
    /// One per host is the pacing, and is why nothing here goes through `RequestPacer`. A
    /// feed is published to be polled; what would be rude is opening four connections to
    /// one blog, and that is exactly what this prevents.
    static let maxConcurrentFeeds = 4

    /// One row per address, in the order they were given. Empty until a run starts and
    /// until a finished one is cleared — which is what makes this "is there anything to
    /// show", for both the sheet and the shelf's banner.
    private(set) var lines: [AddBookLine] = []
    private(set) var isRunning = false
    /// What the run in flight — or the last one — was about. Drives nothing here; the
    /// screens use it to name what they are reporting on.
    private(set) var kind: Kind = .book

    private var task: Task<Void, Never>?
    private var work: Work?
    private let pacer: RequestPacer

    init(pacer: RequestPacer) {
        self.pacer = pacer
    }

    /// Wired by `AppEnvironment` after its own graph is built, because every closure in
    /// `Work` reaches back into it.
    func connect(_ work: Work) {
        self.work = work
    }

    var finished: Int { lines.filter(\.status.isFinished).count }
    var added: Int { lines.filter(\.status.isAdded).count }
    var failures: Int { lines.filter(\.status.isFailure).count }

    /// Starts a run, replacing whatever the last one left on screen.
    ///
    /// - Returns: whether it started. It will not while one is already going, which is the
    ///   state both entry points disable their own controls in — but a file picker and a
    ///   sheet are two ways in, and "the other one is busy" is cheaper to answer here than
    ///   to prevent in two views.
    @discardableResult
    func start(_ requests: [AddBookLine], as kind: Kind) -> Bool {
        guard !isRunning, !requests.isEmpty, work != nil else { return false }
        lines = requests
        self.kind = kind
        isRunning = true
        task = Task { [weak self] in await self?.run(kind) }
        return true
    }

    /// Stops after whatever is in flight. Not an undo: the books already on the shelf were
    /// legitimately added and stay there.
    func stop() {
        task?.cancel()
    }

    /// Clears a finished run's report, which is the reader saying they have read it.
    func clear() {
        guard !isRunning else { return }
        lines = []
    }

    /// Returns once the run in flight has come to rest.
    ///
    /// Nothing in the app awaits this — a run not being awaited is the entire feature —
    /// but a test that started one has no other way to know it is over.
    func settle() async {
        await task?.value
    }

    // MARK: - Running

    private func run(_ kind: Kind) async {
        defer {
            isRunning = false
            task = nil
            work?.settled()
        }
        switch kind {
        case .book: await addBooksInTurn()
        case .subscription, .subscriptionList: await subscribeSiteBySite(kind)
        }
    }

    /// Novels and comics, one after another, not stopping for a failure.
    ///
    /// Sequential because the fetcher is one web view driving one page at a time: ten
    /// parallel calls would queue behind each other anyway, having first told the reader
    /// all ten were in flight. Feeds are the medium that escapes this, and they escape it
    /// by not using the web view to fetch anything.
    ///
    /// A challenge or a sign-in wall *does* stop it, unlike every other failure: those are
    /// answered by the reader in a sheet, and carrying on would spend the rest of the
    /// batch on a host that is going to refuse all of it.
    private func addBooksInTurn() async {
        guard let work else { return }
        // More than one address is unattended work — the reader pasted a list and looked
        // away — so it is paced like a download. A single address is somebody waiting on a
        // tap, and making them wait two seconds for politeness they did not ask for is
        // what the pacer's own note says not to do.
        let paced = lines.count > 1
        defer { if paced { pacer.reset() } }
        for index in lines.indices {
            if Task.isCancelled { return }
            lines[index].status = .working(nil)
            if paced { await pacer.pace(host: host(of: index)) }
            do {
                lines[index].status = .added(try await work.addBook(lines[index].address))
            } catch {
                lines[index].status = .failed(error.localizedDescription)
                if WebFetcher.needsTheUser(error) {
                    work.report(error)
                    return
                }
            }
        }
    }

    /// Subscriptions, several at once, never two against one host.
    ///
    /// The window is refilled as each feed lands rather than in batches of four, so the
    /// one blog that takes four minutes of picture downloads holds up nothing but itself —
    /// which, measured, is exactly the shape a real shelf has: one outlier and twelve
    /// feeds that are done in under a second each.
    private func subscribeSiteBySite(_ kind: Kind) async {
        guard let work else { return }
        var pending = Array(lines.indices)
        var busy: Set<String> = []
        var inFlight = 0
        await withTaskGroup(of: Outcome.self) { group in
            while true {
                while !Task.isCancelled, inFlight < Self.maxConcurrentFeeds,
                      let slot = pending.firstIndex(where: { !busy.contains(host(of: $0)) }) {
                    let index = pending.remove(at: slot)
                    let host = host(of: index)
                    busy.insert(host)
                    inFlight += 1
                    lines[index].status = .working(nil)
                    group.addTask { @MainActor [weak self] in
                        guard let self else { return Outcome(index: index, host: host, status: .waiting) }
                        return Outcome(
                            index: index, host: host,
                            status: await self.subscribe(at: index, as: kind, through: work)
                        )
                    }
                }
                // Nothing running and nothing startable: either the batch is done or it
                // was cancelled, and the difference is only what the untouched rows say.
                guard inFlight > 0, let done = await group.next() else { return }
                inFlight -= 1
                busy.remove(done.host)
                lines[done.index].status = done.status
            }
        }
    }

    /// One finished subscription, on its way back to the row that started it.
    private struct Outcome {
        let index: Int
        let host: String
        let status: AddBookLine.Status
    }

    /// One address, subscribed to.
    ///
    /// No challenge path, unlike the rule-driven one: a feed is fetched over `URLSession`,
    /// which nothing can hand to the user to solve. A host that turns the request away is
    /// a failure on this line and the rest of the batch carries on — which is what a
    /// reader pasting twenty addresses out of another reader wants, since one of them
    /// being dead should not cost them the other nineteen.
    private func subscribe(
        at index: Int, as kind: Kind, through work: Work
    ) async -> AddBookLine.Status {
        let line = lines[index]
        do {
            let name = try await work.subscribe(line.address) { [weak self] progress in
                // A feed that published no bodies to read has nothing to count, and
                // "0 of 0" is a worse thing to show than the spinner alone.
                guard let self, progress.total > 0, self.lines.indices.contains(index),
                      self.lines[index].address == line.address
                else { return }
                self.lines[index].status = .working(
                    String(localized: "library.add.articles \(progress.stored) \(progress.total)")
                )
            }
            return .added(name)
        } catch {
            guard kind.keepsUnreachable,
                  let kept = work.keep(line.address, line.fallbackTitle)
            else { return .failed(error.localizedDescription) }
            return .added(kept)
        }
    }

    /// Which server a row will be asking, so two rows that share one do not ask at once.
    ///
    /// The address itself stands in when it names no host — it is then its own lane, which
    /// is the right answer for something that is about to fail on its own anyway.
    private func host(of index: Int) -> String {
        let address = lines[index].address
        return FeedService.url(from: address)?.host()?.lowercased() ?? address
    }
}

/// One address the reader asked for, and what became of it.
struct AddBookLine: Identifiable {
    enum Status {
        case waiting
        /// Under way, and how far — the article count of a subscription being read for
        /// the first time. Nil while there is nothing to count yet, which is every novel
        /// and comic and the moment before a feed document has been parsed.
        case working(String?)
        /// The book's title, as the site published it — the confirmation that the
        /// address led where the reader thought it did.
        case added(String)
        case failed(String)

        var isFinished: Bool {
            switch self {
            case .added, .failed: return true
            case .waiting, .working: return false
            }
        }

        var isAdded: Bool {
            if case .added = self { return true }
            return false
        }

        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }

        var note: String? {
            switch self {
            case .added(let title): return title
            case .failed(let reason): return reason
            case .working(let progress): return progress
            case .waiting: return nil
            }
        }
    }

    /// Its place in the list, which is also the order it is added in.
    let id: Int
    let address: String
    /// What to call it if its own document will not answer. Only a subscription list has
    /// one — the file named every feed in it, and that name is what an unreachable row
    /// goes onto the shelf under.
    var fallbackTitle: String?
    var status: Status = .waiting

    /// Turns pasted text into the addresses to try.
    ///
    /// One per line, because that is the shape text arrives in when it is copied out
    /// of a notes app or a chat — and the only shape that cannot mangle an address,
    /// which may legitimately contain anything but a newline.
    static func pasted(_ text: String) -> [AddBookLine] {
        numbered(
            text.split(whereSeparator: \.isNewline)
                .map { (address: $0.trimmingCharacters(in: .whitespaces), title: nil) }
        )
    }

    /// Numbered in the order they will be added, with blanks and repeats dropped.
    ///
    /// The same address twice becomes one. Adding a book twice is harmless in the
    /// database — the row is keyed by site and book id — but it is two more round
    /// trips through a WAF for a shelf that would look exactly the same.
    static func numbered(_ addresses: [(address: String, title: String?)]) -> [AddBookLine] {
        var seen: Set<String> = []
        return addresses
            .filter { !$0.address.isEmpty && seen.insert($0.address).inserted }
            .enumerated()
            .map {
                AddBookLine(
                    id: $0.offset, address: $0.element.address, fallbackTitle: $0.element.title
                )
            }
    }
}
