import Foundation

/// Keeps one cover image per book on disk, at `{root}/{site}/{book}`.
///
/// Its own store rather than a corner of `ChapterFileStore`, though it borrows that
/// one's naming. `ChapterFileStore` holds *downloads*, and "delete downloads" is
/// something the reader asks for to get space back — sweeping the covers away with it
/// would answer a question nobody asked, and leave a shelf of grey rectangles as the
/// visible result of reclaiming 40KB. A cover belongs to the book: it arrives when the
/// book does and goes when the book goes, which is the one place a book stops existing
/// (`AppEnvironment.removeBookmark`).
///
/// Why on disk at all, when the covers were drawn straight from the network before:
/// three of the four comic sites answer 403 to a request with no `Referer`, and
/// `AsyncImage` cannot send one. Once the bytes have to be fetched by hand there is
/// nowhere sensible to put them but a file — `URLCache` was where they used to live,
/// and a cache that evicts under pressure is not where a shelf's appearance should be
/// stored.
struct CoverStore {
    let root: URL
    private let fileManager: FileManager

    init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    /// Default location: Application Support/Covers.
    static func makeShared(fileManager: FileManager = .default) throws -> CoverStore {
        let base = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        return CoverStore(root: base.appendingPathComponent("Covers"), fileManager: fileManager)
    }

    /// Where this book's cover lives, whether or not it is there yet.
    ///
    /// No file extension. The bytes are stored exactly as the site served them and
    /// their format is read back out of them (`ImageFormat`), so there is one path per
    /// book instead of a lookup across the four names it might have been saved under.
    func fileURL(for book: Book) -> URL {
        root.appendingPathComponent(ChapterFileStore.safeComponent(book.siteId), isDirectory: true)
            .appendingPathComponent(ChapterFileStore.safeComponent(book.siteBookId))
    }

    func has(_ book: Book) -> Bool {
        fileManager.fileExists(atPath: fileURL(for: book).path)
    }

    func data(for book: Book) -> Data? {
        try? Data(contentsOf: fileURL(for: book))
    }

    func save(_ data: Data, for book: Book) throws {
        let url = fileURL(for: book)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Atomically, because the shelf reads this file the moment it appears: a
        // half-written cover would be drawn as a broken one and then cached as such.
        try data.write(to: url, options: .atomic)
    }

    /// Missing paths are not an error — deletion is idempotent, so a retry after a
    /// partial failure still converges. Same contract as `ChapterFileStore.delete`.
    func remove(_ book: Book) throws {
        let url = fileURL(for: book)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }
}
