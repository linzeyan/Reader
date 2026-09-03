import Foundation

/// One piece of an article, in the shape it will be laid out in.
///
/// A novel chapter is prose: paragraph after paragraph, and `[String]` says everything
/// there is to say about it. An article is not — it has headings, a photograph, a
/// pull-quote, a code listing, and links inside its sentences — and every one of those was
/// being flattened into a line of text before this type existed, which is the difference
/// between reading the piece and reading a transcript of it.
///
/// A struct with a `kind` rather than an enum with associated values, because this crosses
/// two boundaries where an enum is awkward: it is the JSON the in-page extractor emits,
/// and it is the JSON stored on disk beside the article. Both want one flat object per
/// block with the fields that apply filled in.
///
/// Indexed exactly like a paragraph was: block *n* is anchor paragraph *n*, so a bookmark,
/// a highlight and a reading position keep meaning what they meant.
struct ArticleBlock: Codable, Equatable {
    enum Kind: String, Codable {
        case paragraph
        case heading
        case quote
        /// A listing. Held as one run of text rather than as runs, because what makes
        /// code readable is that nothing in it is interpreted.
        case code
        /// One item of a list, flattened. Nesting is carried by `level` and the marker is
        /// resolved by whoever emitted it — a reader does not need the tree, it needs the
        /// bullet in the right place.
        case listItem
        case image
        /// A horizontal rule, which publishers use as a section break often enough that
        /// dropping it silently joins two sections into one.
        case rule
    }

    var kind: Kind
    /// The text, split into runs wherever style or a link changes. Empty for an image or
    /// a rule.
    var runs: [InlineRun]
    /// Heading level 1…6, or list nesting depth from 1.
    var level: Int?
    /// The bullet or number a list item is drawn with, decided where the list structure
    /// was still visible.
    var marker: String?
    /// What the publisher said a listing is written in. Kept even though nothing
    /// highlights syntax yet: it is in the markup, it costs a string, and losing it means
    /// re-fetching every article to get it back.
    var language: String?
    var image: ImageRef?

    /// The block as one line of plain text.
    ///
    /// What everything that has not been taught about structure still asks for: the
    /// highlight gesture selecting a whole paragraph, the bookmark excerpt, the
    /// accessibility label of a laid-out frame. An image answers with its alt text,
    /// which is exactly what it is for.
    var plainText: String {
        switch kind {
        case .image: return image?.alt ?? ""
        case .rule: return ""
        case .listItem: return [marker, runs.map(\.text).joined()].compactMap { $0 }.joined(separator: " ")
        default: return runs.map(\.text).joined()
        }
    }

    static func paragraph(_ text: String) -> ArticleBlock {
        ArticleBlock(kind: .paragraph, runs: [InlineRun(text: text)])
    }
}

/// A stretch of text inside a block that is all one thing.
///
/// Links are the reason this exists at all. A link in the middle of a sentence cannot be
/// expressed by styling the block, and an article whose links are unmarked and untappable
/// is one where a third of what the author wrote — everything they pointed at — is gone.
struct InlineRun: Codable, Equatable {
    var text: String
    /// Absolute, resolved against the article's own address while the DOM still knew it.
    var href: String?
    var bold: Bool
    var italic: Bool
    /// Inline code, `like this`. Drawn in the monospaced face at the body size.
    var code: Bool

    init(text: String, href: String? = nil, bold: Bool = false, italic: Bool = false, code: Bool = false) {
        self.text = text
        self.href = href
        self.bold = bold
        self.italic = italic
        self.code = code
    }

    // Written out rather than synthesised: Swift's generated decoder does not fall back to
    // a property's default value for a missing key, and the flags are absent from most
    // runs the extractor emits — which would fail the decode of the whole article over a
    // word that simply is not bold.
    private enum CodingKeys: String, CodingKey { case text, href, bold, italic, code }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        href = try container.decodeIfPresent(String.self, forKey: .href)
        bold = try container.decodeIfPresent(Bool.self, forKey: .bold) ?? false
        italic = try container.decodeIfPresent(Bool.self, forKey: .italic) ?? false
        code = try container.decodeIfPresent(Bool.self, forKey: .code) ?? false
    }
}

/// A picture in an article: where it came from, and where it is now.
struct ImageRef: Codable, Equatable {
    /// The address the publisher gave. Kept after the file is stored — it is what a
    /// re-fetch would ask for, and the only honest thing to show for a picture that
    /// never arrived.
    var source: String
    /// File name inside the article's own image directory, once it is on the device. Nil
    /// while it is not: an image that would not download leaves the sentence around it
    /// readable rather than the article unopenable.
    var file: String?
    /// Pixel size of the *stored* file, which is what the layout scales from. Nil with
    /// `file`.
    var width: Int?
    var height: Int?
    var alt: String?

    private enum CodingKeys: String, CodingKey { case source, file, width, height, alt }

    init(source: String, file: String? = nil, width: Int? = nil, height: Int? = nil, alt: String? = nil) {
        self.source = source
        self.file = file
        self.width = width
        self.height = height
        self.alt = alt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
        file = try container.decodeIfPresent(String.self, forKey: .file)
        width = try container.decodeIfPresent(Int.self, forKey: .width)
        height = try container.decodeIfPresent(Int.self, forKey: .height)
        alt = try container.decodeIfPresent(String.self, forKey: .alt)
    }
}

extension ArticleBlock {
    private enum CodingKeys: String, CodingKey { case kind, runs, level, marker, language, image }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // An unknown kind reads as a paragraph rather than failing the article. This
        // format is written by the app for the app, so that can only happen across a
        // downgrade — where losing the styling of one block is the small failure and
        // refusing to open the article is the large one.
        kind = (try? container.decode(Kind.self, forKey: .kind)) ?? .paragraph
        runs = try container.decodeIfPresent([InlineRun].self, forKey: .runs) ?? []
        level = try container.decodeIfPresent(Int.self, forKey: .level)
        marker = try container.decodeIfPresent(String.self, forKey: .marker)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        image = try container.decodeIfPresent(ImageRef.self, forKey: .image)
    }
}
