import CryptoKit
import Foundation

/// One chapter as it comes out of an imported file, before it reaches the
/// database and the chapter file store.
struct ImportedChapter {
    let title: String
    let paragraphs: [String]
}

/// Why an import failed, in the user's language.
///
/// `malformed` carries a technical detail on a second line, the same shape
/// `SiteStore.ImportError` uses: the localised sentence says what happened and
/// the detail is what makes a bug report about someone else's EPUB actionable.
enum LocalBookError: LocalizedError {
    case unreadable
    case malformed(String)
    /// A comic archive that is not a ZIP, or is one this app cannot read.
    case badArchive(String)
    case unknownEncoding
    case empty
    /// The book was imported, but its text is no longer on disk.
    case contentDeleted

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return String(localized: "library.import.error.unreadable")
        case .malformed(let detail):
            return String(localized: "library.import.error.malformed") + "\n" + detail
        case .badArchive(let detail):
            return String(localized: "library.import.error.archive") + "\n" + detail
        case .unknownEncoding:
            return String(localized: "library.import.error.encoding")
        case .empty:
            return String(localized: "library.import.error.empty")
        case .contentDeleted:
            return String(localized: "book.local.missingFile")
        }
    }
}

/// Turns a `.txt` or `.epub` the user picked out of Files into a readable book.
///
/// Imported books live under the reserved source `Book.localSiteId`. They have
/// no site to fetch from, so all of their text is written into the download
/// store at import time and read back from there afterwards. That is not a
/// special case bolted onto the reader — it *is* the downloaded-chapter path, so
/// the storage screen, the four delete scopes and the reader's local-first read
/// all work on an imported book without knowing that it is one.
///
/// Not `@MainActor`, and its methods are `async` rather than blocking: a 2 MB
/// text file is a second or two of decoding, splitting and file writes, all of
/// which has to stay off the main thread. The one main-actor hop is the web view
/// that reads EPUB documents, and `WebFetcher` already owns that.
///
/// Cancellation is cooperative and checked per unit of work — per spine document,
/// per chapter written — rather than between the phases: an EPUB is hundreds of
/// extractions and a novel is hundreds of file writes, and a cancel that waited
/// for the current phase to end would be a cancel the user watches do nothing.
/// Anything already written is undone before the error escapes; see `rollBack`.
struct LocalBookImporter {
    /// Progress as a 0…1 fraction rather than a count of chapters. An EPUB is
    /// extracted and then written — two passes of different lengths over the
    /// same book — and a fraction is the only way to show that as one bar that
    /// never runs backwards.
    typealias ProgressHandler = @MainActor (Double) -> Void

    let repo: LibraryRepo
    let downloads: DownloadStore
    let fetcher: WebFetcher

    /// The share of the bar an EPUB's extraction pass gets. Writing the same
    /// number of chapters afterwards costs roughly the same again.
    private static let extractionShare = 0.5

    func importBook(from url: URL, progress: @escaping ProgressHandler) async throws -> Book {
        // Files handed over by the document picker live outside the sandbox.
        // Released as soon as the bytes are in hand rather than in a `defer`, so
        // the scope is not held open across the awaits that follow.
        let scoped = url.startAccessingSecurityScopedResource()
        let data = try? Data(contentsOf: url, options: .mappedIfSafe)
        if scoped { url.stopAccessingSecurityScopedResource() }
        guard let data, !data.isEmpty else { throw LocalBookError.unreadable }
        // Reading the file is itself long enough to cancel during — the picker
        // hands over documents that live on iCloud Drive — so the first checkpoint
        // sits here, before any of the expensive work starts.
        try Task.checkCancellation()

        // Taken before the parse rather than at the call below, where it used to sit.
        // As an argument to `store` its last use was *after* everything the parse
        // builds, which pinned the whole file in memory beside every intermediate the
        // parse makes of it: for a fifty-megabyte text that is the bytes, the decoded
        // string, and the split paragraphs all at once. Hoisted, the file is free to
        // go as soon as the parse has read it.
        let siteBookId = Self.identifier(for: data)

        let parsed: (title: String?, author: String?, chapters: [ImportedChapter])
        let isEpub = url.pathExtension.lowercased() == "epub"
        if isEpub {
            parsed = try await epub(data, progress: progress)
        } else {
            guard let text = TextBookParser.decode(data) else { throw LocalBookError.unknownEncoding }
            // Decoding a large file can be the slow step; the split after it is one
            // pass and not worth threading a cancellation check through, which is
            // why the checkpoint sits between them rather than inside the parser.
            try Task.checkCancellation()
            parsed = (nil, nil, TextBookParser.chapters(from: text))
        }
        guard !parsed.chapters.isEmpty else { throw LocalBookError.empty }

        return try await store(
            // The filename is the fallback title because it is what the user
            // recognises: a `.txt` has no metadata at all, and plenty of EPUBs
            // carry a placeholder title from whatever produced them.
            title: parsed.title?.nonBlank ?? url.deletingPathExtension().lastPathComponent,
            author: parsed.author?.nonBlank,
            siteBookId: siteBookId,
            chapters: parsed.chapters,
            progressBase: isEpub ? Self.extractionShare : 0,
            progress: progress
        )
    }

