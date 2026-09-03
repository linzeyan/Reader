import Foundation

/// Finds the feed a web page advertises.
///
/// Nobody copies a feed address. What gets pasted is the address of the site — from the
/// browser's bar, from a message, off a business card — and the feed behind it is
/// declared in the page's own head, which is the convention every publishing platform
/// has emitted for twenty years:
///
///     <link rel="alternate" type="application/rss+xml" href="/feed.xml">
///
/// Only that declaration. Guessing at `/feed`, `/rss.xml` and the dozen other paths that
/// are sometimes right would turn one failed subscribe into a dozen requests aimed at a
/// site that never asked for them, and would still miss every publisher who files their
/// feed anywhere else.
///
/// Read with a scanner rather than by loading the page into the web view. What is needed
/// here is a handful of self-closing tags in the head, which is the one part of HTML that
/// can be read this way without regret — and the alternative is a round trip through a
/// browser engine, on a path whose whole job is to save the reader from a failure.
enum FeedDiscovery {
    /// The feed addresses the page declares, in the order it declares them.
    ///
    /// - Parameter pageURL: what the page was fetched from, which is what a relative
    ///   `href` is relative to. Feeds are declared as `/feed.xml` far more often than in
    ///   full, so this is not an edge case.
    static func feedURLs(inHTML data: Data, at pageURL: URL) -> [URL] {
        // The importer's decoder, which is already the app's answer to "bytes of text of
        // unknown encoding" — and its Big5-before-GB18030 order matters as much here as
        // there. Its one failure is answered lossily rather than given up on: a page whose
        // encoding nothing recognises still has ASCII tag syntax, and the bytes that will
        // not decode can only be in text this never looks at.
        let text = TextBookParser.decode(data) ?? String(decoding: data, as: UTF8.self)
        let html = head(of: text)
        var found: [(url: URL, isAside: Bool)] = []
        var seen = Set<URL>()

        for match in html.matches(of: linkTag) {
            let attributes = attributes(of: String(match.output))
            guard let rel = attributes["rel"]?.lowercased(),
                  rel.split(separator: " ").contains("alternate"),
                  let type = attributes["type"]?.lowercased(),
                  feedTypes.contains(type),
                  let href = attributes["href"]?.nonBlank,
                  let url = URL(string: unescaped(href), relativeTo: pageURL)?.absoluteURL,
                  seen.insert(url).inserted
            else { continue }
            found.append((url, isAside(attributes["title"], url)))
        }

        // A stable partition, not a filter: a comments feed is still a feed, and a site
        // that publishes nothing else is a site where it is the right answer.
        return found.filter { !$0.isAside }.map(\.url) + found.filter(\.isAside).map(\.url)
    }

    /// The first feed the page declares, which is the one to subscribe to.
    static func feedURL(inHTML data: Data, at pageURL: URL) -> URL? {
        feedURLs(inHTML: data, at: pageURL).first
    }

    /// Whether this is the feed a reader means when they paste a blog's address.
    ///
    /// WordPress declares a comments feed beside the posts feed on every page it serves,
    /// and it is the one an unlucky order would subscribe someone to — a stream of
    /// strangers arguing under articles they never see. The path is the check that
    /// carries: the title is in the site's own language, but `/comments/feed/` is
    /// generated and is the same in all of them.
    private static func isAside(_ title: String?, _ url: URL) -> Bool {
        let path = url.path.lowercased()
        if path.contains("comment") { return true }
        return title?.lowercased().contains("comment") ?? false
    }

    /// Everything up to `</head>`, or a first slice of the document if it has no head.
    ///
    /// A declaration below the head is not one the platform emitted, and the body is
    /// where the false positives live — a `<link>` written out by a script, a code sample
    /// showing this very tag. The cap is for the page that has no head at all, so that a
    /// megabyte of markup is not walked to answer a question the first screenful settles.
    private static func head(of html: String) -> Substring {
        if let end = html.range(of: "</head", options: [.caseInsensitive]) {
            return html[..<end.lowerBound]
        }
        return html.prefix(64_000)
    }

    private static let linkTag = /<link\b[^>]*>/.ignoresCase()

    /// One HTML attribute: unquoted, single- or double-quoted, in any order.
    private static let attributePair =
        /([a-zA-Z][a-zA-Z0-9:-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/

    private static func attributes(of tag: String) -> [String: String] {
        var attributes: [String: String] = [:]
        for match in tag.matches(of: attributePair) {
            let (_, name, doubleQuoted, singleQuoted, bare) = match.output
            guard let value = doubleQuoted ?? singleQuoted ?? bare else { continue }
            // First wins, matching how a browser reads a repeated attribute.
            attributes[name.lowercased()] = attributes[name.lowercased()] ?? String(value)
        }
        return attributes
    }

    /// The types worth following. `application/json` is deliberately absent: pages
    /// advertise API endpoints and manifests under it, and a subscription to one of those
    /// would fail in a way that reads as this app being broken.
    private static let feedTypes: Set<String> = [
        "application/rss+xml",
        "application/atom+xml",
        "application/rdf+xml",
        "application/feed+json"
    ]

    /// The five entities XML defines, which is what an `href` in a page's head carries —
    /// `&amp;` between query parameters, and nothing more exotic than that.
    private static func unescaped(_ value: String) -> String {
        guard value.contains("&") else { return value }
        return value
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            // Last: an `&amp;lt;` in a URL means the text `&lt;`, and doing this first
            // would turn it into a tag bracket.
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
