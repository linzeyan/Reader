import Foundation

/// Builds a `SiteRule` for a site nobody has written a rule for, from one pasted
/// book URL.
///
/// The app ships with no rules and cannot ship a rule repository (App Review 5.2),
/// so the only way a user reaches a source of their own is to author a rule — and
/// hand-authoring one means reading someone else's HTML. Everything needed to do
/// it automatically already existed for other reasons: a real WebKit engine, the
/// largest-text-block heuristic, and id recovery from URLs. This wires them
/// together.
///
/// Nothing is saved without confirmation. The derivation is a guess, so it ends
/// by running the *derived rule* against a real chapter and handing the result
/// back as a preview: the user judges a book title, a chapter count and an
/// opening paragraph, not a pile of CSS selectors.
@MainActor
final class RuleDeriver {
    enum DeriveError: LocalizedError {
        case badURL
        case noChapterLinks
        case noTitle
        case emptyChapter

        var errorDescription: String? {
            switch self {
            case .badURL: return String(localized: "derive.error.badURL")
            case .noChapterLinks: return String(localized: "derive.error.noChapterLinks")
            case .noTitle: return String(localized: "derive.error.noTitle")
            case .emptyChapter: return String(localized: "derive.error.emptyChapter")
            }
        }
    }

    /// What the user is asked to confirm, in terms they can check against the
    /// page they pasted.
    struct Preview: Equatable {
        var bookTitle: String
        var author: String?
        var chapterCount: Int
        var firstChapterTitle: String?
        var excerpt: String
        var warnings: [String]
    }

    struct Draft: Equatable {
        var rule: SiteRule
        var preview: Preview
    }

    private let fetcher: WebFetcher

    init(fetcher: WebFetcher) {
        self.fetcher = fetcher
    }

    // MARK: - Derivation

    func derive(from pastedURL: URL) async throws -> Draft {
        guard let host = pastedURL.host(), pastedURL.scheme?.hasPrefix("http") == true else {
            throw DeriveError.badURL
        }

        // The identifier in the pasted URL, known before anything has been loaded.
        // It is what makes "other pages about this book" findable on a site that
        // labels its catalog link with a picture.
        let bookToken = URLPatternInference.identifierTokens(in: pastedURL).first ?? ""
        let probe = Self.pageProbe(bookToken: bookToken)
        let bookPage = try await fetcher.fetch(pastedURL, extracting: probe, as: PageProbe.self)

        // The catalog is rarely the page the user pasted: a book page shows the
        // newest handful of chapters and links to the full list. So candidates are
        // gathered from the pasted page *and* from the pages it points at, and the
        // one listing the most chapters wins. Picking the first plausible cluster
        // instead would have quietly produced six-chapter catalogs for real books.
        var best = Self.bestCandidate(in: bookPage, bookURL: pastedURL, pageURL: pastedURL)
        if (best?.chapters.count ?? 0) < Self.completeCatalogThreshold {
            for followed in Self.followUps(from: bookPage, excluding: pastedURL).prefix(2) {
                let page: PageProbe
                do {
                    page = try await fetcher.fetch(followed, extracting: probe, as: PageProbe.self)
                } catch let error as WebFetcher.FetchError {
                    // A challenge must reach the user; a dead link must not end
                    // the search while another candidate is still untried.
                    if case .challengePresented = error { throw error }
                    continue
                }
                if let candidate = Self.bestCandidate(in: page, bookURL: pastedURL, pageURL: followed),
                   candidate.chapters.count > (best?.chapters.count ?? 0) {
                    best = candidate
                }
                if (best?.chapters.count ?? 0) >= Self.completeCatalogThreshold { break }
            }
        }
        guard let best else { throw DeriveError.noChapterLinks }
        let (group, inferred, catalogURL, chapters) = (best.group, best.inferred, best.catalogURL, best.chapters)

        let order = Self.order(texts: chapters.map(\.text))
        guard let firstChapter = (order == .descending ? chapters.last : chapters.first),
              let firstChapterURL = URL(string: firstChapter.href)
        else { throw DeriveError.noChapterLinks }

        // Probe the chapter page for a content selector before writing the rule,
        // using the same heuristic the rule would fall back to. A named selector
        // is preferred where the page offers one, because the heuristic can drift
        // when a site adds a large sidebar.
        let chapterProbe = try await fetcher.fetch(
            firstChapterURL, extracting: Self.chapterProbe, as: ChapterProbe.self
        )

        guard let title = Self.title(from: bookPage) else { throw DeriveError.noTitle }
        var rule = Self.assemble(
            host: host,
            inferred: inferred,
            catalogTemplate: URLPatternInference.template(
                for: catalogURL.absoluteString, bookId: inferred.bookId
            ),
            catalogContainer: group.container ?? "body",
            order: order,
            bookPage: bookPage,
            titleSelector: title.selector,
            chapterProbe: chapterProbe
        )

        // Confirmation: run the rule that will be saved against a real chapter.
        // Anything short of this only proves the probes agreed with themselves.
        var paragraphs = try await extractChapter(with: rule, at: firstChapterURL)
        if Self.joined(paragraphs).count < 100, !rule.chapter.contentSelectors.isEmpty {
            // The named selector matched an empty or near-empty node. The
            // heuristic is the better bet at that point — it is what found the
            // text during the probe.
            rule = Self.replacingContentSelectors(in: rule, with: [])
            paragraphs = try await extractChapter(with: rule, at: firstChapterURL)
        }
        guard Self.joined(paragraphs).count >= 100 else { throw DeriveError.emptyChapter }

        var warnings: [String] = []
        if rule.chapter.contentSelectors.isEmpty {
            warnings.append(String(localized: "derive.warning.heuristicContent"))
        }
        warnings.append(String(localized: "derive.warning.noSearch"))

        return Draft(
            rule: rule,
            preview: Preview(
                bookTitle: title.text,
                author: bookPage.metas["og:novel:author"],
                chapterCount: chapters.count,
                firstChapterTitle: firstChapter.text.isEmpty ? nil : firstChapter.text,
                excerpt: String(Self.joined(paragraphs).prefix(160)),
                warnings: warnings
            )
        )
    }

