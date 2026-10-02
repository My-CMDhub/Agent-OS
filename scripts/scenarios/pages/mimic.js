// Shared by every scenario mimic page. The page's own state goes into
// document.title as "key=value" words, which the runner reads back through the
// window's AX title — a witness that never asks J.A.R.V.I.S. what it did.
// "n=<nonce>" (from ?n=) is how the runner finds the window it opened.
(function () {
  const params = new URLSearchParams(location.search);
  const name = document.title;
  const state = { n: params.get('n') || '-', clicks: 0 };
  function render() {
    document.title = name + ' · ' + Object.keys(state).map(k => k + '=' + state[k]).join(' ');
  }
  window.mimic = { params, set(k, v) { state[k] = v; render(); }, get: k => state[k] };
  // Every click anywhere, by anyone: a scenario that must not click reads this.
  document.addEventListener('click', () => { state.clicks++; render(); }, true);
  render();
})();
