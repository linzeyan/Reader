import Foundation

/// Reads the four formats a subscription can arrive in.
///
/// RSS 2.0, RSS 1.0/RDF, Atom and JSON Feed. Which one a feed is written in is the
/// publisher's choice and nothing the reader should ever have to know, so the format is
/// decided from the bytes and the four readers hand back the same `ParsedFeed`.
///
/// Nothing here reaches the network and nothing here is a rule: a feed says what it is.
/// That is the whole reason feeds can be added by pasting an address while a novel site
/// needs a rule file — and it is why this type is pure, and testable against saved
/// documents rather than against a site that may be down.
enum FeedParser {
    enum ParseError: LocalizedError {
        /// The bytes are not any of the four formats. Overwhelmingly this is an HTML
        /// page — the address the reader pasted is a website, not its feed — which is
        /// why the message says so rather than blaming the document.
        case unrecognisedFormat

        var errorDescription: String? {
            switch self {
            case .unrecognisedFormat: return String(localized: "feed.error.notAFeed")
            }
        }
    }

    /// - Parameter url: the address the document was fetched from. Needed because feeds
    ///   publish relative links, and a link that cannot be resolved is a link that opens
    ///   nothing.
    static func parse(_ data: Data, url: URL) throws -> ParsedFeed {
        if opensWithBrace(data) { return try jsonFeed(data, feedURL: url) }
        guard let root = tree(from: data) else { throw ParseError.unrecognisedFormat }
        switch root.name.lowercased() {
        // RSS 2.0 and RSS 1.0/RDF are read by one function. They disagree about where
        // the items sit — inside `<channel>` in 2.0, beside it in 1.0 — and about which
        // element holds the date, and both differences are already absorbed: items are
        // collected from the document rather than from the channel, and `<pubDate>` and
        // `<dc:date>` are both consulted. Nothing else about them differs.
        case "rss", "rdf": return rss(root, feedURL: url)
        case "feed": return atom(root, feedURL: url)
        default: throw ParseError.unrecognisedFormat
        }
    }

    // MARK: - Which format

