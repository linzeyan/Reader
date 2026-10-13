(function () {
  __HELPERS__
  var c = __CFG__;
  var scope = c.resultContainer ? document.querySelector(c.resultContainer) : document;
  if (!scope) return { rows: [] };
  var links = Array.prototype.slice.call(scope.querySelectorAll(c.resultLinkSelector));
  // `named[i]` records whether row `i` got its title from the link itself
  // rather than off a picture inside it — see the replacement below.
  var seen = {}, rows = [], named = [];
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
    var fromLink = !!title;
    if (!title) {
        var img = a.querySelector('img');
        if (img) title = clean(img.getAttribute('alt') || img.getAttribute('title'));
    }
    if (!title) return;
    // Deduped only once a title is in hand. Marking the URL seen earlier
    // let a textless cover link consume the slot and the heading link
    // right after it — the one that actually names the book — be dropped
    // as a duplicate, losing the whole result.
    var at = seen[a.href];
    if (at !== undefined) {
      // A later link may still correct an earlier one, upwards only. The
      // check above accepts an image's `alt` as a title, and 69shuba's
      // covers carry alt="1" — so first-wins handed back six books all
      // called "1" while the heading link that says 「劍來」 was thrown
      // away as a duplicate. A name the link carries beats one scraped
      // off its picture.
      if (fromLink && !named[at]) { rows[at].title = title; named[at] = true; }
      return;
    }
    seen[a.href] = rows.length;
    named.push(fromLink);
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
