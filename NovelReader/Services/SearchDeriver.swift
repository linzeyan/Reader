import Foundation

/// Works out how to search a site, using the site's own search box.
///
/// Separate from `RuleDeriver` because search lives somewhere else: the endpoint,
/// the method and the field name are on pages a book URL never leads to, which is
/// why deriving a rule from a book page leaves `search` empty. This closes that
/// gap for any site whose search is an ordinary HTML form — which is nearly all
/// of them.
///
/// The derivation submits a real form with a real query rather than guessing a
/// URL template. That is what makes the GBK and Big5 sites work: the browser
/// encodes the field using the document's own charset, and for a GET form the
/// address it lands on *is* the template, with the query substituted back out.
@MainActor
final class SearchDeriver {
    enum DeriveError: LocalizedError {
        case badHost
        case noSearchForm
        case noResults

        var errorDescription: String? {
            switch self {
            case .badHost: return String(localized: "derive.error.badURL")
            case .noSearchForm: return String(localized: "search.derive.error.noForm")
            case .noResults: return String(localized: "search.derive.error.noResults")
            }
        }
    }

    struct Derived: Equatable {
        var search: SiteRule.Search
        /// Titles the derived search actually returned, so the user confirms
        /// against results rather than against a configuration.
        var sampleTitles: [String]
    }

    private let fetcher: WebFetcher

    init(fetcher: WebFetcher) {
        self.fetcher = fetcher
    }

    func derive(for rule: SiteRule, probe query: String) async throws -> Derived {
        guard let home = URL(string: "https://\(rule.host)/") else { throw DeriveError.badHost }
        let forms = try await fetcher.fetch(home, extracting: Self.formProbe, as: FormsPayload.self)
        guard !forms.forms.isEmpty else { throw DeriveError.noSearchForm }

        for form in forms.forms {
            // A typed-into search box can only ever produce a GET rule: whatever
            // the page's JavaScript does, it ends up at an address.
            let method: SiteRule.Search.Method =
                (form.inputSelector == nil && form.method == "POST") ? .post : .get
            let submit = try form.inputSelector.map {
                Self.typeAndSubmit(selector: $0, query: query)
            } ?? ExtractorScript.submitForm(
                url: form.action, field: form.field, query: query, method: method
            )
            let landing: ResultsPayload
            do {
                landing = try await fetcher.fetch(
                    home, submitting: submit, extracting: Self.resultsProbe(rule),
                    as: ResultsPayload.self,
                    // Shorter than the default for the typed path: a click that
                    // opens an overlay instead of navigating never lands, and the
                    // next candidate deserves its turn without a 30s wait.
                    timeout: form.inputSelector == nil ? .seconds(30) : .seconds(15)
                )
            } catch let error as WebFetcher.FetchError {
                // A challenge is the user's to clear; a form that leads nowhere
                // just means the next candidate gets a turn.
                if case .challengePresented = error { throw error }
                continue
            }
            guard landing.count > 0 else { continue }

            // For GET, the address the form landed on is the template — but only
            // if the query survives into it in a form we can rebuild. A site that
            // encodes the field in GBK produces bytes this app cannot reproduce
            // for a different query, so it is dropped rather than saved broken.
            let endpoint: String
            switch method {
            case .get:
                guard let template = Self.template(from: landing.href, query: query) else { continue }
                endpoint = template
            case .post:
                endpoint = form.action
            }

            // Scoping to a container keeps a sidebar of "hot books" out of the
            // results — but only if it holds every result. One that loses rows is
            // worse than none, since `SearchService` already discards links with
            // no book id.
            let container = landing.inContainer == landing.count ? landing.container : nil
            let search = SiteRule.Search(
                method: method,
                url: endpoint,
                queryField: form.field,
                resultContainer: container,
                resultLinkSelector: "a",
                resultTitleSelector: nil,
                resultAuthorSelector: nil,
                resultCoverSelector: landing.hasCover ? "img" : nil
            )
            // The titles come from the page the form actually landed on, and the
            // endpoint is that same page's address with the query substituted
            // back out — so the rule is confirmed by construction.
            //
            // Deliberately *not* re-running the search to double-check: some of
            // these sites answer a second identical query within a few seconds
            // with an empty page, which made a working rule look broken. Both the
            // derived rule and the hand-written one score zero on that second
            // request, so the retry was measuring the site's flood control, not
            // the rule.
            return Derived(search: search, sampleTitles: landing.titles)
        }
        // A search box was found and tried; "no form" would send the user looking
        // for the wrong thing.
        throw DeriveError.noResults
    }

