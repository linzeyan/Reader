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

    // MARK: - Delete

    /// Removes the files covered by `scope`. Missing paths are not an error:
    /// deletion is idempotent so a retry after a partial failure still converges.
    func delete(_ scope: Scope) throws {
        let target: URL
        switch scope {
        case let .chapter(siteId, siteBookId, siteChapterId):
            target = fileURL(siteId: siteId, siteBookId: siteBookId, siteChapterId: siteChapterId)
        case let .book(siteId, siteBookId):
            target = directory(siteId: siteId, siteBookId: siteBookId)
        case let .site(siteId):
            target = directory(siteId: siteId)
        case .everything:
            target = root
        }
        guard fileManager.fileExists(atPath: target.path) else { return }
        try fileManager.removeItem(at: target)
    }

    /// Bytes on disk under `scope`, for the storage screen.
    func size(of scope: Scope) -> Int64 {
        let target: URL
        switch scope {
        case let .chapter(siteId, siteBookId, siteChapterId):
            target = fileURL(siteId: siteId, siteBookId: siteBookId, siteChapterId: siteChapterId)
        case let .book(siteId, siteBookId):
            target = directory(siteId: siteId, siteBookId: siteBookId)
        case let .site(siteId):
            target = directory(siteId: siteId)
        case .everything:
            target = root
        }
        return Self.totalSize(at: target, fileManager: fileManager)
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
