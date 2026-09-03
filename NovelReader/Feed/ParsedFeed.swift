import CryptoKit
import Foundation

/// One feed's bytes, read into the shape the rest of the app works in.
///
/// Nothing here is rule-driven, unlike every other source this app reads: a feed is a
/// published, self-describing document, so there is no site-specific knowledge for a
/// rule file to carry and no `SiteRule` in the picture at all. What arrives here is
/// what the publisher wrote, in whichever of the four formats they wrote it.
struct ParsedFeed: Equatable {
    var title: String?
    /// The site the feed is about — not the feed's own address. It is where "open the
    /// original" goes for an item that carries no link of its own.
    var homePageURL: String?
    /// The feed's own picture, which becomes the shelf cover.
    var iconURL: String?
    var items: [ParsedItem]

    /// An empty feed is not an error. A blog that has published nothing yet, and one
    /// whose entire window has been consumed by a filter, are both subscribable — and
    /// refusing them here would mean the reader could only subscribe to feeds that
    /// happened to be busy the day they tried.
    init(title: String? = nil, homePageURL: String? = nil, iconURL: String? = nil, items: [ParsedItem] = []) {
        self.title = title
        self.homePageURL = homePageURL
        self.iconURL = iconURL
        self.items = items
    }
}

/// One article, as the feed publishes it.
struct ParsedItem: Equatable {
    /// What the publisher calls this item: RSS `<guid>`, Atom `<id>`, JSON Feed `id`.
    var guid: String?
    /// The article's own page on the web.
    var url: String?
    var title: String?
    /// The article body as markup. Whatever the format called it — `content:encoded`,
    /// `description`, Atom `content` or `summary`, JSON Feed `content_html` — it is
    /// one body by the time it gets here, because the reader draws one.
    var contentHTML: String?
    var datePublished: Date?
    var author: String?

    init(
        guid: String? = nil,
        url: String? = nil,
        title: String? = nil,
        contentHTML: String? = nil,
        datePublished: Date? = nil,
        author: String? = nil
    ) {
        self.guid = guid
        self.url = url
        self.title = title
        self.contentHTML = contentHTML
        self.datePublished = datePublished
        self.author = author
    }

    /// A stable name for this item, in the order the publisher's own answers deserve
    /// to be trusted.
    ///
    /// This becomes `Chapter.siteChapterId`, which is what the reading position,
    /// bookmarks and highlights all point at. So the two ways it can be wrong are both
    /// serious and opposite: an item that changes identity between two refreshes is an
    /// article the reader loses their place in *and* sees again as new, while two items
    /// sharing an identity are two articles collapsed into one, of which only the first
    /// is ever readable.
    ///
    /// The hash is a last resort for feeds that publish neither an id nor a link — rare,
    /// and not worth refusing a subscription over. It takes the title and the date
    /// together because either alone repeats within one feed: a recurring column shares
    /// its title, and everything published in one batch shares its date. The body is
    /// deliberately *not* in it — a publisher fixing a typo would otherwise republish
    /// the article as a new one.
    var identity: String {
        if let guid = guid?.nonBlank { return guid }
        if let url = url?.nonBlank { return url }
        let material = [title?.nonBlank, datePublished.map(String.init(describing:))]
            .compactMap { $0 }
            .joined(separator: "|")
        let digest = SHA256.hash(data: Data(material.utf8))
        return "sha256-" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
