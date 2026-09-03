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

    /// The page a bookmarked book was read from.
    ///
    /// Rebuilt from the rule's template rather than stored on the book: a book
    /// only ever knew its source id and the id that source gave it, and the
    /// template is the one place that says how those become a URL. So the two
    /// books that cannot answer are the two that have no template — one imported
    /// from a file, which was never on the web, and one whose rule the user has
    /// removed. Both get nil rather than a guessed address.
    func sourceURL(of book: Book) -> URL? {
        // A subscription needs no template and has no rule: its `siteBookId` already *is*
        // the address, which is also the one worth copying — handing someone a feed's
        // address is how a subscription is passed on.
        if book.kind == .feed { return URL(string: book.siteBookId) }
        guard book.hasRule else { return nil }
        return rule(id: book.siteId)?.bookURL(bookId: book.siteBookId)
    }

    /// What to call a source on screen.
    ///
    /// `Book.localSiteId` is named here because it has no rule file and never
    /// will: it is the reserved source for imported files. Falling through to the
    /// raw id — which is what bookmarks of a *removed* rule correctly do, so that
    /// reinstalling the rule brings the name back — would label a shelf of the
    /// user's own files "local".
    func name(ofSite siteId: String) -> String {
        if siteId == Book.localSiteId { return String(localized: "site.local") }
        // Named here for the same reason: it has no rule file and never will. Every
        // subscription shares this one id — what tells them apart is the address in
        // `siteBookId` — so the shelf's grouping puts them together under one heading,
        // which is what a reader with both novels and feeds would draw by hand.
        if siteId == Book.feedSiteId { return String(localized: "site.feed") }
        return rule(id: siteId)?.name ?? siteId
    }

    /// Sites that declare a `search` block, in the order the UI should try them.
    var searchableRules: [SiteRule] { rules.filter { $0.search != nil } }

    /// The sources that publish one medium, in installed order.
    ///
    /// Every screen that shows sources is about one medium at a time — the shelf's
    /// mode, the search's mode, the two sections the settings list is split into — so
    /// the filter is written once here rather than as a `filter` at each of them.
    func rules(of kind: SiteRule.Kind) -> [SiteRule] { rules.filter { $0.kind == kind } }

    // MARK: - Import / remove

    @discardableResult
    func importRule(data: Data) throws -> SiteRule {
        let rule: SiteRule
        do {
            rule = try JSONDecoder().decode(SiteRule.self, from: data)
        } catch {
            throw ImportError.malformed(error.localizedDescription)
        }
        // `Book.localSiteId` belongs to imported files. A rule claiming it would
        // take over those books' screens — they would be labelled with the site's
        // name and offer to refetch a catalog from a site that has never seen
        // them — so the id is refused rather than allowed to collide.
        guard rule.id != Book.localSiteId else {
            throw ImportError.malformed("the source id \"\(Book.localSiteId)\" is reserved")
        }
        // A rule that cannot read a chapter is refused here rather than installed
        // and discovered later. The reader has nowhere honest to go with it: the
        // block is missing, so there is nothing to fall back to and nothing to
        // tell the user beyond "this chapter is empty". Caught while they are
        // looking at an import sheet, the same fact is actionable.
        switch rule.kind {
        case .novel where rule.chapter == nil:
            throw ImportError.malformed("a novel source needs a \"chapter\" block")
        case .comic where rule.images == nil:
            throw ImportError.malformed("a comic source needs an \"images\" block")
        case .feed:
            // A feed describes itself, so there is nothing for a rule to say about one
            // and no code path that would read this file. Installed, it would be a
            // source listed in settings that no book can ever be added through — and one
            // whose id a real subscription could then collide with.
            throw ImportError.malformed("a feed is subscribed to by address, not by rule")
        default:
            break
        }
        // A sign-in block names a page the app will show full screen, with a
        // keyboard in front of it, because the rule said the reader has to sign in.
        // Rule files travel between users, so that address has to belong to the
        // site the rule is for — otherwise a rule for a site you trust can put a
        // lookalike login form in front of you, and the only thing standing between
        // you and typing a password into it is the host label on the sheet.
        //
        // Refused rather than dropped: a rule whose sign-in points elsewhere is not
        // a rule with one bad field, and installing the rest of it as if the author
        // simply made a typo is a guess this has no business making.
        if let signIn = rule.signIn {
            guard let url = signIn.signInURL,
                  url.host()?.caseInsensitiveCompare(rule.host) == .orderedSame
            else {
                throw ImportError.malformed(
                    "the \"signIn\" address must be on \(rule.host)"
                )
            }
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
