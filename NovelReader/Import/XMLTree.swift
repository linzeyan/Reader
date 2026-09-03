import Foundation

/// A minimal read-only XML tree.
///
/// Importing an EPUB means reading four different XML documents — the OCF
/// container, the OPF package, `toc.ncx`, and the EPUB 3 nav document — and all
/// four are read the same way: find elements by name, read attributes, read
/// text. `XMLParser` is the only XML reader in the iOS frameworks and it is a
/// streaming SAX interface, so this wraps it into a tree once instead of
/// spreading four delegate implementations across the importer.
final class XMLTree {
    /// Element name with any namespace prefix removed.
    let name: String
    /// Attributes, likewise with prefixes removed.
    let attributes: [String: String]

    /// Text and child elements in document order. Kept interleaved so that
    /// `text` reassembles a label like `<a>Chapter <b>1</b> begins</a>` in the
    /// order a human wrote it, which a "own text first, children after" model
    /// would silently scramble.
    private enum Content {
        case text(String)
        case element(XMLTree)
    }

    private var contents: [Content] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    // MARK: - Reading

    var children: [XMLTree] {
        contents.compactMap { content in
            guard case .element(let child) = content else { return nil }
            return child
        }
    }

    /// All text under this element, concatenated.
    var text: String {
        contents.map { content in
            switch content {
            case .text(let string): return string
            case .element(let child): return child.text
            }
        }
        .joined()
    }

    /// The first descendant with this name, depth-first. Descendants rather than
    /// direct children because producers disagree about how deeply they nest —
    /// `<metadata><dc:title>` and `<metadata><dc-metadata><dc:title>` both
    /// occur — and nothing we look up here is ambiguous by name.
    func first(_ name: String) -> XMLTree? {
        for child in children {
            if child.name == name { return child }
            if let found = child.first(name) { return found }
        }
        return nil
    }

    /// Every descendant with this name, in document order.
    func all(_ name: String) -> [XMLTree] {
        children.flatMap { child in
            child.name == name ? [child] + child.all(name) : child.all(name)
        }
    }

    /// This element's children written back out as HTML.
    ///
    /// For the one producer that needs it: an Atom `<content type="xhtml">` holds real
    /// elements rather than escaped text, so `text` would hand the reader a whole
    /// article as one paragraph-less run of prose. Everything downstream of a feed
    /// reads HTML, so the subtree is written back into it.
    ///
    /// Attributes come out in name order because the dictionary holding them has no
    /// order of its own, and markup that differs between two runs is markup no test
    /// can pin.
    var innerHTML: String {
        contents.map { content in
            switch content {
            case .text(let string): return Self.escaping(string)
            case .element(let child): return child.outerHTML
            }
        }
        .joined()
    }

    private var outerHTML: String {
        let written = attributes.sorted { $0.key < $1.key }
            .map { " \($0.key)=\"\(Self.escaping($0.value, quotes: true))\"" }
            .joined()
        // A void element written as `<br></br>` is *two* line breaks to an HTML parser,
        // and `<p/>` is a paragraph that never closes. The two shapes are not
        // interchangeable, so the element decides which one it gets.
        if Self.voidElements.contains(name.lowercased()) {
            return "<\(name)\(written) />"
        }
        return "<\(name)\(written)>\(innerHTML)</\(name)>"
    }

    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
        "param", "source", "track", "wbr",
    ]

    /// Ampersand first: escaping it after the others would turn the `&` this very
    /// function just wrote into `&amp;lt;`.
    /// Not private, for the one writer outside this file: `OPML` builds a document by
    /// hand and needs the same five replacements. Two escapers is how one of them ends up
    /// forgetting `&`.
    static func escaping(_ raw: String, quotes: Bool = false) -> String {
        var escaped = raw
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        if quotes { escaped = escaped.replacingOccurrences(of: "\"", with: "&quot;") }
        return escaped
    }

    // MARK: - Parsing

    /// Returns nil rather than throwing, and every caller has to decide what a
    /// nil means for it. That difference matters: a broken OPF makes the book
    /// unimportable, while a nav document that does not parse — XHTML full of
    /// HTML entities `XMLParser` has never heard of is common — only costs the
    /// chapter titles, which the importer can find another way.
    static func parse(_ data: Data) -> XMLTree? {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        // Namespaces off and prefixes stripped by hand: EPUB producers disagree
        // about which prefix goes on what (`dc:title` or `title`, `opf:role`,
        // `epub:type`), and every name we look up here is unambiguous without
        // one.
        parser.shouldProcessNamespaces = false
        guard parser.parse() else { return nil }
        return builder.root
    }

    private func append(_ child: XMLTree) { contents.append(.element(child)) }
    private func append(text: String) { contents.append(.text(text)) }

    private static func localName(_ raw: String) -> String {
        guard let colon = raw.lastIndex(of: ":") else { return raw }
        return String(raw[raw.index(after: colon)...])
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLTree?
        private var stack: [XMLTree] = []

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            var attributes: [String: String] = [:]
            for (key, value) in attributeDict { attributes[XMLTree.localName(key)] = value }
            let node = XMLTree(name: XMLTree.localName(elementName), attributes: attributes)
            stack.last?.append(node)
            if root == nil { root = node }
            stack.append(node)
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            if !stack.isEmpty { stack.removeLast() }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.append(text: string)
        }

        /// CDATA arrives through its own callback and through no other: the contents of
        /// `<description><![CDATA[<p>…</p>]]></description>` never reach
        /// `foundCharacters`, so without this the element reads as empty. That is how
        /// nearly every RSS feed carries its article bodies, and how many EPUB nav
        /// documents carry their styles.
        ///
        /// Bytes that are not UTF-8 are dropped rather than guessed at: a CDATA block
        /// that is not text is embedded binary, and nothing that reads this tree has a
        /// use for one.
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard let text = String(data: CDATABlock, encoding: .utf8) else { return }
            stack.last?.append(text: text)
        }
    }
}
