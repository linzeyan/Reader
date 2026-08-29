import CryptoKit
import Foundation

/// Turns a ZIP of folders into a comic on the shelf.
///
/// The shape it reads is the one `ComicExporter` writes and the one anybody would
/// build by hand: a folder for the comic, a folder per chapter inside it, and the
/// pages inside those. Everything else about the archive is ignored rather than
/// refused — the person who made it used whatever tool they had.
///
/// What it does with what it finds:
///
/// - **Order comes from the folder names**, compared the way Finder compares them,
///   so `第2話` sorts before `第10話` and a numbered export sorts by its numbers.
/// - **A leading number is not part of the title.** `001 第01話` is chapter
///   `第01話`; the number did its job by ordering the folder.
/// - **A chapter is identified by its title, not by its position**, so importing
///   part two of an export before part one still lands them in one comic, in the
///   right order, and re-importing a comic that has since gained a chapter in the
///   middle updates it rather than duplicating everything after the insertion.
///
/// Imported comics live under `Book.localSiteId` beside imported text, and their
/// pages go through `DownloadStore.save(pages:)` — the same call a download makes.
/// Nothing downstream can tell an imported chapter from a downloaded one, which is
/// what makes the reader, the storage screen and the four delete scopes work on
/// these books without knowing they exist.
struct ComicArchiveImporter {
    let repo: LibraryRepo
    let downloads: DownloadStore
    let covers: CoverStore

    typealias ProgressHandler = LocalBookImporter.ProgressHandler

    /// Names that are packaging rather than content. Archives made on a Mac carry a
    /// parallel `__MACOSX` tree of resource forks whose entries sniff as nothing.
    private static let ignoredDirectories: Set<String> = ["__MACOSX"]

    func importComic(from url: URL, progress: @escaping ProgressHandler) async throws -> Book {
        // Held for the whole import, unlike `LocalBookImporter`, which can let go as
        // soon as it has the file's bytes. This one never takes the bytes: the
        // archive stays on disk and is read a page at a time, so the permission to
        // read it has to last as long as the import does.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let reader: ZipFileReader
        do {
            reader = try ZipFileReader(reading: url)
        } catch let error as ZipArchive.ZipError {
            throw LocalBookError.badArchive(error.description)
        } catch {
            throw LocalBookError.unreadable
        }
        try Task.checkCancellation()

        let found = Self.structure(
            of: reader.entries, fallbackTitle: url.deletingPathExtension().lastPathComponent
        )
        guard !found.chapters.isEmpty else { throw LocalBookError.empty }
        return try await store(found, reading: reader, progress: progress)
    }

    // MARK: - Reading the archive's shape

    /// One chapter as the archive describes it, before any of it is read.
    private struct FoundChapter {
        /// The path of the folder holding the pages, minus the comic's own folder.
        /// Kept as it was written because it is the sort key: the numbers people put
        /// in front of chapter names are ordering, and stripping them before sorting
        /// would throw away the only thing that says `序章` comes first.
        let folder: String
        /// The folder name with its leading number taken off — what the reader sees.
        let title: String
        let pages: [ZipFileReader.Entry]
    }

    private struct Structure {
        let title: String
        let chapters: [FoundChapter]
        let cover: ZipFileReader.Entry?
    }

