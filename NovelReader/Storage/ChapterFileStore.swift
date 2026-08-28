import CryptoKit
import Foundation

/// Stores downloaded chapter text on disk as `{root}/{site}/{book}/{chapter}.txt`.
///
/// Text lives in files rather than the database because it is write-once,
/// read-sequentially bulk data, and because the bulk-delete scopes required by
/// the product (chapter / book / site / everything) map exactly onto removing a
/// file or a directory subtree.
struct ChapterFileStore {
    /// The four levels of "delete downloads" the product requires.
    enum Scope: Equatable {
        case chapter(siteId: String, siteBookId: String, siteChapterId: String)
        case book(siteId: String, siteBookId: String)
        case site(siteId: String)
        case everything
    }

    let root: URL
    private let fileManager: FileManager

    init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    /// Default location: Application Support/Chapters.
    static func makeShared(fileManager: FileManager = .default) throws -> ChapterFileStore {
        let base = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        return ChapterFileStore(root: base.appendingPathComponent("Chapters"), fileManager: fileManager)
    }

    // MARK: - Paths

    func directory(siteId: String) -> URL {
        root.appendingPathComponent(Self.safeComponent(siteId), isDirectory: true)
    }

    func directory(siteId: String, siteBookId: String) -> URL {
        directory(siteId: siteId)
            .appendingPathComponent(Self.safeComponent(siteBookId), isDirectory: true)
    }

    func fileURL(siteId: String, siteBookId: String, siteChapterId: String) -> URL {
        directory(siteId: siteId, siteBookId: siteBookId)
            .appendingPathComponent(Self.safeComponent(siteChapterId))
            .appendingPathExtension("txt")
    }

    /// Where a comic chapter's pages live: a directory beside the novels' `.txt`
    /// files, holding one numbered file per page.
    ///
    /// The same tree on purpose. A chapter of a comic is the same thing to everything
    /// above this as a chapter of a novel — something a book owns, that a delete scope
    /// covers and the storage screen counts — and the four delete levels and the size
    /// recursion both work on a directory without knowing what is in it. A second tree
    /// would be two of everything for no answer either one gives better.
    ///
    /// Page count is the number of files and page order is their numbers. No manifest:
    /// a list of what should be there, kept beside what is there, is a second truth to
    /// disagree with the first.
    func pageDirectory(siteId: String, siteBookId: String, siteChapterId: String) -> URL {
        directory(siteId: siteId, siteBookId: siteBookId)
            .appendingPathComponent(Self.safeComponent(siteChapterId), isDirectory: true)
    }

