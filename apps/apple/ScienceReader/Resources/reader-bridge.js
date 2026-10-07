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

  // Citations, references and the paper line (device presentation for every
  // bundle version, like the layout above). Citations are wrapped in inline
  // spans and nothing else changes, so each block's text — and with it
  // selections, quotes and reading positions — is exactly the bundle's.
  // Elements the app adds outside blocks carry CHROME and are never selected.
  const CHROME = 'data-sr-chrome';
  const references = {entries: [], byID: new Map(), numbers: new Map(), labels: new Map(), members: new Set()};
  let citationBack = null; // {origin:{location,cite}, entry, landing}
  const BIBLIOGRAPHY = /^\s*(?:(?:[0-9]+|[ivx]+|[A-Z])(?:\.[0-9]+)*\.?\s+)?(?:references|bibliography|works\s+cited|literature\s+cited|references\s+cited)\s*:?\s*$/i;
  const folded = value => value.normalize('NFKD').replace(/[\u0300-\u036f]/g, '').replace(/[\u2018\u2019]/g, "'").toLowerCase();
  // Years in an entry, not parts of arXiv IDs, DOIs, page ranges or volumes.
  const ENTRY_YEAR = /(?<![\d.:/\-–])((?:19|20)\d{2})([a-z])?(?![a-z\d\-–]|\.\d)/g;
  // The first author's surname: the last word of the text before the first
  // comma, "and", sentence stop or year ("Y. Bai, …", "Amari, Shun-Ichi.", "Samira Abnar and …").
  const firstSurname = text => {
    const match = /^(.*?)(?:,|\s(?:and|&)\s|(?<=\p{L}{2})\.(?:\s|$)|\s\(?(?:19|20)\d{2})/u.exec(text);
    const words = (match ? match[1] : text.slice(0, 80)).trim().split(/\s+/).filter(word => /\p{L}{2}/u.test(word));
    return words.length && words.length <= 5 ? folded(words[words.length - 1].replace(/[.,;:]+$/, '')) : null;
  };
  // A paragraph of references holds one entry per line; a line starting in
  // lower case continues the previous entry.
  const lineRanges = element => {
    const ranges = [], walker = document.createTreeWalker(element, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
      acceptNode: node => node.nodeType === Node.ELEMENT_NODE && node.matches('math,.reader-equation') ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT,
    });
    let range = document.createRange(); range.setStart(element, 0);
    const cut = (end, start) => { end(range); ranges.push(range); range = document.createRange(); start(range); };
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      if (node.nodeType === Node.ELEMENT_NODE) {
        if (node.tagName === 'BR') cut(value => value.setEndBefore(node), value => value.setStartAfter(node));
        continue;
      }
      for (let index = node.data.indexOf('\n'); index >= 0; index = node.data.indexOf('\n', index + 1)) {
        const at = index;
        cut(value => value.setEnd(node, at), value => value.setStart(node, at + 1));
      }
    }
    range.setEnd(element, element.childNodes.length); ranges.push(range);
    const lines = [];
    for (const value of ranges) {
      const text = value.toString().trim();
      if (!text) continue;
      if (lines.length && /^[a-z(]/.test(text)) lines[lines.length - 1].setEnd(value.endContainer, value.endOffset);
      else lines.push(value);
    }
    return lines;
  };
  const addReference = (element, range, implicit) => {
    const text = range.toString().replace(/\s+/g, ' ').trim();
    if (text.length < 8 || text.length > 4000) return;
    const marker = /^(?:\[([^[\]\s]{1,24})\]|(\d{1,4})\.(?=\s))\s*/.exec(text);
    let number = null, label = null;
    if (marker?.[2]) number = Number(marker[2]);
    else if (marker && /^\d{1,4}$/.test(marker[1])) number = Number(marker[1]);
    else if (marker && /\p{L}/u.test(marker[1])) label = marker[1];
    else if (implicit !== null) number = implicit;
    const body = marker ? text.slice(marker[0].length) : text;
    const years = [...body.matchAll(ENTRY_YEAR)].map(match => ({year: match[1], suffix: match[2] || ''}));
    // Something else under the heading (a note, a footnote): no key, no year.
    if (number === null && label === null && !years.length) return;
    const id = 'ref-' + (number ?? label ?? references.entries.length + 1);
    const entry = {id, element, range, text: body, number, label, years, surname: firstSurname(body), authors: folded(body.slice(0, 400))};
    if (references.byID.has(id)) entry.id = id + '-' + (references.entries.length + 1);
    references.entries.push(entry); references.byID.set(entry.id, entry);
    if (number !== null) references.numbers.set(number, references.numbers.has(number) ? null : entry);
    if (label !== null) references.labels.set(label, references.labels.has(label) ? null : entry);
    element.setAttribute('data-sr-reference', entry.id);
  };
  const collectReferences = () => {
    const heading = [...document.querySelectorAll('h1,h2,h3,h4,h5,h6')].find(element => BIBLIOGRAPHY.test(element.textContent));
    if (!heading) return;
    const level = Number(heading.tagName[1]);
    for (let node = heading.nextElementSibling; node; node = node.nextElementSibling) {
      if (/^H[1-6]$/.test(node.tagName)) { if (Number(node.tagName[1]) <= level) break; continue; }
      if (node.matches(`[${CHROME}],.reader-footnotes,figure,.reader-table,pre,hr`)) continue;
      references.members.add(node);
      if (node.matches('ul,ol')) {
        let number = node.tagName === 'OL' ? Number(node.getAttribute('start') || 1) : null;
        for (const item of node.children) {
          if (item.tagName !== 'LI') continue;
          const range = document.createRange(); range.selectNodeContents(item);
          addReference(item, range, number);
          if (number !== null) number += 1;
        }
      } else for (const range of lineRanges(node)) addReference(node, range, null);
    }
  };

  // In-text citations. Numbered "[16]", "[3, 5]", "[1–4]" and labelled
  // "[Bel+15]" link only when every key is in the bibliography; author–year
  // "(Vaswani et al., 2017)" / "Vaswani et al. (2017)" only on a single match.
  const NUMBERED = /\[\s*\d{1,4}(?:\s*[-–—]\s*\d{1,4})?(?:\s*[,;]\s*\d{1,4}(?:\s*[-–—]\s*\d{1,4})?)*\s*\]/g;
  const LABELLED = /\[([^[\]\n]{2,200})\]/g;
  // A surname, optionally after initials ("Y. Sun") or a particle ("van den Oord").
  const NAME = String.raw`(?:\p{Lu}\.\s*){0,3}(?:(?:van|von|de|der|den|del|della|di|da|du|dos|la|le|ten|ter)\s+)*\p{Lu}[\p{L}'’\-]*\p{L}`;
  // "Vaswani et al.", "Hinton & Salakhutdinov", "Gu, Dao, et al.", "Bahdanau, Cho, and Bengio".
  const AUTHOR_LIST = String.raw`(${NAME}(?:,\s+${NAME})*(?:,?\s+(?:and|&)\s+${NAME})?(?:,?\s+et\s+al\.?)?)`;
  const CITED_YEAR = String.raw`((?:19|20)\d{2})([a-z])?`;
  const SEGMENT = new RegExp(String.raw`^((?:e\.g\.|i\.e\.|see(?:\s+also)?|cf\.)\s*,?\s*)?${AUTHOR_LIST},?\s+${CITED_YEAR}$`, 'ud');
  const SURNAME = String.raw`(?<![\p{L}\p{N}.])(?:(?:van|von|de|der|den|del|della|di|da|du|dos|la|le|ten|ter)\s+)*\p{Lu}[\p{L}'’\-]*\p{L}`;
  const NARRATIVE = new RegExp(String.raw`(${SURNAME}(?:\s+et\s+al\.?|\s+(?:and|&)\s+${SURNAME})?)\s+\(${CITED_YEAR}\)`, 'gud');
  const PARENTHESES = /\(([^()]{6,600})\)/g;
  const surnameOf = name => folded(name.replace(/^(?:\p{Lu}\.\s*)+/u, '').trim().split(/\s+/).pop());
  const authorYear = (authors, year, suffix) => {
    const names = authors.replace(/,?\s+et\s+al\.?$/, '').split(/,\s+|\s+(?:and|&)\s+/).map(surnameOf);
    const found = references.entries.filter(entry => entry.surname === names[0] && entry.years.some(value => value.year === year)
      && names.slice(1).every(name => entry.authors.includes(name)));
    const exact = found.filter(entry => entry.years.some(value => value.year === year && value.suffix === suffix));
    if (exact.length === 1) return exact[0];
    if (exact.length > 1) return null;
    // The bibliography may print "2020" where the text cites "2020a".
    return found.length === 1 && (!suffix || !found[0].years.some(value => value.year === year && value.suffix)) ? found[0] : null;
  };
  // "(A et al., 2019; B and C, 2020)" and "(A et al., 2019, B et al., 2018)" → one piece per citation.
  const pieces = (text, offset) => {
    const out = [];
    for (const match of text.matchAll(/[^;]+/g)) {
      let start = 0;
      const part = match[0];
      for (const end of [...part.matchAll(/(?<=(?:19|20)\d{2}[a-z]?),\s+/g)].map(value => value.index).concat(part.length)) {
        const piece = part.slice(start, end), lead = piece.length - piece.trimStart().length;
        out.push({text: piece.trim(), start: offset + match.index + start + lead});
        start = end + (part.slice(end).match(/^,\s+/)?.[0].length || 0);
      }
    }
    return out;
  };
  const styles = {numbered: false, labelled: false, authorYear: false};
  const citationsIn = text => {
    const links = [];
    const keyed = (inner, offset, pattern) => [...inner.matchAll(pattern)].map(token =>
      ({start: offset + token.index, end: offset + token.index + token[0].length, value: token[0]}));
    if (styles.numbered) for (const match of text.matchAll(NUMBERED)) {
      const tokens = keyed(match[0], match.index, /\d{1,4}/g);
      if (!tokens.every(token => references.numbers.get(Number(token.value)))) continue;
      // "[1–4]": both ends exist and form a short increasing range.
      let index = 0, valid = true;
      for (const piece of match[0].slice(1, -1).split(/[,;]/)) {
        const count = (piece.match(/\d{1,4}/g) || []).length;
        if (count === 2) {
          const from = Number(tokens[index].value), to = Number(tokens[index + 1].value);
          if (!(from < to && to - from <= 200)) valid = false;
        }
        index += count;
      }
      if (!valid) continue;
      tokens.forEach((token, index) => links.push({
        start: index === 0 ? match.index : token.start, end: index === tokens.length - 1 ? match.index + match[0].length : token.end,
        entry: references.numbers.get(Number(token.value)), label: 'Reference ' + token.value,
      }));
    }
    if (styles.labelled) for (const match of text.matchAll(LABELLED)) {
      const tokens = keyed(match[1], match.index + 1, /[^,;\s][^,;]*?(?=\s*(?:[,;]|$))/g);
      if (!tokens.length || !tokens.every(token => references.labels.get(token.value))) continue;
      tokens.forEach((token, index) => links.push({
        start: index === 0 ? match.index : token.start, end: index === tokens.length - 1 ? match.index + match[0].length : token.end,
        entry: references.labels.get(token.value), label: 'Reference ' + token.value,
      }));
    }
    if (styles.authorYear) {
      for (const match of text.matchAll(PARENTHESES)) {
        for (const piece of pieces(match[1], match.index + 1)) {
          const segment = SEGMENT.exec(piece.text);
          const entry = segment && authorYear(segment[2], segment[3], segment[4] || '');
          if (entry) links.push({start: piece.start + segment.indices[2][0], end: piece.start + (segment.indices[4] || segment.indices[3])[1], entry});
        }
      }
      for (const match of text.matchAll(NARRATIVE)) {
        const entry = authorYear(match[1], match[2], match[3] || '');
        if (entry) links.push({start: match.index, end: match.index + match[0].length, entry});
      }
    }
    links.sort((a, b) => a.start - b.start);
    return links.filter((link, index) => index === 0 || link.start >= links[index - 1].end);
  };
  const SKIPPED = `math,.reader-equation,pre,code,a,h1,h2,h3,h4,h5,h6,.sr-cite,[${CHROME}]`;
  const inBibliography = node => {
    for (let element = node.parentElement; element && element !== document.body; element = element.parentElement) {
      if (references.members.has(element)) return true;
    }
    return false;
  };
  const linkCitations = () => {
    if (!references.entries.length) return;
    styles.numbered = [...references.numbers.values()].filter(Boolean).length >= 2;
    styles.labelled = [...references.labels.values()].some(Boolean);
    styles.authorYear = references.entries.some(entry => entry.surname && entry.years.length);
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
      acceptNode: node => /[[(]/.test(node.data) && node.parentElement?.closest('[data-reader-block]') && !node.parentElement.closest(SKIPPED)
        && !inBibliography(node) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT,
    });
    const nodes = [];
    for (let node = walker.nextNode(); node; node = walker.nextNode()) nodes.push(node);
    for (const node of nodes) {
      const links = citationsIn(node.data);
      if (!links.length) continue;
      const fragment = document.createDocumentFragment();
      let cursor = 0;
      for (const link of links) {
        if (link.start > cursor) fragment.append(node.data.slice(cursor, link.start));
        const span = document.createElement('span');
        span.className = 'sr-cite'; span.setAttribute('role', 'link'); span.tabIndex = 0;
        span.setAttribute('data-sr-cite', link.entry.id);
        if (link.label) span.setAttribute('aria-label', link.label);
        span.textContent = node.data.slice(link.start, link.end);
        fragment.append(span); cursor = link.end;
      }
      if (cursor < node.data.length) fragment.append(node.data.slice(cursor));
      node.replaceWith(fragment);
    }
  };
  const installCitationStyle = () => {
    const style = document.createElement('style');
    style.textContent = [
      ':root{--sr-link:#5659d6;--sr-flash:rgba(99,102,241,.2)}@media(prefers-color-scheme:dark){:root{--sr-link:#a5a7ff;--sr-flash:rgba(165,180,252,.3)}}',
      // A larger tap target than the digits, without moving any text.
      '.sr-cite{color:var(--sr-link);text-decoration:none;cursor:pointer;border-radius:4px;padding:.45em .2em;margin:-.45em -.2em;-webkit-tap-highlight-color:var(--sr-flash)}',
      '.sr-cite:focus-visible{outline:2px solid var(--sr-link);outline-offset:1px}[data-sr-reference]{cursor:pointer}',
      '.sr-flash{position:absolute;z-index:-1;pointer-events:none;border-radius:8px;background:var(--sr-flash);transition:opacity .9s ease}.sr-flash.sr-flash-done{opacity:0}',
      '.sr-paper-line{font-size:.82rem;line-height:1.4;color:#666;margin:-.3em 0 1.2em;-webkit-user-select:none;user-select:none}',
      '@media(prefers-color-scheme:dark){.sr-paper-line{color:#9a9a9a}}@media(prefers-reduced-motion:reduce){.sr-flash{transition:none}}',
    ].join('');
    document.head.append(style);
  };
  // One secondary line under the authors (or the title): year · venue · source.
  const installPaperLine = text => {
    document.querySelector('[data-sr-paper-line]')?.remove();
    if (typeof text !== 'string' || !text.trim()) return;
    const line = document.createElement('div');
    line.className = 'sr-paper-line'; line.setAttribute(CHROME, ''); line.setAttribute('data-sr-paper-line', '');
    line.textContent = text.slice(0, 300); line.setAttribute('role', 'text'); line.setAttribute('aria-label', line.textContent.split(' · ').join(', '));
    let anchor = document.querySelector('h1[data-reader-block]') || document.querySelector('h1');
    while (anchor?.nextElementSibling?.classList.contains('reader-authors')) anchor = anchor.nextElementSibling;
    if (anchor) anchor.after(line); else document.body.prepend(line);
  };
  window.__scienceReaderSetPaperLine = text => {
    if (config?.figure_id) return false;
    const location = citationBack ? null : (lastPosition ?? window.__scienceReaderLocation());
    installPaperLine(text);
    if (location) window.__scienceReaderRestore(location);
    return true;
  };

  window.__scienceReaderReady = (async () => {
    if (!validDocument()) throw new Error('invalid_reader_index');
    if (config && !config.figure_id) installLayout();
    if (!config?.figure_id) {
      installCitationStyle(); collectReferences(); linkCitations();
      installPaperLine(window.__readerPaperLine);
    }
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
      // reported while reading, not the position after the reflow. After a
      // citation jump that place is the reference (reading resumes on Back).
      if (citationBack) { window.__scienceReaderFit(); showReference(citationBack.entry, true); return; }
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
    if (citationBack) endCitation();
    element.scrollIntoView({behavior:reduced?'instant':'smooth',block:'start'});
    return true;
  };
  window.__scienceReaderLocation = () => {
    const index = blocks.findIndex(element => {
      const rect = element.getBoundingClientRect();
      return rect.height > 0 && rect.bottom > 0;
    });
    const rect = index >= 0 ? blocks[index].getBoundingClientRect() : null;
    // How far through the document this place is: 0 at the top, 1 at the end.
    const scrollable = document.documentElement.scrollHeight - window.innerHeight;
    return {block:index,fraction:rect?-rect.top/Math.max(1,rect.height):0,
      height:rect?Math.max(1,rect.height):1,y:Math.max(0,window.scrollY),
      progress:scrollable<1?1:Math.min(1,Math.max(0,window.scrollY/scrollable))};
  };
  const locationY = location => {
    const rect = blocks[location.block]?.getBoundingClientRect();
    return Math.max(0, rect ? window.scrollY+rect.top+location.fraction*Math.max(1,rect.height) : location.y);
  };
  window.__scienceReaderRestore = location => {
    window.scrollTo({top:locationY(location),behavior:'instant'});
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
  // While "Back" is offered the reading position stays where the reader left
  // the text; it is reported again on Back or once they scroll away.
  const postPosition = () => {
    if (citationBack) return;
    lastPosition = window.__scienceReaderLocation(); post({type:'position',...lastPosition});
  };

  // Citation jumps: to the reference (smooth unless Reduce Motion), a brief
  // highlight, and native "Back" to the exact place left.
  const reducedMotion = () => matchMedia('(prefers-reduced-motion: reduce)').matches;
  const settled = then => {
    let last = NaN, still = 0;
    const started = performance.now();
    const tick = () => {
      still = Math.abs(window.scrollY - last) < 0.5 ? still + 1 : 0; last = window.scrollY;
      if (still >= 4 || performance.now() - started > 1500) then(); else requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  };
  const flash = rect => {
    if (!rect || (!rect.width && !rect.height)) return;
    const box = document.createElement('div');
    box.className = 'sr-flash'; box.setAttribute(CHROME, ''); box.setAttribute('aria-hidden', 'true');
    Object.assign(box.style, {left: rect.left + window.scrollX - 8 + 'px', top: rect.top + window.scrollY - 6 + 'px',
      width: rect.width + 16 + 'px', height: rect.height + 12 + 'px'});
    document.body.append(box);
    setTimeout(() => box.classList.add('sr-flash-done'), 1600);
    setTimeout(() => box.remove(), 2700);
  };
  const scrollTarget = rect => {
    const limit = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
    return Math.min(limit, Math.max(0, window.scrollY + rect.top - Math.max(16, (window.innerHeight - rect.height) / 2)));
  };
  const showReference = (entry, instant) => {
    window.scrollTo({top: scrollTarget(entry.range.getBoundingClientRect()), behavior: instant || reducedMotion() ? 'instant' : 'smooth'});
    if (citationBack) citationBack.landing = null;
    settled(() => {
      if (citationBack?.entry !== entry) return;
      citationBack.landing = window.scrollY;
      if (!instant) flash(entry.range.getBoundingClientRect());
    });
  };
  const endCitation = () => {
    if (!citationBack) return;
    citationBack = null;
    post({type:'citation',state:'ended'});
    postPosition();
  };
  const jumpToReference = (entry, cite) => {
    // A second citation followed from the bibliography keeps the first place.
    const origin = citationBack?.origin ?? {location: window.__scienceReaderLocation(), cite};
    citationBack = {origin, entry, landing: null};
    showReference(entry, false);
    post({type:'citation',state:'jumped',id:entry.id});
  };
  window.__scienceReaderCitationBack = () => {
    const back = citationBack;
    if (!back) return false;
    citationBack = null;
    window.scrollTo({top: locationY(back.origin.location), behavior: reducedMotion() ? 'instant' : 'smooth'});
    post({type:'citation',state:'ended'});
    settled(() => {
      postPosition();
      if (back.origin.cite?.isConnected) flash(back.origin.cite.getBoundingClientRect());
    });
    return true;
  };
  window.addEventListener('scroll',() => {
    // Scrolling a screen away from the reference ends the offer to go back.
    if (citationBack?.landing != null && Math.abs(window.scrollY - citationBack.landing) > window.innerHeight) endCitation();
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
        if (node.hasAttribute(CHROME)) return; // App presentation (the paper line), not the paper's text.
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
  // The bibliography entry under a tap (a paragraph may hold several).
  const referenceAt = (element, x, y) => {
    const found = references.entries.filter(entry => entry.element.contains(element));
    if (found.length <= 1) return found[0] || null;
    const caret = document.caretRangeFromPoint?.(x, y);
    return (caret && found.find(entry => entry.range.isPointInRange(caret.startContainer, caret.startOffset)))
      || found.find(entry => { const rect = entry.range.getBoundingClientRect(); return y >= rect.top && y <= rect.bottom; }) || null;
  };
  const offerReference = entry => {
    const rect = entry.range.getBoundingClientRect();
    const links = [...entry.element.querySelectorAll('a[href]')].filter(link => entry.range.intersectsNode(link))
      .map(link => link.href).filter(href => href.startsWith('https:')).slice(0, 8);
    post({type:'reference',manifest_sha256:manifest,block_id:enclosingBlock(entry.element),id:entry.id,
      number:entry.number,label:entry.label,text:entry.text,links,
      rect:{x:rect.left,y:Math.max(0,rect.top),width:rect.width,height:Math.min(rect.bottom,window.innerHeight)-Math.max(0,rect.top)}});
  };
  if (!config?.figure_id) {
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
    // Citations first (capture), so one inside a figure caption doesn't also open the figure.
    document.addEventListener('click',event => {
      const element = event.target instanceof Element ? event.target : event.target.parentElement;
      const cite = element?.closest('.sr-cite'), entry = cite && references.byID.get(cite.getAttribute('data-sr-cite'));
      if (!entry || gesture?.moved || !window.getSelection()?.isCollapsed) return;
      gesture = null; event.preventDefault(); event.stopPropagation();
      if (selectedEquation) { clearEquation(); post({type:'selection',selection:{manifest_sha256:manifest,parts:[]}}); }
      jumpToReference(entry, cite);
    },true);
    document.addEventListener('click',event => {
      const moved = gesture?.moved; gesture = null;
      if (moved || !window.getSelection()?.isCollapsed) return;
      const element = event.target instanceof Element ? event.target : event.target.parentElement;
      // A bibliography entry offers native actions (its own links keep working).
      const entry = !element?.closest('a,[data-reader-equation]') && element?.closest('[data-sr-reference]') ? referenceAt(element, event.clientX, event.clientY) : null;
      if (entry) {
        if (selectedEquation) { clearEquation(); post({type:'selection',selection:{manifest_sha256:manifest,parts:[]}}); }
        offerReference(entry);
        return;
      }
      if (!config) return;
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
      const cite = event.target instanceof Element && event.target.matches('.sr-cite') ? event.target : null;
      const entry = cite && (event.key === 'Enter' || event.key === ' ') && references.byID.get(cite.getAttribute('data-sr-cite'));
      if (entry) { event.preventDefault(); event.stopPropagation(); jumpToReference(entry, cite); }
    },true);
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
