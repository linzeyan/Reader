(function () {
  var c = __CFG__;
  var el = document.querySelector(c[0]);
  if (!el) return false;
  el.focus();
  el.value = c[1];
  el.dispatchEvent(new Event('input', { bubbles: true }));
  el.dispatchEvent(new Event('change', { bubbles: true }));
  // The button nearest a search box is often the one that empties it — 85novel's
  // × is the box's own sibling — and clicking that submits nothing. Passed over,
  // so the search button further out gets the click, or Enter goes if there is none.
  function clears(b) {
    var label = (b.textContent || b.value || '').trim();
    var hint = [label, b.getAttribute('aria-label'), b.getAttribute('title'),
                b.getAttribute('class'), b.getAttribute('type')].join(' ');
    return /^[×✕✖xX]$/.test(label)
      || /clear|close|reset|cancel|清除|清空|取消|關閉|关闭/i.test(hint);
  }
  var scope = el.parentElement, button = null;
  for (var depth = 0; depth < 3 && scope && !button; depth++) {
    // `input[type=image]` is in here because it is what an ASP.NET page
    // uses for a search button, and those pages ignore a synthesised
    // Enter entirely — without the click there is nothing to submit.
    button = Array.prototype.slice.call(scope.querySelectorAll(
      'button, input[type=submit], input[type=image], .search-btn, .btn-search, [role=button]'
    )).filter(function (b) { return !clears(b); })[0] || null;
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
