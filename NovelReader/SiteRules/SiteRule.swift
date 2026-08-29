import Foundation

/// A declarative description of how to read one site.
///
/// The app ships with no rules at all: users add sources by importing a rule
/// file. Everything site-specific therefore has to be expressible here — any
/// `if site == "..."` in Swift is a bug, not a shortcut.
struct SiteRule: Codable, Identifiable, Hashable {
    /// What this source publishes, which decides how a chapter is read: a novel
    /// chapter is text pulled out by `chapter`, a comic chapter is a list of
    /// image URLs pulled out by `images`.
    ///
    /// `CaseIterable` because this is also what the shelf switches between — see
    /// `MediaMode`. Declared here rather than in that extension because the compiler
    /// only synthesises `allCases` alongside the enum itself.
    enum Kind: String, Codable, CaseIterable {
        case novel
        case comic
    }

    let id: String
    let name: String
    let host: String
    let kind: Kind
    let urls: URLTemplates
    let idPatterns: IDPatterns
    let search: Search?
    let book: BookFields
    /// Required for `.novel`, absent for `.comic`. Enforced at import
    /// (`SiteStore.importRule`) so a rule that cannot read a chapter is refused
    /// while the user is looking at an import sheet, rather than in front of a
    /// reader that has nothing to show.
    let chapter: Chapter?
    /// Required for `.comic`, absent for `.novel`. See `chapter`.
    let images: Images?
    let catalog: Catalog
    /// How this site turns a signed-out reader away, for the sites that do.
    /// Absent means the site never asks anyone to sign in.
    let signIn: SignIn?
    /// Free-form provenance notes. Ignored at runtime, kept so a rule file
    /// stays self-documenting when it travels between devices.
    let notes: [String]?

    /// Spelled out rather than left to the synthesized memberwise init so the
    /// two fields comics added can default: every rule that existed before them
    /// is a novel with no `images`, and every construction site in the app says
    /// so by staying unchanged.
    init(
        id: String,
        name: String,
        host: String,
        kind: Kind = .novel,
        urls: URLTemplates,
        idPatterns: IDPatterns,
        search: Search?,
        book: BookFields,
        catalog: Catalog,
        chapter: Chapter? = nil,
        images: Images? = nil,
        signIn: SignIn? = nil,
        notes: [String]?
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.kind = kind
        self.urls = urls
        self.idPatterns = idPatterns
        self.search = search
        self.book = book
        self.catalog = catalog
        self.chapter = chapter
        self.images = images
        self.signIn = signIn
        self.notes = notes
    }

    // MARK: - Nested shapes

    struct URLTemplates: Codable, Hashable {
        /// Templates use `{bookId}` / `{chapterId}` placeholders.
        let book: String
        let catalog: String
        let chapter: String
    }

    struct IDPatterns: Codable, Hashable {
        /// Regexes with one capture group, used to recover ids from a pasted URL.
        let bookId: String
        let chapterId: String
    }

    struct Search: Codable, Hashable {
        enum Method: String, Codable { case get = "GET", post = "POST" }
        let method: Method
        /// GET: a template containing `{query}`. POST: the form endpoint.
        let url: String
        /// POST field name. Unused for GET templates.
        let queryField: String
        /// Optional wrapper around the result rows. When present, the row
        /// selectors below are scoped to it, which keeps sidebars and
        /// "you may also like" blocks out of the results.
        let resultContainer: String?
        /// Selector for the link of one result row.
        let resultLinkSelector: String
        /// Optional richer fields; when absent the link text becomes the title.
        let resultTitleSelector: String?
        let resultAuthorSelector: String?
        let resultCoverSelector: String?
    }

    /// How to read one field: either an `og:`/`name=` meta tag or a CSS selector.
    /// Meta is preferred where a site provides it — it survives layout changes
    /// that break selectors.
    struct Field: Codable, Hashable {
        let meta: String?
        let selector: String?
        /// Read this attribute instead of the element's text.
        let attribute: String?
    }

    struct BookFields: Codable, Hashable {
        let title: Field
        let author: Field?
        let cover: Field?
        let category: Field?
        let status: Field?
        let intro: Field?
        let latestChapter: Field?
    }