    // MARK: - EPUB

    /// Reads every spine document through the same extractor the site rules use.
    ///
    /// Reusing `ExtractorScript.chapter` is the whole design here: it already
    /// normalises `<br>` / `<p>` / `<div>` into paragraph breaks and drops the
    /// heading a document repeats at the top of its own body. A second HTML
    /// reader written in Swift would be a worse copy of that, and would drift.
    private func epub(
        _ data: Data, progress: @escaping ProgressHandler
    ) async throws -> (String?, String?, [ImportedChapter]) {
        let document: EpubDocument
        do {
            document = try EpubDocument.parse(data)
        } catch let error as ZipArchive.ZipError {
            throw LocalBookError.malformed(error.description)
        }

        let script = try ExtractorScript.chapter(Self.embeddedDocumentRule)
        var chapters: [ImportedChapter] = []
        // Spelled out rather than deferred, because giving the view back is a hop onto
        // the main actor and `defer` cannot await one. Both exits do it: the web view
        // the spine documents are read in is wanted for the length of one import, and
        // the content process behind it is not small enough to leave running for the
        // rest of the session on the strength of a book the user opened once.
        do {
            for (offset, item) in document.items.enumerated() {
                // Before the extraction, not after: each document is a round trip
                // through the web view, and one of those is the whole distance between
                // "it stopped" and "it stops eventually".
                try Task.checkCancellation()
                let payload = try await fetcher.extract(
                    html: item.xhtml, extracting: script, as: ExtractorScript.ChapterPayload.self
                )
                // Documents that extract to nothing are covers and chapter-heading
                // plates — a single image and no text. Keeping them would put rows
                // in the catalog that open onto a blank page.
                if !payload.paragraphs.isEmpty {
                    chapters.append(
                        ImportedChapter(
                            title: item.tocTitle?.nonBlank
                                ?? payload.title?.nonBlank
                                ?? Self.partTitle(chapters.count + 1),
                            paragraphs: payload.paragraphs
                        )
                    )
                }
                await progress(
                    Double(offset + 1) / Double(document.items.count) * Self.extractionShare
                )
            }
        } catch {
            await fetcher.releaseImportView()
            throw error
        }
        await fetcher.releaseImportView()
        return (document.title, document.author, chapters)
    }

    /// How an EPUB document is read.
    ///
    /// `body` is the content node because an EPUB document *is* one chapter —
    /// there is no site chrome to select away. The heading selectors earn their
    /// place twice over: they name a chapter in a book that has no table of
    /// contents, and they are what lets the extractor recognise and drop the
    /// heading repeated at the top of the body.
    ///
    /// Internal so a test can drive the same script the importer uses.
    static let embeddedDocumentRule = SiteRule.Chapter(
        titleSelectors: ["h1", "h2", "h3", "title"],
        contentSelectors: ["body"],
        stripSelectors: ["script", "style", "svg"],
        dropParagraphPatterns: nil,
        prevSelector: nil,
        nextSelector: nil
    )

    // MARK: - Storing

