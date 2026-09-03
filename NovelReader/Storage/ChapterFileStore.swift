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

    /// Where an article's structure lives: the blocks, as JSON, beside the `.txt` a novel
    /// chapter of the same book would have.
    ///
    /// A second file rather than a replacement for the text one, because they hold
    /// different things and only feeds have both. What is stored here is the article as it
    /// will be laid out — headings, listings, the addresses of its links, the file names of
    /// its pictures — and none of that survives the flattening into lines that `.txt` is.
    func blocksURL(siteId: String, siteBookId: String, siteChapterId: String) -> URL {
        directory(siteId: siteId, siteBookId: siteBookId)
            .appendingPathComponent(Self.safeComponent(siteChapterId))
            .appendingPathExtension("json")
    }

    /// Where an article's pictures live — the same directory a comic chapter's pages would
    /// use, and deliberately so.
    ///
    /// A chapter is only ever one kind, so the two can never both be there; and sharing
    /// the path means the delete scopes, the size recursion and the storage screen already
    /// know about article images without being told. The alternative is a third tree and
    /// three of everything that walks one.
    func imageDirectory(siteId: String, siteBookId: String, siteChapterId: String) -> URL {
        pageDirectory(siteId: siteId, siteBookId: siteBookId, siteChapterId: siteChapterId)
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

    /// Writes an article's blocks, and the plain text beside them.
    ///
    /// Both, always. The text file is what every part of this app that predates articles
    /// reads — the export to txt and EPUB, the cache accounting, `readParagraphs` — and
    /// keeping it in step here is what let structure be added without teaching any of them
    /// about blocks. It is also the answer if the JSON is ever unreadable: the article
    /// still opens, as prose.
    func write(
        blocks: [ArticleBlock], siteId: String, siteBookId: String, siteChapterId: String
    ) throws {
        let url = blocksURL(siteId: siteId, siteBookId: siteBookId, siteChapterId: siteChapterId)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONEncoder().encode(blocks).write(to: url, options: .atomic)
        try write(
            paragraphs: blocks.map(\.plainText).filter { !$0.isEmpty },
            siteId: siteId, siteBookId: siteBookId, siteChapterId: siteChapterId
        )
    }

    /// The article's blocks, or nil where there are none — an article stored before this
    /// app knew about structure, or a chapter of a novel, both of which read as prose.
    func readBlocks(siteId: String, siteBookId: String, siteChapterId: String) -> [ArticleBlock]? {
        let url = blocksURL(siteId: siteId, siteBookId: siteBookId, siteChapterId: siteChapterId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([ArticleBlock].self, from: data)
    }

    /// Stores one of an article's pictures under a name the blocks refer to it by.
    func write(
        image data: Data, named name: String,
        siteId: String, siteBookId: String, siteChapterId: String
    ) throws {
        let directory = imageDirectory(
            siteId: siteId, siteBookId: siteBookId, siteChapterId: siteChapterId
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    func exists(siteId: String, siteBookId: String, siteChapterId: String) -> Bool {
        fileManager.fileExists(
            atPath: fileURL(siteId: siteId, siteBookId: siteBookId, siteChapterId: siteChapterId).path
        )
    }

    // MARK: - Pages

    /// Writes a comic chapter's pages, the whole chapter or none of it.
    ///
    /// Through a `.partial` directory that is renamed into place once every page has
    /// landed, because the promise the rest of the app is built on — `downloadedAt` is
    /// not null *if and only if* there is a readable chapter on the device — must not
    /// get weaker because a chapter became fifty files instead of one. A process killed
    /// mid-write leaves a `.partial` nobody looks in, and the next attempt at the same
    /// chapter clears it.
    ///
    /// A `nil` page is one the site would not give up (see `ImageFetcher.chapterImages`)
    /// and is written as an empty `.missing` file rather than left out. Left out, every
    /// page after it would shift up a number and the chapter would read as complete
    /// while being short; written, the numbering is the site's own, the gap is visible
    /// to anyone who opens the folder, and the reader can say which page is absent
    /// instead of showing one that never fills in.
    ///
    /// The one window left is the same one novels have always had: between removing an
    /// older copy and renaming the new one in, a crash leaves the flag set and the
    /// files gone. Everything that reads a chapter already treats missing text as
    /// missing rather than trusting the flag — see `BookExporter.paragraphs(of:in:)`.
    func writePages(
        _ pages: [Data?], siteId: String, siteBookId: String, siteChapterId: String
    ) throws {
        let final = pageDirectory(siteId: siteId, siteBookId: siteBookId, siteChapterId: siteChapterId)
        let partial = final.appendingPathExtension("partial")
        if fileManager.fileExists(atPath: partial.path) {
            try fileManager.removeItem(at: partial)
        }
        try fileManager.createDirectory(at: partial, withIntermediateDirectories: true)
        for (index, page) in pages.enumerated() {
            let name = String(format: "%03d", index)
            guard let bytes = page else {
                try Data().write(
                    to: partial.appendingPathComponent(name)
                        .appendingPathExtension(Self.gapExtension),
                    options: .atomic
                )
                continue
            }
            // The extension comes from the bytes rather than from the address it was
            // fetched from: these CDNs serve `.jpg` URLs holding WebP often enough that
            // the address is not evidence. Nothing reads it back — pages are found by
            // number and decoded by sniffing — so it is there for whoever opens the
            // folder, and being honest costs nothing.
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

    /// What a page the site would not give up is called on disk: `012.missing`, empty,
    /// holding page 12's place in the numbering.
    static let gapExtension = "missing"

    static func isGap(_ url: URL) -> Bool { url.pathExtension == gapExtension }

    /// Fills in a gap in a chapter that is already on the device.
    ///
    /// The one page a reader asked for again and got — see `ComicReaderModel.opening`.
    /// Written straight into the finished directory rather than through `.partial`,
    /// because that is for a chapter appearing all at once and this is a chapter that is
    /// already there and getting better. The real page lands first and the marker goes
    /// afterwards, so the crash in between leaves both — which `pageURLs` resolves in
    /// favour of the page, since the alternative order leaves the chapter one page short
    /// with nothing to say so.
    ///
    /// Does nothing when the chapter is not on disk after all: healing a gap in
    /// something that was deleted while it was open would recreate one page of it.
    func fillPage(
        _ bytes: Data, index: Int, siteId: String, siteBookId: String, siteChapterId: String
    ) throws {
        let directory = pageDirectory(
            siteId: siteId, siteBookId: siteBookId, siteChapterId: siteChapterId
        )
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return }
        let name = String(format: "%03d", index)
        let file = ImageFormat(sniffing: bytes)
            .map { directory.appendingPathComponent(name).appendingPathExtension($0.fileExtension) }
            ?? directory.appendingPathComponent(name)
        try bytes.write(to: file, options: .atomic)
        try? fileManager.removeItem(
            at: directory.appendingPathComponent(name).appendingPathExtension(Self.gapExtension)
        )
    }

    /// A downloaded chapter's pages, in reading order.
    ///
    /// Sorted by the number in the name rather than by the name, so a chapter of more
    /// than a thousand pages does not read back with page 1000 between 099 and 100.
    /// Empty for a chapter that is not downloaded, which is also the answer for one
    /// whose directory is there and empty — a chapter of no pages is not readable, and
    /// saying so here is what keeps the caller from having to ask twice.
    ///
    /// One number, one page: a real page wins over a marker for the same number, which
    /// is the state `fillPage` leaves behind if it is interrupted. Two entries for page
    /// 12 would make the chapter one page longer than it is, and every page after it
    /// off by one.
    func pageURLs(siteId: String, siteBookId: String, siteChapterId: String) -> [URL] {
        let directory = pageDirectory(
            siteId: siteId, siteBookId: siteBookId, siteChapterId: siteChapterId
        )
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        var byNumber: [Int: URL] = [:]
        for name in names {
            guard let number = Int(name.prefix { $0.isNumber }) else { continue }
            let url = directory.appendingPathComponent(name)
            if let existing = byNumber[number], !Self.isGap(existing) { continue }
            byNumber[number] = url
        }
        return byNumber.sorted { $0.key < $1.key }.map(\.value)
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
                blocksURL(siteId: siteId, siteBookId: siteBookId, siteChapterId: siteChapterId),
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

    /// Bytes under one path, whatever is there — a novel chapter's file, a comic
    /// chapter's directory of pages.
    ///
    /// For `ChapterCache`, which weighs chapters against each other before it throws the
    /// oldest away. A scope cannot say this: it names a chapter by its ids, and the cache
    /// is holding the entries it found by walking, whose ids it never learns.
    func size(at url: URL) -> Int64 {
        Self.totalSize(at: url, fileManager: fileManager)
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
