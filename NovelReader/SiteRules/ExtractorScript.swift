import Foundation

/// Turns a `SiteRule` into the JavaScript that runs inside the page.
///
/// All DOM work happens in JS and only JSON crosses back into Swift. That keeps
/// the Swift side free of any HTML parsing dependency, and — more importantly —
/// means adding a site is purely a data change.
enum ExtractorScript {
    enum BuildError: Error {
        case encodingFailed
        /// The rule has no `search` block, so this site cannot be searched.
        /// Surfaced rather than silently returning nothing: an "all sites"
        /// search must be able to tell the user which sources it skipped.
        case searchUnsupported
        /// A chapter was asked to be read the wrong way round for its source: text
        /// from a rule with no `chapter`, or images from one with no `images`.
        ///
        /// Import refuses both shapes (`SiteStore.importRule`), so reaching this
        /// means the caller routed a comic into the novel reader or the reverse —
        /// a bug here, not a bad rule file, and one that should surface rather
        /// than extract nothing and read as an empty chapter.
        case wrongKind(SiteRule.Kind)
    }

    // MARK: - Extracted shapes (mirrored by the JS below)

    struct BookPayload: Decodable {
        let title: String?
        let author: String?
        let cover: String?
        let category: String?
        let status: String?
        let intro: String?
        let latestChapter: String?
    }

    struct CatalogPayload: Decodable {
        struct Entry: Decodable { let title: String; let url: String }
        let entries: [Entry]
    }

    struct ChapterPayload: Decodable {
        let title: String?
        /// Paragraphs, already trimmed and with ad/nav nodes stripped.
        let paragraphs: [String]
        let prevURL: String?
        let nextURL: String?
        /// Which `contentSelectors` entry actually matched — surfaced so a rule
        /// that only works via its fallback can be tightened later.
        let matchedSelector: String?
    }

    struct ComicImagesPayload: Decodable {
        /// Absolute, in page order. One entry per page of the chapter.
        let imageURLs: [String]
        /// Best effort, and only ever used to *lengthen* a catalog-truncated name
        /// (`Chapter.fullerTitle`), whose prefix guard is what makes a wrong guess
        /// harmless rather than a rename.
        let title: String?
        /// Which `images.strategies` entry fired, for the same reason
        /// `matchedSelector` exists: a rule surviving on its fallback should be
        /// visible and tightenable, not silently permanent.
        let matchedStrategy: String?
    }

    // MARK: - Builders

    static func book(_ rule: SiteRule) throws -> String {
        let fields = try json(rule.book)
        return """
        (function () {
          \(helpers)
          var f = \(fields);
          var out = {};
          for (var k in f) { out[k] = readField(f[k]); }
          return out;
        })()
        """
    }

    static func catalog(_ rule: SiteRule) throws -> String {
        let cfg = try json(rule.catalog)
        return """
        (function () {
          \(helpers)
          var c = \(cfg);
          var root = document.querySelector(c.container) || document;
          var links = Array.prototype.slice.call(root.querySelectorAll(c.linkSelector));
          var entries = links.map(function (a) {
            // `url` carries whatever the chapter is identified by, which is the
            // href unless the rule names an attribute — see `Catalog.linkAttribute`.
            // Swift is what pattern-matches it and rebuilds the address; here it is
            // only ever read and passed on.
            var link = c.linkAttribute ? a.getAttribute(c.linkAttribute) : a.href;
            return { title: clean(a.textContent), url: link ? String(link).trim() : '' };
          }).filter(function (e) { return e.title && e.url; });
          // Dedupe by URL: catalogs often repeat the newest chapters in a header.
          var seen = {}, unique = [];
          for (var i = 0; i < entries.length; i++) {
            if (seen[entries[i].url]) continue;
            seen[entries[i].url] = true;
            unique.push(entries[i]);
          }
          // The rule's `order` is the site's habit; `descendingWhen` is the site
          // saying what it did with *this* book. Where the page defines the flag it
          // wins, and where it does not the habit still holds.
          var descending = c.order === 'descending';
          if (c.descendingWhen) {
            var flag = walkPath(window, c.descendingWhen.path);
            if (flag !== null && flag !== undefined) {
              descending = String(flag) === String(c.descendingWhen.equals);
            }
          }
          if (descending) unique.reverse();
          return { entries: unique };
        })()
        """
    }

