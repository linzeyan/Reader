import SwiftUI

/// Turns a pasted book URL into an installable source.
///
/// The screen is deliberately shaped around confirmation rather than
/// configuration: the derivation is a guess, and the only person who can tell
/// whether it guessed right is someone looking at the same page. So it shows a
/// book title, a chapter count and the opening of chapter one — all produced by
/// running the rule that would actually be saved — and nothing that requires
/// knowing what a CSS selector is.
struct DeriveRuleView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var isWorking = false
    @State private var draft: RuleDeriver.Draft?
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("derive.url.prompt", text: $urlText, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityIdentifier("derive.url")
                Button {
                    Task { await analyse() }
                } label: {
                    if isWorking {
                        HStack {
                            ProgressView()
                            Text("derive.analysing")
                        }
                    } else {
                        Text("derive.analyse")
                    }
                }
                .disabled(urlText.trimmed.isEmpty || isWorking)
                .accessibilityIdentifier("derive.analyse")
            } footer: {
                Text("derive.footer")
            }

            if let error {
                Section {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }

            if let draft {
                preview(draft)
            }
        }
        .navigationTitle("derive.title")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func preview(_ draft: RuleDeriver.Draft) -> some View {
        Section("derive.preview") {
            VStack(alignment: .leading, spacing: 4) {
                Text(draft.preview.bookTitle).font(.headline)
                if let author = draft.preview.author {
                    Text(author).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            LabeledContent("derive.chapters", value: "\(draft.preview.chapterCount)")
            if let first = draft.preview.firstChapterTitle {
                LabeledContent("derive.firstChapter", value: first)
            }
            // The excerpt is the load-bearing check: a wrong content selector
            // shows up here as navigation text or an ad, which anyone can spot.
            Text(draft.preview.excerpt)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("derive.excerpt")
        }

        if !draft.preview.warnings.isEmpty {
            Section {
                ForEach(draft.preview.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }

        Section {
            LabeledContent("derive.host", value: draft.rule.host)
            Button("derive.save") { save(draft.rule) }
                .accessibilityIdentifier("derive.save")
        } footer: {
            Text("derive.save.footer")
        }
    }

    private func analyse() async {
        guard let url = URL(string: urlText.trimmed) else {
            error = String(localized: "derive.error.badURL")
            return
        }
        isWorking = true
        error = nil
        draft = nil
        defer { isWorking = false }
        do {
            draft = try await RuleDeriver(fetcher: env.fetcher).derive(from: url)
        } catch {
            // Routed through the environment as well as shown inline: a Cloudflare
            // challenge has to reach the challenge sheet, and once the user clears
            // it, tapping Analyse again just works.
            env.report(error)
            self.error = error.localizedDescription
        }
    }

    private func save(_ rule: SiteRule) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try env.sites.importRule(data: encoder.encode(rule))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Import from a URL

/// The third import path, alongside a file and pasted JSON: fetch a rule someone
/// has published. Rules are portable by design — one person works a site out and
/// everyone else imports the result.
struct RemoteRuleImportView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("settings.sources.importURL.prompt", text: $urlText, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("sources.importURL.field")
                } footer: {
                    Text("settings.sources.importURL.footer")
                }
                if let error {
                    Section { Text(error).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle("settings.sources.importURL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("common.save") { Task { await load() } }
                        .disabled(urlText.trimmed.isEmpty || isWorking)
                        .accessibilityIdentifier("sources.importURL.confirm")
                }
            }
            .overlay { if isWorking { ProgressView() } }
        }
    }

    private func load() async {
        guard let url = URL(string: urlText.trimmed) else {
            error = String(localized: "rules.import.error.unreadable")
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            try await env.sites.importRule(fromRemote: url)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
