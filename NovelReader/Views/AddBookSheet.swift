import SwiftUI

/// The generic "paste a link" path. It is the only way to add a book that does
/// not go through search, and it works for every installed rule because the
/// matching is done by host + id pattern, not by any hardcoded site.
///
/// One address per line, and the lines are independent: each is matched against the
/// installed rules on its own, so a novel address and a comic address can be pasted
/// together and each book lands on its own shelf. Nothing here asks what mode the
/// shelf is in — the rule a line matches is what decides, which is the same answer
/// the book will give for the rest of its life.
struct AddBookSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    /// Empty until the reader presses Add. Its presence is what turns the sheet from
    /// an input into a report — a run that has started cannot be edited, only watched,
    /// stopped, or dismissed.
    @State private var lines: [AddBookLine] = []
    @State private var task: Task<Void, Never>?

    private var isWorking: Bool { task != nil }

    var body: some View {
        NavigationStack {
            Form {
                if lines.isEmpty {
                    inputSection
                    // Nothing to list on the feed shelf: an address is the whole of what
                    // it takes, so a section headed "sources" would be an empty box
                    // implying something is missing.
                    if env.mediaMode != .feed { sourcesSection }
                } else {
                    progressSection
                }
            }
            .navigationTitle(env.mediaMode == .feed ? "library.subscribe" : "library.add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { leadingButton }
                ToolbarItem(placement: .topBarTrailing) { trailingButton }
            }
            // A sheet that goes away mid-run would leave the batch fetching against a
            // screen nobody can see or stop.
            .interactiveDismissDisabled(isWorking)
        }
    }

    // MARK: - Sections

    private var inputSection: some View {
        Section {
            TextField("library.add.url", text: $text, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .accessibilityIdentifier("add.url")
        } footer: {
            Text(env.mediaMode == .feed ? "library.subscribe.hint" : "library.add.hint")
        }
    }

    private var sourcesSection: some View {
        Section("library.add.sources") {
            ForEach(env.sites.rules) { rule in
                HStack {
                    Label(rule.name, systemImage: rule.kind.icon)
                    Spacer()
                    Text(rule.host).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The run, one row per pasted address, in the order they were pasted.
    ///
    /// Every line stays on screen whatever happens to it. A batch of ten where the
    /// fourth address was a search page has to be able to say *which* one, and a list
    /// that dropped the successes to make room for the failures could not.
    private var progressSection: some View {
        let finished = lines.filter(\.status.isFinished).count
        let failures = lines.filter(\.status.isFailure).count
        return Section {
            ForEach(lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    status(of: line)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.address)
                            .font(.footnote)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let note = line.status.note {
                            Text(note)
                                .font(.caption2)
                                .foregroundStyle(line.status.isFailure ? .red : .secondary)
                                .lineLimit(2)
                        }
                    }
                }
                .accessibilityIdentifier("add.line")
            }
        } header: {
            Text("library.add.progress \(finished) \(lines.count)")
        } footer: {
            if failures > 0, !isWorking {
                Text("library.add.failed \(failures)").foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func status(of line: AddBookLine) -> some View {
        switch line.status {
        case .waiting:
            Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
        case .working:
            ProgressView().controlSize(.mini)
        case .added:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        }
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var leadingButton: some View {
        if isWorking {
            // Stopping means "add no more", not "undo what you added": the books
            // already on the shelf were legitimately added and stay there.
            Button("library.add.stop") { task?.cancel() }
                .accessibilityIdentifier("add.stop")
        } else if lines.isEmpty {
            Button("common.cancel") { dismiss() }
        }
    }

    @ViewBuilder
    private var trailingButton: some View {
        if isWorking {
            ProgressView()
        } else if lines.isEmpty {
            Button("library.add.confirm") { run() }
                .accessibilityIdentifier("add.confirm")
                .disabled(AddBookLine.pasted(text).isEmpty)
        } else {
            // A finished run is only reachable with something to look at — a clean
            // sweep dismisses itself. So this is the way out of a report.
            Button("common.done") { dismiss() }
                .accessibilityIdentifier("add.done")
        }
    }

    // MARK: - Running

    private func run() {
        lines = AddBookLine.pasted(text)
        guard !lines.isEmpty else { return }
        task = Task { await addAll() }
    }

    /// Adds each address in turn, and does not stop for a failure.
    ///
    /// Sequential rather than concurrent because the fetcher is one web view driving
    /// one page at a time; ten parallel calls would queue behind each other anyway,
    /// having first told the reader all ten were in flight.
    ///
    /// A challenge or a sign-in wall *does* stop it, unlike every other failure: those
    /// are answered by the reader in a sheet this one is covering, and carrying on
    /// would spend the rest of the batch on a host that is going to refuse all of it.
    @MainActor
    private func addAll() async {
        // More than one address is unattended work — the reader pasted a list and
        // looked away — so it is paced like a download. A single address is somebody
        // waiting on a tap, and making them wait two seconds for politeness they did
        // not ask for is what the pacer's own note says not to do.
        let paced = lines.count > 1
        defer {
            task = nil
            if paced { env.pacer.reset() }
        }
        for index in lines.indices {
            if Task.isCancelled { return }
            lines[index].status = .working
            if paced { await env.pacer.pace() }
            switch await add(lines[index].address) {
            case .added(let title):
                lines[index].status = .added(title)
            case .failed(let reason):
                lines[index].status = .failed(reason)
            case .needsTheUser(let error):
                lines[index].status = .failed(error.localizedDescription)
                env.report(error)
                return
            }
        }
        // Nothing left to report and nothing to decide: the shelf behind the sheet is
        // already showing the books. Kept from before this sheet did batches, where a
        // successful single add closed it.
        if !lines.contains(where: \.status.isFailure) { dismiss() }
    }

    private enum LineOutcome {
        case added(String)
        case failed(String)
        case needsTheUser(any Error)
    }

    private func add(_ address: String) async -> LineOutcome {
        // A subscription is added by address alone, so it does not go looking for a rule
        // to match — and the shelf's mode is what decides, unlike the two media below.
        // Those are told apart by the rule an address matches; a feed address matches
        // nothing, and a novel address pasted onto this shelf would silently become a
        // subscription to a page that is not one.
        if env.mediaMode == .feed { return await subscribe(address) }
        guard let url = URL(string: address), let rule = env.sites.rule(matching: url) else {
            return .failed(String(localized: "library.add.error.noRule"))
        }
        guard let siteBookId = rule.bookId(from: url) else {
            return .failed(String(localized: "library.add.error.noBookId"))
        }
        do {
            let info = try await env.bookService.info(rule: rule, siteBookId: siteBookId)
            try await env.addBook(rule: rule, siteBookId: siteBookId, info: info)
            return .added(info.title)
        } catch {
            return WebFetcher.needsTheUser(error)
                ? .needsTheUser(error)
                : .failed(error.localizedDescription)
        }
    }

    /// One pasted address, subscribed to.
    ///
    /// No challenge path, unlike the rule-driven one: a feed is fetched over
    /// `URLSession`, which nothing can hand to the user to solve. A host that turns the
    /// request away is a failure on this line and the rest of the batch carries on —
    /// which is what a reader pasting twenty addresses out of another reader wants,
    /// since one of them being dead should not cost them the other nineteen.
    private func subscribe(_ address: String) async -> LineOutcome {
        do {
            let book = try await env.subscribeToFeed(address)
            return .added(book.shownName)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// One address the reader pasted, and what became of it.
struct AddBookLine: Identifiable {
    enum Status {
        case waiting
        case working
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

        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }

        var note: String? {
            switch self {
            case .added(let title): return title
            case .failed(let reason): return reason
            case .waiting, .working: return nil
            }
        }
    }

    /// Its place in the pasted text, which is also the order it is added in.
    let id: Int
    let address: String
    var status: Status = .waiting

    /// Turns pasted text into the addresses to try.
    ///
    /// One per line, because that is the shape text arrives in when it is copied out
    /// of a notes app or a chat — and the only shape that cannot mangle an address,
    /// which may legitimately contain anything but a newline.
    ///
    /// The same address twice becomes one. Adding a book twice is harmless in the
    /// database — the row is keyed by site and book id — but it is two more round
    /// trips through a WAF for a shelf that would look exactly the same.
    static func pasted(_ text: String) -> [AddBookLine] {
        var seen: Set<String> = []
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .enumerated()
            .map { AddBookLine(id: $0.offset, address: $0.element) }
    }
}