    static func chapter(_ rule: SiteRule) throws -> String {
        guard let config = rule.chapter else { throw BuildError.wrongKind(rule.kind) }
        return try chapter(config)
    }

    /// The chapter extractor built from the config alone, for content that has
    /// no site behind it: an imported EPUB document is read by exactly this
    /// script, so a local book and a fetched page are normalised identically.
    static func chapter(_ config: SiteRule.Chapter) throws -> String {
        let cfg = try json(config)
        return """
        (function () {
          \(helpers)
          var c = \(cfg);
          var title = null;
          for (var i = 0; i < c.titleSelectors.length && !title; i++) {
            var t = document.querySelector(c.titleSelectors[i]);
            if (t) title = clean(t.textContent);
          }
          var node = null, matched = null;
          for (var j = 0; j < c.contentSelectors.length && !node; j++) {
            var n = document.querySelector(c.contentSelectors[j]);
            if (n && clean(n.textContent).length > 0) { node = n; matched = c.contentSelectors[j]; }
          }
          if (!node) { node = largestTextBlock(); matched = node ? '(heuristic)' : null; }
          var paragraphs = [];
          if (node) {
            // Clone before stripping so the live page the user may be looking at
            // is never mutated.
            var copy = node.cloneNode(true);
            c.stripSelectors.forEach(function (s) {
              if (!s) return;
              Array.prototype.slice.call(copy.querySelectorAll(s)).forEach(function (el) { el.remove(); });
            });
            // These templates separate paragraphs three different ways — <br>,
            // <p>, and bare <div> — and `textContent` inserts nothing between
            // block elements, so a div-per-paragraph site would collapse into a
            // single unreadable line. Normalise all three into line breaks.
            copy.innerHTML = copy.innerHTML.replace(/<br\\s*\\/?>/gi, '\\n');
            Array.prototype.slice.call(copy.querySelectorAll('p, div, li, h1, h2, h3, h4, blockquote'))
              .forEach(function (el) {
                el.insertAdjacentText('beforebegin', '\\n');
                el.insertAdjacentText('afterend', '\\n');
              });
            paragraphs = (copy.textContent || '').split('\\n')
              .map(clean)
              .filter(function (s) { return s.length > 0; });
          }
          // Most of these sites repeat the chapter title — usually with the book
          // title glued in front — as the first line of the body. Drop that echo,
          // but only near the top and only when the line is barely longer than the
          // title itself, so a paragraph that genuinely quotes it survives.
          // Matched both ways round, because sites disagree about which of the
          // title node and the body line carries the book name: hjwzw's body line
          // is "書名 + 章節名" while its title node is just the chapter, and
          // czbooks is the exact reverse. Each direction carries its own guard —
          // a near-equal length one way, a minimum length the other — so a short
          // opening line that merely happens to appear in the title survives.
          if (title) {
            var deduped = [];
            for (var q = 0; q < paragraphs.length; q++) {
              var p = paragraphs[q];
              var isEcho = q < 3 && (
                (p.indexOf(title) !== -1 && p.length <= title.length + 30)
                || (title.indexOf(p) !== -1 && p.length >= 4)
              );
              if (!isEcho) deduped.push(p);
            }
            paragraphs = deduped;
          }
          var prev = c.prevSelector ? document.querySelector(c.prevSelector) : null;
          var next = c.nextSelector ? document.querySelector(c.nextSelector) : null;
          return {
            title: title,
            paragraphs: paragraphs,
            prevURL: prev ? prev.href : null,
            nextURL: next ? next.href : null,
            matchedSelector: matched
          };
        })()
        """
    }

