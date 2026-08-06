import Foundation

/// The set of site rules the user has installed.
///
/// The app binary ships with no rules (App Review 5.2 — it must not point at any
/// particular content source), so this store is the only way a source exists.
/// Rules live as individual JSON files rather than one blob so that importing a
/// broken rule can never corrupt the ones already working.
@MainActor
@Observable
final class SiteStore {
    enum ImportError: LocalizedError {
        case unreadable
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .unreadable: return String(localized: "rules.import.error.unreadable")
            case .malformed(let detail): return String(localized: "rules.import.error.malformed") + "\n" + detail
            }
        }
    }

    private(set) var rules: [SiteRule] = []

    private let directory: URL
    private let fileManager: FileManager

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    static func makeShared() throws -> SiteStore {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let store = SiteStore(directory: base.appendingPathComponent("Rules", isDirectory: true))
        try store.load()
        return store
    }

    // MARK: - Loading

    func load() throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        #if DEBUG
        // Screenshot runs install their own fictional sources; re-seeding the
        // recon rules on every load would put the real sites straight back.
        if !DemoSeed.isRequested { seedDevelopmentRules() }
        #endif
        let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        rules = files
            .filter { $0.pathExtension.lowercased() == "json" }
            // A rule that no longer decodes is skipped rather than fatal: one bad
            // file must not take the user's whole source list down with it.
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(SiteRule.self, from: data)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Lookup

    func rule(id: String) -> SiteRule? { rules.first { $0.id == id } }

    /// Which installed rule can read this URL — the entry point for "paste a link".
    func rule(matching url: URL) -> SiteRule? { rules.first { $0.matches(url) } }

    func name(ofSite siteId: String) -> String { rule(id: siteId)?.name ?? siteId }

    /// Sites that declare a `search` block, in the order the UI should try them.
    var searchableRules: [SiteRule] { rules.filter { $0.search != nil } }

    // MARK: - Import / remove

    @discardableResult
    func importRule(data: Data) throws -> SiteRule {
        let rule: SiteRule
        do {
            rule = try JSONDecoder().decode(SiteRule.self, from: data)
        } catch {
            throw ImportError.malformed(error.localizedDescription)
        }
        let target = directory.appendingPathComponent(
            ChapterFileStore.safeComponent(rule.id)
        ).appendingPathExtension("json")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // Re-encode rather than copying the bytes: what lands on disk is then
        // guaranteed to be something this build can read back.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(rule).write(to: target, options: .atomic)
        try load()
        return rule
    }

    @discardableResult
    func importRule(from url: URL) throws -> SiteRule {
        // Files handed over by the document picker live outside the sandbox.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { throw ImportError.unreadable }
        return try importRule(data: data)
    }

    /// Fetches a rule published at a URL and imports it.
    ///
    /// Plain `URLSession` rather than the shared `WebFetcher`: a rule file is a
    /// static JSON document on whatever host its author chose, not one of the
    /// challenged novel sites, and routing it through the one web view would
    /// evict whatever page a download is part-way through reading.
    @discardableResult
    func importRule(fromRemote url: URL) async throws -> SiteRule {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw ImportError.unreadable
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let data: Data
        do {
            let (payload, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ImportError.malformed("HTTP \(http.statusCode)")
            }
            data = payload
        } catch let error as ImportError {
            throw error
        } catch {
            throw ImportError.unreadable
        }
        return try importRule(data: data)
    }

    /// Where a rule is stored, for sharing it out.
    ///
    /// Handing over the file on disk rather than re-encoding into a temporary
    /// copy: it is the exact bytes the app reads back, so a rule that works here
    /// is the rule that arrives on the other device.
    func fileURL(forRuleId id: String) -> URL? {
        let target = directory.appendingPathComponent(
            ChapterFileStore.safeComponent(id)
        ).appendingPathExtension("json")
        return fileManager.fileExists(atPath: target.path) ? target : nil
    }

    func remove(id: String) throws {
        let target = directory.appendingPathComponent(
            ChapterFileStore.safeComponent(id)
        ).appendingPathExtension("json")
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        try load()
    }

    // MARK: - Development seeding

    #if DEBUG
    /// Copies the recon rules bundled by the Debug-only build phase into the store.
    ///
    /// Debug-only on purpose: the shipping binary must contain no site rules at
    /// all, but the UI cannot be exercised in a simulator without sources. The
    /// build phase that produces `DevSiteRules` is likewise gated on Debug, so a
    /// Release build has neither the folder nor this code path.
    ///
    /// Overwrites on every launch rather than seeding once. Seeding-if-absent
    /// looks safer but is actively wrong here: fixing a selector in the repo then
    /// rebuilding left the simulator running the *old* rule, because the file
    /// already existed — which cost a debugging session chasing a fix that had in
    /// fact landed. These are fixtures, not user data.
    private func seedDevelopmentRules() {
        guard let seedFolder = Bundle.main.url(forResource: "DevSiteRules", withExtension: nil),
              let seeds = try? fileManager.contentsOfDirectory(at: seedFolder, includingPropertiesForKeys: nil)
        else { return }
        for seed in seeds where seed.pathExtension.lowercased() == "json" {
            let target = directory.appendingPathComponent(seed.lastPathComponent)
            try? fileManager.removeItem(at: target)
            try? fileManager.copyItem(at: seed, to: target)
        }
    }
    #endif
}
