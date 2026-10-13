(function () {
  __HELPERS__
  function selectorFor(el) {
    if (!el || !el.tagName) return null;
    if (el.id) return '#' + el.id;
    var classes = (el.getAttribute('class') || '').trim().split(/\s+/).filter(function (c) {
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

  // The page images, if this is a comic.
  //
  // Ordered by how these sites actually behave rather than by the spec: an
  // unloaded lazy image has an empty `src` and its real address in an attribute
  // of the site's own choosing, so `src` alone finds a fraction of a chapter.
  var ATTRS = ['src', 'data-src', 'data-original', 'data-echo', 'data-lazy-src'];
  function addressOf(img) {
    for (var i = 0; i < ATTRS.length; i++) {
      var v = img.getAttribute(ATTRS[i]);
      // A placeholder pixel and a vector both mean furniture, not a page: a
      // lazy loader parks a `data:` gif in `src`, and every navigation arrow
      // and flag on these pages is an `.svg`.
      if (v && !/^data:/i.test(v) && !/\.svg(\?|#|$)/i.test(v)) {
        return { attr: ATTRS[i], url: v };
      }
    }
    return null;
  }
  // Every way to name one image, widening: each of its own classes alone, its
  // first two together, then its parent's and its grandparent's. A comic page is
  // usually wrapped, and the wrapper is often what carries the meaningful class
  // while the image carries none.
  //
  // Classes one at a time as well as in pairs, and that is not thoroughness for
  // its own sake. On a utility-CSS site the meaningful class sits among layout
  // ones — `class="lozad page w-full mx-auto"` — so taking the first two yields
  // `img.lozad.page`, which is accidentally specific: the images already loaded
  // have no `lozad` and land under a different name, splitting one chapter into
  // two partial selectors that each match a fraction of it. `img.page` names the
  // whole run. Scoring below is what picks between the candidates, so offering
  // more of them costs nothing but a few counts.
  function namesFor(img) {
    var out = [];
    (img.getAttribute('class') || '').trim().split(/\s+/).forEach(function (c) {
      if (c && /^[A-Za-z][-_A-Za-z0-9]*$/.test(c)) out.push('img.' + c);
    });
    var own = selectorFor(img);
    if (own) out.push(own);
    var p = img.parentElement, ps = p ? selectorFor(p) : null;
    if (ps) out.push(ps + ' img');
    var g = p ? p.parentElement : null, gs = g ? selectorFor(g) : null;
    if (gs) out.push(gs + ' img');
    return out;
  }
  var found = [];
  Array.prototype.slice.call(document.querySelectorAll('img')).forEach(function (img) {
    var a = addressOf(img);
    if (a) found.push({ img: img, attr: a.attr, url: a.url });
  });
  var tally = {};
  found.forEach(function (e) {
    namesFor(e.img).forEach(function (sel) { tally[sel] = (tally[sel] || 0) + 1; });
  });
  var best = null;
  Object.keys(tally).forEach(function (sel) {
    // The selector has to reach these images and no others. One that also
    // sweeps up the site logo is not a description of the chapter, and the
    // count is what proves it: reaching more nodes than were counted means it
    // reaches something that had no address.
    var reached;
    try { reached = document.querySelectorAll(sel).length; } catch (e) { return; }
    if (reached !== tally[sel]) return;
    if (!best || tally[sel] > best.count
        || (tally[sel] === best.count && sel.length < best.selector.length)) {
      best = { selector: sel, count: tally[sel] };
    }
  });
  var images = null;
  if (best) {
    var mine = found.filter(function (e) { return e.img.matches(best.selector); });
    var attrs = [];
    ATTRS.forEach(function (a) {
      if (mine.some(function (e) { return e.attr === a; })) attrs.push(a);
    });
    images = {
      selector: best.selector,
      attributes: attrs,
      count: mine.length,
      first: mine.length ? new URL(mine[0].url, location.href).href : ''
    };
  }

  return {
    contentSelector: selector,
    unique: selector ? document.querySelectorAll(selector).length === 1 : false,
    title: title,
    titleSelector: titleSelector,
    images: images
  };
})()