    private func extractChapter(with rule: SiteRule, at url: URL) async throws -> [String] {
        let payload = try await fetcher.fetch(
            url, extracting: try ExtractorScript.chapter(rule), as: ExtractorScript.ChapterPayload.self
        )
        return payload.paragraphs
    }

    // MARK: - Assembly

    private static func assemble(
        host: String,
        inferred: URLPatternInference.Inferred,
        catalogTemplate: String,
        catalogContainer: String,
        order: SiteRule.Catalog.Order,
        bookPage: PageProbe,
        titleSelector: String?,
        chapterProbe: ChapterProbe
    ) -> SiteRule {
        // The host is the id. A prettier short name would risk two different
        // sites sharing a file name in the rule store, where the second import
        // would silently replace the first.
        let contentSelectors = (chapterProbe.unique ? chapterProbe.contentSelector.map { [$0] } : nil) ?? []
        let titleSelectors = [chapterProbe.titleSelector, "h1", "h2"].compactMap { $0 }.uniqued()

        return SiteRule(
            id: host,
            name: shortName(for: host),
            host: host,
            urls: SiteRule.URLTemplates(
                book: inferred.bookTemplate,
                catalog: catalogTemplate,
                chapter: inferred.chapterTemplate
            ),
            idPatterns: SiteRule.IDPatterns(
                bookId: inferred.bookIdPattern,
                chapterId: inferred.chapterIdPattern
            ),
            // Search cannot be derived from a book page: the query endpoint,
            // method and form field live on a page this flow never visits, and
            // guessing them would produce a source that reports every search as
            // broken. Absent is honest — the UI already tells the user which
            // sources a search skipped.
            search: nil,
            book: bookFields(from: bookPage, titleSelector: titleSelector),
            catalog: SiteRule.Catalog(container: catalogContainer, linkSelector: "a", order: order),
            chapter: SiteRule.Chapter(
                titleSelectors: titleSelectors,
                contentSelectors: contentSelectors,
                // Universally junk inside a content node, and cheap insurance:
                // one of these sites hides ~50k characters of inline ad script
                // inside the chapter body.
                stripSelectors: ["script", "style", "ins", ".ads"],
                dropParagraphPatterns: nil,
                prevSelector: nil,
                nextSelector: nil
            ),
            notes: [
                "Auto-derived from \(inferred.bookTemplate)",
                "Content selector: \(contentSelectors.first ?? "(largest text block heuristic)")",
                "Catalog container: \(catalogContainer), order: \(order.rawValue)",
            ]
        )
    }