    struct Catalog: Codable, Hashable {
        enum Order: String, Codable {
            /// Chapter 1 first (DOM order matches reading order).
            case ascending
            /// Newest first — the list has to be reversed after extraction.
            case descending
        }
        let container: String
        let linkSelector: String
        let order: Order
        /// Read this attribute instead of the link's `href` as the text a chapter
        /// id is recovered from, and rebuild the chapter URL from `urls.chapter`.
        ///
        /// Exists because one of the comic sites publishes its catalog as
        /// `<a href="#" onclick="cview('103-1.html', 3)">` — the href identifies
        /// nothing, and the chapter is named only inside the handler's arguments.
        /// The attribute's contents are matched by `idPatterns.chapterId` as a
        /// plain string, never parsed as a URL and never executed.
        let linkAttribute: String?
        /// The site's own sort control, for a site that remembers it per book.
        ///
        /// `order` is a claim about the site, and on one of the comic sites there is
        /// no such claim to make: it ships a reverse button and stores the choice
        /// against the book, so a fixed answer reads four books in eleven backwards.
        /// When this resolves it decides; when the page does not define it at all,
        /// `order` still does.
        let descendingWhen: Condition?

        /// A value on the page compared against an expected one.
        struct Condition: Codable, Hashable {
            /// Dot path from `window`, walked exactly as an image strategy's paths are.
            let path: String
            /// Compared as text: a site writes this kind of flag as a bare number in
            /// one place and a quoted one in another, and the difference means nothing.
            let equals: String
        }

        init(
            container: String,
            linkSelector: String,
            order: Order,
            linkAttribute: String? = nil,
            descendingWhen: Condition? = nil
        ) {
            self.container = container
            self.linkSelector = linkSelector
            self.order = order
            self.linkAttribute = linkAttribute
            self.descendingWhen = descendingWhen
        }
    }

    /// How to read one comic chapter's page images.
    ///
    /// Strategies are tried in order and the first to yield a non-empty list
    /// wins — the same convention as `Chapter.contentSelectors`, and for the same
    /// reason: the part of a site's markup most likely to drift is exactly the
    /// part recon can least confirm, so a rule is allowed to carry fallbacks and
    /// the extractor reports which one actually fired.
    struct Images: Codable, Hashable {
        let strategies: [Strategy]

        /// One attempt, described entirely as data.
        ///
        /// A flat struct of optionals rather than an enum with associated values,
        /// matching `Field`: this shape is hand-written as JSON by whoever adds a
        /// site, and it is handed to the page's JavaScript as a plain object.
        /// Which fields a strategy uses follows from its `type`; the rest are absent.
        struct Strategy: Codable, Hashable {
            enum Kind: String, Codable {
                /// Read the URLs off elements already in the DOM.
                case dom
                /// Read them out of a global the page's own scripts built.
                case global
                /// Read them out of the page's own packed script, undone as text.
                ///
                /// For the site that ships its page list inside
                /// `eval(function(p,a,c,k,e,d){…}(…))` and hands the result straight
                /// to a function, so nothing of it is ever left on a global or in
                /// the DOM — 194 pages in a chapter, one address findable. Undoing
                /// that packing is base conversion and dictionary substitution: the
                /// data was always in the first bytes of the page, only compressed.
                ///
                /// The paths below are read the same way as for `global`, but from
                /// the decoded object rather than from `window`.
                case packed
            }

            let type: Kind

            // MARK: dom

            let selector: String?
            /// Attribute names in priority order; the first non-empty one wins.
            ///
            /// Never just `src`: two of these sites keep only one image in the DOM
            /// at a time and a third ships every `<img>` with an empty `src` until
            /// its own lazy-loader fills it, so the real URL lives in an attribute
            /// of the site's choosing.
            let attributes: [String]?
            /// Run the attribute's value through HTML entity decoding first.
            let unescape: Bool?

            // MARK: global / packed

            /// Dot path to an array of file names or URLs, e.g. `newImgs` or
            /// `cInfo.files`. Rooted at `window` for `global`, at the decoded
            /// object for `packed`.
            ///
            /// Walked one property at a time by the extractor's own JavaScript.
            /// A rule file travels between users and is read inside the web view
            /// holding every cookie they own, so a rule is data and only data:
            /// nothing here reaches `eval` or `new Function`.
            let arrayPath: String?
            /// Dot path to a directory prefix each entry hangs off.
            let prefixPath: String?
            /// Dot path to the query parameters the CDN requires, as either a
            /// prebuilt string or an object of key/value pairs.
            let queryPath: String?
            /// Origin to resolve `prefixPath` against when the site's own global
            /// holds a path with no host.
            let baseURL: String?

