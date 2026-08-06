import SwiftUI

/// What one installed source can do, and the two things a user can do to it:
/// pass it on, or teach it to search.
///
/// Both exist because rules are portable. One person works a site out, everyone
/// else imports the result — which only works if there is a way to get a rule
/// back *out* of the app.
struct SiteDetailView: View {
    @Environment(AppEnvironment.self) private var env

    let siteId: String

    @State private var probe = ""
    @State private var isWorking = false
    @State private var derived: SearchDeriver.Derived?
    @State private var error: String?

    private var rule: SiteRule? { env.sites.rule(id: siteId) }

    var body: some View {
        Form {
            if let rule {
                Section {
                    LabeledContent("derive.host", value: rule.host)
                    LabeledContent("site.detail.search") {
                        Text(rule.search == nil ? "site.detail.search.no" : "site.detail.search.yes")
                            .foregroundStyle(rule.search == nil ? .orange : .secondary)
                    }
                    if let file = env.sites.fileURL(forRuleId: rule.id) {
                        ShareLink(item: file) {
                            Label("site.detail.export", systemImage: "square.and.arrow.up")
                        }
                        .accessibilityIdentifier("site.export")
                    }
                } footer: {
                    Text("site.detail.export.footer")
                }

                if rule.search == nil {
                    searchSection(rule)
                }

                if let notes = rule.notes, !notes.isEmpty {
                    Section("site.detail.notes") {
                        ForEach(notes, id: \.self) { note in
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(rule?.name ?? siteId)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // A book already bookmarked from this source is the safest probe
            // there is: it is known to exist on the site, so an empty result set
            // means the search derivation failed rather than the word being rare.
            if probe.isEmpty {
                probe = env.books.first { $0.siteId == siteId }?.title ?? ""
            }
        }
    }

    @ViewBuilder
    private func searchSection(_ rule: SiteRule) -> some View {
        Section {
            TextField("search.derive.probe", text: $probe)
                .autocorrectionDisabled()
                .accessibilityIdentifier("site.search.probe")
            Button {
                Task { await deriveSearch(rule) }
            } label: {
                if isWorking {
                    HStack { ProgressView(); Text("derive.analysing") }
                } else {
                    Text("search.derive.start")
                }
            }
            .disabled(probe.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
            .accessibilityIdentifier("site.search.derive")
        } header: {
            Text("search.derive.title")
        } footer: {
            Text("search.derive.footer")
        }

        if let error {
            Section { Text(error).font(.footnote).foregroundStyle(.red) }
        }

        if let derived {
            Section {
                ForEach(derived.sampleTitles, id: \.self) { title in
                    Text(title).font(.footnote)
                }
                Button("search.derive.save") { save(rule, derived.search) }
                    .accessibilityIdentifier("site.search.save")
            } header: {
                Text("derive.preview")
            }
        }
    }

    private func deriveSearch(_ rule: SiteRule) async {
        isWorking = true
        error = nil
        derived = nil
        defer { isWorking = false }
        do {
            derived = try await SearchDeriver(fetcher: env.fetcher)
                .derive(for: rule, probe: probe.trimmingCharacters(in: .whitespaces))
        } catch {
            env.report(error)
            self.error = error.localizedDescription
        }
    }

    private func save(_ rule: SiteRule, _ search: SiteRule.Search) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            // Same id, so this replaces the stored rule in place and every
            // bookmark under it keeps working.
            try env.sites.importRule(data: encoder.encode(rule.settingSearch(search)))
            derived = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
