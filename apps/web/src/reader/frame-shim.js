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
  const send = value => { if (target) parent.postMessage({ gradstep: 'reader', value }, target); };
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
