"use client";

import { useCallback, useEffect, useRef, useState } from "react";

export interface HighlightInfo {
  text: string;
  chatId: string;
}

export type SelectionAction = "define" | "relevance" | "ingest" | "similar";

interface Props {
  html: string;
  onSelectionAction: (selectedText: string, action: SelectionAction) => void;
  darkMode: boolean;
  highlights?: HighlightInfo[];
  onChatHighlightClick?: (chatId: string) => void;
  mobile?: boolean;
  fontScale?: number;
  onFontScaleChange?: (scale: number) => void;
  scrollToHeadingId?: string | null;
  onScrollComplete?: () => void;
  onFigureClick?: (src: string) => void;
}

function injectStyles(html: string, darkMode: boolean, mobile?: boolean): string {
  const selectionScript = `
<script>
// Notify parent that iframe scripts are ready
window.parent.postMessage({ type: 'iframe-ready' }, '*');

document.addEventListener('mousedown', function() {
  window.parent.postMessage({ type: 'text-selection-clear' }, '*');
});

function reportSelection() {
  var sel = window.getSelection();
  var text = sel ? sel.toString().trim() : '';
  if (text.length > 2 && sel.rangeCount > 0) {
    var range = sel.getRangeAt(0);
    var rect = range.getBoundingClientRect();
    window.parent.postMessage({
      type: 'text-selection',
      text: text,
      rect: { top: rect.top, bottom: rect.bottom, left: rect.left, right: rect.right, width: rect.width }
    }, '*');
  }
}

document.addEventListener('mouseup', reportSelection);

// Suppress native context menu so only our custom action buttons show
document.addEventListener('contextmenu', function(e) {
  var sel = window.getSelection();
  var text = sel ? sel.toString().trim() : '';
  if (text.length > 2) {
    e.preventDefault();
  }
});

// Use native text selection on all platforms — selectionchange reports it to parent
var selectionTimer = null;
document.addEventListener('selectionchange', function() {
  clearTimeout(selectionTimer);
  selectionTimer = setTimeout(function() {
    var sel = window.getSelection();
    var text = sel ? sel.toString().trim() : '';
    if (text.length > 2) {
      reportSelection();
    } else {
      window.parent.postMessage({ type: 'text-selection-clear' }, '*');
    }
  }, 300);
});

// Click on figures to open in figure viewer
document.addEventListener('click', function(e) {
  var img = e.target.closest('img');
  if (img && img.src) {
    window.parent.postMessage({ type: 'figure-click', src: img.src }, '*');
  }
});

// Helper: find and wrap text in a span
function highlightText(searchText, className, style, chatId) {
  var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
  var node;
  while (node = walker.nextNode()) {
    var idx = node.textContent.indexOf(searchText);
    if (idx !== -1) {
      var range = document.createRange();
      range.setStart(node, idx);
      range.setEnd(node, Math.min(idx + searchText.length, node.textContent.length));
      var mark = document.createElement('span');
      mark.className = className;
      mark.style.cssText = style;
      if (chatId) {
        mark.setAttribute('data-chat-id', chatId);
        mark.style.cursor = 'pointer';
        mark.addEventListener('click', function(evt) {
          evt.stopPropagation();
          window.parent.postMessage({ type: 'highlight-click', chatId: chatId }, '*');
        });
      }
      range.surroundContents(mark);
      return mark;
    }
  }
  return null;
}

// Listen for messages from parent
window.addEventListener('message', function(e) {
  if (!e.data) return;

  // Scroll to specific text (temporary highlight for navigation)
  if (e.data.type === 'scroll-to-text' && e.data.text) {
    // Remove previous temporary highlights only
    document.querySelectorAll('.paper-highlight').forEach(function(el) {
      var parent = el.parentNode;
      parent.replaceChild(document.createTextNode(el.textContent), el);
      parent.normalize();
    });
    var searchText = e.data.text;
    var hlStyle = 'background: rgba(99,102,241,0.3); border-radius: 2px; padding: 1px 0;';
    var mark = highlightText(searchText, 'paper-highlight', hlStyle, null);

    // If exact match failed, try the first line/sentence (selections across
    // elements produce newlines that don't exist in individual text nodes)
    if (!mark) {
      var lines = searchText.split(/[\\n\\r]+/);
      var firstLine = lines[0] ? lines[0].trim() : '';
      if (firstLine.length > 10) {
        mark = highlightText(firstLine, 'paper-highlight', hlStyle, null);
      }
    }

    // Try progressively shorter substrings of the first line
    if (!mark) {
      var base = (searchText.split(/[\\n\\r]+/)[0] || searchText).trim();
      var tryLengths = [80, 60, 40, 25];
      for (var ti = 0; ti < tryLengths.length && !mark; ti++) {
        if (base.length > tryLengths[ti]) {
          mark = highlightText(base.substring(0, tryLengths[ti]), 'paper-highlight', hlStyle, null);
        }
      }
    }

    // Last resort: walk all text nodes, normalize whitespace, find partial match, scroll
    if (!mark) {
      var needle = searchText.replace(/\\s+/g, ' ').trim().substring(0, 40);
      var walker2 = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
      var n2;
      while (n2 = walker2.nextNode()) {
        var nodeText = (n2.textContent || '').replace(/\\s+/g, ' ');
        if (nodeText.indexOf(needle) !== -1 || (needle.length > 15 && nodeText.indexOf(needle.substring(0, 15)) !== -1)) {
          if (n2.parentElement) {
            n2.parentElement.scrollIntoView({ behavior: 'smooth', block: 'center' });
          }
          break;
        }
      }
    }

    if (mark) mark.scrollIntoView({ behavior: 'smooth', block: 'center' });
  }

  // Apply persistent highlights for all chat anchors
  if (e.data.type === 'highlight-persistent' && e.data.highlights) {
    // Remove old persistent highlights
    document.querySelectorAll('.paper-highlight-persistent').forEach(function(el) {
      var parent = el.parentNode;
      parent.replaceChild(document.createTextNode(el.textContent), el);
      parent.normalize();
    });
    e.data.highlights.forEach(function(h) {
      highlightText(
        h.text,
        'paper-highlight-persistent',
        'background: rgba(99,102,241,0.12); border-radius: 2px; padding: 1px 0; border-bottom: 2px dotted rgba(99,102,241,0.5);',
        h.chatId
      );
    });
  }

  // Adjust font scale dynamically via zoom (works in all modern browsers)
  if (e.data.type === 'set-font-scale' && typeof e.data.scale === 'number') {
    var scale = e.data.scale;
    var basePadding = window.innerWidth < 768 ? 10 : 20;
    document.body.style.zoom = String(scale);
    // Compensate padding so visual whitespace stays constant
    document.body.style.setProperty('padding', (basePadding / scale) + 'px', 'important');
  }

  // Scroll to heading by id (for TOC navigation)
  if (e.data.type === 'scroll-to-heading' && e.data.id) {
    var el = document.getElementById(e.data.id);
    if (el) {
      el.scrollIntoView({ behavior: 'smooth', block: 'start' });
      window.parent.postMessage({ type: 'scroll-to-heading-done' }, '*');
    }
  }

  // Force scroll recalculation after parent container resize
  if (e.data.type === 'refresh-scroll') {
    var prev = document.documentElement.scrollTop;
    document.documentElement.style.overflow = 'hidden';
    document.body.style.overflow = 'hidden';
    requestAnimationFrame(function() {
      document.documentElement.style.overflow = '';
      document.body.style.overflow = '';
      document.documentElement.scrollTop = prev;
    });
  }
});
</script>`;

  const darkStyles = `
<style id="dark-mode-override">
  html, body {
    background: #141414 !important;
    color: #e4e4e7 !important;
    padding: 20px !important;
    overflow-y: auto !important;
    font-size: 15px !important;
  }
  #preview { font-size: 15px !important; }
  *, *::before, *::after {
    color: #e4e4e7 !important;
    border-color: #52525b !important;
  }
  h1, h2, h3, h4, h5, h6 { color: #f4f4f5 !important; margin: 1.2em 0 0.5em !important; }
  h1 { font-size: 1.4em !important; }
  h2 { font-size: 1.25em !important; }
  h3 { font-size: 1.1em !important; }
  p, li, dd, dt { line-height: 1.6 !important; margin-bottom: 0.6em !important; }
  .math-block { display: block !important; margin: 20px 0 !important; }
  .katex-display { margin: 20px 0 !important; }
  a { color: #818cf8 !important; }
  table, table * { background-color: transparent !important; }
  table { background: #1a1a2e !important; }
  th, thead td { background: #27272a !important; color: #f4f4f5 !important; }
  pre, code { background: #1a1a2e !important; }
  blockquote { border-left-color: #6366f1 !important; }
  hr { border-color: #3f3f46 !important; }
  img { max-width: 100% !important; border-radius: 8px; }
  svg path, svg rect, svg line, svg circle, svg polygon { fill: #e4e4e7 !important; }
  svg path[fill="none"] { fill: none !important; }
  svg path[stroke="none"], svg rect[stroke="none"] { stroke: none !important; }
  svg text { fill: #e4e4e7 !important; }
  ::selection { background: #6366f1 !important; color: white !important; }
  .cite-ref { cursor:pointer; color:#818cf8; text-decoration:underline dotted rgba(129,140,248,0.5); text-underline-offset:2px; }
  .cite-ref:hover { color:#a5b4fc; }
  .ref-popup { background:#27272a; color:#e4e4e7; border:1px solid #52525b; }
  figure, .figure_img { background:#1a1a2e !important; border-radius:8px; padding:12px !important; margin:28px 0 !important; border:1px solid #27272a; }
  figure img, .figure_img img { border-radius:4px; display:block; margin:0 auto; }
  .caption_figure { margin-top:8px; font-size:0.9em; color:#a1a1aa !important; line-height:1.5; }
  .caption_table { font-size:0.85em; color:#a1a1aa !important; line-height:1.5; padding:12px 14px 8px; font-weight:500; text-transform:none !important; margin:0 !important; background:#1e1e24 !important; border-radius:8px 8px 0 0; border:1px solid #2a2a35; border-bottom:none; }
  .table_tabular { background:#1e1e24 !important; border-radius:0 0 8px 8px; padding:0 14px 12px; border:1px solid #2a2a35; border-top:none; margin:0 0 24px !important; overflow-x:auto; }
  .caption_table + .table_tabular { border-radius:0 0 8px 8px; }
  table { display:block; overflow-x:auto; margin:0 !important; }
  table.tabular { background:transparent !important; }
</style>
<script>
function applyDarkMode() {
  document.querySelectorAll('svg path:not([fill="none"])').forEach(function(el) {
    el.setAttribute('fill', '#e4e4e7');
  });
}
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', function() { setTimeout(applyDarkMode, 500); });
} else {
  setTimeout(applyDarkMode, 500);
}
new MutationObserver(applyDarkMode).observe(document.documentElement, { childList: true, subtree: true });
</script>`;

  const mobileStyles = `
<style id="mobile-responsive">
  *, *::before, *::after {
    box-sizing: border-box !important;
    -webkit-touch-callout: none !important;
  }
  html {
    padding: 0 !important;
    margin: 0 !important;
    overflow-x: hidden !important;
    width: 100% !important;
  }
  body {
    width: 100% !important;
    max-width: 100% !important;
    overflow-x: hidden !important;
    padding: 10px !important;
    margin: 0 !important;
    font-size: 17px !important;
    line-height: 1.6 !important;
    word-wrap: break-word !important;
    overflow-wrap: break-word !important;
    -webkit-touch-callout: none !important;
  }
  /* Force all containers to fill available width, preserve auto-centering */
  body *:not(td):not(th):not(table):not(thead):not(tbody):not(tr) {
    max-width: 100% !important;
    overflow-wrap: break-word !important;
    word-break: break-word !important;
    min-width: 0 !important;
  }
  /* Zero out side padding on block containers only – keep inline/table spacing */
  body > div, body > section, body > article, body > main,
  body > div > div, body > section > div {
    padding-left: 0 !important;
    padding-right: 0 !important;
  }
  /* Make wrapper/container divs fill full width */
  body > div, body > section, body > article, body > main,
  body > div > div, body > section > div, body > article > div {
    width: 100% !important;
    max-width: 100% !important;
    margin-left: 0 !important;
    margin-right: 0 !important;
  }
  /* Tables: allow horizontal scroll, don't squish cells */
  table { display: block !important; overflow-x: auto !important; white-space: nowrap !important; max-width: 100% !important; }
  td, th { padding: 4px 6px !important; word-break: normal !important; overflow-wrap: normal !important; white-space: nowrap !important; min-width: auto !important; }
  /* Allow wrapping in cells with long text */
  td p, th p { white-space: normal !important; }
  /* Restore code block padding */
  pre { padding: 8px !important; overflow-x: auto !important; font-size: 0.8em !important; }
  code { padding: 1px 3px !important; }
  pre code { padding: 0 !important; }
  h1 { font-size: 1.4em !important; }
  h2 { font-size: 1.25em !important; }
  h3 { font-size: 1.1em !important; }
  p, li, dd, dt { font-size: 1em !important; line-height: 1.6 !important; white-space: normal !important; text-align: left !important; }
  td, th { font-size: 0.85em !important; line-height: 1.4 !important; }
  div, section, article { text-align: left !important; }
  img { max-width: 100% !important; height: auto !important; }
  svg { max-width: 100% !important; height: auto !important; }
  .katex-display { overflow-x: auto !important; overflow-y: hidden !important; padding: 4px 0 !important; margin: 12px 0 !important; }
  .math-block { display: block; margin: 12px 0 !important; }
  /* Visible scrollbar on mobile */
  html { scrollbar-width: thin; scrollbar-color: #888 transparent; }
  ::-webkit-scrollbar { width: 6px; }
  ::-webkit-scrollbar-track { background: transparent; }
  ::-webkit-scrollbar-thumb { background: #888; border-radius: 3px; }
</style>`;

  const lightStyles = `
<style id="light-mode-tweaks">
  html, body { overflow-y: auto !important; font-size: 15px !important; }
  #preview { font-size: 15px !important; }
  body { padding: 20px !important; }
  h1 { font-size: 1.4em !important; }
  h2 { font-size: 1.25em !important; }
  h3 { font-size: 1.1em !important; }
  h1, h2, h3, h4, h5, h6 { margin: 1.2em 0 0.5em !important; }
  p, li, dd, dt { line-height: 1.6 !important; margin-bottom: 0.6em !important; }
  .math-block { display: block !important; margin: 20px 0 !important; }
  .katex-display { margin: 20px 0 !important; }
  img { max-width: 100% !important; }
  ::selection { background: #6366f1 !important; color: white !important; }
  .cite-ref { cursor:pointer; color:#6366f1; text-decoration:underline dotted rgba(99,102,241,0.5); text-underline-offset:2px; }
  .cite-ref:hover { color:#4f46e5; }
  .ref-popup { background:#fff; color:#1e1e1e; border:1px solid #d4d4d8; }
  figure, .figure_img { background:#f8f8fa !important; border-radius:8px; padding:12px !important; margin:28px 0 !important; border:1px solid #e4e4e7; }
  figure img, .figure_img img { border-radius:4px; display:block; margin:0 auto; }
  .caption_figure { margin-top:8px; font-size:0.9em; color:#71717a !important; line-height:1.5; }
  .caption_table { font-size:0.85em; color:#52525b !important; line-height:1.5; padding:12px 14px 8px; font-weight:500; text-transform:none !important; margin:0 !important; background:#f0f0f4 !important; border-radius:8px 8px 0 0; border:1px solid #d4d4d8; border-bottom:none; }
  .table_tabular { background:#f0f0f4 !important; border-radius:0 0 8px 8px; padding:0 14px 12px; border:1px solid #d4d4d8; border-top:none; margin:0 0 24px !important; overflow-x:auto; }
  .caption_table + .table_tabular { border-radius:0 0 8px 8px; }
  table { display:block; overflow-x:auto; margin:0 !important; }
  table.tabular { background:transparent !important; }
</style>`;

  // KaTeX for raw LaTeX + equation hover for Mathpix MathJax SVGs
  const katexScript = `
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css" crossorigin="anonymous">
<script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js" crossorigin="anonymous"></script>
<script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/contrib/auto-render.min.js" crossorigin="anonymous"
  onload="renderMathInElement(document.body,{delimiters:[{left:'$$',right:'$$',display:true},{left:'$',right:'$',display:false},{left:'\\\\(',right:'\\\\)',display:false},{left:'\\\\[',right:'\\\\]',display:true}],throwOnError:false})"></script>
<script>
(function() {
  var btn = document.createElement('button');
  btn.textContent = 'Explain equation';
  btn.style.cssText = 'position:absolute;z-index:9999;padding:4px 10px;border:none;border-radius:6px;' +
    'background:#6366f1;color:#fff;font-size:12px;font-weight:600;cursor:pointer;' +
    'box-shadow:0 2px 8px rgba(0,0,0,0.25);white-space:nowrap;opacity:0;pointer-events:none;' +
    'transition:opacity 0.12s;font-family:-apple-system,BlinkMacSystemFont,sans-serif;';
  document.body.appendChild(btn);

  var cur = null, ht = null;
  function show(el, evt) {
    clearTimeout(ht); cur = el;
    var sy = window.scrollY || document.documentElement.scrollTop;
    var sx = window.scrollX || document.documentElement.scrollLeft;
    var zoom = parseFloat(document.body.style.zoom) || 1;
    var top, left;
    if (evt) {
      // Position near mouse: just below cursor
      top = evt.pageY / zoom + 8;
      left = evt.pageX / zoom - btn.offsetWidth / 2;
    } else {
      var r = el.getBoundingClientRect();
      top = r.bottom / zoom + sy / zoom + 6;
      left = r.left / zoom + sx / zoom + r.width / zoom / 2 - btn.offsetWidth / 2;
    }
    left = Math.max(4, Math.min(left, document.documentElement.clientWidth / zoom - btn.offsetWidth - 4));
    btn.style.top = top + 'px';
    btn.style.left = left + 'px';
    btn.style.opacity = '1'; btn.style.pointerEvents = 'auto';
  }
  function hide() {
    ht = setTimeout(function() { btn.style.opacity = '0'; btn.style.pointerEvents = 'none'; cur = null; }, 600);
  }
  function findMath(t) { return t.closest('.math-inline,.math-block,.katex'); }

  document.body.addEventListener('mouseover', function(e) { var el = findMath(e.target); if (el) show(el, e); });
  document.body.addEventListener('mouseout', function(e) { var el = findMath(e.target); if (el) hide(); });
  btn.addEventListener('mouseenter', function() { clearTimeout(ht); });
  btn.addEventListener('mouseleave', function() { hide(); });
  btn.addEventListener('touchstart', function() { clearTimeout(ht); }, {passive:true});
  btn.addEventListener('click', function(e) {
    e.preventDefault(); e.stopPropagation();
    if (!cur) return;
    var ann = cur.querySelector('annotation[encoding="application/x-tex"]');
    var tex = ann ? ann.textContent : '';
    if (!tex) tex = cur.getAttribute('data-latex') || '';
    if (!tex) {
      // MathJax SVG: textContent is empty, try to get surrounding context
      var stripped = cur.textContent.trim();
      if (stripped) tex = stripped;
    }
    // Gather surrounding text for context
    var context = '';
    var parent = cur.parentElement;
    if (parent) context = parent.textContent.trim().slice(0, 300);
    var r = cur.getBoundingClientRect();
    window.parent.postMessage({
      type: 'equation-explain', latex: tex, context: context,
      rect: { top: r.top, bottom: r.bottom, left: r.left, right: r.right, width: r.width }
    }, '*');
    btn.style.opacity = '0'; btn.style.pointerEvents = 'none';
  });
  document.body.addEventListener('click', function(e) {
    var el = findMath(e.target);
    if (el && el !== cur) { e.preventDefault(); show(el); }
  });
})();
</script>`;

  // Reference citation popup: click [1] in body text to see the reference inline
  // Shows one ref at a time with prev/next for multi-refs, plus an Ingest button
  const refPopupScript = `
<script>
(function() {
  setTimeout(function() {
    // ── Build reference map from the references section ──
    var refMap = {};
    var refList = document.querySelector('.references-list');
    if (!refList) {
      var headings = document.querySelectorAll('h1,h2,h3,h4');
      for (var i = 0; i < headings.length; i++) {
        if (/^References?$/i.test(headings[i].textContent.trim())) {
          var sib = headings[i].nextElementSibling;
          while (sib && !/^H[1-4]$/.test(sib.tagName)) {
            var stxt = sib.textContent.trim();
            var m = stxt.match(/\\[(\\d+)\\]/);
            if (m) refMap[parseInt(m[1], 10)] = stxt;
            sib = sib.nextElementSibling;
          }
          break;
        }
      }
      if (Object.keys(refMap).length === 0) return;
    }
    if (refList) {
      var ps = refList.querySelectorAll('p');
      for (var j = 0; j < ps.length; j++) {
        var ptxt = ps[j].textContent.trim();
        if (!ptxt) continue;
        var rm = ptxt.match(/\\[(\\d+)\\]/);
        if (rm) refMap[parseInt(rm[1], 10)] = ptxt;
      }
    }
    if (Object.keys(refMap).length === 0) return;

    // ── Helpers ──
    function parseRefs(s) {
      var nums = [];
      s.split(/\\s*,\\s*/).forEach(function(part) {
        var rng = part.split(/\\s*[-\\u2013]\\s*/);
        if (rng.length === 2) {
          for (var n = parseInt(rng[0], 10); n <= parseInt(rng[1], 10); n++) nums.push(n);
        } else {
          var v = parseInt(part, 10);
          if (!isNaN(v)) nums.push(v);
        }
      });
      return nums;
    }

    function shouldSkip(node) {
      var el = node.parentElement;
      while (el) {
        if (el.classList && (el.classList.contains('references-list') || el.classList.contains('cite-ref'))) return true;
        var tag = el.tagName;
        if (tag === 'PRE' || tag === 'CODE' || tag === 'SCRIPT' || tag === 'STYLE' || tag === 'ANNOTATION') return true;
        if (el.classList && el.classList.contains('katex')) return true;
        el = el.parentElement;
      }
      return false;
    }

    function esc(s) { return s.replace(/</g, '&lt;').replace(/>/g, '&gt;'); }

    // ── Wrap citation markers — each ref number gets its own clickable span ──
    var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
    var textNodes = [];
    while (walker.nextNode()) textNodes.push(walker.currentNode);

    var pat = /\\[(\\d+(?:\\s*[-,\\u2013]\\s*\\d+)*)\\]/g;
    for (var ti = textNodes.length - 1; ti >= 0; ti--) {
      var tn = textNodes[ti];
      if (shouldSkip(tn)) continue;
      var txt = tn.textContent;
      var matches = [];
      pat.lastIndex = 0;
      var mx;
      while ((mx = pat.exec(txt)) !== null) {
        var rn = parseRefs(mx[1]);
        if (rn.some(function(n) { return !!refMap[n]; })) {
          matches.push({ idx: mx.index, len: mx[0].length, text: mx[0], refs: rn });
        }
      }
      for (var mi = matches.length - 1; mi >= 0; mi--) {
        var mt = matches[mi];
        var before = document.createTextNode(tn.textContent.substring(0, mt.idx));
        var after = document.createTextNode(tn.textContent.substring(mt.idx + mt.len));
        // Build a fragment: [ + clickable numbers separated by , + ]
        var frag = document.createDocumentFragment();
        frag.appendChild(document.createTextNode('['));
        for (var ri = 0; ri < mt.refs.length; ri++) {
          if (ri > 0) frag.appendChild(document.createTextNode(', '));
          var sp = document.createElement('span');
          sp.className = 'cite-ref';
          sp.setAttribute('data-refs', String(mt.refs[ri]));
          sp.textContent = String(mt.refs[ri]);
          frag.appendChild(sp);
        }
        frag.appendChild(document.createTextNode(']'));
        tn.parentNode.insertBefore(before, tn);
        tn.parentNode.insertBefore(frag, tn);
        tn.parentNode.insertBefore(after, tn);
        tn.parentNode.removeChild(tn);
        tn = before;
      }
    }

    // ── Popup element ──
    var popup = document.createElement('div');
    popup.className = 'ref-popup';
    popup.style.cssText = 'position:absolute;z-index:10000;border-radius:8px;' +
      'padding:10px 12px;box-shadow:0 4px 20px rgba(0,0,0,0.25);font-size:13px;line-height:1.5;' +
      'display:none;opacity:0;transition:opacity 0.15s;font-family:-apple-system,BlinkMacSystemFont,sans-serif;';
    document.body.appendChild(popup);

    function showPopup(span) {
      var refs = parseRefs(span.getAttribute('data-refs'));
      var n = refs[0];
      var rt = refMap[n];
      var txt = rt ? esc(rt) : '[' + n + '] Reference not found';
      popup.innerHTML = '<div>' + txt + '</div>' +
        '<button class="ref-ingest-btn" data-ref="' + n + '" style="display:block;width:100%;margin-top:8px;' +
        'background:#6366f1;color:#fff;border:none;border-radius:6px;padding:5px 10px;font-size:11px;' +
        'font-weight:600;cursor:pointer;">Ingest</button>';
      // Constrain popup width to the text column (body content area)
      var bodyStyle = getComputedStyle(document.body);
      var bodyPadL = parseFloat(bodyStyle.paddingLeft) || 0;
      var bodyPadR = parseFloat(bodyStyle.paddingRight) || 0;
      var textWidth = document.body.clientWidth - bodyPadL - bodyPadR;
      popup.style.maxWidth = Math.min(textWidth, document.documentElement.clientWidth - 8) + 'px';
      popup.style.display = 'block';
      setTimeout(function() { popup.style.opacity = '1'; }, 10);
      var sr = span.getBoundingClientRect();
      var sy = window.scrollY || document.documentElement.scrollTop;
      var sx = window.scrollX || document.documentElement.scrollLeft;
      var popW = popup.offsetWidth;
      var left = bodyPadL + sx;
      popup.style.top = (sr.bottom + sy + 6) + 'px';
      popup.style.left = left + 'px';
      if (sr.bottom + popup.offsetHeight + 10 > window.innerHeight) {
        popup.style.top = (sr.top + sy - popup.offsetHeight - 6) + 'px';
      }
      // Dismiss on any scroll or touch outside
      setTimeout(function() {
        window.addEventListener('scroll', hidePopup, { once: true, capture: true });
        document.addEventListener('touchstart', function dismissOnTouch(e) {
          if (!popup.contains(e.target)) {
            hidePopup();
            document.removeEventListener('touchstart', dismissOnTouch, true);
          }
        }, { capture: true });
      }, 100);
    }

    function hidePopup() {
      popup.style.opacity = '0';
      setTimeout(function() { popup.style.display = 'none'; }, 150);
    }

    // ── Event delegation ──
    document.body.addEventListener('click', function(e) {
      if (e.target.closest('.ref-ingest-btn')) {
        e.stopPropagation();
        var rn = parseInt(e.target.closest('.ref-ingest-btn').getAttribute('data-ref'), 10);
        window.parent.postMessage({ type: 'ref-ingest', refText: refMap[rn] || '' }, '*');
        hidePopup();
        return;
      }
      var cr = e.target.closest('.cite-ref');
      if (cr) { e.stopPropagation(); showPopup(cr); return; }
      if (!e.target.closest('.ref-popup')) hidePopup();
    });
    document.addEventListener('keydown', function(e) { if (e.key === 'Escape') hidePopup(); });
  }, 500);
})();
</script>`;

  const injection = (darkMode ? darkStyles : lightStyles) + (mobile ? mobileStyles : "") + selectionScript + katexScript + refPopupScript;

  const bodyClose = /<\/body>/i;
  const htmlClose = /<\/html>/i;
  if (bodyClose.test(html)) {
    return html.replace(bodyClose, injection + "</body>");
  }
  if (htmlClose.test(html)) {
    return html.replace(htmlClose, injection + "</html>");
  }
  return html + injection;
}

