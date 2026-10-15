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
  window.__readerPaperTags = config?.paper_tags ?? null;
  window.__readerLineWidth = config?.line_width ?? null;
  const send = value => { if (target) parent.postMessage({ gradstep: 'reader', value }, target); };
  window.webkit = Object.freeze({ messageHandlers: Object.freeze({ reader: Object.freeze({ postMessage: send }) }) });
  if (config?.font_size) document.documentElement.style.fontSize = config.font_size + 'px';
  const commands = {
    jump: (id, reduced) => window.__scienceReaderJumpToHeading?.(String(id), !!reduced),
    restore: location => window.__scienceReaderRestore?.(location),
    citationBack: () => window.__scienceReaderCitationBack?.(),
    clearSelection: () => window.__scienceReaderClearSelection?.(),
    paperLine: text => window.__scienceReaderSetPaperLine?.(text),
    paperTags: tags => window.__scienceReaderSetPaperTags?.(tags),
    fontSize: size => { document.documentElement.style.fontSize = Number(size) + 'px'; window.__scienceReaderFit?.(); return true; },
    lineWidth: mode => window.__scienceReaderSetLineWidth?.(String(mode)),
    // The third argument is used only after a verified `figureref` message from a supporting bridge.
    showFigure: (id, reduced, fromReference) => window.__scienceReaderShowFigure?.(String(id), !!reduced, fromReference === true),
    find: (query, direction) => find(String(query ?? ''), direction),
    findClear: () => clearFind(),
    theme: value => setScheme(value),
    goToPassage: anchor => send({ type: 'passage', found: !!window.__scienceReaderGoToPassage?.(anchor)?.found }),
    setMarks: list => window.__scienceReaderSetMarks?.(list),
  };

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

  // Find in the paper (app-owned, not the bridge): every match is a CSS custom highlight; the current one is
  // scrolled to the upper third. Text is matched case-insensitively across inline elements, never across blocks.
  const FIND = 'gradstep-find', CURRENT = 'gradstep-find-current', LIMIT = 1000;
  const BLOCK = 'p,li,h1,h2,h3,h4,h5,h6,figure,figcaption,table,td,th,pre,blockquote,dd,dt,div,section,math[display=block]';
  let findQuery = '', matches = [], current = -1;
  const lower = text => [...text].map(ch => { const l = ch.toLowerCase(); return l.length === ch.length ? l : ch; }).join('').replace(/\s/g, ' ');
  const highlights = () => (globalThis.CSS && CSS.highlights && typeof Highlight === 'function') ? CSS.highlights : null;
  function clearFind() {
    findQuery = ''; matches = []; current = -1;
    highlights()?.delete(FIND); highlights()?.delete(CURRENT);
  }
  function search(query) {
    const segments = [];
    let flat = '', block = null;
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, { acceptNode: node =>
      !node.data || node.parentElement?.closest('script,style,template') ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT });
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const owner = node.parentElement?.closest(BLOCK) ?? null;
      if (owner !== block) { flat += '\u0000'; block = owner; }
      segments.push({ node, start: flat.length });
      flat += lower(node.data);
    }
    const at = offset => {
      let lo = 0, hi = segments.length - 1;
      while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (segments[mid].start <= offset) lo = mid; else hi = mid - 1; }
      return { node: segments[lo].node, offset: offset - segments[lo].start };
    };
    const found = [];
    for (let index = flat.indexOf(query); index >= 0 && found.length < LIMIT; index = flat.indexOf(query, index + query.length)) {
      const start = at(index), end = at(index + query.length - 1);
      const range = document.createRange();
      range.setStart(start.node, start.offset); range.setEnd(end.node, end.offset + 1);
      found.push(range);
    }
    return found;
  }
  function find(text, direction) {
    const query = lower(text.trim().replace(/\s+/g, ' ')).slice(0, 200);
    if (!query) { clearFind(); send({ type: 'find', count: 0, index: -1 }); return; }
    if (query !== findQuery || !matches.length) {
      findQuery = query; matches = search(query);
      // Start from the reading place, like the system find bar.
      current = matches.findIndex(range => range.getBoundingClientRect().bottom > 0);
      if (current < 0) current = matches.length ? 0 : -1;
    } else if (direction === 'previous') current = (current - 1 + matches.length) % matches.length;
    else if (direction === 'next') current = (current + 1) % matches.length;
    const registry = highlights();
    if (registry) {
      registry.set(FIND, new Highlight(...matches));
      if (current >= 0) registry.set(CURRENT, new Highlight(matches[current])); else registry.delete(CURRENT);
      if (!document.getElementById(FIND)) {
        const style = document.createElement('style');
        style.id = FIND;
        style.textContent = `::highlight(${FIND}){background:rgba(250,204,21,.4)}::highlight(${CURRENT}){background:rgba(249,115,22,.7)}`;
        document.head.append(style);
      }
    }
    if (current >= 0) {
      const rect = matches[current].getBoundingClientRect();
      window.scrollTo({ top: window.scrollY + rect.top - window.innerHeight / 3, behavior: 'instant' });
    }
    send({ type: 'find', count: matches.length, index: current });
  }

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
  addEventListener('message', event => {
    const message = event.data;
    if (event.source !== parent || event.origin !== target || !message || message.gradstep !== 'command') return;
    const command = Object.hasOwn(commands, message.name) ? commands[message.name] : null;
    if (command) (window.__scienceReaderReady || Promise.resolve()).then(() => command(...(Array.isArray(message.args) ? message.args : []))).catch(() => {});
  });
})();