    /// Turns the URL a GET search landed on back into a `{query}` template.
    nonisolated static func template(from href: String, query: String) -> String? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        for needle in [encoded, query] where !needle.isEmpty && href.contains(needle) {
            return href.replacingOccurrences(of: needle, with: "{query}")
        }
        return nil
    }

    // MARK: - Probe payloads

    struct FormsPayload: Decodable {
        struct Form: Decodable {
            let method: String
            let action: String
            let field: String
            /// Set when the search box is not inside a `<form>` at all. Several
            /// of these sites drive search from JavaScript, so there is nothing
            /// to submit — the box has to be typed into and the button clicked,
            /// the way a person would.
            let inputSelector: String?
        }
        let forms: [Form]
    }

    struct ResultsPayload: Decodable {
        let href: String
        let container: String?
        /// Books found anywhere on the page.
        let count: Int
        /// How many of those the proposed container holds. A container that
        /// loses results is worse than no container at all.
        let inContainer: Int
        let hasCover: Bool
        /// Names read the way the extractor reads them, so the preview shows
        /// what a search will actually show.
        let titles: [String]
    }

    // MARK: - Probes

    /// Finds the site's search forms, best guess first.
    static let formProbe = """
    (function () {
      function absolute(url) {
        try { return new URL(url, location.href).href; } catch (e) { return null; }
      }
      // The names these sites give a search box. Ordered matters only in that a
      // named match beats the shape-based fallback below it.
      var named = /^(searchkey|keyword|keywords|key|searchword|q|s|wd|kw|word|name|title|term)$/i;
      var searchy = /search|so\\.|\\/s\\/|query|find/i;
      var out = [];
      Array.prototype.slice.call(document.querySelectorAll('form')).forEach(function (form) {
        var action = absolute(form.getAttribute('action') || location.href);
        if (!action) return;
        var inputs = Array.prototype.slice.call(form.querySelectorAll('input')).filter(function (input) {
          var type = (input.getAttribute('type') || 'text').toLowerCase();
          return (type === 'text' || type === 'search') && input.name;
        });
        if (!inputs.length) return;
        var field = null;
        for (var i = 0; i < inputs.length && !field; i++) {
          if (named.test(inputs[i].name)) field = inputs[i].name;
        }
        // A form with a single free-text box pointed at a search-looking address
        // is a search box even when the field is named something local.
        if (!field && inputs.length === 1 && searchy.test(action)) field = inputs[0].name;
        if (!field) return;
        out.push({
          method: (form.getAttribute('method') || 'GET').toUpperCase(),
          action: action,
          field: field,
          inputSelector: null
        });
      });

      // Sites whose search is JavaScript have no form to submit — the box is a
      // bare input with a click handler. Offered after real forms, because a
      // form is the exact answer and this is an imitation of one.
      Array.prototype.slice.call(document.querySelectorAll('input[type=text], input[type=search]'))
        .forEach(function (input) {
          if (input.form) return;
          var hint = [input.name, input.id, input.getAttribute('placeholder'),
                      input.getAttribute('class')].join(' ');
          if (!/search|keyword|key|query|搜尋|搜索|書名|书名/i.test(hint)) return;
          var selector = input.id ? '#' + input.id
            : (input.name ? 'input[name="' + input.name + '"]' : null);
          // One match is ideal but not required: sites that ship a phone and a
          // desktop header have the same search box twice, and `querySelector`
          // picking the first of them still types into a real search box.
          if (!selector || !document.querySelector(selector)) return;
          out.push({
            method: 'GET',
            action: location.href,
            field: input.name || input.id || 'q',
            inputSelector: selector
          });
        });

      return { forms: out.slice(0, 4) };
    })()
    """

    /// Types a query into a search box and sets it off, for sites with no form.
    ///
    /// Clicks a nearby button in preference to synthesising Enter: a site that
    /// binds only a click handler ignores the key event, and one that binds both
    /// behaves the same either way.
    static func typeAndSubmit(selector: String, query: String) -> String {
        let cfg = (try? String(data: JSONEncoder().encode([selector, query]), encoding: .utf8)) ?? "[]"
        return """
        (function () {
          var c = \(cfg);
          var el = document.querySelector(c[0]);
          if (!el) return false;
          el.focus();
          el.value = c[1];
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          var scope = el.parentElement, button = null;
          for (var depth = 0; depth < 3 && scope && !button; depth++) {
            // `input[type=image]` is in here because it is what an ASP.NET page
            // uses for a search button, and those pages ignore a synthesised
            // Enter entirely — without the click there is nothing to submit.
            button = scope.querySelector(
              'button, input[type=submit], input[type=image], .search-btn, .btn-search, [role=button]'
            );
            scope = scope.parentElement;
          }
          if (button) { button.click(); return true; }
          ['keydown', 'keypress', 'keyup'].forEach(function (type) {
            el.dispatchEvent(new KeyboardEvent(type, {
              key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true
            }));
          });
          return true;
        })()
        """
    }

    /// Counts the book links on a results page and names the block holding them.
    ///
    /// "Book link" is decided by the rule's own id patterns rather than by
    /// markup: a result row is exactly a link the app can turn into a bookmark,
    /// and that test is already written down.
    static func resultsProbe(_ rule: SiteRule) -> String {
        let bookPattern = jsString(rule.idPatterns.bookId)
        let chapterPattern = jsString(rule.idPatterns.chapterId)
        return """
        (function () {
          var bookRe, chapterRe;
          try {
            bookRe = new RegExp(\(bookPattern));
            chapterRe = new RegExp(\(chapterPattern));
          } catch (e) { return { href: location.href, container: null, count: 0, hasCover: false }; }
          function selectorFor(el) {
            if (!el || !el.tagName) return null;
            if (el.id) return '#' + el.id;
            var classes = (el.getAttribute('class') || '').trim().split(/\\s+/).filter(function (c) {
              return c && /^[A-Za-z][-_A-Za-z0-9]*$/.test(c);
            });
            if (classes.length) return el.tagName.toLowerCase() + '.' + classes.slice(0, 2).join('.');
            return null;
          }
          function clean(s) { return (s || '').replace(/\\u00a0/g, ' ').replace(/\\s+/g, ' ').trim(); }
          // The same order the search extractor reads a row's name in. Kept in
          // step deliberately: a title this cannot find is a result the app will
          // not show either, so counting it here would overstate the rule.
          function nameOf(a) {
            var name = clean(a.textContent) || clean(a.getAttribute('title'));
            if (!name) {
              var img = a.querySelector('img');
              if (img) name = clean(img.getAttribute('alt') || img.getAttribute('title'));
            }
            return name;
          }
          var empty = { href: location.href, container: null, count: 0, inContainer: 0,
                        hasCover: false, titles: [] };
          var seen = {}, links = [], titles = [];
          Array.prototype.slice.call(document.querySelectorAll('a[href]')).forEach(function (a) {
            var href = a.href;
            if (!href || href.indexOf(location.origin) !== 0) return;
            if (!bookRe.test(href) || chapterRe.test(href)) return;
            var id = bookRe.exec(href)[1];
            if (!id || seen[id]) return;
            var name = nameOf(a);
            if (!name) return;
            seen[id] = true;
            links.push(a);
            if (titles.length < 5) titles.push(name);
          });
          if (!links.length) return empty;
          var node = links[0], container = null, inContainer = 0;
          while (node && node !== document.documentElement) {
            var inside = 0;
            for (var i = 0; i < links.length; i++) { if (node.contains(links[i])) inside++; }
            if (inside >= links.length * 0.8) {
              var sel = selectorFor(node);
              if (sel && document.querySelectorAll(sel).length === 1) {
                container = sel;
                inContainer = inside;
                break;
              }
            }
            node = node.parentElement;
          }
          var row = links[0].closest('li, tr, .item, .result, div') || links[0].parentElement;
          return {
            href: location.href,
            container: container,
            count: links.length,
            inContainer: inContainer,
            hasCover: !!(row && row.querySelector('img')),
            titles: titles
          };
        })()
        """
    }

    /// A regex written for `NSRegularExpression`, quoted as a JS string literal.
    private static func jsString(_ value: String) -> String {
        (try? String(data: JSONEncoder().encode(value), encoding: .utf8)) ?? "\"\""
    }
}

