import Foundation
import UniformTypeIdentifiers

/// Writes a book in the library back out as a file the user owns.
///
/// The rule of the whole type is that it only ever writes text that is really on
/// this device. A chapter row says the *site* has the text; the download store is
/// what says we do. Exporting a heading with nothing under it would put a lie in
/// the file, so a chapter without a local copy is left out entirely and the count
/// that comes back says how much of the book made it — which is what lets the
/// caller tell the user they are holding part of a novel rather than all of one.
///
/// Nothing here reaches the network, cover included: an export is what the device
/// already has, and a file the user is waiting for must not be waiting on someone
/// else's server.
///
/// Not `@MainActor`, and `export` is `async` rather than blocking, for the same
/// reason `LocalBookImporter` is not: a long novel is hundreds of file reads plus
/// a deflate pass over the lot, and none of that belongs on the main thread.
struct BookExporter {
    enum Format {
        /// UTF-8 plain text, in the shape `TextBookParser` reads back.
        case text
        /// A minimal EPUB 3.
        case epub

        var contentType: UTType {
            switch self {
            case .text: return .plainText
            case .epub: return .epub
            }
        }

        var pathExtension: String {
            switch self {
            case .text: return "txt"
            case .epub: return "epub"
            }
        }
    }

    /// A finished export: a file on disk, not its bytes.
    ///
    /// The book goes to disk a chapter at a time and is handed on as a file
    /// because the alternative is a whole novel resident in memory for as long as
    /// the save sheet is open — fifteen megabytes for a long one, for no purpose,
    /// on the one screen the user is already watching a progress bar on.
    struct Export {
        let format: Format
        /// The finished file, inside `BookExporter.directory`. The caller owns it
        /// from here: it survives until the export after this one, or until the
        /// caller deletes it once the save sheet has taken its copy.
        let url: URL
        /// Without an extension — the save sheet appends the one that belongs to
        /// `format`, and the user can edit the name before committing to it.
        let filename: String
        /// Chapters actually written.
        let chapterCount: Int
        /// Chapters the book's catalog lists.
        let catalogCount: Int

        /// Whether the file holds less than the book. The caller has to say so:
        /// handing over half a novel as though it were whole is the one failure
        /// mode of this feature that the user cannot see for themselves.
        var isPartial: Bool { chapterCount < catalogCount }
    }

    /// Chapters done as a 0…1 fraction, reported per chapter of the *catalog* so
    /// the bar measures the work rather than the result — a book with gaps in its
    /// downloads would otherwise jump.
    ///
    /// Determinate on purpose: a thirteen-hundred-chapter novel is a minute of
    /// file reads and deflate, and a spinner over that looks stuck.
    typealias ProgressHandler = @MainActor (Double) -> Void

    let downloads: DownloadStore
    /// Where the cover on the title page comes from. See `cover(of:)`.
    let covers: CoverStore

