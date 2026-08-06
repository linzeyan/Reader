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
            return { title: clean(a.textContent), url: a.href };
          }).filter(function (e) { return e.title && e.url; });
          // Dedupe by URL: catalogs often repeat the newest chapters in a header.
          var seen = {}, unique = [];
          for (var i = 0; i < entries.length; i++) {
            if (seen[entries[i].url]) continue;
            seen[entries[i].url] = true;
            unique.push(entries[i]);
          }
          if (c.order === 'descending') unique.reverse();
          return { entries: unique };
        })()
        """
    }

    static func chapter(_ rule: SiteRule) throws -> String {
        let cfg = try json(rule.chapter)
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
        function readField(f) {
          if (!f) return null;
          if (f.meta) {
            var m = document.querySelector('meta[property="' + f.meta + '"], meta[name="' + f.meta + '"]');
            if (m) return clean(m.getAttribute('content'));
          }
          if (f.selector) {
            var el = document.querySelector(f.selector);
            if (el) return clean(f.attribute ? el.getAttribute(f.attribute) : el.textContent);
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
