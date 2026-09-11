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
///
/// The run itself belongs to `env.additions`, not to this view. That is what lets the
/// sheet be closed while twenty addresses are still being fetched: this screen is one of
/// two ways to watch a batch, and the other one is the banner on the shelf behind it.
struct AddBookSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""

    private var additions: BookAdditions { env.additions }

    /// Empty until a run starts. Its presence is what turns the sheet from an input into
    /// a report — a run that has started cannot be edited, only watched, stopped, or
    /// left to get on with it.
    private var lines: [AddBookLine] { additions.lines }

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
            // Nothing left to report and nothing to decide: the shelf behind the sheet is
            // already showing the books. A run with failures in it stays up, because
            // *which* address failed is the only thing this screen knows that the shelf
            // does not.
            .onChange(of: additions.isRunning) { _, running in
                guard !running, additions.failures == 0 else { return }
                additions.clear()
                dismiss()
            }
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

    /// The run, one row per address, in the order they were given.
    ///
    /// Every line stays on screen whatever happens to it. A batch of ten where the
    /// fourth address was a search page has to be able to say *which* one, and a list
    /// that dropped the successes to make room for the failures could not.
    private var progressSection: some View {
        Section {
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
            Text("library.add.progress \(additions.finished) \(lines.count)")
        } footer: {
            if additions.failures > 0, !additions.isRunning {
                Text("library.add.failed \(additions.failures)").foregroundStyle(.red)
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
        if additions.isRunning {
            // Stopping means "add no more", not "undo what you added": the books
            // already on the shelf were legitimately added and stay there.
            Button("library.add.stop") { additions.stop() }
                .accessibilityIdentifier("add.stop")
        } else if lines.isEmpty {
            Button("common.cancel") { dismiss() }
        }
    }

    @ViewBuilder
    private var trailingButton: some View {
        if additions.isRunning {
            // The whole point of the queue living outside this sheet. Closing it leaves
            // the batch fetching, and the shelf's banner is where it reappears — so a
            // reader who pasted forty addresses can go and read something meanwhile.
            Button("library.add.hide") { dismiss() }
                .accessibilityIdentifier("add.hide")
        } else if lines.isEmpty {
            Button("library.add.confirm") { run() }
                .accessibilityIdentifier("add.confirm")
                .disabled(AddBookLine.pasted(text).isEmpty)
        } else {
            // A finished run is only left on screen with something to look at — a clean
            // sweep dismisses itself. So this is the way out of a report.
            Button("common.done") {
                additions.clear()
                dismiss()
            }
            .accessibilityIdentifier("add.done")
        }
    }

    // MARK: - Running

    /// A subscription is added by address alone, so it does not go looking for a rule to
    /// match — and the shelf's mode is what decides, unlike the two media below. Those are
    /// told apart by the rule an address matches; a feed address matches nothing, and a
    /// novel address pasted onto this shelf would silently become a subscription to a page
    /// that is not one.
    private func run() {
        additions.start(
            AddBookLine.pasted(text), as: env.mediaMode == .feed ? .subscription : .book
        )
    }
}