    /// Prefers `og:` meta tags wherever the page publishes them — a meta tag
    /// survives the layout changes that break selectors, which is the same
    /// reasoning the hand-written rules follow.
    private static func bookFields(from page: PageProbe, titleSelector: String?) -> SiteRule.BookFields {
        func field(_ meta: String, _ selector: String? = nil, attribute: String? = nil) -> SiteRule.Field? {
            let hasMeta = page.metas[meta] != nil
            guard hasMeta || selector != nil else { return nil }
            return SiteRule.Field(meta: hasMeta ? meta : nil, selector: selector, attribute: attribute)
        }
        let titleMeta = page.metas["og:novel:book_name"] != nil ? "og:novel:book_name" : "og:title"
        return SiteRule.BookFields(
            title: SiteRule.Field(
                meta: page.metas[titleMeta] != nil ? titleMeta : nil,
                selector: titleSelector,
                attribute: nil
            ),
            author: field("og:novel:author"),
            cover: field("og:image"),
            category: field("og:novel:category"),
            status: field("og:novel:status"),
            intro: field("og:description"),
            latestChapter: field("og:novel:latest_chapter_name")
        )
    }

    private static func replacingContentSelectors(in rule: SiteRule, with selectors: [String]) -> SiteRule {
        SiteRule(
            id: rule.id, name: rule.name, host: rule.host, urls: rule.urls,
            idPatterns: rule.idPatterns, search: rule.search, book: rule.book, catalog: rule.catalog,
            chapter: SiteRule.Chapter(
                titleSelectors: rule.chapter.titleSelectors,
                contentSelectors: selectors,
                stripSelectors: rule.chapter.stripSelectors,
                dropParagraphPatterns: rule.chapter.dropParagraphPatterns,
                prevSelector: rule.chapter.prevSelector,
                nextSelector: rule.chapter.nextSelector
            ),
            notes: rule.notes
        )
    }

    /// `www.hetubook.com` → `hetubook`. Display only; the id stays the full host.
    static func shortName(for host: String) -> String {
        var parts = host.lowercased().split(separator: ".").map(String.init)
        let prefixes: Set<String> = ["www", "m", "big5", "gb", "tw", "hk", "cn", "www1", "www2"]
        while parts.count > 2, let first = parts.first, prefixes.contains(first) { parts.removeFirst() }
        if parts.count > 1 { parts.removeLast() }
        return parts.joined(separator: ".").isEmpty ? host : parts.joined(separator: ".")
    }

    // MARK: - Reading the probes

    /// A link cluster that has been shown to describe this book's chapters.
    struct Candidate {
        let group: PageProbe.Group
        let inferred: URLPatternInference.Inferred
        let catalogURL: URL
        /// Links surviving the derived patterns — what the catalog will really
        /// contain once the rule is in use.
        let chapters: [(href: String, text: String)]
    }

    /// Past this many chapters a cluster is taken to be the complete catalog, and
    /// no further pages are loaded looking for a longer one. Teaser lists on book
    /// pages are a handful of entries; real catalogs are hundreds.
    static let completeCatalogThreshold = 100

    /// The cluster on `page` that yields the most readable chapters for this book.
    ///
    /// Every cluster is scored the way `BookService.refreshCatalog` will score it
    /// later — links the chapter pattern cannot read, and links belonging to a
    /// different book, are discarded here too. Anything else would report a
    /// chapter count the app then fails to reproduce.
    static func bestCandidate(in page: PageProbe, bookURL: URL, pageURL: URL) -> Candidate? {
        let catalogURL = URL(string: page.href) ?? pageURL
        var best: Candidate?
        for group in page.groups where group.hrefs.count >= 5 {
            guard let inferred = URLPatternInference.infer(
                bookURL: bookURL, chapterURLs: group.hrefs.compactMap { URL(string: $0) }
            ) else { continue }
            let chapters = zip(group.hrefs, group.texts).filter { href, _ in
                guard let url = URL(string: href),
                      capture(inferred.chapterIdPattern, in: url.absoluteString) != nil
                else { return false }
                guard let owner = capture(inferred.bookIdPattern, in: url.absoluteString) else { return true }
                return owner == inferred.bookId
            }
            .map { (href: $0.0, text: $0.1) }
            if !chapters.isEmpty, chapters.count > (best?.chapters.count ?? 0) {
                best = Candidate(group: group, inferred: inferred, catalogURL: catalogURL, chapters: chapters)
            }
        }
        return best
    }

