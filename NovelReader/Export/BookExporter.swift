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
    }

    /// A finished export, held in memory rather than written to a temporary file:
    /// the destination is chosen afterwards, in the system's own save sheet, and
    /// a temporary copy would only be a second thing to clean up.
    struct Export {
        let format: Format
        let data: Data
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

    let downloads: DownloadStore

    func export(book: Book, chapters: [Chapter], format: Format) async throws -> Export {
        var written: [ImportedChapter] = []
        for chapter in chapters where chapter.isDownloaded {
            // `try?`, and empty paragraphs skipped: the flag can outlive the file
            // (see `LocalBookError.contentDeleted`), and a chapter whose text has
            // gone missing is a chapter this file cannot contain. Counting it as
            // absent is what keeps `isPartial` honest.
            guard let paragraphs = try? downloads.readParagraphs(
                book: book, siteChapterId: chapter.siteChapterId
            ), !paragraphs.isEmpty else { continue }
            written.append(ImportedChapter(title: chapter.title, paragraphs: paragraphs))
        }
        guard !written.isEmpty else { throw BookExportError.nothingOnDevice }

        let data: Data
        switch format {
        case .text:
            data = Self.text(written)
        case .epub:
            data = Self.epub(
                title: book.shownName, author: book.author, identifier: book.id,
                modified: book.addedAt, chapters: written
            )
        }
        return Export(
            format: format,
            data: data,
            filename: Self.filename(from: book.shownName),
            chapterCount: written.count,
            catalogCount: chapters.count
        )
    }

    // MARK: - Plain text

    /// Heading, blank line, then one paragraph per line with a blank line between.
    ///
    /// That shape is what `TextBookParser` reads back — it splits on newlines and
    /// drops the empty ones, so the blank lines cost nothing on the way in and are
    /// what makes the file readable in anything else.
    ///
    /// One limitation is inherent and deliberate: a chapter title the parser's
    /// heading pattern does not recognise (a part number, an English chapter name)
    /// comes back as the first line of the body rather than as a title. The only
    /// fix would be a marker of our own invention, which would make the file worse
    /// for every reader that is not this app.
    private static func text(_ chapters: [ImportedChapter]) -> Data {
        let body = chapters
            .map { ([$0.title] + $0.paragraphs).joined(separator: "\n\n") }
            .joined(separator: "\n\n")
        return Data((body + "\n").utf8)
    }

    // MARK: - EPUB

    private static let opfPath = "OEBPS/content.opf"
    private static let navPath = "OEBPS/nav.xhtml"

    /// A minimal EPUB 3: the OCF `mimetype`, the container, one package document,
    /// a nav document, and one XHTML file per chapter.
    ///
    /// `mimetype` is first and stored because OCF requires exactly that — a
    /// reader is allowed to identify an EPUB by reading a fixed offset near the
    /// start of the file, which only works if the bytes are uncompressed and the
    /// entry is where it says it will be.
    private static func epub(
        title: String, author: String?, identifier: String, modified: Date,
        chapters: [ImportedChapter]
    ) -> Data {
        var entries: [ZipBuilder.Entry] = [
            ZipBuilder.Entry(name: "mimetype", text: "application/epub+zip", compressed: false),
            ZipBuilder.Entry(name: "META-INF/container.xml", text: """
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles>
                <rootfile full-path="\(opfPath)" media-type="application/oebps-package+xml"/>
              </rootfiles>
            </container>
            """),
        ]

        let hrefs = chapters.indices.map { "text/\(documentName($0))" }
        entries.append(
            ZipBuilder.Entry(name: opfPath, text: package(
                title: title, author: author, identifier: identifier,
                modified: modified, chapters: chapters, hrefs: hrefs
            ))
        )
        entries.append(
            ZipBuilder.Entry(name: navPath, text: navigation(
                title: title, chapters: chapters, hrefs: hrefs
            ))
        )
        for (index, chapter) in chapters.enumerated() {
            entries.append(
                ZipBuilder.Entry(
                    name: "OEBPS/\(hrefs[index])", text: document(chapter)
                )
            )
        }
        return ZipBuilder.archive(entries)
    }

    /// Zero-padded so the documents sort in reading order for anyone who unzips
    /// the file, the same reason `LocalBookImporter` pads its chapter ids.
    private static func documentName(_ index: Int) -> String {
        String(format: "chapter-%05d.xhtml", index + 1)
    }

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
        chapters: [ImportedChapter], hrefs: [String]
    ) -> String {
        let creator = author.map { "\n    <dc:creator>\(escaped($0))</dc:creator>" } ?? ""
        let manifest = chapters.indices
            .map { index in
                """
                    <item id="\(chapterId(index))" href="\(hrefs[index])" \
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
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
        \(manifest)
          </manifest>
          <spine>
        \(spine)
          </spine>
        </package>
        """
    }

    private static func chapterId(_ index: Int) -> String { "c\(index + 1)" }

    /// EPUB 3's navigation document, which is where a reading system — and this
    /// app's own importer — takes the chapter names from.
    ///
    /// Kept out of the spine on purpose. It is a table of contents, not a
    /// chapter: putting it in the reading order would open the book on a list of
    /// links, and our own importer would faithfully turn that list into chapter
    /// one.
    private static func navigation(
        title: String, chapters: [ImportedChapter], hrefs: [String]
    ) -> String {
        let items = chapters.enumerated()
            .map { index, chapter in
                "      <li><a href=\"\(hrefs[index])\">\(escaped(chapter.title))</a></li>"
            }
            .joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" \
        xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="und">
          <head>
            <title>\(escaped(title))</title>
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
    private static func document(_ chapter: ImportedChapter) -> String {
        let paragraphs = chapter.paragraphs
            .map { "    <p>\(escaped($0))</p>" }
            .joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="und">
          <head>
            <title>\(escaped(chapter.title))</title>
          </head>
          <body>
            <h1>\(escaped(chapter.title))</h1>
        \(paragraphs)
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
