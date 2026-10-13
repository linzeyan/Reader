(function () {
  __HELPERS__
  var BASE = __BASE__;
  var TITLE = __HEADING__;
  var WHOLE_PAGE = __WHOLEPAGE__;
  var SKIP = {
    script: 1, style: 1, noscript: 1, iframe: 1, svg: 1, form: 1, button: 1,
    nav: 1, aside: 1, video: 1, audio: 1, canvas: 1, object: 1, embed: 1
  };
  // What makes a container a container rather than a paragraph.
  var BLOCKISH = 'p, div, h1, h2, h3, h4, h5, h6, ul, ol, pre, blockquote, img, '
    + 'table, figure, hr';
  var blocks = [];

  function absolute(raw) {
    if (!raw) return null;
    try { return new URL(String(raw).trim(), BASE).href; } catch (e) { return null; }
  }

  // The address of a picture, through the four ways a publisher writes one. The
  // last candidate of a srcset is the largest, which is the one worth storing:
  // this is read once and kept, so picking the phone-sized variant would freeze
  // the article at the resolution of the device that first fetched it.
  function imageSource(el) {
    var set = el.getAttribute('srcset');
    if (set) {
      var parts = set.split(',');
      var last = parts[parts.length - 1].trim().split(/\s+/)[0];
      if (last) return absolute(last);
    }
    return absolute(
      el.getAttribute('src') || el.getAttribute('data-src')
        || el.getAttribute('data-original') || el.getAttribute('data-lazy-src')
    );
  }

  function push(block) {
    if (block) blocks.push(block);
  }

  // Runs, split wherever a link or an emphasis starts or stops. `inherited`
  // carries what an ancestor already established — a `<strong>` inside an `<a>`
  // is both — because the flags belong to the text, not to the element.
  function runs(node, inherited, out) {
    for (var i = 0; i < node.childNodes.length; i++) {
      var child = node.childNodes[i];
      if (child.nodeType === 3) {
        var text = String(child.nodeValue || '').replace(/\s+/g, ' ');
        if (!text) continue;
        out.push({
          text: text, href: inherited.href, bold: inherited.bold,
          italic: inherited.italic, code: inherited.code
        });
        continue;
      }
      if (child.nodeType !== 1) continue;
      var tag = child.tagName.toLowerCase();
      if (SKIP[tag]) continue;
      if (tag === 'br') {
        // A line separator, not a newline: this stays inside one block, which
        // is what a `<br>` means, and it survives the flattening to plain text
        // without turning one paragraph into two.
        out.push({ text: '\u2028' });
        continue;
      }
      runs(child, styled(child, inherited), out);
    }
    return out;
  }

  function styled(el, inherited) {
    var tag = el.tagName.toLowerCase();
    return {
      href: tag === 'a' ? (absolute(el.getAttribute('href')) || inherited.href) : inherited.href,
      bold: inherited.bold || tag === 'strong' || tag === 'b',
      italic: inherited.italic || tag === 'em' || tag === 'i',
      code: inherited.code || tag === 'code' || tag === 'kbd' || tag === 'samp'
    };
  }

  // Starting from the node's own style, not a blank one: a bare `<a>` sitting
  // in a container is emitted as a paragraph of its own, and walking only its
  // children dropped its link (少數派's closing 「查看全文」 came out as text).
  function trimmedRuns(node) {
    var out = runs(node, styled(node, { href: null, bold: false, italic: false, code: false }), []);
    // Leading and trailing whitespace belongs to the markup's indentation, not
    // to the sentence.
    while (out.length && !out[0].text.trim()) out.shift();
    while (out.length && !out[out.length - 1].text.trim()) out.pop();
    if (out.length) {
      out[0].text = out[0].text.replace(/^\s+/, '');
      out[out.length - 1].text = out[out.length - 1].text.replace(/\s+$/, '');
    }
    return out.filter(function (r) { return r.text.length > 0; });
  }

  function textOf(node) {
    return trimmedRuns(node).map(function (r) { return r.text; }).join('');
  }

  // Both elements' classes, because the two conventions disagree about which one
  // carries it: `<pre class="highlight-swift">` and
  // `<pre><code class="language-swift">` are the same document to a reader.
  function language(el) {
    var inner = el.querySelector('code');
    var names = (el.className || '') + ' ' + ((inner && inner.className) || '');
    var match = /(?:language|lang|highlight)-([a-z0-9+#-]+)/i.exec(names);
    return match ? match[1] : null;
  }

  function imageBlock(el) {
    var source = imageSource(el);
    // A data URI is already in the document and needs no fetching; it is also
    // routinely a tracking pixel or an icon, and storing one as an article's
    // picture would put a 1-pixel image in the middle of the prose.
    if (!source || source.indexOf('data:') === 0) return null;
    var w = parseInt(el.getAttribute('width') || '0', 10);
    var h = parseInt(el.getAttribute('height') || '0', 10);
    if ((w && w < 8) || (h && h < 8)) return null;
    return {
      kind: 'image',
      runs: [],
      image: { source: source, alt: clean(el.getAttribute('alt')) || null }
    };
  }

  // A table has no honest shape on a phone: columns that fit a page do not fit a
  // measure a third as wide, and a laid-out column has no sideways to scroll. The
  // rows are kept as a listing so the *data* survives, and the reader who needs
  // the table itself has "open original" one tap away.
  function tableBlock(el) {
    var rows = Array.prototype.slice.call(el.querySelectorAll('tr'));
    var lines = rows.map(function (row) {
      return Array.prototype.slice.call(row.querySelectorAll('th, td'))
        .map(function (cell) { return clean(cell.textContent); })
        .join(' | ');
    }).filter(function (line) { return line.replace(/[\s|]/g, '').length > 0; });
    if (!lines.length) return null;
    return { kind: 'code', runs: [{ text: lines.join('\n') }] };
  }

  function listBlocks(el, depth) {
    var ordered = el.tagName.toLowerCase() === 'ol';
    var number = parseInt(el.getAttribute('start') || '1', 10) || 1;
    for (var i = 0; i < el.children.length; i++) {
      var item = el.children[i];
      if (item.tagName.toLowerCase() !== 'li') continue;
      // A nested list is emitted after its own item, one level deeper, so the
      // reader sees the tree as indentation rather than as one run-on line.
      var nested = Array.prototype.slice.call(item.children).filter(function (child) {
        var tag = child.tagName.toLowerCase();
        return tag === 'ul' || tag === 'ol';
      });
      nested.forEach(function (list) { list.remove(); });
      var content = trimmedRuns(item);
      if (content.length) {
        push({
          kind: 'listItem', runs: content, level: depth,
          marker: ordered ? (number + '.') : '\u2022'
        });
      }
      number += 1;
      nested.forEach(function (list) { listBlocks(list, depth + 1); });
    }
  }

  function walk(node, depth) {
    for (var i = 0; i < node.childNodes.length; i++) {
      var child = node.childNodes[i];
      if (child.nodeType === 3) {
        // Text sitting directly inside a container, which is how a great many
        // hand-written posts are written. It is a paragraph.
        var loose = clean(child.nodeValue);
        if (loose) push({ kind: 'paragraph', runs: [{ text: loose }] });
        continue;
      }
      if (child.nodeType !== 1) continue;
      var tag = child.tagName.toLowerCase();
      if (SKIP[tag]) continue;
      if (tag === 'img') { push(imageBlock(child)); continue; }
      if (tag === 'hr') { push({ kind: 'rule', runs: [] }); continue; }
      if (tag === 'pre') {
        var listing = child.textContent || '';
        if (listing.trim()) {
          push({ kind: 'code', runs: [{ text: listing.replace(/\s+$/, '') }],
                 language: language(child) });
        }
        continue;
      }
      if (tag === 'table') { push(tableBlock(child)); continue; }
      if (tag === 'ul' || tag === 'ol') { listBlocks(child, 1); continue; }
      if (tag === 'blockquote') {
        var quoted = trimmedRuns(child);
        if (quoted.length) push({ kind: 'quote', runs: quoted });
        continue;
      }
      if (/^h[1-6]$/.test(tag)) {
        var heading = trimmedRuns(child);
        if (heading.length) {
          push({ kind: 'heading', runs: heading, level: parseInt(tag.charAt(1), 10) });
        }
        continue;
      }
      if (tag === 'p') {
        var paragraph = trimmedRuns(child);
        // A paragraph whose only content is a picture — the shape every
        // WordPress image lands in — is the picture, not an empty line.
        var pictures = Array.prototype.slice.call(child.querySelectorAll('img'));
        if (!paragraph.length && pictures.length) {
          pictures.forEach(function (el) { push(imageBlock(el)); });
          continue;
        }
        if (paragraph.length) push({ kind: 'paragraph', runs: paragraph });
        // Pictures inside a paragraph that also has text are emitted after it:
        // a laid-out column has no float, so the alternative is losing them.
        if (paragraph.length && pictures.length) {
          pictures.forEach(function (el) { push(imageBlock(el)); });
        }
        continue;
      }
      // Anything else — div, section, figure, article — is a container if it has
      // block children and a paragraph if it does not. Recursing without that
      // test emits one block per nesting level of a deeply wrapped post; testing
      // without recursing flattens a whole article into one line.
      if (depth < 12 && child.querySelector(BLOCKISH)) {
        walk(child, depth + 1);
        continue;
      }
      var inline = trimmedRuns(child);
      if (inline.length) push({ kind: 'paragraph', runs: inline });
    }
  }

  // A page's menus are not always in `<nav>` (少數派's sit in a `<header>`), so a
  // whole page is read from its one `<article>`; several are a listing, and none
  // leaves the body. A feed's own body is never narrowed: an `<article>` in it is
  // an embed, and taking it would drop the rest of the piece.
  var articles = WHOLE_PAGE ? document.querySelectorAll('article') : [];
  walk(articles.length === 1 ? articles[0] : document.body, 0);

  // Publishers repeat the headline as the first line of the body constantly. Drop
  // that echo, but only at the very top and only where it is barely longer than
  // the title, so a piece that opens by quoting its own title survives.
  if (TITLE) {
    for (var k = 0; k < Math.min(2, blocks.length); k++) {
      var text = (blocks[k].runs || []).map(function (r) { return r.text; }).join('');
      if (text && text.indexOf(TITLE) !== -1 && text.length <= TITLE.length + 20) {
        blocks.splice(k, 1);
        break;
      }
    }
  }
  return { blocks: blocks };
})()
