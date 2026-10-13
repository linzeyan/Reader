(function () {
  __HELPERS__
  var c = __CFG__;
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
    if (c.visibleOnly) {
      // Computed style exists only on the live page, so the hidden elements
      // are found there and their twins removed from the copy. A clone keeps
      // the tree's shape, so position in document order names the twin.
      var live = node.getElementsByTagName('*');
      var twins = copy.getElementsByTagName('*');
      var hidden = [];
      for (var h = 0; h < live.length; h++) {
        if (getComputedStyle(live[h]).display === 'none') hidden.push(twins[h]);
      }
      hidden.forEach(function (el) { el.remove(); });
    }
    c.stripSelectors.forEach(function (s) {
      if (!s) return;
      Array.prototype.slice.call(copy.querySelectorAll(s)).forEach(function (el) { el.remove(); });
    });
    // These templates separate paragraphs three different ways — <br>,
    // <p>, and bare <div> — and `textContent` inserts nothing between
    // block elements, so a div-per-paragraph site would collapse into a
    // single unreadable line. Normalise all three into line breaks.
    copy.innerHTML = copy.innerHTML.replace(/<br\s*\/?>/gi, '\n');
    Array.prototype.slice.call(copy.querySelectorAll('p, div, li, h1, h2, h3, h4, blockquote'))
      .forEach(function (el) {
        el.insertAdjacentText('beforebegin', '\n');
        el.insertAdjacentText('afterend', '\n');
      });
    paragraphs = (copy.textContent || '').split('\n')
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