    /// Groups the archive's files into a comic.
    ///
    /// Chapters are the folders that directly contain pages, whatever depth they sit
    /// at, so `名/卷一/第1話/001.jpg` works as well as `名/第1話/001.jpg`. The comic's
    /// own folder is only recognised as one when *every* file is inside it and every
    /// file is at least two levels deep; a zip made from inside the comic's folder
    /// has no such wrapper, and then the file's own name is the best title there is.
    ///
    /// Images sitting directly beside the chapter folders are covers, not pages —
    /// unless there are no chapter folders at all, in which case a bag of pictures
    /// is one chapter, which is what somebody who zipped a single chapter meant.
    private static func structure(
        of entries: [ZipFileReader.Entry], fallbackTitle: String
    ) -> Structure {
        var paths: [(components: [String], entry: ZipFileReader.Entry)] = []
        for entry in entries {
            let components = entry.name.split(separator: "/").map(String.init)
            guard let name = components.last, !name.hasPrefix(".") else { continue }
            // Hidden folders and the Mac's resource-fork tree. Dropped by path rather
            // than by name so that a chapter legitimately called `.5話` — a folder
            // beginning with a dot — cannot drag its pages in with it either way.
            guard !components.dropLast().contains(where: {
                $0.hasPrefix(".") || ignoredDirectories.contains($0)
            }) else { continue }
            guard couldBeAnImage(name) else { continue }
            paths.append((components, entry))
        }

        // The wrapper folder, if there is one: every file inside the same first
        // component, and none of them sitting directly in it.
        let roots = Set(paths.compactMap(\.components.first))
        let hasWrapper = roots.count == 1 && paths.allSatisfy { $0.components.count >= 3 }
        let title = hasWrapper ? (roots.first ?? fallbackTitle) : fallbackTitle
        let stripped = paths.map { path in
            (path.components.dropFirst(hasWrapper ? 1 : 0), path.entry)
        }

        var byFolder: [String: [ZipFileReader.Entry]] = [:]
        var loose: [ZipFileReader.Entry] = []
        for (components, entry) in stripped {
            let folder = components.dropLast().joined(separator: "/")
            if folder.isEmpty {
                loose.append(entry)
            } else {
                byFolder[folder, default: []].append(entry)
            }
        }

        // A bag of pictures with no folders is one chapter named after the archive.
        if byFolder.isEmpty, !loose.isEmpty {
            return Structure(
                title: title,
                chapters: [
                    FoundChapter(folder: title, title: title, pages: sorted(loose))
                ],
                cover: nil
            )
        }

        let chapters = byFolder.keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { folder in
                FoundChapter(
                    folder: folder,
                    title: chapterTitle(of: folder),
                    pages: sorted(byFolder[folder] ?? [])
                )
            }
        return Structure(
            title: title,
            chapters: chapters,
            cover: loose.first { $0.name.lastPathComponent.lowercased().hasPrefix("cover") }
        )
    }

    /// Pages in reading order: the way a person reads the numbers in the names, so
    /// `9.jpg` comes before `10.jpg` however many digits either was written with.
    private static func sorted(_ entries: [ZipFileReader.Entry]) -> [ZipFileReader.Entry] {
        entries.sorted {
            $0.name.lastPathComponent.localizedStandardCompare($1.name.lastPathComponent)
                == .orderedAscending
        }
    }

