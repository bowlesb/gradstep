// The equation view's frame script (equation-frame.ts): the chosen size, fitted to the width unless scrolling
// sideways, and the height reported to the panel. In a tiles document (#eq-tiles) it scales each equation down to its
// tile and posts the id of the tile chosen. Allowed by its hash in the app's CSP (vite.config.ts).
(() => {
  'use strict';
  const root = document.documentElement;
  let config = {};
  try { config = JSON.parse(document.getElementById('eq-config').textContent); } catch { config = {}; }
  const tiles = document.getElementById('eq-tiles');
  if (tiles) {
    root.style.fontSize = Math.min(112, Math.max(10, config.size || 18)) + 'px';
    let width = -1;
    // Every equation at its natural size, then each scaled to fit its tile: reads, then writes, so one layout.
    const fit = () => {
      const held = [...tiles.querySelectorAll('.eq-tile-math > span')];
      for (const h of held) h.style.zoom = '';
      const sizes = held.map(h => { const r = h.getBoundingClientRect(), box = h.parentElement; return [r.width, r.height, box.clientWidth, box.clientHeight]; });
      held.forEach((h, i) => {
        const [w, ht, roomW, roomH] = sizes[i];
        // 8 px of the tile on each side beyond its padding (owner, 2026-10-21: a margin around every equation shown).
        const zoom = Math.min(1, w > 0 ? (roomW - 16) / w : 1, ht > 0 ? (roomH - 2) / ht : 1);
        if (zoom < 1) h.style.zoom = String(Math.max(0.05, zoom));
      });
    };
    tiles.addEventListener('click', e => {
      const tile = e.target instanceof Element ? e.target.closest('[data-tile]') : null;
      if (tile) parent.postMessage({ gradstep: 'equation-tile', id: tile.getAttribute('data-tile') }, config.origin || '*');
    });
    new ResizeObserver(() => { if (tiles.clientWidth !== width) { width = tiles.clientWidth; fit(); } }).observe(tiles);
    return;
  }
  const box = document.getElementById('eq-box'), eq = document.getElementById('eq');
  let size = config.size || 28, scale = config.scale || 1, width = -1;
  const report = () => parent.postMessage({ gradstep: 'equation', height: Math.ceil(box.getBoundingClientRect().height) }, config.origin || '*');
  const apply = () => {
    root.style.fontSize = size + 'px';
    eq.style.zoom = '';
    box.classList.add('scroll');
    const style = getComputedStyle(box), room = box.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
    const natural = eq.getBoundingClientRect().width;
    let fit = Math.max(0.05, Math.min(1, room > 0 && natural > 0 ? (room - 2) / natural : 1));
    for (let i=0;i<2;i++) { eq.style.zoom=String(fit); const actual=eq.getBoundingClientRect().width; if(actual>room-2 && actual>0)fit*=Math.max(1,room-2)/actual; }
    eq.style.zoom = String(fit * scale);
    if (scale <= 1) box.scrollLeft = 0;
    report();
  };
  window.addEventListener('message', e => {
    if (e.source !== parent || e.data?.gradstep !== 'equation-command') return;
    if (Number.isFinite(e.data.size)) size = Math.min(112, Math.max(10, e.data.size));
    if (Number.isFinite(e.data.scale)) scale = Math.max(1, Math.min(4, e.data.scale));
    apply();
  });
  new ResizeObserver(() => { if (box.clientWidth !== width) { width = box.clientWidth; apply(); } }).observe(box);
  apply();
})();
