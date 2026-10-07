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
  const send = value => { if (target) parent.postMessage({ gradstep: 'reader', value }, target); };
  window.webkit = Object.freeze({ messageHandlers: Object.freeze({ reader: Object.freeze({ postMessage: send }) }) });
  if (config?.font_size) document.documentElement.style.fontSize = config.font_size + 'px';
  const commands = {
    jump: (id, reduced) => window.__scienceReaderJumpToHeading?.(String(id), !!reduced),
    restore: location => window.__scienceReaderRestore?.(location),
    citationBack: () => window.__scienceReaderCitationBack?.(),
    clearSelection: () => window.__scienceReaderClearSelection?.(),
    fontSize: size => { document.documentElement.style.fontSize = Number(size) + 'px'; window.__scienceReaderFit?.(); return true; },
  };
  addEventListener('message', event => {
    const message = event.data;
    if (event.source !== parent || event.origin !== target || !message || message.gradstep !== 'command') return;
    const command = Object.hasOwn(commands, message.name) ? commands[message.name] : null;
    if (command) (window.__scienceReaderReady || Promise.resolve()).then(() => command(...(Array.isArray(message.args) ? message.args : []))).catch(() => {});
  });
})();
