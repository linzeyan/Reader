(function () {
  __HELPERS__
  var c = __CFG__;
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
      /\\(x([0-9a-fA-F]{2})|u([0-9a-fA-F]{4})|([\s\S]))/g,
      function (all, whole, hex, uni, ch) {
        if (hex) return String.fromCharCode(parseInt(hex, 16));
        if (uni) return String.fromCharCode(parseInt(uni, 16));
        if (ch === 'n') return '\n';
        if (ch === 't') return '\t';
        if (ch === 'r') return '\r';
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
      if (ch === '\\') { escaped = true; continue; }
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
        /\}\('((?:[^'\\]|\\[\s\S])*)',(\d+),(\d+),'((?:[^'\\]|\\[\s\S])*)'\s*(?:\[([^\]]*)\]|\.([A-Za-z_$][\w$]*))\(([^)]*)\)/
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
        text = text.replace(new RegExp('\\b' + token(j) + '\\b', 'g'), words[j]);
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
  // A heading only, never `document.title`: that carries the site's name
  // after the chapter's ("Episode 9: The Remedy - Pepper&Carrot"), which
  // passes `Chapter.fullerTitle`'s prefix guard and was stored as the name.
  var heading = document.querySelector('h1');
  var title = heading ? clean(heading.textContent) : '';
  return { imageURLs: urls, title: title || null, matchedStrategy: matched };
})()
