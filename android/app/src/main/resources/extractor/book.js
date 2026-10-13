(function () {
  __HELPERS__
  var f = __FIELDS__;
  var out = {};
  for (var k in f) { out[k] = readField(f[k]); }
  return out;
})()