export default function MarkdownReader({
  html,
  onSelectionAction,
  darkMode,
  highlights,
  onChatHighlightClick,
  mobile,
  fontScale = 1.0,
  onFontScaleChange,
  scrollToHeadingId,
  onScrollComplete,
  onFigureClick,
}: Props) {
  const containerRef = useRef<HTMLDivElement>(null);
  const iframeRef = useRef<HTMLIFrameElement>(null);
  const [selection, setSelection] = useState<string | null>(null);
  const [selectionPos, setSelectionPos] = useState<{ top: number; left: number } | null>(null);

  const handleAction = useCallback((action: SelectionAction) => {
    if (selection) {
      onSelectionAction(selection, action);
      setSelection(null);
      setSelectionPos(null);
      // Tell iframe to clear custom selection highlight
    }
  }, [selection, onSelectionAction]);

  // After container resize, force iframe to recalculate scroll.
  // Uses direct DOM manipulation (no React state) to avoid re-renders during drag.
  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;
    let debounceTimer: ReturnType<typeof setTimeout> | null = null;
    const ro = new ResizeObserver(() => {
      // Debounce: only fire after resize settles (end of drag)
      if (debounceTimer) clearTimeout(debounceTimer);
      debounceTimer = setTimeout(() => {
        const iframe = iframeRef.current;
        if (iframe?.contentWindow) {
          iframe.contentWindow.postMessage({ type: "refresh-scroll" }, "*");
        }
      }, 100);
    });
    ro.observe(container);
    return () => {
      ro.disconnect();
      if (debounceTimer) clearTimeout(debounceTimer);
    };
  }, []);

  // Send persistent highlights to iframe
  const sendHighlights = useCallback(() => {
    const iframe = iframeRef.current;
    if (iframe?.contentWindow && highlights && highlights.length > 0) {
      iframe.contentWindow.postMessage(
        { type: "highlight-persistent", highlights },
        "*"
      );
    }
  }, [highlights]);

  // Re-send when highlights change
  useEffect(() => {
    sendHighlights();
  }, [sendHighlights]);

  // Send font scale to iframe
  const sendFontScale = useCallback(() => {
    const iframe = iframeRef.current;
    if (iframe?.contentWindow) {
      iframe.contentWindow.postMessage({ type: "set-font-scale", scale: fontScale }, "*");
    }
  }, [fontScale]);

  // Update iframe font scale when it changes
  useEffect(() => {
    sendFontScale();
  }, [sendFontScale]);

  // On iframe load, send highlights and font scale after content is ready
  const handleIframeLoad = useCallback(() => {
    setTimeout(() => {
      sendHighlights();
      sendFontScale();
    }, 150);
  }, [sendHighlights, sendFontScale]);

  // Scroll to heading when requested
  useEffect(() => {
    if (!scrollToHeadingId) return;
    const iframe = iframeRef.current;
    if (iframe?.contentWindow) {
      iframe.contentWindow.postMessage(
        { type: "scroll-to-heading", id: scrollToHeadingId },
        "*"
      );
    }
  }, [scrollToHeadingId]);

  // Clear selection buttons when clicking anywhere outside the reader iframe
  useEffect(() => {
    function handleDocMouseDown(e: MouseEvent) {
      // If the click is inside our container, the iframe's own mousedown handler
      // will send a text-selection-clear message. For clicks outside, clear here.
      if (containerRef.current && !containerRef.current.contains(e.target as Node)) {
        setSelection(null);
        setSelectionPos(null);
      }
    }
    document.addEventListener("mousedown", handleDocMouseDown);
    return () => document.removeEventListener("mousedown", handleDocMouseDown);
  }, []);

  useEffect(() => {
    function handleMessage(e: MessageEvent) {
      if (e.data?.type === "scroll-to-heading-done" && onScrollComplete) {
        onScrollComplete();
        return;
      }
      if (e.data?.type === "text-selection-clear") {
        setSelection(null);
        setSelectionPos(null);
        return;
      }
      if (e.data?.type === "text-selection" && e.data.text) {
        setSelection(e.data.text);
        if (e.data.rect && iframeRef.current) {
          const iframeRect = iframeRef.current.getBoundingClientRect();
          const containerRect = containerRef.current?.getBoundingClientRect();
          if (containerRect) {
            const top = iframeRect.top - containerRect.top + e.data.rect.bottom + 6;
            const left = iframeRect.left - containerRect.left + e.data.rect.left;
            setSelectionPos({ top, left });
          }
        }
      }
      if (e.data?.type === "highlight-click" && e.data.chatId && onChatHighlightClick) {
        onChatHighlightClick(e.data.chatId);
      }
      if (e.data?.type === "figure-click" && e.data.src && onFigureClick) {
        onFigureClick(e.data.src);
        return;
      }
      if (e.data?.type === "equation-explain") {
        const latex = e.data.latex || "";
        const ctx = e.data.context || "";
        let prompt: string;
        if (latex) {
          prompt = `Explain this equation within the context of the paper: $$${latex}$$\n\nPlease concisely review the knowledge required to understand the equation. Describe the high-level message that is conveyed by the equation. Describe each element of the equation, and math concepts related to the equation. Please discuss the authors' choices in terms of notational commonalities with respect to ML papers more generally.`;
        } else {
          prompt = `Explain the equation in this passage from the paper:\n\n"${ctx}"\n\nPlease identify which equation is being referenced from the paper's markdown, then concisely review the knowledge required to understand it. Describe the high-level message conveyed by the equation, each element, and math concepts related to it.`;
        }
        onSelectionAction(prompt, "define");
      }
      if (e.data?.type === "ref-ingest" && e.data.refText) {
        onSelectionAction(e.data.refText, "ingest");
      }
    }
    window.addEventListener("message", handleMessage);
    return () => window.removeEventListener("message", handleMessage);
  }, [onSelectionAction, onChatHighlightClick, onScrollComplete, onFigureClick]);

  const srcDoc = injectStyles(html, darkMode, mobile);

  // Suppress native context menu when our selection action popup is visible
  const handleContextMenu = useCallback((e: React.MouseEvent) => {
    if (selection && selectionPos) {
      e.preventDefault();
    }
  }, [selection, selectionPos]);

  return (
    <div
      ref={containerRef}
      onContextMenu={handleContextMenu}
      style={{
        position: "relative",
        height: "100%",
        overflow: "hidden",
      }}
    >
      {selection && selectionPos && (
        <div
          className={mobile ? "mobile-selection-actions" : undefined}
          style={{
            position: "absolute",
            top: selectionPos.top,
            left: Math.max(4, Math.min(selectionPos.left, (containerRef.current?.offsetWidth ?? 300) - 280)),
            zIndex: 10,
            display: "flex",
            flexDirection: "row",
            gap: mobile ? "4px" : "5px",
            maxWidth: "calc(100% - 8px)",
          }}
        >
          <button onClick={() => handleAction("define")} style={{
            ...actionBtnStyle,
            ...(mobile ? { padding: "4px 8px", fontSize: "11px" } : {}),
          }}>
            Define
          </button>
          <button onClick={() => handleAction("relevance")} style={{
            ...actionBtnStyle,
            ...(mobile ? { padding: "4px 8px", fontSize: "11px" } : {}),
          }}>
            Relevance
          </button>
          <button
            onClick={() => handleAction("ingest")}
            style={{
              ...actionBtnStyle,
              background: "#10b981",
              ...(mobile ? { padding: "4px 8px", fontSize: "11px" } : {}),
            }}
          >
            Ingest
          </button>
          <button
            onClick={() => handleAction("similar")}
            style={{
              ...actionBtnStyle,
              background: "#6366f1",
              ...(mobile ? { padding: "4px 8px", fontSize: "11px" } : {}),
            }}
          >
            Similar
          </button>
        </div>
      )}
      <iframe
        ref={iframeRef}
        onLoad={handleIframeLoad}
        onMouseEnter={() => iframeRef.current?.focus()}
        tabIndex={-1}
        srcDoc={srcDoc}
        style={{
          position: "absolute",
          top: 0,
          left: 0,
          width: "100%",
          height: "100%",
          border: "none",
          background: darkMode ? "#141414" : "#ffffff",
        }}
        sandbox="allow-scripts"
        title="Paper"
      />
      {/* Font scale control */}
      {onFontScaleChange && (
        <div
          style={{
            position: "absolute",
            bottom: mobile ? 12 : 16,
            right: mobile ? 12 : 16,
            zIndex: 15,
            display: "flex",
            alignItems: "center",
            gap: 2,
            background: darkMode ? "rgba(30,30,30,0.9)" : "rgba(255,255,255,0.9)",
            border: `1px solid ${darkMode ? "#3f3f46" : "#d4d4d8"}`,
            borderRadius: "10px",
            padding: "4px",
            boxShadow: "0 2px 8px rgba(0,0,0,0.15)",
            backdropFilter: "blur(8px)",
            WebkitBackdropFilter: "blur(8px)",
          }}
        >
          <button
            onClick={() => onFontScaleChange(fontScale - 0.1)}
            disabled={fontScale <= 0.7}
            style={{
              ...fontScaleBtnStyle,
              color: fontScale <= 0.7 ? (darkMode ? "#555" : "#ccc") : (darkMode ? "#e4e4e7" : "#18181b"),
              fontSize: "13px",
            }}
            title="Decrease text size"
          >
            A
          </button>
          <div style={{
            width: 1,
            height: 16,
            background: darkMode ? "#3f3f46" : "#d4d4d8",
          }} />
          <button
            onClick={() => onFontScaleChange(fontScale + 0.1)}
            disabled={fontScale >= 1.8}
            style={{
              ...fontScaleBtnStyle,
              color: fontScale >= 1.8 ? (darkMode ? "#555" : "#ccc") : (darkMode ? "#e4e4e7" : "#18181b"),
              fontSize: "17px",
            }}
            title="Increase text size"
          >
            A
          </button>
        </div>
      )}
    </div>
  );
}

const actionBtnStyle: React.CSSProperties = {
  background: "#6366f1",
  color: "white",
  border: "none",
  borderRadius: "8px",
  padding: "5px 12px",
  fontSize: "12px",
  cursor: "pointer",
  boxShadow: "0 2px 12px rgba(0,0,0,0.25)",
  whiteSpace: "nowrap",
};

const fontScaleBtnStyle: React.CSSProperties = {
  background: "transparent",
  border: "none",
  cursor: "pointer",
  padding: "4px 8px",
  fontWeight: 600,
  lineHeight: 1,
  display: "flex",
  alignItems: "center",
  justifyContent: "center",
  fontFamily: "Georgia, serif",
};