    /// Whether a file is worth opening at all.
    ///
    /// By extension, which is a guess — the bytes decide, later, when they are read.
    /// This one is only here to keep `Thumbs.db` and a stray `readme.txt` out of the
    /// page count. A file with no extension is kept on purpose: a page whose format
    /// could not be identified when it was downloaded is stored without one, so
    /// refusing them would lose pages on the way back in.
    private static func couldBeAnImage(_ name: String) -> Bool {
        let known: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "avif", ""]
        return known.contains((name as NSString).pathExtension.lowercased())
    }

    /// A folder name without the number that ordered it.
    ///
    /// `001 第01話` → `第01話`; `第1話` is untouched, because its number is part of
    /// what the chapter is called. A folder that is *only* a number keeps it —
    /// stripping would leave nothing to show.
    static func chapterTitle(of folder: String) -> String {
        let name = folder.split(separator: "/").last.map(String.init) ?? folder
        let digits = name.prefix(while: \.isNumber)
        guard !digits.isEmpty else { return name }
        let rest = name.dropFirst(digits.count)
            .drop { $0 == " " || $0 == "." || $0 == "-" || $0 == "_" }
            .trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? name : rest
    }

    // MARK: - Storing

    /// Writes the book row, the merged catalog, and every page.
    ///
    /// This is the only phase that writes anything, so it is the only one that has
    /// to undo itself. What "undo" means depends on whether the comic was already
    /// there: a first import that fails leaves no trace, while a second part that
    /// fails leaves the first part exactly as it was.
    private func store(
        _ found: Structure, reading reader: ZipFileReader, progress: @escaping ProgressHandler
    ) async throws -> Book {
        let siteBookId = Self.identifier(for: found.title)
        let bookId = Book.makeId(siteId: Book.localSiteId, siteBookId: siteBookId)
        // Read before the upsert, because both are what a rollback has to put back:
        // whether there was a book, and what its catalog was.
        let previous = (try? repo.chapters(bookId: bookId)) ?? []
        let wasAlreadyOnTheShelf = try repo.book(id: bookId) != nil

        let incoming = Self.identify(found.chapters)
        let book = try repo.bookmark(
            siteId: Book.localSiteId, siteBookId: siteBookId, kind: .comic, title: found.title
        )
        var written: [String] = []
        do {
            try repo.replaceCatalog(
                bookId: book.id, entries: Self.merge(incoming, into: previous, of: siteBookId)
            )
            var skipped: Set<String> = []
            for (offset, chapter) in incoming.enumerated() {
                try Task.checkCancellation()
                let pages = try chapter.chapter.pages.compactMap { entry -> Data? in
                    let data = try reader.data(of: entry)
                    // The bytes decide. A `.jpg` that is really a text file would go
                    // to disk as a page the reader could never draw.
                    return ImageFormat.isImage(data) ? data : nil
                }
                if pages.isEmpty {
                    skipped.insert(chapter.siteChapterId)
                } else {
                    try downloads.save(
                        pages: pages, book: book, siteChapterId: chapter.siteChapterId
                    )
                    written.append(chapter.siteChapterId)
                }
                await progress(Double(offset + 1) / Double(incoming.count))
            }
            // Only when something was actually dropped, so the ordinary import is
            // one catalog write. A folder that held no readable image is not a
            // chapter, and a row for it would open onto an error forever.
            if !skipped.isEmpty {
                let kept = incoming.filter { !skipped.contains($0.siteChapterId) }
                guard !kept.isEmpty else { throw LocalBookError.empty }
                try repo.replaceCatalog(
                    bookId: book.id, entries: Self.merge(kept, into: previous, of: siteBookId)
                )
            }
            try saveCover(found, reading: reader, book: book)
        } catch {
            rollBack(book, wrote: written, restoring: previous, keepingRow: wasAlreadyOnTheShelf)
            throw error
        }
        return book
    }

    /// The cover: the archive's own, or the first page of the first chapter.
    ///
    /// A comic with no cover on the shelf is a grey rectangle, and an imported one
    /// has no site to fetch a real cover from — the first page is the best thing on
    /// hand, and it is what the comic looks like. An archive that carries a cover
    /// overrides whatever is there, because someone put it in the file on purpose.
    private func saveCover(
        _ found: Structure, reading reader: ZipFileReader, book: Book
    ) throws {
        if let entry = found.cover, let data = try? reader.data(of: entry),
           ImageFormat.isImage(data) {
            try covers.save(data, for: book)
            return
        }
        guard !covers.has(book) else { return }
        for chapter in found.chapters {
            guard let first = chapter.pages.first, let data = try? reader.data(of: first),
                  ImageFormat.isImage(data)
            else { continue }
            try covers.save(data, for: book)
            return
        }
    }

    /// Undoes what this import wrote.
    ///
    /// The chapters it saved, by the same call the storage screen makes, and then
    /// the catalog it replaced. A comic that was already on the shelf keeps its row,
    /// its earlier chapters and their pages: importing part two must not be able to
    /// take part one down with it.
    ///
    /// A chapter that was already there is left alone even when this import wrote
    /// over it. Pages land all-or-nothing (`ChapterFileStore.writePages`), so such a
    /// chapter is complete either way — deleting it to be tidy would turn a failed
    /// import into the one thing worse than a failed import, which is a chapter the
    /// reader used to have and no longer does.
    private func rollBack(
        _ book: Book, wrote: [String], restoring previous: [Chapter], keepingRow: Bool
    ) {
        // Errors are swallowed on purpose: the caller's error is the one worth
        // reporting, and a failed cleanup must not replace "cancelled" with some
        // filesystem message about the cleanup itself.
        let kept = Set(previous.map(\.siteChapterId))
        for siteChapterId in wrote where !kept.contains(siteChapterId) {
            try? downloads.delete(.chapter(book: book, siteChapterId: siteChapterId))
        }
        guard keepingRow else {
            try? downloads.delete(.book(book))
            try? covers.remove(book)
            try? repo.removeBookmark(bookId: book.id)
            return
        }
        try? repo.replaceCatalog(
            bookId: book.id,
            entries: previous.map {
                (siteChapterId: $0.siteChapterId, title: $0.title, url: $0.url)
            }
        )
    }

    // MARK: - Identity and order

    /// A chapter of the archive with the id it will be stored under.
    private struct IdentifiedChapter {
        let chapter: FoundChapter
        let siteChapterId: String
    }

    /// Gives every chapter a stable id.
    ///
    /// From the title rather than from the position or the folder name, so that the
    /// same chapter imported twice is the same chapter — an export made after the
    /// comic gained an episode renumbers every folder after it, and an id taken from
    /// `002 第01話` would make a second copy of everything.
    ///
    /// Two chapters that strip to the same title fall back to their folder names,
    /// which is the only thing left that tells them apart. Re-importing that comic
    /// keeps them separate as long as the folders keep their names.
    private static func identify(_ chapters: [FoundChapter]) -> [IdentifiedChapter] {
        var counts: [String: Int] = [:]
        for chapter in chapters { counts[chapter.title, default: 0] += 1 }
        return chapters.map {
            IdentifiedChapter(
                chapter: $0,
                siteChapterId: identifier(for: counts[$0.title] == 1 ? $0.title : $0.folder)
            )
        }
    }

    /// This import's chapters merged with the ones already on the shelf, in order.
    ///
    /// Both lists are needed because `LibraryRepo.replaceCatalog` deletes what it is
    /// not given: handing it only the new part would take the previous parts off the
    /// shelf. It keeps `downloadedAt` for the ids it recognises, which is what lets
    /// the pages of part one survive the import of part two.
    ///
    /// The sort key is the folder name each chapter came in under, carried in the
    /// chapter's URL. That URL is never fetched — imported chapters have no site —
    /// and `LocalBookImporter` already puts an unfetchable address there for the same
    /// reason, so this is the field's second use rather than a new idea.
    private static func merge(
        _ incoming: [IdentifiedChapter], into previous: [Chapter], of siteBookId: String
    ) -> [(siteChapterId: String, title: String, url: String)] {
        var folders: [String: (title: String, folder: String)] = [:]
        for chapter in previous {
            folders[chapter.siteChapterId] = (chapter.title, folder(of: chapter))
        }
        for chapter in incoming {
            folders[chapter.siteChapterId] = (chapter.chapter.title, chapter.chapter.folder)
        }
        return folders
            .map { (siteChapterId: $0.key, title: $0.value.title, folder: $0.value.folder) }
            .sorted { $0.folder.localizedStandardCompare($1.folder) == .orderedAscending }
            .map {
                (
                    siteChapterId: $0.siteChapterId,
                    title: $0.title,
                    url: url(folder: $0.folder, siteBookId: siteBookId)
                )
            }
    }

    /// Percent-encoded, because a chapter folder is called things like `第 1 話` and
    /// `URL(string:)` — which every reader of this field goes through — refuses a
    /// string with a space in it.
    private static func url(folder: String, siteBookId: String) -> String {
        let encoded = folder.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? folder
        return "\(Book.localSiteId)://\(siteBookId)/\(encoded)"
    }

    /// The folder a stored chapter came in under. Falls back to its title, which is
    /// what a chapter written by an older import or by the text importer has.
    private static func folder(of chapter: Chapter) -> String {
        let tail = chapter.url.split(separator: "/").last.map(String.init) ?? ""
        let decoded = tail.removingPercentEncoding ?? tail
        return decoded.isEmpty ? chapter.title : decoded
    }

    /// A digest, for the same reason `LocalBookImporter` uses one: this string is a
    /// primary key and it goes in a file path, and a comic called `../../etc` must
    /// not be able to choose where its pages land.
    private static func identifier(for name: String) -> String {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return SHA512.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private extension String {
    var lastPathComponent: String { (self as NSString).lastPathComponent }
}
