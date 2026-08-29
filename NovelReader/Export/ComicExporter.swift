import Foundation
import UniformTypeIdentifiers

/// Writes a downloaded comic back out as a ZIP of folders.
///
/// The shape is the one a person would make by hand, and the one
/// `ComicArchiveImporter` reads back: a folder named after the comic, a folder per
/// chapter inside it, and the pages inside those. Nothing app-specific is written
/// — no manifest, no index — because a file whose only reader is this app is a
/// worse gift than a folder of pictures anything can open.
///
/// Images are copied byte for byte and *stored* rather than deflated. A JPEG does
/// not compress twice; running two gigabytes of them through DEFLATE would cost
/// minutes of CPU to produce a file the same size. This also means the pages that
/// come back out of an export are bit-identical to the ones the site served.
///
/// Its own type rather than a third `BookExporter.Format`: that one turns chapters
/// of text into one document, and everything it does — the title page, the cover,
/// the paragraph joining, the single file at the end — is about text. The only
/// thing the two share is where the finished file waits.
struct ComicExporter {
    /// A finished export: one file, or several when the comic is too big for one.
    ///
    /// The parts are files on disk, never bytes in memory. A comic is gigabytes,
    /// and the save sheet can sit open for a minute.
    struct Export {
        /// In order. Every part carries the same top-level folder name, so
        /// importing them one after another lands on one comic rather than three.
        let urls: [URL]
        /// The comic's name, without a part suffix or an extension — what the save
        /// sheet shows when there is a single file.
        let filename: String
        /// Chapters actually written.
        let chapterCount: Int
        /// Chapters the book's catalog lists.
        let catalogCount: Int

        /// Whether the archive holds less than the comic. The caller has to say so:
        /// handing over a third of a comic as though it were whole is the one
        /// failure the user cannot see for themselves.
        var isPartial: Bool { chapterCount < catalogCount }
    }

    /// Chapters done as a 0…1 fraction, over the *catalog* rather than over what is
    /// on the device, so the bar measures the work and does not jump on a book with
    /// gaps in its downloads. Same contract as `BookExporter.ProgressHandler`.
    typealias ProgressHandler = @MainActor (Double) -> Void

    let files: ChapterFileStore
    let covers: CoverStore

    /// How much goes into one part.
    ///
    /// `ZipBuilder` writes 32-bit offsets — it was built for EPUBs, where four
    /// gigabytes is not a number anyone approaches — and a comic is the first thing
    /// in this app that can pass it. Three gibibytes leaves a gibibyte of room for
    /// the local headers and the central directory, which is far more than either
    /// needs, and splitting is what the size limit buys instead of ZIP64: the parts
    /// are whole zips a person can open one at a time, and every chapter is intact
    /// inside exactly one of them.
    ///
    /// A property rather than a constant so a test can ask for the splitting
    /// behaviour without three gibibytes of fixture.
    var partLimit: Int64 = 3 << 30