    /// Where a finished export waits for the save sheet.
    ///
    /// Emptied at the start of an export rather than at the end of one: the file
    /// has to outlive `export`, because the save sheet is what copies it and the
    /// user may sit on that sheet for a minute. The first moment nobody can still
    /// need the previous file is when the next export begins, so a process that
    /// dies in between costs one leftover file rather than one per export.
    static let directory = URL.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)

    /// Writes the book out and returns the file.
    ///
    /// Cancellation is checked at every chapter boundary — the same granularity
    /// `LocalBookImporter` uses, and for the same reason: a cancel that waited
    /// for the whole book to finish is a cancel the user watches do nothing.
    /// A cancelled or failed export leaves no file behind; half an EPUB is not a
    /// document, and half a novel that looks like a whole one is worse.
    func export(
        book: Book, chapters: [Chapter], format: Format, progress: @escaping ProgressHandler
    ) async throws -> Export {
        let filename = Self.filename(from: book.shownName)
        let url = try Self.makeDestination(filename: filename, format: format)
        do {
            let count: Int
            switch format {
            case .text:
                count = try await writeText(to: url, book: book, chapters: chapters, progress: progress)
            case .epub:
                count = try await writeEpub(to: url, book: book, chapters: chapters, progress: progress)
            }
            guard count > 0 else { throw BookExportError.nothingOnDevice }
            await progress(1)
            return Export(
                format: format,
                url: url,
                filename: filename,
                chapterCount: count,
                catalogCount: chapters.count
            )
        } catch {
            // Includes the cancelled case. The bytes written so far are not a
            // file anybody asked for, and leaving them would put a truncated book
            // in the place the next export looks.
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private static func makeDestination(filename: String, format: Format) throws -> URL {
        let manager = FileManager.default
        try? manager.removeItem(at: directory)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
            .appendingPathComponent(filename)
            .appendingPathExtension(format.pathExtension)
    }

    /// The chapter's text, or nil for a chapter this file cannot contain.
    ///
    /// `try?`, and empty paragraphs treated as absent: the downloaded flag can
    /// outlive the file (see `LocalBookError.contentDeleted`), and counting a
    /// chapter whose text has gone missing as absent is what keeps `isPartial`
    /// honest.
    private func paragraphs(of chapter: Chapter, in book: Book) -> [String]? {
        guard chapter.isDownloaded,
              let paragraphs = try? downloads.readParagraphs(
                  book: book, siteChapterId: chapter.siteChapterId
              ),
              !paragraphs.isEmpty
        else { return nil }
        return paragraphs
    }

    // MARK: - Plain text

    /// Heading, blank line, then one paragraph per line with a blank line between.
    ///
    /// That shape is what `TextBookParser` reads back — it splits on newlines and
    /// drops the empty ones, so the blank lines cost nothing on the way in and are
    /// what makes the file readable in anything else.
    ///
    /// One limitation is inherent and deliberate: a chapter title the parser's
    /// heading pattern does not recognise comes back as the first line of the body
    /// rather than as a title. The shapes it knows have grown — numbered Chinese
    /// units, English chapter and part numbers, the unnumbered names — but a site
    /// is free to title a chapter anything at all, and the only complete fix would
    /// be a marker of our own invention, which would make the file worse for every
    /// reader that is not this app.
    private func writeText(
        to url: URL, book: Book, chapters: [Chapter], progress: @escaping ProgressHandler
    ) async throws -> Int {
        try Data().write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var count = 0
        for (offset, chapter) in chapters.enumerated() {
            try Task.checkCancellation()
            if let paragraphs = paragraphs(of: chapter, in: book) {
                // The separator goes *before* every chapter but the first, which
                // is what makes the file identical to joining the whole book with
                // it — the property the importer's digest-based identity rests on.
                let block = ([chapter.title] + paragraphs).joined(separator: "\n\n")
                try handle.write(contentsOf: Data(((count == 0 ? "" : "\n\n") + block).utf8))
                count += 1
            }
            await progress(Double(offset + 1) / Double(chapters.count))
        }
        // A trailing newline so the last line is a line, not a fragment.
        if count > 0 { try handle.write(contentsOf: Data("\n".utf8)) }
        return count
    }

    // MARK: - EPUB

    private static let opfPath = "OEBPS/content.opf"
    private static let navHref = "nav.xhtml"
    private static let styleHref = "style.css"
    private static let titlePageHref = "titlepage.xhtml"

    /// A minimal EPUB 3: the OCF `mimetype`, the container, a stylesheet, a title
    /// page, one XHTML file per chapter, a nav document and the package document.
    ///
    /// `mimetype` is first and stored because OCF requires exactly that — a
    /// reader is allowed to identify an EPUB by reading a fixed offset near the
    /// start of the file, which only works if the bytes are uncompressed and the
    /// entry is where it says it will be. Everything after it is ordered so that
    /// the chapters can be written as they are read: the package document and the
    /// table of contents have to name exactly the chapters that made it into the
    /// file, so they are written last, which a ZIP does not mind at all — entries
    /// are found through the central directory, not by their position.
    private func writeEpub(
        to url: URL, book: Book, chapters: [Chapter], progress: @escaping ProgressHandler
    ) async throws -> Int {
        let zip = try ZipBuilder(creating: url)
        try zip.append(
            ZipBuilder.Entry(name: "mimetype", text: "application/epub+zip", compressed: false)
        )
        try zip.append(ZipBuilder.Entry(name: "META-INF/container.xml", text: """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="\(Self.opfPath)" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """))
        try zip.append(ZipBuilder.Entry(name: "OEBPS/\(Self.styleHref)", text: Self.stylesheet))

        var titles: [String] = []
        for (offset, chapter) in chapters.enumerated() {
            try Task.checkCancellation()
            if let paragraphs = paragraphs(of: chapter, in: book) {
                try zip.append(
                    ZipBuilder.Entry(
                        name: "OEBPS/\(Self.chapterHref(titles.count))",
                        text: Self.document(title: chapter.title, paragraphs: paragraphs)
                    )
                )
                titles.append(chapter.title)
            }
            await progress(Double(offset + 1) / Double(chapters.count))
        }
        // Left unfinished on purpose: no central directory means no archive, and
        // `export` deletes the file anyway. Writing a valid but empty EPUB would
        // be offering the user a book with nothing in it.
        guard !titles.isEmpty else { return 0 }

        let cover = cover(of: book)
        let author = Self.author(of: book)
        if let cover {
            try zip.append(ZipBuilder.Entry(name: "OEBPS/\(cover.href)", data: cover.data))
        }
        try zip.append(ZipBuilder.Entry(name: "OEBPS/\(Self.titlePageHref)", text: Self.titlePage(
            title: book.shownName, author: author, cover: cover
        )))
        try zip.append(ZipBuilder.Entry(name: "OEBPS/\(Self.navHref)", text: Self.navigation(
            title: book.shownName, chapters: titles
        )))
        try zip.append(ZipBuilder.Entry(name: Self.opfPath, text: Self.package(
            title: book.shownName, author: author, identifier: book.id,
            modified: book.addedAt, chapters: titles, cover: cover
        )))
        try zip.finish()
        return titles.count
    }

    /// Zero-padded so the documents sort in reading order for anyone who unzips
    /// the file, the same reason `LocalBookImporter` pads its chapter ids.
    private static func chapterHref(_ index: Int) -> String {
        String(format: "text/chapter-%05d.xhtml", index + 1)
    }

    private static func chapterId(_ index: Int) -> String { "c\(index + 1)" }

    // MARK: - Style

    /// The defaults another reading system will use, and nothing more.
    ///
    /// This app never loads this file — it draws chapter text itself, from its own
    /// settings — so every line here is for somebody else's reader, which is why
    /// there is so little of it. Deliberately absent: font families, and any
    /// colour at all. A reading system's night mode wins by recolouring what the
    /// book did not insist on, and an exported novel that ignores it is a novel
    /// that cannot be read in bed.
    ///
    /// What is here is Chinese-aware: justified text with no hyphenation, and
    /// strict line breaking so a line cannot begin with 」or 。— the two things a
    /// reader's Latin defaults get wrong on this text.
    private static let stylesheet = """
    html {
      /* CJK text is never hyphenated; the prefixed form is what EPUB 3 reading
         systems actually implement. */
      hyphens: none;
      -epub-hyphens: none;
    }

    body {
      margin: 4% 5%;
      line-height: 1.75;
      text-align: justify;
      /* Keeps closing brackets and full stops off the start of a line. */
      line-break: strict;
      word-break: normal;
      overflow-wrap: break-word;
    }

    h1 {
      font-size: 1.2em;
      line-height: 1.4;
      margin: 0 0 1.6em;
      text-align: left;
    }

    /* Space between paragraphs rather than a first-line indent: these are web
       novels, whose paragraphs are short exchanges of dialogue, and an indent
       makes a page of them look like a list. */
    p {
      margin: 0 0 0.9em;
      text-indent: 0;
    }

    .titlepage {
      margin-top: 20%;
      text-align: center;
    }

    .titlepage h1 {
      font-size: 1.8em;
      margin: 0 0 0.8em;
      text-align: center;
    }

    /* Centred by the block above rather than by auto margins, which need a
       display change an inline image does not otherwise want. */
    .titlepage img {
      max-width: 80%;
      margin: 0 0 1.5em;
    }

    .titlepage .author {
      font-size: 1.05em;
      margin: 0;
    }
    """

    // MARK: - Title page

    /// The author to write, or nil for a book that has one in name only.
    ///
    /// A blank author is not an absent one until it is made so here, and the
    /// difference is a broken file: EPUB 3 requires `dc:creator` to carry at least
    /// one character, and epubcheck rejects an empty one outright (RSC-005 — found
    /// by handing it exactly this shape, see `EpubValidationTests`).
    ///
    /// It is reachable. `ExtractorScript.readField` cleans the text it finds but
    /// does not fold empty to nil, so a site whose author element exists with
    /// nothing inside it stores `""` — and every screen that shows an author
    /// already checks for that, which is why nobody noticed until a validator did.
    private static func author(of book: Book) -> String? {
        let trimmed = book.author?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == true ? nil : trimmed
    }

    /// The cover's bytes, if this device has them.
    ///
    /// From `CoverStore`, which is where the cover on the shelf comes from, so a book
    /// whose cover has ever been drawn has one here. A book that has not gets a
    /// text-only title page instead: an export must not make a network request,
    /// because a picture is not worth making the user wait on a site that may not
    /// answer.
    ///
    /// The one cost is stated here so it is not a surprise: an export made before the
    /// cover was ever fetched differs from one made after, so re-importing the two
    /// would produce two books. Every other input to the file is fixed.
    private struct Cover {
        let href: String
        let mediaType: String
        let data: Data
    }

    /// The image types EPUB 3 lists as core, minus SVG, which a fetched cover never
    /// is. WebP is left out on purpose: it only became a core type in EPUB 3.3 and the
    /// package below declares 3.0, so a WebP cover would trade validity for a picture
    /// — and would need a fallback image this does not have. That is a live case
    /// rather than a hypothetical one: WebP is what manhuagui serves.
    private static let epubCoverFormats: Set<ImageFormat> = [.jpeg, .png, .gif]

    /// The format is read out of the bytes rather than believed from what anything
    /// says about them. Not pedantry: declining a WebP is the whole job here, and the
    /// previous source of this answer — a cached response's `Content-Type` — is
    /// exactly the field that is wrong when it matters.
    private func cover(of book: Book) -> Cover? {
        guard let data = covers.data(for: book), !data.isEmpty,
              let format = ImageFormat(sniffing: data),
              Self.epubCoverFormats.contains(format)
        else { return nil }
        return Cover(
            href: "cover.\(format.fileExtension)", mediaType: format.mediaType, data: data
        )
    }

    /// One page carrying what the book is called and who wrote it.
    ///
    /// Kept out of the reading order (`linear="no"` in the spine) rather than
    /// opening the book on it. That is what the attribute is for — auxiliary
    /// front matter — and it is also what stops this app's own importer from
    /// turning the plate into chapter one when the file comes back in. It stays
    /// reachable through the table of contents, which EPUB 3 requires of
    /// non-linear content.
    private static func titlePage(title: String, author: String?, cover: Cover?) -> String {
        let image = cover.map {
            "    <img src=\"\($0.href)\" alt=\"\(escaped(title))\"/>\n"
        } ?? ""
        let byline = author.map { "\n    <p class=\"author\">\(escaped($0))</p>" } ?? ""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" \
        xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="und">
          <head>
            <title>\(escaped(title))</title>
            <link rel="stylesheet" type="text/css" href="\(styleHref)"/>
          </head>
          <body>
            <section class="titlepage" epub:type="titlepage">
        \(image)    <h1>\(escaped(title))</h1>\(byline)
            </section>
          </body>
        </html>
        """
    }

    // MARK: - Package document

    /// The package document: metadata, manifest, spine.
    ///
    /// Two decisions worth stating. The language is `und` — BCP 47 for
    /// "undetermined" — because EPUB 3 requires exactly one `dc:language` and we
    /// genuinely do not know it: the app reads Chinese novels and English ones,
    /// and a guess here would tell a reading system to hyphenate and font-match
    /// the wrong way round. And `dcterms:modified` comes from the book's own
    /// `addedAt` rather than from the clock: EPUB 3.0 required the property, so
    /// leaving it out risks a validator complaining, while `Date()` in it would
    /// make every export of the same book a different file (see `ZipBuilder`).
    private static func package(
        title: String, author: String?, identifier: String, modified: Date,
        chapters: [String], cover: Cover?
    ) -> String {
        // Taken to be non-empty: `author(of:)` is what turns a blank author into an
        // absent one, and an empty `dc:creator` makes the whole file invalid.
        let creator = author.map { "\n    <dc:creator>\(escaped($0))</dc:creator>" } ?? ""
        // `properties="cover-image"` is how EPUB 3 names the picture a reading
        // system puts on its shelf; without it the file is just an image nobody
        // looks at.
        let coverItem = cover.map {
            """
            \n    <item id="cover-image" href="\($0.href)" media-type="\($0.mediaType)" \
            properties="cover-image"/>
            """
        } ?? ""
        let manifest = chapters.indices
            .map { index in
                """
                    <item id="\(chapterId(index))" href="\(chapterHref(index))" \
                media-type="application/xhtml+xml"/>
                """
            }
            .joined(separator: "\n")
        let spine = chapters.indices
            .map { "    <itemref idref=\"\(chapterId($0))\"/>" }
            .joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" \
        unique-identifier="book-id" xml:lang="und">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="book-id">novelreader:\(escaped(identifier))</dc:identifier>
            <dc:title>\(escaped(title))</dc:title>\(creator)
            <dc:language>und</dc:language>
            <meta property="dcterms:modified">\(timestamp(modified))</meta>
          </metadata>
          <manifest>
            <item id="nav" href="\(navHref)" media-type="application/xhtml+xml" properties="nav"/>
            <item id="style" href="\(styleHref)" media-type="text/css"/>
            <item id="titlepage" href="\(titlePageHref)" media-type="application/xhtml+xml"/>\(coverItem)
        \(manifest)
          </manifest>
          <spine>
            <itemref idref="titlepage" linear="no"/>
        \(spine)
          </spine>
        </package>
        """
    }

    /// EPUB 3's navigation document, which is where a reading system — and this
    /// app's own importer — takes the chapter names from.
    ///
    /// Kept out of the spine on purpose. It is a table of contents, not a
    /// chapter: putting it in the reading order would open the book on a list of
    /// links, and our own importer would faithfully turn that list into chapter
    /// one.
    ///
    /// The title page leads the list, labelled with the book's own name. That is
    /// what makes it reachable — EPUB 3 asks that non-linear content be — without
    /// inventing an English "Title page" to sit at the top of a Chinese novel.
    private static func navigation(title: String, chapters: [String]) -> String {
        let entries = [(titlePageHref, title)]
            + chapters.enumerated().map { (chapterHref($0.offset), $0.element) }
        let items = entries
            .map { href, label in "      <li><a href=\"\(href)\">\(escaped(label))</a></li>" }
            .joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" \
        xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="und">
          <head>
            <title>\(escaped(title))</title>
            <link rel="stylesheet" type="text/css" href="\(styleHref)"/>
          </head>
          <body>
            <nav epub:type="toc" id="toc">
              <h1>\(escaped(title))</h1>
              <ol>
        \(items)
              </ol>
            </nav>
          </body>
        </html>
        """
    }

    /// One chapter.
    ///
    /// The heading is repeated inside the body as well as in `<head><title>`
    /// because that is what a reader displays, and it costs nothing on the way
    /// back in: the extractor an imported EPUB goes through recognises the
    /// heading it has already taken as the title and drops the echo.
    private static func document(title: String, paragraphs: [String]) -> String {
        let body = paragraphs
            .map { "    <p>\(escaped($0))</p>" }
            .joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="und">
          <head>
            <title>\(escaped(title))</title>
            <link rel="stylesheet" type="text/css" href="../\(styleHref)"/>
          </head>
          <body>
            <h1>\(escaped(title))</h1>
        \(body)
          </body>
        </html>
        """
    }

    /// `CCYY-MM-DDThh:mm:ssZ`, the only form EPUB accepts for a date.
    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    /// Escapes text for XML and drops the characters XML cannot carry at all.
    ///
    /// The dropping is the part that matters. These paragraphs came out of
    /// arbitrary web pages, and a single stray control character — a 0x0b left
    /// behind by a mis-decoded page — makes the whole document unparseable, which
    /// would mean an EPUB nothing can open, this app included. Removing the
    /// character loses nothing anybody would have seen on screen.
    private static func escaped(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "\t", "\n", "\r": result.unicodeScalars.append(scalar)
            default: if scalar.value >= 0x20 { result.unicodeScalars.append(scalar) }
            }
        }
        return result
    }

    // MARK: - Naming

    /// A filename from a book's title.
    ///
    /// A blacklist, unlike `ChapterFileStore.safeComponent`'s whitelist: that one
    /// protects a path the user never sees and can afford to reduce a Chinese
    /// title to underscores, while this name is the first thing they read in the
    /// save sheet. So only what genuinely cannot survive a filesystem or a share
    /// sheet is replaced.
    static func filename(from title: String) -> String {
        let forbidden = CharacterSet(charactersIn: ":/\\?%*|\"<>")
        var cleaned = ""
        for scalar in title.unicodeScalars {
            let unusable = forbidden.contains(scalar) || scalar.value < 0x20
            cleaned.unicodeScalars.append(unusable ? " " : scalar)
        }
        // Leading dots hide the file; runs of whitespace are what replacing the
        // forbidden characters leaves behind. The cap keeps the name well clear of
        // the filesystem's own limit once an extension is appended.
        let collapsed = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let trimmed = String(collapsed.drop { $0 == "." }.prefix(80))
            .trimmingCharacters(in: .whitespaces)
        // Not localised: this only appears for a title made entirely of
        // punctuation, and a name is more useful to the user than a sentence.
        return trimmed.isEmpty ? "book" : trimmed
    }
}

/// Why an export produced nothing, in the user's language.
enum BookExportError: LocalizedError {
    /// Every chapter of the book is still on the site.
    case nothingOnDevice

    var errorDescription: String? {
        switch self {
        case .nothingOnDevice:
            return String(localized: "book.export.error.empty")
        }
    }
}