            /// Spelled out so a strategy can be written the way it is documented:
            /// name its `type` and the fields that type uses, and let the rest be
            /// absent. The synthesised memberwise init would demand all eight,
            /// which for a `dom` strategy is five explicit nils. `Catalog` carries
            /// one for the same reason.
            init(
                type: Kind,
                selector: String? = nil,
                attributes: [String]? = nil,
                unescape: Bool? = nil,
                arrayPath: String? = nil,
                prefixPath: String? = nil,
                queryPath: String? = nil,
                baseURL: String? = nil
            ) {
                self.type = type
                self.selector = selector
                self.attributes = attributes
                self.unescape = unescape
                self.arrayPath = arrayPath
                self.prefixPath = prefixPath
                self.queryPath = queryPath
                self.baseURL = baseURL
            }
        }
    }

    /// A site that turns signed-out readers away, and where they can sign in.
    ///
    /// Modelled on the Cloudflare path and handled by the same sheet, because to
    /// the reader it is the same interruption: the app cannot get past this by
    /// itself, so it stops and hands over the browser. The difference is where it
    /// hands them — a challenge page *is* the thing to complete, while the page a
    /// signed-out reader is bounced to is a dead end, so the sheet has to be taken
    /// to the site's own sign-in form instead.
    ///
    /// Data only, like everything else in a rule file. `landsOn` is compared as
    /// text in Swift and `url` is loaded as a page; neither is executed, and
    /// neither can name a host other than the one it points at.
    struct SignIn: Codable, Hashable {
        /// Part of the address the site bounces a signed-out reader to. Matched as
        /// a plain substring of the landed URL — 8comic redirects to
        /// `/member/404.html` from a script in `<head>`, so by the time the page
        /// settles the address is the only evidence left that a gate fired.
        let landsOn: String
        /// The site's own sign-in page, shown to the user in the sheet.
        let url: String

        /// Whether the page that loaded is the site's locked door.
        ///
        /// Nil is not a match: a fetch that landed nowhere failed for some other
        /// reason, and reporting it as "please sign in" would send the reader to
        /// type a password at a site that never asked for one.
        func turnsAway(_ landed: URL?) -> Bool {
            guard let landed, !landsOn.isEmpty else { return false }
            return landed.absoluteString.contains(landsOn)
        }

        /// Where to send the reader. Nil for an unparseable rule, which the caller
        /// treats as "no gate" — an unusable address is not worth interrupting for.
        var signInURL: URL? { URL(string: url) }
    }

    struct Chapter: Codable, Hashable {
        /// Tried in order; the first selector that matches a non-empty node wins.
        /// A list rather than a single value because a site's chapter markup is
        /// the part most likely to drift, and recon can't always confirm it.
        let titleSelectors: [String]
        let contentSelectors: [String]
        /// Removed from the content node before text extraction (ads, nav, scripts).
        let stripSelectors: [String]
        /// Regexes matched against each extracted paragraph; a match drops the line.
        ///
        /// Exists because these sites bury boilerplate *inside* the chapter body —
        /// "請記住本站域名: …", "本章未完，請點擊下一頁" — where no selector can reach
        /// it, especially on the sites whose text is only found by the
        /// largest-text-block heuristic. Optional so rule files written before it
        /// existed still decode.
        let dropParagraphPatterns: [String]?
        let prevSelector: String?
        let nextSelector: String?
    }

    // MARK: - Decoding

    private enum CodingKeys: String, CodingKey {
        case id, name, host, kind, urls, idPatterns, search, book, catalog, chapter, images
        case signIn, notes
    }

