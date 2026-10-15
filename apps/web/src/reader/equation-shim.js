// The equation view's frame script (equation-frame.ts): the chosen size, fitted to the width unless scrolling
// sideways, and the height reported to the panel. Allowed by its hash in the app's CSP (vite.config.ts).
(() => {
  'use strict';
  const root = document.documentElement, box = document.getElementById('eq-box'), eq = document.getElementById('eq');
  let config = {};
  try { config = JSON.parse(document.getElementById('eq-config').textContent); } catch { config = {}; }
  let size = config.size || 28, scroll = !!config.scroll, width = -1;
  const report = () => parent.postMessage({ gradstep: 'equation', height: Math.ceil(box.getBoundingClientRect().height) }, config.origin || '*');
  const apply = () => {
    root.style.fontSize = size + 'px';
    eq.style.zoom = '';
    box.classList.toggle('scroll', scroll);
    if (!scroll) {
      const style = getComputedStyle(box), room = box.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
      // Text does not shrink exactly in proportion (hinting, rounding): measure again once and correct.
      let zoom = 1;
      for (let pass = 0; pass < 2; pass++) {
        const wide = eq.getBoundingClientRect().width;
        if (!(wide > room && wide > 0 && room > 0)) break;
        zoom = Math.max(0.05, zoom * (room - 1) / wide);
        eq.style.zoom = String(zoom);
      }
    }
    report();
  };
  window.addEventListener('message', e => {
    if (e.source !== parent || e.data?.gradstep !== 'equation-command') return;
    if (Number.isFinite(e.data.size)) size = Math.min(112, Math.max(10, e.data.size));
    scroll = !!e.data.scroll;
    apply();
  });
  new ResizeObserver(() => { if (box.clientWidth !== width) { width = box.clientWidth; apply(); } }).observe(box);
  apply();
})();