    func export(
        book: Book, chapters: [Chapter], progress: @escaping ProgressHandler
    ) async throws -> Export {
        let root = BookExporter.filename(from: book.shownName)
        let planned = plan(book: book, chapters: chapters, root: root)
        guard !planned.isEmpty else { throw BookExportError.nothingOnDevice }
        let parts = split(planned)
        let directory = try Self.makeDirectory()

        var urls: [URL] = []
        var done = 0
        do {
            for (index, part) in parts.enumerated() {
                let name = Self.partName(root, part: index + 1, of: parts.count)
                let url = directory.appendingPathComponent(name).appendingPathExtension("zip")
                urls.append(url)
                let builder = try ZipBuilder(creating: url)
                // Only in the first part, and only if the shelf has one: a cover is
                // for whoever opens the archive, and repeating it in every part
                // would put three copies in the folder they extract to.
                if index == 0, let cover = coverEntry(book: book, root: root) {
                    try builder.append(cover)
                }
                for chapter in part {
                    // Per chapter, matching the granularity `BookExporter` and
                    // `LocalBookImporter` cancel at: a cancel that waited for a
                    // whole comic is a cancel the user watches do nothing.
                    try Task.checkCancellation()
                    for page in chapter.pages {
                        try builder.append(
                            ZipBuilder.Entry(
                                name: "\(chapter.folder)/\(page.lastPathComponent)",
                                data: try Data(contentsOf: page),
                                compressed: false
                            )
                        )
                    }
                    done += 1
                    await progress(Double(done) / Double(chapters.count))
                }
                try builder.finish()
            }
        } catch {
            // Includes the cancelled case. An unfinished part has no central
            // directory, so it is not an archive anybody can open, and leaving one
            // behind would put a broken file where the next export looks.
            for url in urls { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        await progress(1)
        return Export(
            urls: urls, filename: root, chapterCount: done, catalogCount: chapters.count
        )
    }

    // MARK: - Planning

    /// One chapter's worth of the archive, worked out before anything is written.
    private struct PlannedChapter {
        /// The folder this chapter becomes, numbered so that the archive opens in
        /// reading order in any tool, and so that a chapter added to the middle of a
        /// comic later still sorts where it belongs on the way back in.
        let folder: String
        let pages: [URL]
        let bytes: Int64
    }

    /// What can actually be written, in catalog order.
    ///
    /// Two chapters are skipped, and neither is an error: one the reader never
    /// downloaded, and one whose flag outlived its files (see
    /// `ChapterFileStore.writePages`). Counting either would put an empty folder in
    /// the archive and a lie in `chapterCount`.
    private func plan(book: Book, chapters: [Chapter], root: String) -> [PlannedChapter] {
        // Wide enough that the numbers sort as text: a 1300-chapter comic needs
        // four digits, and three is the width people expect on a short one.
        let width = max(3, String(chapters.count).count)
        return chapters.enumerated().compactMap { index, chapter in
            guard chapter.isDownloaded else { return nil }
            // Without the markers a download left where a page would not come back
            // (`ChapterFileStore.writePages`): an archive is for reading elsewhere, and
            // an empty `.missing` file is a note to this app, not a page. The numbering
            // inside the folder keeps the gap, which is the honest shape.
            let pages = files.pageURLs(
                siteId: book.siteId, siteBookId: book.siteBookId,
                siteChapterId: chapter.siteChapterId
            ).filter { $0.pathExtension != "missing" }
            guard !pages.isEmpty else { return nil }
            let number = String(format: "%0\(width)d", index + 1)
            let folder = "\(root)/\(number) \(BookExporter.filename(from: chapter.title))"
            return PlannedChapter(
                folder: folder, pages: pages, bytes: pages.reduce(0) { $0 + Self.size(of: $1) }
            )
        }
    }

    /// Chapters grouped into parts, each under `partLimit`.
    ///
    /// A chapter is never split across two parts: half a chapter in each of two
    /// files is unreadable on its own and merges back wrong if only one is
    /// imported. A single chapter bigger than the limit would therefore make a part
    /// that is over it — three gibibytes of one chapter is not a thing that exists,
    /// and if it ever did, one oversized part is a better answer than a refused
    /// export or a chapter cut in half.
    private func split(_ chapters: [PlannedChapter]) -> [[PlannedChapter]] {
        var parts: [[PlannedChapter]] = []
        var current: [PlannedChapter] = []
        var bytes: Int64 = 0
        for chapter in chapters {
            if !current.isEmpty, bytes + chapter.bytes > partLimit {
                parts.append(current)
                current = []
                bytes = 0
            }
            current.append(chapter)
            bytes += chapter.bytes
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    private static func partName(_ base: String, part: Int, of total: Int) -> String {
        guard total > 1 else { return base }
        return base + " " + String(localized: "book.export.part \(part) \(total)")
    }

    /// The cover as the archive's own file, so that unzipping a comic shows what it
    /// is. Named `cover`, which is what the importer looks for.
    private func coverEntry(book: Book, root: String) -> ZipBuilder.Entry? {
        guard let data = covers.data(for: book), let format = ImageFormat(sniffing: data) else {
            return nil
        }
        return ZipBuilder.Entry(
            name: "\(root)/cover.\(format.fileExtension)", data: data, compressed: false
        )
    }

    /// Where the finished parts wait for the save sheet — the same directory
    /// `BookExporter` uses, emptied at the start of an export for the same reason:
    /// the files have to outlive this call, and the first moment nobody can need the
    /// previous ones is when the next export begins.
    private static func makeDirectory() throws -> URL {
        let manager = FileManager.default
        try? manager.removeItem(at: BookExporter.directory)
        try manager.createDirectory(at: BookExporter.directory, withIntermediateDirectories: true)
        return BookExporter.directory
    }

    private static func size(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
}