    /// Decoded by hand for one field: `kind` has to read as `.novel` when the key
    /// is missing.
    ///
    /// Every rule file written before comics existed is a novel rule and none of
    /// them carry the field, so "absent" has a correct answer rather than being an
    /// error — and a synthesized `init(from:)` cannot express a default for a
    /// non-optional property. Non-optional is what the boilerplate buys: the
    /// alternative leaves every `rule.kind == …` comparison in the app to remember
    /// the fallback, and one that forgets silently files a comic under novels.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .novel
        urls = try c.decode(URLTemplates.self, forKey: .urls)
        idPatterns = try c.decode(IDPatterns.self, forKey: .idPatterns)
        search = try c.decodeIfPresent(Search.self, forKey: .search)
        book = try c.decode(BookFields.self, forKey: .book)
        catalog = try c.decode(Catalog.self, forKey: .catalog)
        chapter = try c.decodeIfPresent(Chapter.self, forKey: .chapter)
        images = try c.decodeIfPresent(Images.self, forKey: .images)
        signIn = try c.decodeIfPresent(SignIn.self, forKey: .signIn)
        notes = try c.decodeIfPresent([String].self, forKey: .notes)
    }
}

// MARK: - URL building / parsing

extension SiteRule {
    func bookURL(bookId: String) -> URL? {
        URL(string: urls.book.replacingOccurrences(of: "{bookId}", with: bookId))
    }

    func catalogURL(bookId: String) -> URL? {
        URL(string: urls.catalog.replacingOccurrences(of: "{bookId}", with: bookId))
    }

    func chapterURL(bookId: String, chapterId: String) -> URL? {
        let s = urls.chapter
            .replacingOccurrences(of: "{bookId}", with: bookId)
            .replacingOccurrences(of: "{chapterId}", with: chapterId)
        return URL(string: s)
    }

    /// Recovers a book id from any URL on this site, so "paste a link" works
    /// whether the user copied the book page or the catalog page.
    func bookId(from url: URL) -> String? { bookId(inLinkText: url.absoluteString) }

    func chapterId(from url: URL) -> String? { chapterId(inLinkText: url.absoluteString) }

    /// The same two patterns run against raw catalog link text instead of a URL.
    ///
    /// A catalog carrying `linkAttribute` hands the extractor an attribute's
    /// contents rather than an href, and on the site that needs it those contents
    /// are a JavaScript call — `cview('103-1.html', 3)` — which is not a URL and
    /// must not be forced through `URL(string:)` to be matched against.
    func bookId(inLinkText text: String) -> String? {
        Self.firstCapture(of: idPatterns.bookId, in: text)
    }

    func chapterId(inLinkText text: String) -> String? {
        Self.firstCapture(of: idPatterns.chapterId, in: text)
    }

    /// Whether this rule reads the site `url` is on.
    ///
    /// The device label is dropped from both hosts before they are compared, because
    /// `www.manhuagui.com` and `m.manhuagui.com` are one site serving one book, and a
    /// rule can only name the one its selectors were written against. Someone who
    /// copies an address out of a desktop browser is asking for the book, not for a
    /// subdomain — and nothing downstream ever sees what they pasted, because every
    /// address the app then fetches is rebuilt from `urls`, which carries this rule's
    /// own host.
    func matches(_ url: URL) -> Bool {
        guard let pasted = url.host() else { return false }
        return Self.site(of: pasted).caseInsensitiveCompare(Self.site(of: host)) == .orderedSame
    }

    /// A host with its device label removed, and only these three, and only as a whole
    /// first label. Dropping *any* first label would make a rule for one subdomain
    /// match every other subdomain of the same domain — which for the sites that put
    /// unrelated properties on their subdomains would read the wrong pages.
    private static func site(of host: String) -> String {
        let lowered = host.lowercased()
        for label in ["www.", "m.", "mobile."] where lowered.count > label.count
            && lowered.hasPrefix(label) {
            return String(lowered.dropFirst(label.count))
        }
        return lowered
    }

    /// A copy carrying a different search block. Search is the one part of a rule
    /// that can be worked out separately from the rest — it lives on pages the
    /// book-page derivation never visits — so it has to be attachable afterwards.
    func settingSearch(_ search: Search?) -> SiteRule {
        SiteRule(
            id: id, name: name, host: host, kind: kind, urls: urls, idPatterns: idPatterns,
            search: search, book: book, catalog: catalog, chapter: chapter, images: images,
            signIn: signIn, notes: notes
        )
    }

    private static func firstCapture(of pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s)
        else { return nil }
        return String(s[r])
    }
}
