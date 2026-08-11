import Foundation

/// The parts of an EPUB the importer needs: the book's own metadata, and the
/// reading order with each document's bytes and its table-of-contents title.
///
/// Only the structure is parsed here. The chapter *text* is not: that is
/// `ExtractorScript`'s job, run against the XHTML in the app's web view, so an
/// imported book and a fetched page go through exactly the same normalisation.
struct EpubDocument {
    struct Item {
        /// Path inside the archive. Kept for diagnosis when a book comes out
        /// with chapters in an order nobody expected.
        let path: String
        /// Title as the book's own table of contents gives it. Preferred over
        /// anything found in the document, because the toc is where the author
        /// wrote the names the reader is supposed to see.
        let tocTitle: String?
        let xhtml: Data
    }

    let title: String?
    let author: String?
    /// Spine order — the reading order. Documents the archive does not actually
    /// contain are dropped.
    let items: [Item]

    static func parse(_ data: Data) throws -> EpubDocument {
        let archive = try ZipArchive(data: data)

        guard let containerData = try archive.data(named: "META-INF/container.xml"),
              let container = XMLTree.parse(containerData),
              let opfPath = container.first("rootfile")?.attributes["full-path"]
        else {
            throw LocalBookError.malformed("no readable META-INF/container.xml")
        }
        guard let opfData = try archive.data(named: opfPath),
              let opf = XMLTree.parse(opfData)
        else {
            throw LocalBookError.malformed("package document \(opfPath) is missing or unreadable")
        }
        let opfDirectory = directory(of: opfPath)

        let metadata = opf.first("metadata")
        let manifest = manifest(in: opf)
        let tocTitles = tableOfContents(
            archive: archive, opf: opf, manifest: manifest, opfDirectory: opfDirectory
        )

        var items: [Item] = []
        for path in spine(in: opf, manifest: manifest, opfDirectory: opfDirectory) {
            // A spine entry whose document is missing is skipped rather than
            // fatal. The rest of the book is still worth reading, and the
            // chapter count on screen is what tells the user something is off.
            guard let xhtml = try archive.data(named: path) else { continue }
            items.append(Item(path: path, tocTitle: tocTitles[path], xhtml: xhtml))
        }
        guard !items.isEmpty else { throw LocalBookError.empty }

        return EpubDocument(
            title: metadata?.first("title")?.text,
            author: metadata?.first("creator")?.text,
            items: items
        )
    }

    // MARK: - Package document

    private struct ManifestItem {
        let href: String
        let mediaType: String
        let properties: String
    }

    private static func manifest(in opf: XMLTree) -> [String: ManifestItem] {
        var manifest: [String: ManifestItem] = [:]
        for item in opf.first("manifest")?.all("item") ?? [] {
            guard let id = item.attributes["id"], let href = item.attributes["href"] else { continue }
            manifest[id] = ManifestItem(
                href: href,
                mediaType: item.attributes["media-type"] ?? "",
                properties: item.attributes["properties"] ?? ""
            )
        }
        return manifest
    }

    /// Archive paths in reading order.
    ///
    /// `linear="no"` entries are left out because that is precisely what the
    /// attribute means: the document is reachable from the book but is not part
    /// of the linear reading order — copyright plates, footnote collections,
    /// sometimes the nav document itself.
    private static func spine(
        in opf: XMLTree, manifest: [String: ManifestItem], opfDirectory: String
    ) -> [String] {
        (opf.first("spine")?.all("itemref") ?? []).compactMap { reference in
            guard reference.attributes["linear"]?.lowercased() != "no",
                  let idref = reference.attributes["idref"],
                  let item = manifest[idref]
            else { return nil }
            return resolve(item.href, relativeTo: opfDirectory)
        }
    }

    // MARK: - Table of contents

    /// Archive path → chapter title, from whichever table of contents the book
    /// carries. EPUB 3's nav document is tried first and `toc.ncx` second, which
    /// is the same order a reading system is required to prefer them in; EPUB 3
    /// books often ship both, and the ncx in them is the legacy copy.
    ///
    /// A toc that cannot be parsed yields an empty map rather than an error: the
    /// importer falls back to each document's own heading, which is a worse
    /// chapter name but not a failed import.
    private static func tableOfContents(
        archive: ZipArchive,
        opf: XMLTree,
        manifest: [String: ManifestItem],
        opfDirectory: String
    ) -> [String: String] {
        if let nav = manifest.values.first(where: { $0.properties.contains("nav") }),
           let titles = try? navigationTitles(archive: archive, href: nav.href, opfDirectory: opfDirectory),
           !titles.isEmpty {
            return titles
        }
        let ncxHref = opf.first("spine")?.attributes["toc"].flatMap { manifest[$0]?.href }
            ?? manifest.values.first { $0.mediaType == "application/x-dtbncx+xml" }?.href
        guard let ncxHref,
              let titles = try? ncxTitles(archive: archive, href: ncxHref, opfDirectory: opfDirectory)
        else { return [:] }
        return titles
    }

    private static func navigationTitles(
        archive: ZipArchive, href: String, opfDirectory: String
    ) throws -> [String: String] {
        let path = resolve(href, relativeTo: opfDirectory)
        guard let data = try archive.data(named: path), let document = XMLTree.parse(data) else {
            return [:]
        }
        // A nav document may hold several lists — toc, landmarks, page-list —
        // and only the one typed `toc` names chapters.
        let toc = document.all("nav").first { $0.attributes["type"]?.contains("toc") == true }
            ?? document.all("nav").first
        guard let toc else { return [:] }
        var titles: [String: String] = [:]
        for link in toc.all("a") {
            guard let target = link.attributes["href"] else { continue }
            add(link.text, for: resolve(target, relativeTo: directory(of: path)), to: &titles)
        }
        return titles
    }

    private static func ncxTitles(
        archive: ZipArchive, href: String, opfDirectory: String
    ) throws -> [String: String] {
        let path = resolve(href, relativeTo: opfDirectory)
        guard let data = try archive.data(named: path), let document = XMLTree.parse(data) else {
            return [:]
        }
        var titles: [String: String] = [:]
        for point in document.all("navPoint") {
            guard let target = point.first("content")?.attributes["src"],
                  let label = point.first("text")?.text
            else { continue }
            add(label, for: resolve(target, relativeTo: directory(of: path)), to: &titles)
        }
        return titles
    }

    /// First title wins. A toc routinely points at the same document more than
    /// once through fragments — one entry per section of a long chapter — and the
    /// first of those is the one that names the chapter as a whole.
    private static func add(_ title: String, for path: String, to titles: inout [String: String]) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, titles[path] == nil else { return }
        titles[path] = trimmed
    }

    // MARK: - Paths

    /// Turns an href into an archive path.
    ///
    /// Percent-decoded because hrefs are URLs while ZIP entry names are not: a
    /// book with a space in a filename writes `chapter%201.xhtml` in its OPF and
    /// `chapter 1.xhtml` in the archive.
    static func resolve(_ href: String, relativeTo directory: String) -> String {
        let withoutFragment = String(href.prefix { $0 != "#" })
        let decoded = withoutFragment.removingPercentEncoding ?? withoutFragment
        var parts = directory.isEmpty ? [] : directory.split(separator: "/").map(String.init)
        for part in decoded.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(String(part))
            }
        }
        return parts.joined(separator: "/")
    }

    static func directory(of path: String) -> String {
        var parts = path.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return "" }
        parts.removeLast()
        return parts.joined(separator: "/")
    }
}
