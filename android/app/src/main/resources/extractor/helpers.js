function clean(s) {
  return (s || '').replace(/\u00a0/g, ' ').replace(/\s+/g, ' ').trim();
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