    /// Pages worth loading when the pasted one did not carry a full catalog:
    /// links it labels as a table of contents first, then any other page whose URL
    /// carries this book's identifier, preferring named pages ("xiaoshuo.html")
    /// over numbered ones, which are chapters.
    static func followUps(from page: PageProbe, excluding pasted: URL) -> [URL] {
        let named = page.sameBookLinks.filter { link in
            URL(string: link).map { !($0.lastPathComponent.contains(where: \.isNumber)) } ?? false
        }
        var seen = Set([pasted.absoluteString])
        return (page.catalogLinks + named + page.sameBookLinks)
            .filter { seen.insert($0).inserted }
            .compactMap(URL.init(string:))
    }

    private static func title(from page: PageProbe) -> (text: String, selector: String?)? {
        // `og:novel:book_name` means exactly one thing and needs no judgement.
        if let name = page.metas["og:novel:book_name"], !name.isEmpty {
            let agreeing = page.titleCandidates.first { name.contains($0.text) || $0.text.contains(name) }
            return (name, agreeing?.selector)
        }
        // Otherwise the best evidence is the document title: the book's name is in
        // it, and so is nothing else on the page. Longest wins, because the site's
        // own name is in there too and is always the shorter of the two — taking
        // the first match instead bookmarked one site's books as "和圖書".
        let inDocumentTitle = page.titleCandidates
            .filter { !$0.text.isEmpty && page.docTitle.contains($0.text) }
            .max { $0.text.count < $1.text.count }
        if let match = inDocumentTitle {
            return (match.text, match.selector)
        }
        // `og:title` last: several of these sites fill it with a sentence of SEO
        // keywords wrapped around the title rather than the title itself.
        if let name = page.metas["og:title"], !name.isEmpty { return (name, nil) }
        guard let first = page.titleCandidates.first else { return nil }
        return (first.text, first.selector)
    }

    /// Catalogs disagree about direction, and getting it wrong makes chapter 1 the
    /// last entry. Read the chapter numbers out of the link text and compare the
    /// ends — the numbers are in the text even when they are not in the URL.
    private static func order(texts: [String]) -> SiteRule.Catalog.Order {
        let numbers = texts.compactMap(chapterNumber)
        guard numbers.count >= 2, let first = numbers.first, let last = numbers.last else {
            return .ascending
        }
        return first > last ? .descending : .ascending
    }

    private static func chapterNumber(in text: String) -> Int? {
        for pattern in [#"第\s*(\d+)\s*[章回节節卷]"#, #"^\s*(\d+)"#] {
            if let value = capture(pattern, in: text), let number = Int(value) { return number }
        }
        return nil
    }