    /// Reads one comic chapter's page images.
    ///
    /// Parallel to `chapter` rather than folded into it: a comic chapter's pages
    /// are named by the site's own scripts, or by an attribute of the site's
    /// choosing, and none of that is expressible as "find the text node".
    ///
    /// The whole list has to come back from this single evaluation. The fetcher
    /// parks on `about:blank` the moment extraction returns
    /// (`WebFetcher.parkAfterExtraction`), so the page's globals are gone
    /// afterwards and there is no fetching the rest of the pages later.
    static func comicImages(_ rule: SiteRule) throws -> String {
        guard let images = rule.images else { throw BuildError.wrongKind(rule.kind) }
        let cfg = try json(images)
        return """
        (function () {
          \(helpers)
          var c = \(cfg);
          function absolute(u) {
            var s = (u === null || u === undefined) ? '' : String(u).trim();
            if (!s) return null;
            try { return new URL(s, location.href).href; } catch (e) { return null; }
          }
          // `unescape` is percent decoding, not HTML entity decoding: the site that
          // needs it stores each address as JavaScript `escape()` output
          // ("%2f%2fimg9%2e38comic.com%2f…") and calls `unescape()` on it before
          // use. A malformed sequence throws — the raw value is a better answer to
          // that than nothing, and it is what a `%uXXXX` escape (the one thing
          // `escape` emits that this cannot read) would fall through to.
          function decodePercent(s) {
            try { return decodeURIComponent(s); } catch (e) { return s; }
          }
          // A site states its CDN query either already built ('e=1&m=2') or as the
          // object it was built from. Both are accepted because both are what these
          // pages hold — and the object is joined raw, exactly as the site joins it.
          // This query is a signature the CDN checks: encoding it "properly" changes
          // the bytes and the signature stops matching.
          function queryString(v) {
            if (v === null || v === undefined) return '';
            if (typeof v === 'string') {
              var s = v.trim();
              if (!s) return '';
              return s.charAt(0) === '?' ? s : '?' + s;
            }
            if (typeof v !== 'object') return '';
            var parts = [];
            for (var k in v) {
              if (!Object.prototype.hasOwnProperty.call(v, k)) continue;
              parts.push(k + '=' + v[k]);
            }
            return parts.length ? '?' + parts.join('&') : '';
          }
          // Builds the addresses from an object the rule names paths into. `window`
          // for a `global` strategy, the page's decoded packed script for a
          // `packed` one — the assembly is identical either way, and the only thing
          // that differs is where the reading starts.
          function buildFrom(root, s) {
            var list = walkPath(root, s.arrayPath);
            if (!list || typeof list.length !== 'number') return [];
            var prefix = s.prefixPath ? walkPath(root, s.prefixPath) : '';
            if (typeof prefix !== 'string') prefix = '';
            var base = (s.baseURL || '') + prefix;
            var query = queryString(s.queryPath ? walkPath(root, s.queryPath) : null);
            var out = [];
            for (var i = 0; i < list.length; i++) {
              var entry = list[i];
              if (typeof entry !== 'string' || !entry) continue;
              var u = absolute(base + entry + query);
              if (u) out.push(u);
            }
            return out;
          }
          // --- Undoing a packed script ---------------------------------------
          //
          // One site keeps its page list nowhere a reader can reach it: the chapter
          // ships as `eval(function(p,a,c,k,e,d){…}(…))`, and the code that comes
          // out hands the list straight to a function that keeps none of it. A
          // chapter of 194 pages leaves exactly one address anywhere in the
          // document, and `window` holds nothing.
          //
          // But the list is not missing, only compressed: that packer is base
          // conversion plus dictionary substitution, and undoing it is arithmetic
          // over strings. So this reads it rather than runs it. Nothing reaches
          // `eval` or `new Function`; the object comes back through `JSON.parse`,
          // which cannot execute anything, and the rule names only paths into the
          // result — exactly as it does for a global.
          //
          // What *is* borrowed from the page is the dictionary's own decompressor,
          // which the site installs on `String.prototype` under a name it obfuscates.
          // Its name and its separator are read out of the packed call itself rather
          // than written down here, so this stays a description of the packer rather
          // than of one site — and if the method is missing, plain `split` is what an
          // unobfuscated packer uses anyway.
          var packedCache;
          function stringLiteral(src) {
            var s = String(src == null ? '' : src).trim();
            var q = s.charAt(0);
            if (s.length >= 2 && (q === "'" || q === '"') && s.charAt(s.length - 1) === q) {
              s = s.slice(1, -1);
            }
            return s.replace(
              /\\\\(x([0-9a-fA-F]{2})|u([0-9a-fA-F]{4})|([\\s\\S]))/g,
              function (all, whole, hex, uni, ch) {
                if (hex) return String.fromCharCode(parseInt(hex, 16));
                if (uni) return String.fromCharCode(parseInt(uni, 16));
                if (ch === 'n') return '\\n';
                if (ch === 't') return '\\t';
                if (ch === 'r') return '\\r';
                return ch;
              }
            );
          }
          // The first complete `{…}`, counted rather than searched for: the unpacked
          // text is a call with the object inside it, and `lastIndexOf('}')` would
          // swallow anything the site appended after.
          function firstObject(text) {
            var start = text.indexOf('{');
            if (start < 0) return null;
            var depth = 0, quote = '', escaped = false;
            for (var i = start; i < text.length; i++) {
              var ch = text.charAt(i);
              if (escaped) { escaped = false; continue; }
              if (ch === '\\\\') { escaped = true; continue; }
              if (quote) { if (ch === quote) quote = ''; continue; }
              if (ch === '"' || ch === "'") { quote = ch; continue; }
              if (ch === '{') depth++;
              else if (ch === '}' && --depth === 0) return text.slice(start, i + 1);
            }
            return null;
          }
          function unpacked() {
            if (packedCache !== undefined) return packedCache;
            packedCache = null;
            var scripts = document.querySelectorAll('script');
            for (var i = 0; i < scripts.length; i++) {
              var src = scripts[i].textContent || '';
              if (src.indexOf('p,a,c,k,e,d') === -1) continue;
              var m = src.match(
                /\\}\\('((?:[^'\\\\]|\\\\[\\s\\S])*)',(\\d+),(\\d+),'((?:[^'\\\\]|\\\\[\\s\\S])*)'\\s*(?:\\[([^\\]]*)\\]|\\.([A-Za-z_$][\\w$]*))\\(([^)]*)\\)/
              );
              if (!m) continue;
              var payload = stringLiteral("'" + m[1] + "'");
              var radix = parseInt(m[2], 10);
              var count = parseInt(m[3], 10);
              var blob = stringLiteral("'" + m[4] + "'");
              var method = m[5] ? stringLiteral(m[5]) : m[6];
              var separator = stringLiteral(m[7]);
              var words;
              try {
                words = (method && typeof blob[method] === 'function')
                  ? blob[method](separator)
                  : blob.split(separator);
              } catch (e) { continue; }
              if (!words || typeof words.length !== 'number') continue;
              function token(n) {
                return (n < radix ? '' : token(Math.floor(n / radix)))
                  + ((n = n % radix) > 35 ? String.fromCharCode(n + 29) : n.toString(36));
              }
              var text = payload, j = count;
              while (j--) {
                if (!words[j]) continue;
                text = text.replace(new RegExp('\\\\b' + token(j) + '\\\\b', 'g'), words[j]);
              }
              var body = firstObject(text);
              if (!body) continue;
              try { packedCache = JSON.parse(body); } catch (e) { continue; }
              if (packedCache) return packedCache;
            }
            return packedCache;
          }
          function fromDom(s) {
            if (!s.selector) return [];
            var nodes = Array.prototype.slice.call(document.querySelectorAll(s.selector));
            var attrs = (s.attributes && s.attributes.length) ? s.attributes : ['src'];
            var out = [];
            for (var i = 0; i < nodes.length; i++) {
              var raw = null;
              for (var j = 0; j < attrs.length && !raw; j++) {
                var v = nodes[i].getAttribute(attrs[j]);
                if (v && v.trim()) raw = v.trim();
              }
              if (!raw) continue;
              if (s.unescape) raw = decodePercent(raw);
              var u = absolute(raw);
              if (u) out.push(u);
            }
            return out;
          }
          // Duplicates are kept: the page count is the chapter, and a site that
          // genuinely repeats an image has repeated a page.
          var urls = [], matched = null;
          for (var i = 0; i < c.strategies.length && !urls.length; i++) {
            var s = c.strategies[i];
            var found = s.type === 'global' ? buildFrom(window, s)
              : (s.type === 'packed' ? buildFrom(unpacked(), s)
              : (s.type === 'dom' ? fromDom(s) : []));
            if (found.length) {
              urls = found;
              matched = s.type + ':' + (s.arrayPath || s.selector || '');
            }
          }
          var heading = document.querySelector('h1');
          var title = clean(heading ? heading.textContent : document.title);
          return { imageURLs: urls, title: title || null, matchedStrategy: matched };
        })()
        """
    }

