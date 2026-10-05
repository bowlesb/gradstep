// App-owned script, injected only into WKContentWorld.defaultClient. Content
// has no scripts and cannot supply equation source or arbitrary figure HTML.
(() => {
  'use strict';
  const config = window.__readerBundleConfig || null;
  const post = value => window.webkit.messageHandlers.reader.postMessage(value);
  const manifest = config?.manifest_sha256;
  const headings = new Map(), blocks = [];
  const figureIDs = new Set(config?.figures.map(value => value.id) || []);
  const equationIDs = new Map(config?.equations.map(value => [value.id, value.block_id]) || []);
  const blockIDs = new Set(config?.blocks.map(value => value.id) || []);
  const key = 'data-reader-block';
  const enclosingBlock = node => (node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement)?.closest(`[${key}]`)?.id;
  const validDocument = () => {
    if (!config) return true; // App test fixtures; production requires a bundle.
    const seen = new Set();
    for (const element of document.querySelectorAll('[id]')) {
      if (seen.has(element.id)) return false;
      seen.add(element.id);
    }
    for (const block of config.blocks) {
      const element = document.getElementById(block.id);
      if (!element || element.getAttribute(key) !== block.id) return false;
      blocks.push(element);
    }
    for (const equation of config.equations) {
      const element = document.getElementById(equation.id);
      if (!element || element.getAttribute('data-reader-equation') !== equation.id || enclosingBlock(element) !== equation.block_id) return false;
    }
    for (const figure of config.figures) {
      const element = document.getElementById(figure.id);
      if (!element || element.tagName !== 'FIGURE' || element.getAttribute('data-reader-figure') !== figure.id) return false;
    }
    return document.querySelectorAll(`[${key}]`).length === config.blocks.length
      && document.querySelectorAll('[data-reader-equation]').length === config.equations.length
      && document.querySelectorAll('[data-reader-figure]').length === config.figures.length;
  };

  // Device-side presentation for every bundle version (no content changes):
  // WebKit ignores mtable/mtr columnalign, so cells get their own alignment;
  // equation numbers stay visible; math that is slightly too wide is scaled
  // to the column and the rest scrolls inside its own box (never the page).
  const MIN_SCALE = 0.75;
  const fitted = new Set();
  let lastPosition = null;
  const installLayout = () => {
    const style = document.createElement('style');
    style.textContent = [
      'mtd[columnalign=left]{text-align:left}mtd[columnalign=right]{text-align:right}mtd[columnalign=center]{text-align:center}',
      ':root{--sr-bg:#fff}@media(prefers-color-scheme:dark){:root{--sr-bg:#0f0f0f}}',
      '.reader-display,.reader-table,.reader-inline-wide{background:linear-gradient(to right,var(--sr-bg) 30%,transparent) left/40px 100% no-repeat local,'
        + 'linear-gradient(to left,var(--sr-bg) 30%,transparent) right/40px 100% no-repeat local,'
        + 'radial-gradient(farthest-side at 0 50%,rgba(127,127,127,.35),transparent) left/12px 100% no-repeat scroll,'
        + 'radial-gradient(farthest-side at 100% 50%,rgba(127,127,127,.35),transparent) right/12px 100% no-repeat scroll}',
      '.reader-display.reader-tagged{padding-right:0}.reader-display.reader-tagged>.reader-tag{position:sticky;right:0;align-self:stretch;display:flex;align-items:center;padding:0 6px 0 .5em;background:var(--sr-bg)}',
      '.reader-inline-wide{display:inline-block;max-width:100%;overflow-x:auto;overflow-y:hidden;vertical-align:middle}',
    ].join('');
    document.head.append(style);
    for (const cell of document.querySelectorAll('mtd:not([columnalign])')) {
      const row = cell.parentElement, table = row?.parentElement;
      const source = row?.getAttribute('columnalign') || (table?.tagName.toLowerCase() === 'mtable' ? table.getAttribute('columnalign') : null);
      if (!source) continue;
      const aligns = source.trim().split(/\s+/).filter(value => ['left', 'right', 'center'].includes(value));
      const index = [...row.children].indexOf(cell);
      if (aligns.length && index >= 0) cell.setAttribute('columnalign', aligns[Math.min(index, aligns.length - 1)]);
    }
  };
  const fitMath = () => {
    // Reset, then measure everything, then write: one layout pass each.
    for (const math of fitted) math.style.fontSize = '';
    for (const span of document.querySelectorAll('.reader-inline-wide')) span.classList.remove('reader-inline-wide');
    fitted.clear();
    const writes = [];
    for (const box of document.querySelectorAll('.reader-display')) {
      const math = box.querySelector(':scope > math');
      if (!math || box.scrollWidth <= box.clientWidth + 1) continue;
      const computed = getComputedStyle(box), tag = box.querySelector(':scope > .reader-tag');
      const available = box.clientWidth - parseFloat(computed.paddingLeft) - parseFloat(computed.paddingRight)
        - (tag ? tag.getBoundingClientRect().width + (parseFloat(computed.columnGap) || 0) : 0);
      const ratio = available / Math.max(1, math.getBoundingClientRect().width);
      if (ratio >= MIN_SCALE && ratio < 1) writes.push([math, ratio]);
    }
    const body = getComputedStyle(document.body);
    const column = document.body.clientWidth - parseFloat(body.paddingLeft) - parseFloat(body.paddingRight);
    const wide = [];
    for (const span of document.querySelectorAll('.reader-inline')) {
      if (span.closest('.reader-table,pre')) continue;
      const math = span.querySelector('math'), width = span.getBoundingClientRect().width;
      if (!math || width <= column) continue;
      const ratio = column / width;
      if (ratio >= MIN_SCALE) writes.push([math, ratio]); else wide.push(span);
    }
    for (const [math, ratio] of writes) {
      const base = parseFloat(getComputedStyle(math).fontSize) || 17;
      math.style.fontSize = Math.floor(base * ratio * 0.98 * 100) / 100 + 'px';
      fitted.add(math);
    }
    for (const span of wide) span.classList.add('reader-inline-wide');
  };
  window.__scienceReaderFit = () => { if (config && !config.figure_id) fitMath(); };

  window.__scienceReaderReady = (async () => {
    if (!validDocument()) throw new Error('invalid_reader_index');
    if (config && !config.figure_id) installLayout();
    if (config?.figure_id) {
      if (!figureIDs.has(config.figure_id)) throw new Error('invalid_reader_figure');
      const figure = document.getElementById(config.figure_id);
      document.body.replaceChildren(figure);
      document.body.classList.add('reader-figure-detail');
      const style = document.createElement('style');
      style.textContent = 'body.reader-figure-detail{max-width:none;padding:24px 18px 32px}body.reader-figure-detail figure{margin:0}body.reader-figure-detail img{max-width:100%;height:auto}';
      document.head.append(style);
    }
    await document.fonts.ready;
    await Promise.all([...document.images].map(image => image.decode()));
    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    if (config?.figure_id) return true;
    window.__scienceReaderFit();
    // Rotation or split-view width changes refit while keeping the place.
    let width = document.documentElement.clientWidth;
    new ResizeObserver(() => {
      if (document.documentElement.clientWidth === width) return;
      width = document.documentElement.clientWidth;
      // WebKit has already reflowed for the new width: keep the place last
      // reported while reading, not the position after the reflow.
      const location = lastPosition ?? window.__scienceReaderLocation();
      window.__scienceReaderFit(); window.__scienceReaderRestore(location);
    }).observe(document.documentElement);

    let items;
    if (config) {
      items = config.headings.map(heading => {
        const element = document.getElementById(heading.id);
        if (!element || element.tagName !== 'H' + heading.level) throw new Error('invalid_reader_heading');
        headings.set(heading.id, element);
        return {id: heading.id, title: heading.title};
      });
    } else {
      // Retain source anchors in the existing local navigation regressions.
      const counts = new Map();
      document.querySelectorAll('[id]').forEach(element => counts.set(element.id, (counts.get(element.id) || 0) + 1));
      const used = new Set(counts.keys());
      items = [...document.querySelectorAll('h1,h2,h3')].filter(element => element.textContent.trim()).slice(0,500).map((element,index) => {
        let id = element.id;
        if (!id || id.length > 512 || /[\u0000-\u0020\u007f]/.test(id) || counts.get(id) !== 1) {
          const stem = 'sr-heading-' + index; let suffix = 0; id = stem;
          while (used.has(id)) id = stem + '-' + (++suffix);
          used.add(id);
        }
        headings.set(id,element);
        return {id,title:element.textContent.trim().slice(0,2000)};
      });
      blocks.push(...document.querySelectorAll('h1,h2,h3,h4,h5,h6,p,li,figure,table,pre'));
    }
    post({type:'headings',items});
    return true;
  })();
  // Attach a rejection observer immediately, even before didFinish awaits it.
  window.__scienceReaderReady.catch(() => post({type:'invalid'}));

  window.__scienceReaderJumpToHeading = (id,reduced) => {
    const element = headings.get(id);
    if (!element) return false;
    element.scrollIntoView({behavior:reduced?'instant':'smooth',block:'start'});
    return true;
  };
  window.__scienceReaderLocation = () => {
    const index = blocks.findIndex(element => {
      const rect = element.getBoundingClientRect();
      return rect.height > 0 && rect.bottom > 0;
    });
    const rect = index >= 0 ? blocks[index].getBoundingClientRect() : null;
    return {block:index,fraction:rect?-rect.top/Math.max(1,rect.height):0,
      height:rect?Math.max(1,rect.height):1,y:Math.max(0,window.scrollY)};
  };
  window.__scienceReaderRestore = location => {
    const rect = blocks[location.block]?.getBoundingClientRect();
    const y = rect ? window.scrollY+rect.top+location.fraction*Math.max(1,rect.height) : location.y;
    window.scrollTo({top:Math.max(0,y),behavior:'instant'});
  };
  let positionTimer, selectionTimer, selectedEquation;
  const clearEquation = () => {
    selectedEquation?.classList.remove('reader-selected-equation');
    selectedEquation = null;
  };
  window.__scienceReaderClearSelection = () => {
    clearTimeout(selectionTimer);
    clearEquation();
    window.getSelection()?.removeAllRanges();
  };
  const postPosition = () => { lastPosition = window.__scienceReaderLocation(); post({type:'position',...lastPosition}); };
  window.addEventListener('scroll',() => {
    if (positionTimer || config?.figure_id) return;
    positionTimer = setTimeout(() => {positionTimer=null;postPosition();},120);
  },{passive:true});
  window.addEventListener('scrollend',() => {if (!config?.figure_id) postPosition();});

  function selectionParts() {
    const selection = window.getSelection();
    if (!selection || selection.rangeCount !== 1 || selection.isCollapsed) return [];
    const range = selection.getRangeAt(0);
    if (!document.body.contains(range.startContainer) || !document.body.contains(range.endContainer)) return [];
    const parts = []; let length = 0, invalid = false;
    const append = part => {
      length += part.text?.length || 0;
      if (parts.length >= 512 || length > 20000) { invalid = true; return; }
      const previous = parts[parts.length-1];
      if (part.kind === 'text' && previous?.kind === 'text' && previous.block_id === part.block_id) previous.text += part.text;
      else parts.push(part);
    };
    function walk(node) {
      if (invalid || !range.intersectsNode(node)) return;
      if (node.nodeType === Node.ELEMENT_NODE) {
        if (node.matches('script,style,mjx-assistive-mml,[aria-hidden="true"]') && !node.hasAttribute('data-reader-equation')) return;
        const equation = node.getAttribute('data-reader-equation');
        if (equation) {
          const block = enclosingBlock(node);
          if (equationIDs.get(equation) !== block) { invalid = true; return; }
          append({kind:'equation',block_id:block,equation_id:equation});
          return; // Never count SVG glyphs or assistive MathML a second time.
        }
        const block = enclosingBlock(node);
        if (node.tagName === 'BR' && blockIDs.has(block)) append({kind:'text',block_id:block,text:'\n'});
        for (const child of node.childNodes) walk(child);
        if (parts.length && blockIDs.has(block)) {
          if (node.tagName === 'TD' || node.tagName === 'TH') append({kind:'text',block_id:block,text:'\t'});
          if (node.tagName === 'TR' || node.tagName === 'LI') append({kind:'text',block_id:block,text:'\n'});
        }
        if (node.hasAttribute(key) && parts.length) {
          append({kind:'text',block_id:node.id,text:'\n'});
        }
      } else if (node.nodeType === Node.TEXT_NODE) {
        // Pretty-printing whitespace between table cells/list items is not
        // visible prose. Their explicit separators above carry the structure.
        if (/^(TABLE|THEAD|TBODY|TFOOT|TR|UL|OL)$/.test(node.parentElement?.tagName || '') && !node.textContent.trim()) return;
        const block = enclosingBlock(node);
        if (!blockIDs.has(block)) { if (node.textContent.trim()) invalid = true; return; }
        const start = node === range.startContainer ? range.startOffset : 0;
        const end = node === range.endContainer ? range.endOffset : node.length;
        if (end > start) append({kind:'text',block_id:block,text:node.textContent.slice(start,end)});
      }
    }
    walk(document.body);
    return invalid ? [] : parts;
  }
  document.addEventListener('selectionchange',() => {
    clearTimeout(selectionTimer);
    selectionTimer = setTimeout(() => {
      if (config && !config.figure_id) {
        if (selectedEquation && window.getSelection()?.isCollapsed) return;
        clearEquation();
        post({type:'selection',selection:{manifest_sha256:manifest,parts:selectionParts()}});
      }
    },180);
  });
  if (config && !config.figure_id) {
    const style = document.createElement('style');
    style.textContent = '.reader-selected-equation{outline:2px solid Highlight;outline-offset:4px;border-radius:3px}';
    document.head.append(style);
    // Keep the math/assistive MathML tree intact. A tap offers the same native
    // actions as text selection; it does not send a question by itself.
    let gesture;
    document.addEventListener('pointerdown',event => {
      gesture = {id:event.pointerId,x:event.clientX,y:event.clientY,moved:false};
    },{passive:true});
    document.addEventListener('pointermove',event => {
      if (gesture?.id === event.pointerId && Math.hypot(event.clientX-gesture.x,event.clientY-gesture.y)>8) gesture.moved = true;
    },{passive:true});
    document.addEventListener('pointercancel',() => {if (gesture) gesture.moved = true;},{passive:true});
    document.addEventListener('click',event => {
      const moved = gesture?.moved; gesture = null;
      if (moved || !window.getSelection()?.isCollapsed) return;
      const element = event.target instanceof Element ? event.target : event.target.parentElement;
      const equation = element?.closest('[data-reader-equation]');
      if (equation && !element.closest('a')) {
        const id = equation.getAttribute('data-reader-equation'), block = enclosingBlock(equation);
        if (equationIDs.get(id) !== block) return;
        clearTimeout(selectionTimer); clearEquation();
        selectedEquation = equation; equation.classList.add('reader-selected-equation');
        post({type:'selection',selection:{manifest_sha256:manifest,parts:[{kind:'equation',block_id:block,equation_id:id}]}});
      } else if (selectedEquation) {
        clearEquation(); post({type:'selection',selection:{manifest_sha256:manifest,parts:[]}});
      }
    });
    document.addEventListener('keydown',event => {
      if (event.key === 'Escape' && selectedEquation) {
        clearEquation(); post({type:'selection',selection:{manifest_sha256:manifest,parts:[]}});
      }
    });
  }
  if (config && !config.figure_id) for (const id of figureIDs) {
    const figure = document.getElementById(id);
    if (!figure) continue;
    const open = () => {
      if (!window.getSelection()?.isCollapsed) return;
      post({type:'figure',id,manifest_sha256:manifest});
    };
    figure.setAttribute('role','button'); figure.setAttribute('tabindex','0');
    figure.setAttribute('aria-label','Open figure: ' + config.figures.find(value => value.id === id).alt);
    figure.addEventListener('click',open);
    figure.addEventListener('keydown',event => {
      if (event.key === 'Enter' || event.key === ' ') {event.preventDefault();open();}
    });
  }
})();