    /// Writes the book row, its catalog, and every chapter's text.
    ///
    /// Chapters go through `DownloadStore.save`, which is the same call a real
    /// download makes: file first, then the `downloadedAt` flag. Nothing about
    /// an imported chapter is stored differently from a downloaded one, and that
    /// is what makes the rest of the app work on these books unchanged.
    ///
    /// This is the only phase that writes anything, so it is the only one that has
    /// to undo itself — everything before it can stop wherever it likes.
    private func store(
        title: String,
        author: String?,
        siteBookId: String,
        chapters: [ImportedChapter],
        progressBase: Double,
        progress: @escaping ProgressHandler
    ) async throws -> Book {
        try Task.checkCancellation()
        // Asked before the upsert, because the answer decides how far a rollback
        // may go: re-importing a file the shelf already holds must not be able to
        // take the existing book down with it.
        let wasAlreadyOnTheShelf = try repo.book(
            id: Book.makeId(siteId: Book.localSiteId, siteBookId: siteBookId)
        ) != nil
        let book = try repo.bookmark(
            siteId: Book.localSiteId, siteBookId: siteBookId, title: title, author: author
        )
        do {
            try repo.replaceCatalog(
                bookId: book.id,
                entries: chapters.enumerated().map { offset, chapter in
                    (
                        siteChapterId: Self.chapterId(offset),
                        title: chapter.title,
                        // `Chapter.url` is not nullable and means nothing for a book
                        // that came out of a file. It carries a scheme nothing can
                        // fetch, so a code path that ever tries to load it fails
                        // loudly instead of quietly hitting some site.
                        url: "\(Book.localSiteId)://\(siteBookId)/\(offset)"
                    )
                }
            )
            for (offset, chapter) in chapters.enumerated() {
                try Task.checkCancellation()
                try downloads.save(
                    paragraphs: chapter.paragraphs, book: book, siteChapterId: Self.chapterId(offset)
                )
                let done = Double(offset + 1) / Double(chapters.count)
                await progress(progressBase + done * (1 - progressBase))
            }
        } catch {
            rollBack(book, keepingRow: wasAlreadyOnTheShelf)
            throw error
        }
        return book
    }

    /// Undoes a partial import — a cancel, or a write that failed part-way.
    ///
    /// A book left here would sit on the shelf claiming a full catalog while
    /// holding its first few chapters, and nothing in the row would say so: the
    /// reader finds out by running off the end of the text. That is strictly worse
    /// than an import that plainly failed and left no trace.
    ///
    /// Both calls are the ones removing a bookmark already makes — the flags and
    /// files through `DownloadStore`, the row through `LibraryRepo` — rather than a
    /// private undo path, because a second way to delete a book is a second way for
    /// the index and the disk to drift apart.
    private func rollBack(_ book: Book, keepingRow: Bool) {
        // Errors are swallowed on purpose: the caller's error is the one worth
        // reporting, and a failed cleanup must not replace "cancelled" with some
        // filesystem message about the cleanup itself.
        try? downloads.delete(.book(book))
        // A re-import keeps the row. The reading position and any custom name
        // predate this import and belong to the user, not to it. Stripped of its
        // text the book reports `contentDeleted`, which the reader already explains
        // and a finished import repairs.
        if !keepingRow { try? repo.removeBookmark(bookId: book.id) }
    }

    /// Zero-padded so the files on disk sort in reading order, which is what
    /// anyone looking at the download folder expects to see.
    private static func chapterId(_ index: Int) -> String { String(format: "%05d", index) }

    /// A digest of the file's bytes, not a fresh UUID: importing the same file
    /// twice must land on the same book, so that re-importing after a storage
    /// cleanup restores the text under the reading position the user already
    /// has instead of adding a duplicate beside it.
    ///
    /// The whole digest, not a prefix. It is the primary key for every imported
    /// book on the device and it goes in a file path — both places where a
    /// collision means one book quietly serving another book's text — and the
    /// only thing a truncation buys is a shorter string nobody reads.
    private static func identifier(for data: Data) -> String {
        SHA512.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func partTitle(_ number: Int) -> String {
        String(localized: "library.import.part \(number)")
    }
}

extension String {
    /// nil when there is nothing left after trimming. Metadata in these files is
    /// routinely present but blank, and a blank title is worse than none: the
    /// fallback can only run if the absence is visible. Shared with the feed parser,
    /// whose fields are blank for exactly the same reason.
    var nonBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
