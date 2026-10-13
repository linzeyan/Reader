(function () {
  var c = __CFG__;
  var form = document.createElement('form');
  form.method = c.method;
  form.action = c.url;
  var input = document.createElement('input');
  input.type = 'hidden';
  input.name = c.field;
  input.value = c.query;
  form.appendChild(input);
  document.body.appendChild(form);
  form.submit();
  return true;
})()