    /// Ids arrive from user-imported rule files and from remote URLs, so a raw
    /// id can legitimately contain `/`, `..`, or characters no filesystem wants.
    /// Whitelist the allowed set, then disambiguate with a hash whenever the
    /// sanitised form differs from the original — otherwise two distinct ids
    /// could collapse onto the same file and silently serve the wrong chapter.
    static func safeComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        var sanitised = ""
        for scalar in raw.unicodeScalars {
            sanitised.append(allowed.contains(scalar) ? Character(scalar) : "_")
        }
        guard sanitised != raw || sanitised.isEmpty else { return sanitised }
        let digest = SHA256.hash(data: Data(raw.utf8))
            .prefix(6)
            .map { String(format: "%02x", $0) }
            .joined()
        // Cap the readable part so deep paths stay well inside PATH_MAX.
        return String(sanitised.prefix(48)) + "-" + digest
    }

    // MARK: - Read / write

    func write(paragraphs: [String], siteId: String, siteBookId: String, siteChapterId: String) throws {
        let url = fileURL(siteId: siteId, siteBookId: siteBookId, siteChapterId: siteChapterId)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try paragraphs.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    func readParagraphs(siteId: String, siteBookId: String, siteChapterId: String) throws -> [String] {
        let url = fileURL(siteId: siteId, siteBookId: siteBookId, siteChapterId: siteChapterId)
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    func exists(siteId: String, siteBookId: String, siteChapterId: String) -> Bool {
        fileManager.fileExists(
            atPath: fileURL(siteId: siteId, siteBookId: siteBookId, siteChapterId: siteChapterId).path
        )
    }

    // MARK: - Pages

    /// Writes a comic chapter's pages, all of them or none of them.
    ///
    /// Through a `.partial` directory that is renamed into place once every page has
    /// landed, because the promise the rest of the app is built on — `downloadedAt` is
    /// not null *if and only if* there is a complete, readable chapter on the device —
    /// must not get weaker because a chapter became fifty files instead of one. A
    /// process killed mid-write leaves a `.partial` nobody looks in, and the next
    /// attempt at the same chapter clears it.
    ///
    /// The one window left is the same one novels have always had: between removing an
    /// older copy and renaming the new one in, a crash leaves the flag set and the
    /// files gone. Everything that reads a chapter already treats missing text as
    /// missing rather than trusting the flag — see `BookExporter.paragraphs(of:in:)`.
    func writePages(
        _ pages: [Data], siteId: String, siteBookId: String, siteChapterId: String
    ) throws {
        let final = pageDirectory(siteId: siteId, siteBookId: siteBookId, siteChapterId: siteChapterId)
        let partial = final.appendingPathExtension("partial")
        if fileManager.fileExists(atPath: partial.path) {
            try fileManager.removeItem(at: partial)
        }
        try fileManager.createDirectory(at: partial, withIntermediateDirectories: true)
        for (index, bytes) in pages.enumerated() {
            // The extension comes from the bytes rather than from the address it was
            // fetched from: these CDNs serve `.jpg` URLs holding WebP often enough that
            // the address is not evidence. Nothing reads it back — pages are found by
            // number and decoded by sniffing — so it is there for whoever opens the
            // folder, and being honest costs nothing.
            let name = String(format: "%03d", index)
            let file = ImageFormat(sniffing: bytes)
                .map { partial.appendingPathComponent(name).appendingPathExtension($0.fileExtension) }
                ?? partial.appendingPathComponent(name)
            try bytes.write(to: file, options: .atomic)
        }
        if fileManager.fileExists(atPath: final.path) {
            try fileManager.removeItem(at: final)
        }
        try fileManager.moveItem(at: partial, to: final)
    }

    /// A downloaded chapter's pages, in reading order.
    ///
    /// Sorted by the number in the name rather than by the name, so a chapter of more
    /// than a thousand pages does not read back with page 1000 between 099 and 100.
    /// Empty for a chapter that is not downloaded, which is also the answer for one
    /// whose directory is there and empty — a chapter of no pages is not readable, and
    /// saying so here is what keeps the caller from having to ask twice.
    func pageURLs(siteId: String, siteBookId: String, siteChapterId: String) -> [URL] {
        let directory = pageDirectory(
            siteId: siteId, siteBookId: siteBookId, siteChapterId: siteChapterId
        )
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return names
            .compactMap { name -> (Int, URL)? in
                guard let number = Int(name.prefix { $0.isNumber }) else { return nil }
                return (number, directory.appendingPathComponent(name))
            }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
    }

    func hasPages(siteId: String, siteBookId: String, siteChapterId: String) -> Bool {
        !pageURLs(siteId: siteId, siteBookId: siteBookId, siteChapterId: siteChapterId).isEmpty
    }

    // MARK: - Delete

    /// Every path a scope covers.
    ///
    /// One for all of them but a chapter, which is where the two media differ: a novel
    /// chapter is a file and a comic chapter is a directory of pages, and a book can
    /// only ever be one of those — but the scope names a chapter, not a kind, and
    /// asking the caller which shape to delete would be asking it to know something it
    /// has no reason to. A leftover `.partial` from a download that died mid-write goes
    /// with them, since it is this chapter's and nothing will ever read it.
    private func targets(for scope: Scope) -> [URL] {
        switch scope {
        case let .chapter(siteId, siteBookId, siteChapterId):
            let pages = pageDirectory(
                siteId: siteId, siteBookId: siteBookId, siteChapterId: siteChapterId
            )
            return [
                fileURL(siteId: siteId, siteBookId: siteBookId, siteChapterId: siteChapterId),
                pages,
                pages.appendingPathExtension("partial"),
            ]
        case let .book(siteId, siteBookId):
            return [directory(siteId: siteId, siteBookId: siteBookId)]
        case let .site(siteId):
            return [directory(siteId: siteId)]
        case .everything:
            return [root]
        }
    }

    /// Removes the files covered by `scope`. Missing paths are not an error:
    /// deletion is idempotent so a retry after a partial failure still converges.
    func delete(_ scope: Scope) throws {
        for target in targets(for: scope) where fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
    }

    /// Bytes on disk under `scope`, for the storage screen.
    func size(of scope: Scope) -> Int64 {
        targets(for: scope).reduce(0) { $0 + Self.totalSize(at: $1, fileManager: fileManager) }
    }

    private static func totalSize(at url: URL, fileManager: FileManager) -> Int64 {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            let attrs = try? fileManager.attributesOfItem(atPath: url.path)
            return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }
        guard let e = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let child as URL in e {
            let values = try? child.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }
}