    struct SearchPayload: Decodable {
        struct Row: Decodable {
            let title: String
            let url: String
            let author: String?
            let cover: String?
        }
        let rows: [Row]
    }

    static func searchResults(_ rule: SiteRule) throws -> String {
        guard let search = rule.search else { throw BuildError.searchUnsupported }
        let cfg = try json(search)
        return """
        (function () {
          \(helpers)
          var c = \(cfg);
          var scope = c.resultContainer ? document.querySelector(c.resultContainer) : document;
          if (!scope) return { rows: [] };
          var links = Array.prototype.slice.call(scope.querySelectorAll(c.resultLinkSelector));
          var seen = {}, rows = [];
          links.forEach(function (a) {
            if (!a.href) return;
            // Row-scoped lookups walk up to the nearest container so that a
            // result's author/cover cannot be picked up from a neighbouring row.
            var row = a.closest('li, tr, .item, .result, div') || a.parentElement || a;
            function pick(sel) {
              if (!sel) return null;
              // Strictly row-scoped, with no document-wide fallback. A fallback
              // looks helpful and is the opposite: when a row genuinely lacks the
              // field — czbooks puts the author outside the row container the
              // link closes over — every row silently inherits the *first* row's
              // author. A missing field must read as missing.
              var el = row.querySelector(sel);
              return el ? clean(el.textContent) : null;
            }
            var coverEl = c.resultCoverSelector ? row.querySelector(c.resultCoverSelector) : null;
            var title = c.resultTitleSelector ? pick(c.resultTitleSelector) : clean(a.textContent);
            if (!title) title = clean(a.textContent);
            // Image-only links carry their title in an attribute. Worth reading
            // because result rows habitually link the same book twice — once from
            // the cover, once from the heading.
            if (!title) title = clean(a.getAttribute('title'));
            if (!title) {
                var img = a.querySelector('img');
                if (img) title = clean(img.getAttribute('alt') || img.getAttribute('title'));
            }
            if (!title) return;
            // Deduped only once a title is in hand. Marking the URL seen earlier
            // let a textless cover link consume the slot and the heading link
            // right after it — the one that actually names the book — be dropped
            // as a duplicate, losing the whole result.
            if (seen[a.href]) return;
            seen[a.href] = true;
            rows.push({
              title: title,
              url: a.href,
              author: pick(c.resultAuthorSelector),
              // data-* before src: on lazy-loading result lists `src` holds a
              // placeholder ("nocover.jpg") and the real URL is in the data
              // attribute, so reading src first would show every book as
              // coverless. Sites without lazy loading have no data-* and fall
              // through to src unchanged.
              cover: coverEl
                ? (coverEl.getAttribute('data-original')
                   || coverEl.getAttribute('data-src')
                   || coverEl.src)
                : null
            });
          });
          return { rows: rows };
        })()
        """
    }