    private static func capture(_ pattern: String, in string: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let match = re.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: string)
        else { return nil }
        return String(string[range])
    }

    private static func joined(_ paragraphs: [String]) -> String { paragraphs.joined() }

    // MARK: - Probe payloads (mirrored by the JS below)

    struct PageProbe: Decodable {
        struct Group: Decodable {
            let container: String?
            let hrefs: [String]
            let texts: [String]
        }
        struct Candidate: Decodable {
            let selector: String
            let text: String
        }
        let href: String
        let docTitle: String
        let metas: [String: String]
        /// Link clusters sharing a URL shape, largest first.
        let groups: [Group]
        let catalogLinks: [String]
        /// Other pages on this site whose URL carries the same identifier as the
        /// pasted one. On sites that keep the chapter list on its own page and
        /// label the link with a picture or "開始閱讀", this is the only trail
        /// leading to it.
        let sameBookLinks: [String]
        let titleCandidates: [Candidate]
    }

    struct ChapterProbe: Decodable {
        let contentSelector: String?
        /// Whether that selector matches exactly one node. A selector that
        /// matches several would make `querySelector` pick an arbitrary one.
        let unique: Bool
        let title: String?
        let titleSelector: String?
    }

    // MARK: - Probes

    /// Finds the chapter-link clusters on a book or catalog page.
    ///
    /// Groups every same-host link by the *shape* of its path (digits and slugs
    /// collapsed to placeholders) and returns the biggest few. Size alone does not
    /// decide — a book page's "you may also like" grid routinely outnumbers the
    /// handful of recent chapters shown beside it — so the caller tries each in
    /// turn and keeps whichever actually yields this book's chapters.
    ///
    /// - Parameter bookToken: the identifier from the pasted URL, used to spot
    ///   other pages about the same book.
    static func pageProbe(bookToken: String) -> String {
        let token = (try? String(data: JSONEncoder().encode(bookToken), encoding: .utf8)) ?? "\"\""
        return """
    (function () {
      var bookToken = \(token);
      function clean(s) { return (s || '').replace(/\\u00a0/g, ' ').replace(/\\s+/g, ' ').trim(); }
      function selectorFor(el) {
        if (!el || !el.tagName) return null;
        if (el.id) return '#' + el.id;
        var classes = (el.getAttribute('class') || '').trim().split(/\\s+/).filter(function (c) {
          // Generated/utility class names are unstable; a plain identifier is not.
          return c && /^[A-Za-z][-_A-Za-z0-9]*$/.test(c);
        });
        if (classes.length) return el.tagName.toLowerCase() + '.' + classes.slice(0, 2).join('.');
        return null;
      }
      function parse(href) {
        try {
          var u = new URL(href, location.href);
          u.hash = '';
          // Same host over a different scheme is the same page. Left alone it
          // duplicates every chapter in the catalog, and lets the URL templates
          // be built from whichever copy happened to come first in the DOM —
          // which is how a site served over https ends up with an http rule that
          // sends every later request in plaintext.
          if (u.host === location.host && u.protocol !== location.protocol) u.protocol = location.protocol;
          return u;
        } catch (e) { return null; }
      }
      var self = parse(location.href);
      var selfPath = self ? self.pathname : '';
      function shapeOf(u) {
        return u.pathname.split('/').map(function (seg) {
          if (!seg) return '';
          if (/^\\d+$/.test(seg)) return '#';
          return /^[A-Za-z]+$/.test(seg) && seg.length <= 10 ? seg.toLowerCase() : '@';
        }).join('/');
      }

      var groups = {}, seen = {}, catalogLinks = [], sameBookLinks = [], sameBookSeen = {};
      var catalogWord = /目[錄录]|章節|章节|全部章|所有章|開始閱讀|开始阅读/;
      Array.prototype.slice.call(document.querySelectorAll('a[href]')).forEach(function (a) {
        var u = parse(a.href);
        if (!u || u.host !== location.host) return;
        var key = u.pathname + u.search;
        // The page cannot be a chapter of itself.
        if (u.pathname === selfPath) return;
        if (catalogWord.test(clean(a.textContent))) catalogLinks.push(u.href);
        if (bookToken && key.indexOf(bookToken) !== -1 && !sameBookSeen[key]) {
          sameBookSeen[key] = true;
          sameBookLinks.push(u.href);
        }
        if (seen[key]) return;
        seen[key] = true;
        var shape = shapeOf(u);
        if (!groups[shape]) groups[shape] = [];
        // Carry the normalised href, not `a.href`: the raw attribute is what
        // holds the wrong scheme, and it is the href that becomes the rule's
        // chapter URL template.
        groups[shape].push({ el: a, href: u.href, text: clean(a.textContent) });
      });

      var ranked = [];
      for (var shape in groups) { if (groups[shape].length >= 5) ranked.push(groups[shape]); }
      ranked.sort(function (a, b) { return b.length - a.length; });

      function describe(links) {
        // Walk up until an ancestor holds nearly all of the cluster *and* can be
        // named by a selector that is unique in the document. A container that
        // matched several nodes would send the catalog extractor to the wrong one.
        var node = links[0].el, container = null;
        while (node && node !== document.documentElement) {
          var inside = 0;
          for (var i = 0; i < links.length; i++) { if (node.contains(links[i].el)) inside++; }
          if (inside >= links.length * 0.8) {
            var sel = selectorFor(node);
            if (sel && document.querySelectorAll(sel).length === 1) { container = sel; break; }
          }
          node = node.parentElement;
        }
        return {
          container: container,
          hrefs: links.map(function (e) { return e.href; }),
          texts: links.map(function (e) { return e.text; })
        };
      }

      var metas = {};
      Array.prototype.slice.call(document.querySelectorAll('meta[property], meta[name]')).forEach(function (m) {
        var key = m.getAttribute('property') || m.getAttribute('name');
        var value = clean(m.getAttribute('content'));
        if (key && value && !metas[key]) metas[key] = value;
      });

      // Builds the shortest descendant selector that resolves to exactly this
      // element. Needed because the book title is often *not* the first `.title`
      // on the page — a sidebar heading usually is — so candidates have to be
      // addressable individually rather than by the bare selector they matched.
      function pathFor(el) {
        var parts = [], node = el, depth = 0;
        while (node && node.tagName && depth < 4) {
          if (node.id) {
            parts.unshift('#' + node.id);
            var byId = parts.join(' ');
            return document.querySelector(byId) === el ? byId : null;
          }
          var classes = (node.getAttribute('class') || '').trim().split(/\\s+/).filter(function (c) {
            return c && /^[A-Za-z][-_A-Za-z0-9]*$/.test(c);
          });
          parts.unshift(classes.length
            ? node.tagName.toLowerCase() + '.' + classes.slice(0, 2).join('.')
            : node.tagName.toLowerCase());
          var path = parts.join(' ');
          if (document.querySelector(path) === el) return path;
          node = node.parentElement;
          depth++;
        }
        return null;
      }

      var titleCandidates = [], titleSeen = {};
      ['h1', 'h2', 'h3', '#title', '.title', '.bookname', '.book-name', '.booktitle', '.book-title']
        .forEach(function (sel) {
          Array.prototype.slice.call(document.querySelectorAll(sel)).slice(0, 6).forEach(function (el) {
            var text = clean(el.textContent);
            if (!text || text.length > 60 || titleSeen[text]) return;
            var path = pathFor(el);
            if (!path) return;
            titleSeen[text] = true;
            titleCandidates.push({ selector: path, text: text });
          });
        });

      return {
        href: location.href,
        docTitle: clean(document.title),
        metas: metas,
        groups: ranked.slice(0, 4).map(describe),
        catalogLinks: catalogLinks.slice(0, 3),
        sameBookLinks: sameBookLinks.slice(0, 40),
        titleCandidates: titleCandidates
      };
    })()
    """
    }

    /// Names the node the largest-text-block heuristic settles on, so the saved
    /// rule can point at it directly instead of re-deriving it on every read.
    static let chapterProbe = """
    (function () {
      \(ExtractorScript.helpers)
      function selectorFor(el) {
        if (!el || !el.tagName) return null;
        if (el.id) return '#' + el.id;
        var classes = (el.getAttribute('class') || '').trim().split(/\\s+/).filter(function (c) {
          return c && /^[A-Za-z][-_A-Za-z0-9]*$/.test(c);
        });
        if (classes.length) return el.tagName.toLowerCase() + '.' + classes.slice(0, 2).join('.');
        return null;
      }
      var node = largestTextBlock();
      var selector = node ? selectorFor(node) : null;
      var title = null, titleSelector = null;
      ['h1', '.bookname h1', '#chapter-title', '.chapter-title', '.title', 'h2', 'h3'].forEach(function (sel) {
        if (title) return;
        var el = document.querySelector(sel);
        if (!el) return;
        var text = clean(el.textContent);
        if (text && text.length <= 80) { title = text; titleSelector = sel; }
      });
      return {
        contentSelector: selector,
        unique: selector ? document.querySelectorAll(selector).length === 1 : false,
        title: title,
        titleSelector: titleSelector
      };
    })()
    """
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