    /// Whether the document is JSON.
    ///
    /// The opening character, not the `Content-Type`: hosts serve JSON Feed as
    /// `application/json`, `application/feed+json`, `text/plain` and occasionally
    /// `text/html`, so the header is the one piece of evidence that cannot be relied on.
    /// Only the first bytes are examined, past a byte-order mark and any leading
    /// whitespace, because that is as far as the answer can be hiding.
    private static func opensWithBrace(_ data: Data) -> Bool {
        for byte in data.prefix(64) {
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF: continue
            default: return byte == UInt8(ascii: "{")
            }
        }
        return false
    }

    // MARK: - XML

    /// The document as a tree, healing the one thing that reliably breaks it.
    private static func tree(from data: Data) -> XMLTree? {
        if let tree = XMLTree.parse(data) { return tree }
        guard let healed = healingEntities(in: data) else { return nil }
        return XMLTree.parse(healed)
    }

    /// Rewrites the named HTML entities that XML has never defined.
    ///
    /// XML defines five: `&amp;` `&lt;` `&gt;` `&quot;` `&apos;`. HTML defines hundreds,
    /// and feeds are written by people thinking in HTML, so `&nbsp;` and `&mdash;` turn
    /// up in titles constantly. `XMLParser` treats an undefined entity as a fatal error,
    /// so one em dash in one headline costs the reader the entire feed.
    ///
    /// Only after a parse has already failed, never on the way in: healthy documents are
    /// the overwhelming majority and this walks every byte of one.
    ///
    /// An entity this does not know is escaped rather than dropped or left as it is.
    /// Left as it is, the retry fails exactly like the first attempt and the feed is
    /// still lost; dropped, it silently eats text nobody can see is missing. Escaped, it
    /// shows up as the literal `&frobnicate;` the publisher wrote — one wrong word in an
    /// article that is otherwise readable, which is the honest outcome.
    private static func healingEntities(in data: Data) -> Data? {
        // A document that is not UTF-8 cannot be repaired here: `XMLParser` decodes it
        // from the declaration in its own prologue, and this has no such declaration to
        // read. Returning nil leaves the original failure standing, which is correct —
        // pretending to have fixed it would only move the error somewhere less clear.
        guard let text = String(data: data, encoding: .utf8),
              let pattern = try? NSRegularExpression(pattern: "&([A-Za-z][A-Za-z0-9]{1,30});")
        else { return nil }

        var healed = ""
        var cursor = text.startIndex
        // Forward, appending slices, rather than replacing in place from the back:
        // indices taken from one string are not valid in another, and the "same
        // storage" that makes the reversed version appear to work is not something the
        // language promises.
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text),
                  let nameRange = Range(match.range(at: 1), in: text)
            else { continue }
            healed += text[cursor..<whole.lowerBound]
            let name = String(text[nameRange])
            if xmlEntities.contains(name) {
                healed += text[whole]
            } else if let code = htmlEntities[name] {
                healed += "&#\(code);"
            } else {
                healed += "&amp;\(name);"
            }
            cursor = whole.upperBound
        }
        healed += text[cursor...]
        return Data(healed.utf8)
    }

    private static let xmlEntities: Set<String> = ["amp", "lt", "gt", "quot", "apos"]

    /// The named entities that actually turn up in feed prose, as code points.
    ///
    /// Deliberately not all of HTML's several hundred: the long tail is chemistry and
    /// mathematics symbols that no article title has ever contained, and every entry
    /// here is a line of code carried forever. What is missing degrades to a visible
    /// literal rather than to a lost feed, so the list can be short without being risky.
    private static let htmlEntities: [String: Int] = [
        "nbsp": 160, "iexcl": 161, "cent": 162, "pound": 163, "curren": 164, "yen": 165,
        "sect": 167, "copy": 169, "laquo": 171, "not": 172, "shy": 173, "reg": 174,
        "deg": 176, "plusmn": 177, "micro": 181, "para": 182, "middot": 183,
        "raquo": 187, "frac14": 188, "frac12": 189, "frac34": 190, "iquest": 191,
        "times": 215, "divide": 247, "ndash": 8211, "mdash": 8212, "lsquo": 8216,
        "rsquo": 8217, "sbquo": 8218, "ldquo": 8220, "rdquo": 8221, "bdquo": 8222,
        "dagger": 8224, "Dagger": 8225, "bull": 8226, "hellip": 8230, "permil": 8240,
        "prime": 8242, "Prime": 8243, "lsaquo": 8249, "rsaquo": 8250, "euro": 8364,
        "trade": 8482, "larr": 8592, "uarr": 8593, "rarr": 8594, "darr": 8595,
        "minus": 8722, "ne": 8800, "le": 8804, "ge": 8805,
    ]

    // MARK: - RSS 2.0 and RDF

    private static func rss(_ root: XMLTree, feedURL: URL) -> ParsedFeed {
        // The channel where there is one, and the root where there is not: a document
        // that has lost its `<channel>` still has items, and the reader wants those far
        // more than they want a title.
        let channel = root.child("channel") ?? root
        return ParsedFeed(
            title: channel.childText("title"),
            homePageURL: absolute(siteLink(of: channel), feedURL),
            iconURL: absolute(channel.child("image")?.childText("url"), feedURL),
            items: root.all("item").map { rssItem($0, feedURL: feedURL) }
        )
    }

    private static func rssItem(_ item: XMLTree, feedURL: URL) -> ParsedItem {
        ParsedItem(
            guid: item.childText("guid"),
            url: absolute(siteLink(of: item), feedURL),
            title: item.childText("title"),
            // `content:encoded` first — the namespace prefix is stripped by `XMLTree`,
            // hence the bare name. RSS specifies `<description>` as a *summary*, and a
            // site that fills both puts the whole article in one and a teaser sentence
            // in the other. Reading them the other way round would hand the reader a
            // library of one-paragraph articles ending in "read more".
            contentHTML: item.childText("encoded") ?? item.childText("description"),
            // `<dc:date>` is the fallback because RSS 1.0 has no `<pubDate>` at all.
            datePublished: FeedDate.parse(item.childText("pubDate") ?? item.childText("date")),
            // `<dc:creator>` first: RSS's own `<author>` is specified as an email
            // address, and the feeds that fill both put the person's name in the other.
            author: item.childText("creator") ?? item.childText("author")
        )
    }

    // MARK: - Atom

    private static func atom(_ root: XMLTree, feedURL: URL) -> ParsedFeed {
        ParsedFeed(
            title: root.childText("title"),
            homePageURL: absolute(siteLink(of: root), feedURL),
            iconURL: absolute(root.childText("icon") ?? root.childText("logo"), feedURL),
            items: root.all("entry").map { atomEntry($0, feedURL: feedURL) }
        )
    }

    private static func atomEntry(_ entry: XMLTree, feedURL: URL) -> ParsedItem {
        ParsedItem(
            guid: entry.childText("id"),
            url: absolute(siteLink(of: entry), feedURL),
            title: entry.childText("title"),
            contentHTML: body(of: entry.child("content")) ?? body(of: entry.child("summary")),
            // `published` is when the article appeared; `updated` is when it last
            // changed, which is a different fact. It is the fallback rather than an
            // equal because Atom requires `updated` and makes `published` optional, so
            // for a good many feeds it is the only date on offer.
            datePublished: FeedDate.parse(
                entry.childText("published") ?? entry.childText("updated")
            ),
            author: entry.child("author")?.childText("name")
        )
    }

    /// An Atom body, which says what it is made of — and the three answers are not
    /// interchangeable.
    ///
    /// `xhtml` holds real elements rather than escaped text, so the subtree is written
    /// back out as markup; read as text it would arrive as one paragraph-less run of
    /// prose. `text` is not markup at all and is escaped into some, since everything
    /// downstream of here reads HTML. Anything else — including the common case of a
    /// publisher omitting the attribute while putting HTML in the element — is taken as
    /// the markup it appears to be.
    ///
    /// That last case departs from the specification, which says an absent `type` means
    /// `text`. Following it would escape the tags of every feed whose author forgot the
    /// attribute, and the reader would be looking at `<p>` printed on the page.
    private static func body(of element: XMLTree?) -> String? {
        guard let element else { return nil }
        switch element.attributes["type"]?.lowercased() {
        case "xhtml": return element.innerHTML.nonBlank
        case "text": return element.text.nonBlank.map(html(fromPlainText:))
        default: return element.text.nonBlank
        }
    }

    // MARK: - JSON Feed

    private static func jsonFeed(_ data: Data, feedURL: URL) throws -> ParsedFeed {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let document = try? decoder.decode(JSONFeedDocument.self, from: data),
              // `version` is what says this is a feed at all. Every other field is
              // optional, so without this check a JSON error page from a misconfigured
              // host decodes cleanly as a feed with no items — which would subscribe the
              // reader to nothing and report success.
              document.version?.nonBlank != nil
        else { throw ParseError.unrecognisedFormat }

        return ParsedFeed(
            title: document.title?.nonBlank,
            homePageURL: absolute(document.homePageUrl, feedURL),
            // `icon` is the large square one and `favicon` the small one; either is
            // better than the placeholder the shelf would otherwise draw.
            iconURL: absolute(document.icon ?? document.favicon, feedURL),
            items: (document.items ?? []).map { item in
                ParsedItem(
                    guid: item.id?.nonBlank,
                    // `external_url` is what a link blog points at: the item's own page
                    // is `url`, and only when there is none does the thing being linked
                    // to become the article's address.
                    url: absolute(item.url ?? item.externalUrl, feedURL),
                    title: item.title?.nonBlank,
                    contentHTML: item.contentHtml?.nonBlank
                        ?? item.contentText?.nonBlank.map(html(fromPlainText:))
                        ?? item.summary?.nonBlank,
                    datePublished: FeedDate.parse(item.datePublished),
                    // 1.1 publishes `authors`, 1.0 published `author`. Both are read
                    // because a feed written to either version is a feed in the wild.
                    author: item.authors?.compactMap { $0.name?.nonBlank }.first
                        ?? item.author?.name?.nonBlank
                )
            }
        )
    }

    /// Every field optional, including the ones the specification requires.
    ///
    /// A feed missing its title is still a feed full of articles, and refusing to decode
    /// it would lose the reader everything over a field they will never look at. The one
    /// field that is checked for presence is `version`, and it is checked above rather
    /// than by the decoder, so that its absence reports "this is not a feed" instead of
    /// a decoding error naming a key.
    private struct JSONFeedDocument: Decodable {
        struct Author: Decodable {
            let name: String?
        }

        struct Item: Decodable {
            let id: String?
            let url: String?
            let externalUrl: String?
            let title: String?
            let contentHtml: String?
            let contentText: String?
            let summary: String?
            let datePublished: String?
            let author: Author?
            let authors: [Author]?
        }

        let version: String?
        let title: String?
        let homePageUrl: String?
        let icon: String?
        let favicon: String?
        let items: [Item]?
    }

    // MARK: - Shared

    /// The web address an element points at.
    ///
    /// Text first, because that is where RSS 2.0 puts it. The `href` attribute is the
    /// fallback, which is what Atom uses and what the `<atom:link>` elements embedded in
    /// RSS feeds for autodiscovery carry. `rel="self"` is skipped: that one addresses
    /// the feed document itself, and taken as the article's address it would send a
    /// reader who asked for the original page to the XML they are already reading.
    private static func siteLink(of element: XMLTree) -> String? {
        let links = element.children.filter { $0.name == "link" }
        if let text = links.compactMap({ $0.text.nonBlank }).first { return text }
        return links.first { link in
            let rel = link.attributes["rel"]?.lowercased()
            return rel == nil || rel == "alternate"
        }?
        .attributes["href"]?.nonBlank
    }

    /// Resolves an address against the feed's own.
    ///
    /// Feeds publish relative links more often than they should — `/2026/09/a-post` —
    /// and a relative address is useless to everything that later opens it, since by
    /// then the document it was relative to is long gone.
    private static func absolute(_ raw: String?, _ feedURL: URL) -> String? {
        guard let text = raw?.nonBlank else { return nil }
        return URL(string: text, relativeTo: feedURL)?.absoluteURL.absoluteString
    }

    /// Plain text as the markup everything downstream reads.
    ///
    /// Escaped first, then broken at its line breaks: a body that is not markup still
    /// has paragraphs in it, and handed over as one string it would become one paragraph
    /// the length of an article. `<p>` rather than `<br>` because the extractor these go
    /// through splits on block elements.
    private static func html(fromPlainText text: String) -> String {
        text.components(separatedBy: .newlines)
            .compactMap { $0.nonBlank }
            .map { line in
                let escaped = line
                    .replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
                return "<p>\(escaped)</p>"
            }
            .joined()
    }
}

private extension XMLTree {
    /// The first *direct* child with this name.
    ///
    /// `first(_:)` searches descendants, which in a feed reaches inside the items:
    /// nothing requires a channel to declare its `<title>` before its first `<item>`,
    /// and one that does not would have the whole feed named after an article.
    func child(_ name: String) -> XMLTree? { children.first { $0.name == name } }

    func childText(_ name: String) -> String? { child(name)?.text.nonBlank }
}
