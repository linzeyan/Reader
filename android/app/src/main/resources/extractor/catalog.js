(function () {
  __HELPERS__
  var c = __CFG__;
  var root = document.querySelector(c.container) || document;
  var entries;
  if (c.json) {
    // A JSON document, which WebKit shows as its own text (`Catalog.json`).
    // Parsed, never evaluated; anything that is not the expected shape reads
    // as an empty catalog.
    var data = null;
    try { data = JSON.parse(document.body ? document.body.textContent : ''); } catch (e) {}
    var list = walkPath(data, c.json.arrayPath);
    var items = (list && typeof list.length === 'number') ? Array.prototype.slice.call(list) : [];
    entries = items.map(function (item) {
      if (!item || typeof item !== 'object') return null;
      var id = item[c.json.idKey], name = item[c.json.titleKey];
      return {
        title: clean(name === null || name === undefined ? '' : String(name)),
        url: id === null || id === undefined ? '' : String(id).trim()
      };
    }).filter(function (e) { return e && e.title && e.url; });
  } else if (c.lines) {
    // No links to read: each line of the container is a chapter name, and
    // its position is the chapter id (`Catalog.lines`). `document` has no
    // textContent, so a missing container reads as an empty catalog.
    entries = (root.textContent || '').split('\n').map(clean)
      .filter(function (t) { return t.length > 0; })
      .map(function (t, i) { return { title: t, url: String(i + 1) }; });
  } else {
    var links = Array.prototype.slice.call(root.querySelectorAll(c.linkSelector));
    entries = links.map(function (a) {
      // `url` carries whatever the chapter is identified by, which is the
      // href unless the rule names an attribute — see `Catalog.linkAttribute`.
      // Swift is what pattern-matches it and rebuilds the address; here it is
      // only ever read and passed on.
      var link = c.linkAttribute ? a.getAttribute(c.linkAttribute) : a.href;
      return { title: clean(a.textContent), url: link ? String(link).trim() : '' };
    }).filter(function (e) { return e.title && e.url; });
  }
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
