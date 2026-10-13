(function () {
  var bookRe, chapterRe;
  try {
    bookRe = new RegExp(__BOOKPATTERN__);
    chapterRe = new RegExp(__CHAPTERPATTERN__);
  } catch (e) { return { href: location.href, container: null, count: 0, hasCover: false }; }
  function selectorFor(el) {
    if (!el || !el.tagName) return null;
    if (el.id) return '#' + el.id;
    var classes = (el.getAttribute('class') || '').trim().split(/\s+/).filter(function (c) {
      return c && /^[A-Za-z][-_A-Za-z0-9]*$/.test(c);
    });
    if (classes.length) return el.tagName.toLowerCase() + '.' + classes.slice(0, 2).join('.');
    return null;
  }
  function clean(s) { return (s || '').replace(/\u00a0/g, ' ').replace(/\s+/g, ' ').trim(); }
  // The same order the search extractor reads a row's name in, including
  // its preference for a name the link carries over one scraped off a
  // picture inside it. Kept in step deliberately: a title this cannot
  // find is a result the app will not show either, so counting it here
  // would overstate the rule — and a title it reads differently is a
  // preview that lies about what the derived rule will produce.
  function nameOf(a) {
    var name = clean(a.textContent) || clean(a.getAttribute('title'));
    if (name) return { name: name, fromLink: true };
    var img = a.querySelector('img');
    return {
      name: img ? clean(img.getAttribute('alt') || img.getAttribute('title')) : '',
      fromLink: false
    };
  }
  var empty = { href: location.href, container: null, count: 0, inContainer: 0,
                hasCover: false, titles: [] };
  var seen = {}, links = [], titles = [], named = [];
  Array.prototype.slice.call(document.querySelectorAll('a[href]')).forEach(function (a) {
    var href = a.href;
    if (!href || href.indexOf(location.origin) !== 0) return;
    if (!bookRe.test(href) || chapterRe.test(href)) return;
    var id = bookRe.exec(href)[1];
    if (!id) return;
    var found = nameOf(a);
    if (!found.name) return;
    var at = seen[id];
    if (at !== undefined) {
      // Upwards only, and the reason is the whole point of `sampleTitles`:
      // the user confirms a derived rule against the names it produced.
      // 69shuba links each book from its cover and again from its heading,
      // and the cover's `alt` is "1" — so first-wins offered six books
      // called "1" for confirmation, which confirms nothing.
      if (found.fromLink && !named[at]) { titles[at] = found.name; named[at] = true; }
      return;
    }
    seen[id] = links.length;
    links.push(a);
    titles.push(found.name);
    named.push(found.fromLink);
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
    // Capped at the end rather than while collecting, so a name corrected
    // by a later link is the one that reaches the preview.
    titles: titles.slice(0, 5)
  };
})()