    /// Submits a POST search from inside the page.
    ///
    /// Done as a real form submission rather than a hand-built request because
    /// several of these sites are GBK: the browser encodes form fields using the
    /// document's charset, so a query in Chinese is transmitted correctly without
    /// the app owning any legacy-encoding logic.
    static func submitSearch(_ rule: SiteRule, query: String) throws -> String {
        guard let search = rule.search else { throw BuildError.searchUnsupported }
        return try submitForm(url: search.url, field: search.queryField, query: query, method: search.method)
    }

    /// Builds and submits a form from scratch, for a form that may not be on the
    /// page. `method` is explicit because rule derivation has to try a site's
    /// own GET form the same way, and for the same reason: letting the browser
    /// submit is what gets the charset right on the GBK/Big5 sites.
    static func submitForm(
        url: String, field: String, query: String, method: SiteRule.Search.Method
    ) throws -> String {
        let cfg = try json(SubmitConfig(url: url, field: field, query: query, method: method.rawValue))
        return """
        (function () {
          var c = \(cfg);
          var form = document.createElement('form');
          form.method = c.method;
          form.action = c.url;
          var input = document.createElement('input');
          input.type = 'hidden';
          input.name = c.field;
          input.value = c.query;
          form.appendChild(input);
          document.body.appendChild(form);
          form.submit();
          return true;
        })()
        """
    }

    private struct SubmitConfig: Encodable {
        let url: String
        let field: String
        let query: String
        let method: String
    }

