(function () {
  var bookToken = __TOKEN__;
  function clean(s) { return (s || '').replace(/\u00a0/g, ' ').replace(/\s+/g, ' ').trim(); }
  function selectorFor(el) {
    if (!el || !el.tagName) return null;
    if (el.id) return '#' + el.id;
    var classes = (el.getAttribute('class') || '').trim().split(/\s+/).filter(function (c) {
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
      if (/^\d+$/.test(seg)) return '#';
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
      var classes = (node.getAttribute('class') || '').trim().split(/\s+/).filter(function (c) {
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
