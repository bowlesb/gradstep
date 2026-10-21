// Web shim for the app-owned reader bridge. The build concatenates this file with
// apps/apple/ScienceReader/Resources/reader-bridge.js (unchanged) into the reader
// frame's only permitted script (CSP hash). It stands in for WebKit's script message
// handler and for the native calls into the bridge's own window functions.
(() => {
  'use strict';
  const data = document.querySelector('script[type="application/json"][data-gradstep-config]');
  let config = null;
  try { config = data ? JSON.parse(data.textContent) : null; } catch { config = null; }
  data?.remove();
  const target = config?.parent_origin;
  window.__readerBundleConfig = config?.bundle ?? null;
  window.__readerPaperLine = config?.paper_line ?? null;
  window.__readerAuthors = config?.paper_authors ?? [];
  window.__readerPaperTags = config?.paper_tags ?? null;
  window.__readerLineWidth = config?.line_width ?? null;
  const send = (value, transfer) => { if (target) parent.postMessage({ gradstep: 'reader', value }, target, transfer || []); };
  window.webkit = Object.freeze({ messageHandlers: Object.freeze({ reader: Object.freeze({ postMessage: send }) }) });
  if (config?.font_size) document.documentElement.style.fontSize = config.font_size + 'px';
  const commands = {
    jump: (id, reduced) => window.__scienceReaderJumpToHeading?.(String(id), !!reduced),
    restore: location => window.__scienceReaderRestore?.(location),
    citationBack: () => window.__scienceReaderCitationBack?.(),
    // The X beside Back: the offer goes away without going back (PaperView's citationDismissButton).
    endCitation: () => window.__scienceReaderEndCitation?.(),
    clearSelection: () => window.__scienceReaderClearSelection?.(),
    paperLine: text => window.__scienceReaderSetPaperLine?.(text),
    paperTags: tags => window.__scienceReaderSetPaperTags?.(tags),
    fontSize: size => { document.documentElement.style.fontSize = Number(size) + 'px'; window.__scienceReaderFit?.(); return true; },
    lineWidth: mode => window.__scienceReaderSetLineWidth?.(String(mode)),
    // The third argument is used only after a verified `figureref` message from a supporting bridge.
    showFigure: (id, reduced, fromReference) => window.__scienceReaderShowFigure?.(String(id), !!reduced, fromReference === true),
    // Contents › Equations: the equation centred and highlighted, with Back (an older bridge without it does nothing).
    showEquation: (id, reduced) => window.__scienceReaderShowEquation?.(String(id), !!reduced),
    find: (query, direction) => send(window.__scienceReaderFind?.(String(query ?? ''), direction)),
    findClear: () => window.__scienceReaderFindClear?.(),
    theme: value => setScheme(value),
    goToPassage: anchor => send({ type: 'passage', found: !!window.__scienceReaderGoToPassage?.(anchor)?.found }),
    setMarks: list => window.__scienceReaderSetMarks?.(list),
    // Notes: a region of the visible paper, or one element (a figure, table or equation), as a PNG made in this frame.
    capture: (nonce, rect) => capture(nonce, rect),
    captureProbe: nonce => probe(nonce),
  };

  // ---------- Notes and snippets: local, network-free region capture (NOTES_AND_SNIPPETS.md) ----------
  // The document is cloned with its stylesheets (media conditions resolved as they apply now, so the chosen appearance
  // and width hold), placed in an SVG foreignObject at the paper's own width and drawn to a canvas here, inside the
  // sandboxed frame. Images are the bundle's own data URIs; nothing is fetched and the CSP is unchanged. The parent
  // checks the reply (nonce, sizes, block IDs) before using it.
  const BLANK = 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';
  const MAX_EDGE = 4096, MAX_PIXELS = 6000000;
  function styles() {
    const out = [];
    const visit = rules => {
      for (const rule of rules) {
        if (rule instanceof CSSMediaRule) { if (matchMedia(rule.media.mediaText).matches) visit(rule.cssRules); continue; }
        if (typeof CSSSupportsRule !== 'undefined' && rule instanceof CSSSupportsRule) { if (CSS.supports(rule.conditionText)) visit(rule.cssRules); continue; }
        if (rule instanceof CSSImportRule || rule instanceof CSSFontFaceRule) continue;
        let text = rule.cssText;
        // In the image the document root is the <svg>: keep `:root` rules on the cloned <html>, at the same specificity.
        if (rule instanceof CSSStyleRule) { const brace = text.indexOf('{'); text = text.slice(0, brace).replace(/:root\b/g, ':where(html):not(.sr-none)') + text.slice(brace); }
        out.push(text);
      }
    };
    for (const sheet of document.styleSheets) { try { visit(sheet.cssRules); } catch { /* unreadable sheet */ } }
    return out.join('\n');
  }
  // A copy of the document with only the images near the region kept (others become same-sized blanks).
  function copyFor(region) {
    const root = document.documentElement, live = [root, ...root.querySelectorAll('*')];
    const copy = root.cloneNode(true), copies = [copy, ...copy.querySelectorAll('*')];
    if (copies.length !== live.length) throw new Error('clone');
    const near = r => r.bottom >= region.y - 400 && r.top <= region.y + region.height + 400;
    const pictures = [];
    for (let i = 0; i < live.length; i++) {
      const element = live[i], twin = copies[i], tag = element.localName;
      if (tag === 'script' || tag === 'style' || tag === 'link' || tag === 'meta' || tag === 'noscript' || tag === 'template') { twin.remove(); continue; }
      if (tag === 'img') {
        const r = element.getBoundingClientRect();
        if (!near(r)) { twin.setAttribute('src', BLANK); twin.style.width = r.width + 'px'; twin.style.height = r.height + 'px'; }
        else if (r.bottom > region.y && r.top < region.y + region.height && r.right > region.x && r.left < region.x + region.width && element.complete && element.naturalWidth) pictures.push(element);
      }
      // A scrolled box (a wide equation or table): its content keeps the position the reader sees.
      if ((element.scrollLeft || element.scrollTop) && element !== root && element !== document.body) {
        twin.style.overflow = 'hidden';
        for (const child of twin.children) child.style.translate = `${-element.scrollLeft}px ${-element.scrollTop}px`;
      }
    }
    return { copy, pictures };
  }
  function base64(text) {
    const bytes = new TextEncoder().encode(text);
    let binary = '';
    for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    return btoa(binary);
  }
  const loaded = image => image.decode ? image.decode() : new Promise((resolve, reject) => { image.onload = resolve; image.onerror = reject; });
  // The paper's own pictures, drawn again from the frame's decoded images over the rendered document: WebKit paints
  // pictures inside an SVG image only after its first paint, and this keeps their exact pixels in every engine.
  function paintPictures(context, pictures, region, scale) {
    for (const picture of pictures) {
      const style = getComputedStyle(picture);
      if (style.visibility === 'hidden' || Number(style.opacity) < 1 || style.display === 'none') continue;
      const r = picture.getBoundingClientRect(), px = name => parseFloat(style[name]) || 0;
      const x = r.left + px('borderLeftWidth') + px('paddingLeft'), y = r.top + px('borderTopWidth') + px('paddingTop');
      const width = r.width - px('borderLeftWidth') - px('borderRightWidth') - px('paddingLeft') - px('paddingRight');
      const height = r.height - px('borderTopWidth') - px('borderBottomWidth') - px('paddingTop') - px('paddingBottom');
      if (!(width > 0 && height > 0)) continue;
      const box = [(x - region.x) * scale, (y - region.y) * scale, width * scale, height * scale];
      context.save();
      context.beginPath();
      const radius = ['borderTopLeftRadius', 'borderTopRightRadius', 'borderBottomRightRadius', 'borderBottomLeftRadius'].map(name => px(name) * scale);
      if (context.roundRect && radius.some(Boolean)) context.roundRect(...box, radius); else context.rect(...box);
      context.clip();
      if (opaque(style.backgroundColor)) { context.fillStyle = style.backgroundColor; context.fillRect(...box); }
      context.imageSmoothingQuality = 'high';
      context.drawImage(picture, ...box);
      context.restore();
    }
  }
  async function draw(svg, crop, scale, background, paint) {
    const image = new Image();
    image.src = 'data:image/svg+xml;base64,' + base64(svg);
    await loaded(image);
    const canvas = document.createElement('canvas');
    canvas.width = Math.max(1, Math.round(crop.width * scale)); canvas.height = Math.max(1, Math.round(crop.height * scale));
    const context = canvas.getContext('2d');
    context.fillStyle = background; context.fillRect(0, 0, canvas.width, canvas.height);
    context.drawImage(image, crop.x, crop.y, crop.width, crop.height, 0, 0, canvas.width, canvas.height);
    paint?.(context);
    // Reading back fails here (SecurityError) if this engine treats the drawing as cross-origin.
    const center = context.getImageData(Math.floor(canvas.width / 2), Math.floor(canvas.height / 2), 1, 1).data;
    const blob = await new Promise(resolve => canvas.toBlob(resolve, 'image/png'));
    if (!blob) throw new Error('encode');
    return { png: await blob.arrayBuffer(), width: canvas.width, height: canvas.height, probe: `${center[0]},${center[1]},${center[2]}` };
  }
  const opaque = color => { const c = color.match(/rgba?\(([^)]+)\)/); return !c || c[1].split(',').length < 4 || Number(c[1].split(',')[3]) > 0; };
  // The paper's background as the reader sees it (the root's, else the body's, else the scheme's default).
  function background() {
    for (const element of [document.documentElement, document.body]) { const color = getComputedStyle(element).backgroundColor; if (color && opaque(color)) return color; }
    return getComputedStyle(document.documentElement).colorScheme.includes('dark') ? '#000' : '#fff';
  }
  // `rect` is in this frame's viewport (CSS px): a box drawn over the paper. `{ element }` names a figure, table or
  // equation, captured whole wherever it is, with a small margin.
  async function capture(nonce, rect) {
    if (typeof nonce !== 'string' || !/^[0-9a-f-]{36}$/.test(nonce)) return;
    try {
      let region;
      if (rect && typeof rect.element === 'string') {
        const element = document.getElementById(rect.element);
        if (!element) throw new Error('missing');
        const r = element.getBoundingClientRect(), pad = 8;
        region = { x: Math.max(0, r.left - pad), y: r.top - pad, width: Math.min(innerWidth, r.right + pad) - Math.max(0, r.left - pad), height: r.height + 2 * pad };
      } else {
        const values = rect && [rect.x, rect.y, rect.width, rect.height];
        if (!values || !values.every(Number.isFinite) || rect.width < 8 || rect.height < 8) throw new Error('rect');
        region = { x: Math.max(0, rect.x), y: Math.max(0, rect.y), width: Math.min(innerWidth, rect.x + rect.width) - Math.max(0, rect.x), height: Math.min(innerHeight, rect.y + rect.height) - Math.max(0, rect.y) };
      }
      // Whole CSS pixels, so the image lines up with the screen's own pixel grid.
      const left = Math.floor(region.x), upper = Math.floor(region.y);
      region = { x: left, y: upper, width: Math.ceil(region.x + region.width) - left, height: Math.ceil(region.y + region.height) - upper };
      if (!(region.width >= 8 && region.height >= 8)) throw new Error('rect');
      const root = document.documentElement, width = root.clientWidth, height = Math.max(root.scrollHeight, document.body.scrollHeight, innerHeight);
      // The image is the frame's viewport (so vw/vh match), shifted to show the region when it lies outside it.
      const top = region.y >= 0 && region.y + region.height <= innerHeight ? 0 : region.y, viewHeight = Math.max(innerHeight, Math.ceil(region.height));
      const ratio = devicePixelRatio || 1, scale = Math.min(ratio, MAX_EDGE / Math.max(region.width, region.height), Math.sqrt(MAX_PIXELS / (region.width * region.height)));
      const { copy, pictures } = copyFor(region), style = document.createElement('style');
      style.textContent = styles();
      (copy.querySelector('head') || copy).append(style);
      const markup = new XMLSerializer().serializeToString(copy);
      const rootFont = getComputedStyle(root).fontSize;
      const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${innerWidth}" height="${viewHeight}" viewBox="0 0 ${innerWidth} ${viewHeight}" style="font-size:${rootFont}">`
        + `<foreignObject x="${-scrollX}" y="${-(scrollY + top)}" width="${width}" height="${height}">${markup}</foreignObject></svg>`;
      const result = await draw(svg, { x: region.x, y: region.y - top, width: region.width, height: region.height }, scale, background(), context => paintPictures(context, pictures, region, scale));
      // The paper's blocks the region covers (at most 64), for reopening it later.
      const blocks = [];
      for (const block of document.querySelectorAll('[data-reader-block]')) {
        const r = block.getBoundingClientRect();
        if (r.bottom > region.y && r.top < region.y + region.height && r.right > region.x && r.left < region.x + region.width && /^[0-9A-Za-z_-]{1,200}$/.test(block.id)) blocks.push(block.id);
        if (blocks.length === 64) break;
      }
      send({ type: 'capture', nonce, ok: true, png: result.png, width: result.width, height: result.height, blocks,
        box: [region.x, region.y, region.width, region.height], viewport: [innerWidth, innerHeight, ratio],
        manifest_sha256: window.__readerBundleConfig?.manifest_sha256 ?? null }, [result.png]);
    } catch (error) {
      send({ type: 'capture', nonce, ok: false, reason: error && error.name === 'SecurityError' ? 'tainted' : error && /^(rect|missing)$/.test(error.message) ? error.message : 'failed' });
    }
  }
  // Whether this engine can draw such an image and read it back (a canvas that isn't tainted).
  async function probe(nonce) {
    if (typeof nonce !== 'string' || !/^[0-9a-f-]{36}$/.test(nonce)) return;
    let ok = false;
    try {
      const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"><foreignObject width="20" height="20"><div xmlns="http://www.w3.org/1999/xhtml" style="width:20px;height:20px;background:#123456"></div></foreignObject></svg>';
      const result = await draw(svg, { x: 0, y: 0, width: 20, height: 20 }, 1, '#fff');
      ok = result.png.byteLength > 0 && result.probe === '18,52,86';
    } catch { ok = false; }
    send({ type: 'captureProbe', nonce, ok });
  }

  // The app's appearance, whatever the system's: the frame can't inherit the parent's choice, so the documents' own
  // prefers-color-scheme conditions (bundle and bridge styles) are rewritten in place, and restored for the system's.
  let scheme = null;
  const originals = new WeakMap(), SCHEME = /\(\s*prefers-color-scheme\s*:\s*(dark|light)\s*\)/gi;
  function applyScheme() {
    document.documentElement.style.colorScheme = scheme ?? '';
    const visit = rules => {
      for (const rule of rules) {
        if (rule.media) {
          if (!originals.has(rule)) originals.set(rule, rule.media.mediaText);
          const original = originals.get(rule);
          if (/prefers-color-scheme/i.test(original)) {
            rule.media.mediaText = scheme ? original.replace(SCHEME, (_, value) => value.toLowerCase() === scheme ? '(min-width: 0px)' : '(max-width: 0.01px)') : original;
          }
        }
        if (rule.cssRules) visit(rule.cssRules);
      }
    };
    for (const sheet of document.styleSheets) { try { visit(sheet.cssRules); } catch { /* unreadable sheet */ } }
  }
  function setScheme(value) { scheme = value === 'dark' || value === 'light' ? value : null; applyScheme(); return true; }
  setScheme(config?.theme);
  new MutationObserver(records => { if (records.some(r => [...r.addedNodes].some(n => n.nodeName === 'STYLE'))) applyScheme(); })
    .observe(document.documentElement, { childList: true, subtree: true });

  // App shortcuts typed while the paper has focus: find, search, panes, help, reading mode, sections and Escape.
  addEventListener('keydown', event => {
    const target = event.target;
    const typing = target && (target.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName));
    const command = (event.metaKey || event.ctrlKey) && !event.altKey;
    let key = null;
    if (command && event.key.toLowerCase() === 'f') key = 'find';
    else if (command && event.key.toLowerCase() === 'k') key = 'search';
    else if (event.key === 'Escape') key = 'escape';
    // F reading mode, J / K the next and previous section (READING_MODE.md).
    else if (!typing && !event.metaKey && !event.ctrlKey && !event.altKey) key = { '/': 'search', '[': 'left', ']': 'right', '?': 'help', f: 'reading', j: 'next', k: 'previous' }[event.key] ?? null;
    if (!key) return;
    if (key !== 'escape') event.preventDefault();
    send({ type: 'key', key });
  }, true);
  // A link out of the paper (a dataset, code, a cited page): the frame never navigates away from the paper (the page's
  // CSP would refuse it and the reading place would be lost). The app opens it in a new tab, as the apps hand it to
  // Safari (PaperView's decidePolicyFor). Runs after the bridge's own handlers, which keep in-page links and citations.
  addEventListener('click', event => {
    const element = event.target instanceof Element ? event.target : event.target?.parentElement;
    const anchor = element?.closest('a[href]');
    if (!anchor || event.defaultPrevented) return;
    const raw = anchor.getAttribute('href') ?? '';
    if (raw.startsWith('#')) return;
    event.preventDefault();
    let url = null;
    try { url = new URL(raw); } catch { url = null; }
    // A drag that selected text over the link is a selection, not a click on it.
    if (url && (url.protocol === 'https:' || url.protocol === 'http:') && window.getSelection()?.isCollapsed !== false) send({ type: 'link', url: url.href });
  });
  addEventListener('message', event => {
    const message = event.data;
    if (event.source !== parent || event.origin !== target || !message || message.gradstep !== 'command') return;
    const command = Object.hasOwn(commands, message.name) ? commands[message.name] : null;
    if (command) (window.__scienceReaderReady || Promise.resolve()).then(() => command(...(Array.isArray(message.args) ? message.args : []))).catch(() => {});
  });
})();
