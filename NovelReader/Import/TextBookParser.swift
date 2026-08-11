import Foundation

/// Reads a plain-text novel: works out the encoding, then finds the chapters.
///
/// Both halves are guesses, and both are guesses that fail loudly rather than
/// subtly if they are wrong — a mis-detected encoding turns the whole book into
/// mojibake, and a missed chapter pattern turns it into one unscrollable wall of
/// text — so the ordering and the thresholds below are the substance of this
/// type, not the mechanics.
enum TextBookParser {
    // MARK: - Encoding

    /// Decodes the file, trying encodings in the only order that is safe:
    ///
    /// 1. A byte-order mark, when there is one. It is the file telling us
    ///    outright, so nothing else gets a say.
    /// 2. Strict UTF-8. `String(data:encoding:.utf8)` rejects invalid
    ///    sequences, so a file that decodes cleanly this way essentially is
    ///    UTF-8: the multi-byte structure is far too specific to hit by
    ///    accident with Big5 or GBK bytes.
    /// 3. Big5, then GB18030 — and *never* the other way round. GB18030 is a
    ///    complete mapping of Unicode: it accepts almost any byte sequence and
    ///    therefore "succeeds" on Big5 input, producing plausible-looking
    ///    Simplified nonsense. Big5 has undefined pairs, so it can still fail,
    ///    which is what makes it a usable test.
    static func decode(_ data: Data) -> String? {
        if let marked = decodeUsingByteOrderMark(data) { return marked }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        for encoding in [big5, gb18030] {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        return nil
    }

    private static func decodeUsingByteOrderMark(_ data: Data) -> String? {
        let head = [UInt8](data.prefix(3))
        if head.starts(with: [0xef, 0xbb, 0xbf]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if head.starts(with: [0xff, 0xfe]) {
            return String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        }
        if head.starts(with: [0xfe, 0xff]) {
            return String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        }
        return nil
    }

    /// Neither legacy Chinese encoding has a `String.Encoding` constant; both
    /// have to be looked up through CoreFoundation's table.
    private static let big5 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.big5.rawValue)
        )
    )

    private static let gb18030 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
    )

    // MARK: - Chapters

    /// Splits the text into chapters at heading lines, falling back to
    /// fixed-length parts when there are no headings to split on.
    ///
    /// - Parameter partLength: how many characters a fallback part holds. The
    ///   fallback is not a nicety: the reader renders a whole chapter as one
    ///   stack of `Text` views, so a 2 MB file arriving as a single chapter is
    ///   both unscrollable and a memory problem.
    static func chapters(from text: String, partLength: Int = 4_000) -> [ImportedChapter] {
        let paragraphs = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let regex = try? NSRegularExpression(pattern: headingPattern)
        var found: [ImportedChapter] = []
        var title: String?
        var body: [String] = []

        func flush() {
            // A heading with nothing under it is dropped rather than becoming an
            // empty chapter: two headings in a row happen (a volume title
            // immediately followed by a chapter title), and a chapter that opens
            // to a blank page reads as a bug.
            guard !body.isEmpty else { return }
            found.append(
                ImportedChapter(
                    title: title ?? String(localized: "library.import.preface"),
                    paragraphs: body
                )
            )
            body = []
        }

        for paragraph in paragraphs {
            if isHeading(paragraph, regex) {
                flush()
                title = paragraph
            } else {
                body.append(paragraph)
            }
        }
        flush()

        // One chapter out of a long file means the headings are written in some
        // shape this pattern does not know. Parts are a worse table of contents
        // but a working book; a single 2 MB chapter is neither.
        let length = paragraphs.reduce(0) { $0 + $1.count }
        if found.count <= 1 && length > partLength { return parts(of: paragraphs, length: partLength) }
        return found
    }

    /// Headings as these files actually write them: `第十七章`, `第3卷`, `第一回`,
    /// `第５話`, `第二節`, plus the handful of unnumbered section names that are
    /// just as common in Chinese web novels as the numbered ones.
    ///
    /// Chinese numerals are listed explicitly rather than matched as "any
    /// characters": `第一章` and `第三部分の話` differ only in what sits between
    /// `第` and the unit, and a permissive class there promotes ordinary
    /// sentences into chapter breaks.
    private static let headingPattern = """
        ^(?:\
        第[0-9０-９〇零一二三四五六七八九十百千萬万兩两廿]{1,12}[章卷回話话節节篇集部]\
        |序章|序言|楔子|引子|前言|後記|后记|終章|终章|尾聲|尾声|番外\
        )
        """

    /// A heading is a single short line that starts like one.
    ///
    /// Punctuation is allowed to appear anywhere, including at the end: real
    /// headings carry it ("第一章 上京：雪夜"), and rejecting a trailing 。／！ to
    /// protect against a paragraph *opening* with "第三章的內容其實是……" bought that
    /// protection by silently dropping headings people actually write. The length
    /// cap alone draws the line: a 30-character ceiling is roomy for a title and
    /// short for prose. The cost is accepted and stated — a body line that begins
    /// with a chapter reference and stays under the cap becomes a chapter break.
    ///
    /// Lines are what the splitter iterates over, so "single line" is structural
    /// rather than checked: a heading cannot span a newline because a newline is
    /// what ended it.
    private static func isHeading(_ line: String, _ regex: NSRegularExpression?) -> Bool {
        guard let regex, line.count <= 30 else { return false }
        return regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// Cuts at paragraph boundaries, never mid-sentence: a part that starts
    /// half-way through a line is worse than one that runs slightly long.
    private static func parts(of paragraphs: [String], length: Int) -> [ImportedChapter] {
        var result: [ImportedChapter] = []
        var body: [String] = []
        var used = 0

        func flush() {
            guard !body.isEmpty else { return }
            result.append(
                ImportedChapter(
                    title: String(localized: "library.import.part \(result.count + 1)"),
                    paragraphs: body
                )
            )
            body = []
            used = 0
        }

        for paragraph in paragraphs {
            body.append(paragraph)
            used += paragraph.count
            if used >= length { flush() }
        }
        flush()
        return result
    }
}
