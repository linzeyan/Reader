(function () {
  function absolute(url) {
    try { return new URL(url, location.href).href; } catch (e) { return null; }
  }
  // The names these sites give a search box. Ordered matters only in that a
  // named match beats the shape-based fallback below it.
  var named = /^(searchkey|keyword|keywords|key|searchword|q|s|wd|kw|word|name|title|term)$/i;
  var searchy = /search|so\.|\/s\/|query|find/i;
  var out = [];
  Array.prototype.slice.call(document.querySelectorAll('form')).forEach(function (form) {
    var action = absolute(form.getAttribute('action') || location.href);
    if (!action) return;
    var inputs = Array.prototype.slice.call(form.querySelectorAll('input')).filter(function (input) {
      var type = (input.getAttribute('type') || 'text').toLowerCase();
      return (type === 'text' || type === 'search') && input.name;
    });
    if (!inputs.length) return;
    var field = null;
    for (var i = 0; i < inputs.length && !field; i++) {
      if (named.test(inputs[i].name)) field = inputs[i].name;
    }
    // A form with a single free-text box pointed at a search-looking address
    // is a search box even when the field is named something local.
    if (!field && inputs.length === 1 && searchy.test(action)) field = inputs[0].name;
    if (!field) return;
    out.push({
      method: (form.getAttribute('method') || 'GET').toUpperCase(),
      action: action,
      field: field,
      inputSelector: null
    });
  });

  // Sites whose search is JavaScript have no form to submit — the box is a
  // bare input with a click handler. Offered after real forms, because a
  // form is the exact answer and this is an imitation of one.
  Array.prototype.slice.call(document.querySelectorAll('input[type=text], input[type=search]'))
    .forEach(function (input) {
      if (input.form) return;
      var hint = [input.name, input.id, input.getAttribute('placeholder'),
                  input.getAttribute('class')].join(' ');
      if (!/search|keyword|key|query|搜尋|搜索|書名|书名/i.test(hint)) return;
      var selector = input.id ? '#' + input.id
        : (input.name ? 'input[name="' + input.name + '"]' : null);
      // One match is ideal but not required: sites that ship a phone and a
      // desktop header have the same search box twice, and `querySelector`
      // picking the first of them still types into a real search box.
      if (!selector || !document.querySelector(selector)) return;
      out.push({
        method: 'GET',
        action: location.href,
        field: input.name || input.id || 'q',
        inputSelector: selector
      });
    });

  // A homepage with no box of its own usually links to a page that has one — wfxs's
  // is an empty <a href="/s/"> drawn as a magnifier, so the address and the class
  // say it where the text does not.
  var link = null;
  if (!out.length) {
    Array.prototype.slice.call(document.querySelectorAll('a[href]')).some(function (a) {
      if (a.origin !== location.origin
          || a.href.split('#')[0] === location.href.split('#')[0]) return false;
      var hint = [a.textContent, a.getAttribute('title'), a.getAttribute('class')].join(' ');
      if (!searchy.test(a.pathname) && !/search|搜尋|搜索/i.test(hint)) return false;
      link = a.href;
      return true;
    });
  }
  return { forms: out.slice(0, 4), searchLink: link };
})()
