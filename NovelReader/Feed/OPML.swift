import Foundation

/// The subscription list as a file, in the format every feed reader has agreed on since
/// 2005.
///
/// This is what makes a shelf of subscriptions the reader's rather than this app's: an
/// OPML file is how a list moves to NetNewsWire, to Reeder, to a browser, and back. A
/// reader who cannot get their feeds out of an app is a reader who has to think about
/// whether to put them in.
///
/// Read with `XMLTree` and written with string interpolation, which is not a double
/// standard: reading OPML means surviving whatever twenty years of exporters have
/// produced, and writing it means emitting one shape this app controls entirely.
enum OPML {
    struct Subscription: Equatable {
        var title: String?
        var address: String
    }

    // MARK: - Reading

    /// Every feed in the document, folders flattened.
    ///
    /// Flattened because this app has no folders. An import that dropped everything
    /// inside one would silently lose most of a list from any reader that does — folders
    /// are how people with forty subscriptions keep them — and there is nothing to be
    /// gained by refusing what we can plainly read.
    ///
    /// An outline with no `xmlUrl` is a folder or a note, and is skipped rather than
    /// reported: it is not an error in the file, it is the file having structure.
    static func subscriptions(in data: Data) -> [Subscription] {
        guard let root = XMLTree.parse(data) else { return [] }
        var seen = Set<String>()
        return root.all("outline").compactMap { outline in
            let attributes = outline.attributes.reduce(into: [String: String]()) {
                // OPML says `xmlUrl`; exporters have written `xmlurl` and `XMLURL`, and a
                // reader that insists on the spelling loses the whole file over it.
                $0[$1.key.lowercased()] = $1.value
            }
            guard let address = attributes["xmlurl"]?.nonBlank, seen.insert(address).inserted
            else { return nil }
            // `title` is the OPML attribute for it; `text` is what the specification
            // requires every outline to carry and what most exporters actually fill in.
            let title = attributes["title"]?.nonBlank ?? attributes["text"]?.nonBlank
            return Subscription(title: title, address: address)
        }
    }

    // MARK: - Writing

    /// The list as a document, ready to be handed to another reader.
    ///
    /// `type="rss"` on every outline whatever the feed is actually written in. It is what
    /// the format says and what every importer keys off; "atom" and "json" appear in the
    /// wild and are read by nothing.
    static func document(
        title: String, subscriptions: [Subscription], now: Date = Date()
    ) -> String {
        let outlines = subscriptions.map { subscription in
            let name = XMLTree.escaping(subscription.title ?? subscription.address, quotes: true)
            let address = XMLTree.escaping(subscription.address, quotes: true)
            // `text` and `title` both, with the same value: importers disagree about which
            // one names a feed, and a file that fills in only one shows up in the other
            // half of them as a list of blank rows.
            return #"    <outline text="\#(name)" title="\#(name)" type="rss" xmlUrl="\#(address)"/>"#
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="1.0">
          <head>
            <title>\(XMLTree.escaping(title))</title>
            <dateCreated>\(rfc822.string(from: now))</dateCreated>
          </head>
          <body>
        \(outlines.joined(separator: "\n"))
          </body>
        </opml>
        """
    }

    /// The date format OPML inherited from RSS. Pinned to `en_US_POSIX` and GMT for the
    /// reason every date formatter in this app is: the month is written as text, and on a
    /// device set to Chinese the current locale writes 「十月」.
    private static let rfc822: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()
}