    // MARK: - Shared JS helpers

    /// `readField` implements the meta-preferred / selector-fallback rule from
    /// `SiteRule.Field`; `clean` collapses the non-breaking spaces these sites
    /// use as indentation.
    ///
    /// Internal rather than private so `RuleDeriver` can reuse `largestTextBlock`:
    /// the selector it proposes for a new rule has to be found by exactly the same
    /// heuristic the rule will later run, or the preview would confirm something
    /// different from what gets saved.
    static let helpers = """
        function clean(s) {
          return (s || '').replace(/\\u00a0/g, ' ').replace(/\\s+/g, ' ').trim();
        }
        // Walks a dot path by property access, one segment at a time, starting from
        // `node`. A rule file travels between users and is read inside the web view
        // holding every cookie they own, so a path a rule names is walked — never
        // evaluated.
        function walkPath(node, path) {
          if (!path) return undefined;
          var parts = String(path).split('.');
          for (var i = 0; i < parts.length; i++) {
            if (node === null || node === undefined) return undefined;
            node = node[parts[i]];
          }
          return node;
        }
        // Last resort when a rule's contentSelectors all miss. Several of these
        // sites are table-layout era markup where the chapter body has no id or
        // class at all, and the only stable selector would be positional
        // (`table:nth-of-type(7) > tr > td > div:nth-of-type(5)`) — which breaks
        // the moment a banner is added. Picking the densest text block instead
        // survives layout churn, so a rule can leave contentSelectors as hints.
        function largestTextBlock() {
          var best = null, bestScore = 0;
          var nodes = document.querySelectorAll('div, td, article, section');
          for (var i = 0; i < nodes.length; i++) {
            var el = nodes[i];
            var text = clean(el.textContent);
            if (text.length < 200) continue;
            // Navigation and recommendation blocks are link-dense; chapter text
            // is not. Charge each link against the score.
            var score = text.length - el.getElementsByTagName('a').length * 120;
            // Prefer the innermost node holding the text: a wrapper scores the
            // same as its child, and we want the child.
            var childHoldsAll = false;
            for (var k = 0; k < el.children.length; k++) {
              if (clean(el.children[k].textContent).length >= text.length * 0.95) {
                childHoldsAll = true;
                break;
              }
            }
            if (childHoldsAll) continue;
            if (score > bestScore) { bestScore = score; best = el; }
          }
          return best;
        }
        // Attributes HTML itself defines as URLs. Their values are resolved against
        // the document, because a cover published as "/pics/0/103.jpg" or
        // "//cdn.example.com/1.jpg" is not an address anything outside the page can
        // use — and two of the comic sites publish theirs exactly that way, where
        // the shelf would simply draw nothing. An already-absolute value is
        // unchanged, so the sites that were always fine stay fine.
        var URL_ATTRIBUTES = { src: 1, href: 1, poster: 1, 'data-src': 1, 'data-original': 1 };
        function readField(f) {
          if (!f) return null;
          if (f.meta) {
            var m = document.querySelector('meta[property="' + f.meta + '"], meta[name="' + f.meta + '"]');
            if (m) return clean(m.getAttribute('content'));
          }
          if (f.selector) {
            var el = document.querySelector(f.selector);
            if (!el) return null;
            if (!f.attribute) return clean(el.textContent);
            var raw = clean(el.getAttribute(f.attribute));
            if (!raw || !URL_ATTRIBUTES[f.attribute]) return raw;
            try { return new URL(raw, location.href).href; } catch (e) { return raw; }
          }
          return null;
        }
        """

    /// Encodes a rule fragment straight into the script.
    ///
    /// Encoding the Codable rule types rather than hand-built dictionaries is
    /// what keeps absent optional fields out of the JS entirely: the synthesized
    /// `encode(to:)` omits nil keys, so `readField` never sees a null it has to
    /// defend against.
    private static func json<T: Encodable>(_ value: T) throws -> String {
        // withoutEscapingSlashes: selectors are full of slashes and `\/` makes a
        // generated script painful to read when diagnosing a broken rule.
        // sortedKeys: stable output, so tests can assert on it.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        guard let data = try? encoder.encode(value),
              let s = String(data: data, encoding: .utf8)
        else { throw BuildError.encodingFailed }
        return s
    }
}
