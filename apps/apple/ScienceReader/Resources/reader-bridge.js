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
  // Wide tables and equations scroll sideways in flat boxes (owner, build 58: "I really dislike this gradient": the
  // scroll shadows are gone). An edge with more of the box beyond it shows a hairline.
  const SCROLLERS = '.reader-display,.reader-table,.reader-inline-wide';
  const scrollEdges = box => {
    const hidden = box.scrollWidth - box.clientWidth;
    box.classList.toggle('sr-more-left', hidden > 1 && box.scrollLeft > 1);
    box.classList.toggle('sr-more-right', hidden > 1 && box.scrollLeft < hidden - 1);
  };
  const markScrollEdges = () => {
    for (const box of document.querySelectorAll('.sr-more-left,.sr-more-right')) box.classList.remove('sr-more-left', 'sr-more-right');
    for (const box of document.querySelectorAll(SCROLLERS)) scrollEdges(box);
  };
  const installLayout = () => {
    const style = document.createElement('style');
    style.textContent = [
      'mtd[columnalign=left]{text-align:left}mtd[columnalign=right]{text-align:right}mtd[columnalign=center]{text-align:center}',
      ':root{--sr-bg:#fff;--sr-edge:rgba(60,60,67,.22)}@media(prefers-color-scheme:dark){:root{--sr-bg:#0f0f0f;--sr-edge:rgba(235,235,245,.2)}}',
      '.sr-more-left{box-shadow:inset 1px 0 0 var(--sr-edge)}.sr-more-right{box-shadow:inset -1px 0 0 var(--sr-edge)}'
        + '.sr-more-left.sr-more-right{box-shadow:inset 1px 0 0 var(--sr-edge),inset -1px 0 0 var(--sr-edge)}',
      '.reader-display.reader-tagged{padding-right:0}.reader-display.reader-tagged>.reader-tag{position:sticky;right:0;align-self:stretch;display:flex;align-items:center;padding:0 6px 0 .5em;background:var(--sr-bg)}',
      '.reader-inline-wide{display:inline-block;max-width:100%;overflow-x:auto;overflow-y:hidden;vertical-align:middle}',
    ].join('');
    document.head.append(style);
    document.addEventListener('scroll', event => {
      if (event.target instanceof Element && event.target.matches(SCROLLERS)) scrollEdges(event.target);
    }, {capture: true, passive: true});
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
    markScrollEdges();
  };
  window.__scienceReaderFit = () => { if (config && !config.figure_id) fitMath(); };

  // LINE WIDTH (docs/architecture/READING_MODE.md): the host's measure for the text column, never the bundle's CSS.
  // Comfortable keeps about 72 characters a line at every text size (the bundle also caps it at 704 px, which made
  // larger text hold fewer words); Wide about 100; Full width reflows to the window, so a wider window holds more
  // words on each line. Figures stay at a readable size; tables and display math scroll inside their own boxes.
  const LINE_WIDTHS = ['comfortable', 'wide', 'full'];
  let lineWidthStyle = null;
  const applyLineWidth = mode => {
    const value = LINE_WIDTHS.includes(mode) ? mode : 'comfortable';
    if (!lineWidthStyle) {
      lineWidthStyle = document.createElement('style');
      lineWidthStyle.textContent = [
        'html[data-sr-line-width=comfortable] body:not(.reader-figure-detail){max-width:72ch}',
        'html[data-sr-line-width=wide] body:not(.reader-figure-detail){max-width:100ch}',
        'html[data-sr-line-width=full] body:not(.reader-figure-detail){max-width:none;padding-left:clamp(22px,4vw,72px);padding-right:clamp(22px,4vw,72px)}',
        'html[data-sr-line-width=wide] figure,html[data-sr-line-width=full] figure{max-width:min(100%,110ch);margin-left:auto;margin-right:auto}',
      ].join('');
      document.head.append(lineWidthStyle);
    }
    document.documentElement.setAttribute('data-sr-line-width', value);
    return value;
  };
  if (!config?.figure_id) applyLineWidth(window.__readerLineWidth);
  // A live change keeps the place: the paragraph at the top of the viewport stays there (after a citation jump, the
  // reference stays in view and Back still returns to the place left).
  window.__scienceReaderSetLineWidth = mode => {
    if (config?.figure_id) return false;
    const before = document.documentElement.getAttribute('data-sr-line-width');
    // Measured now, before the new measure reflows the page (unlike a resize, which has reflowed already).
    const location = citationBack ? null : window.__scienceReaderLocation?.();
    const value = applyLineWidth(mode);
    if (value === before) return true;
    window.__scienceReaderFit();
    if (citationBack) showReference(citationBack.entry, true);
    else if (location) window.__scienceReaderRestore(location);
    return true;
  };

  // Citations, references and the paper line (device presentation for every
  // bundle version, like the layout above). Citations are wrapped in inline
  // spans and nothing else changes, so each block's text — and with it
  // selections, quotes and reading positions — is exactly the bundle's.
  // Elements the app adds outside blocks carry CHROME and are never selected.
  const CHROME = 'data-sr-chrome';
  const references = {entries: [], byID: new Map(), members: new Set(), index: null};
  let citationBack = null; // {origin:{location,cite}, entry, landing}

  // BEGIN CITATION MATCHER
  // Pure text logic, no DOM: parses bibliography entries and finds in-text
  // citations with their offsets. scripts/citation-harness.mjs evaluates this
  // section unchanged in Node to measure it on real bundles.
  const CitationMatcher = (() => {
    // Folded for comparison: lower case, no diacritics (combining; spacing, as OCR prints them in "Ce´sar"; and
    // letters NFKD keeps whole, "Søgaard", "Łukasz") and no hyphens, soft or hard: a surname split by
    // hyphenation ("Ten-nenholtz", "Ten- nenholtz") is the entry's "Tennenholtz", and "Lopez-Paz" matches "Lopez‐Paz".
    const LETTERS = {'ø': 'o', 'Ø': 'O', 'ł': 'l', 'Ł': 'L', 'đ': 'd', 'Đ': 'D', 'æ': 'ae', 'Æ': 'AE',
      'œ': 'oe', 'Œ': 'OE', 'ß': 'ss', 'ı': 'i', 'þ': 'th', 'Þ': 'Th'};
    const fold = value => value.replace(/[¨¯´¸˂-˟]/g, '')
      .replace(/[øØłŁđĐæÆœŒßıþÞ]/g, letter => LETTERS[letter])
      .normalize('NFKD').replace(/[̀-ͯ]/g, '').replace(/[‘’]/g, "'").replace(/[­‐‑-]/g, '').toLowerCase();
    // One surname word as a key: folded, with a hyphen's line break closed up ("Ten-\nnenholtz").
    const surnameKey = word => fold(word).replace(/\s+/g, '');
    // A hyphen at a line break inside a word: "Ten- nenholtz" (Mathpix keeps the break as a space), "Ten-\nnenholtz".
    const BROKEN_WORD = /(\p{L})[\-‐­]\s+(?!(?:and|et|und)\b)(?=\p{L})/gu;
    const BIBLIOGRAPHY = /^\s*(?:(?:[0-9]+|[ivx]+|[A-Z])(?:\.[0-9]+)*\.?\s+)?(?:references|bibliography|works\s+cited|literature\s+cited|references\s+cited)\s*:?\s*$/i;
    // A paragraph that starts an appendix ("Appendix", "B Experiment details") ends the bibliography.
    const APPENDIX = /^\s*(?:(?:[Aa]ppendi(?:x|ces)|APPENDI(?:X|CES)|[Ss]upplement(?:ary|al))\b[^.]{0,80}|[A-Z](?:\.\d+)*\.?\s+\p{Lu}[\p{L}\s\-:,]{2,60})$/u;
    const endsBibliography = text => APPENDIX.test(text) && !/(?:19|20)\d{2}/.test(text);
    // Years in an entry, not parts of arXiv IDs, DOIs, page ranges or volumes.
    const ENTRY_YEAR = /(?<![\d.:/\-–])((?:19|20)\d{2})([a-z])?(?![a-z\d\-–]|\.\d)/g;

    // Bibliography entries: each author's surname words (folded: lower case, no
    // diacritics) and key (the last surname word), the years and the author count.
    const PARTICLES = new Set(['van', 'von', 'de', 'der', 'den', 'del', 'della', 'di', 'da', 'du', 'dos', 'das', 'do', 'la', 'le', 'lo',
      'ten', 'ter', 'zu', 'bin', 'ibn', 'al', 'el', 'y', 'vander', 'vanden']);
    const GROUP_WORDS = new Set(['collaboration', 'team', 'consortium', 'group', 'project', 'authors', 'contributors', 'community', 'committee']);
    const INITIAL = /^(?:\p{Lu}\.?(?:-?\p{Lu}\.?){0,2}|\p{Lu}\p{Ll}\.)$/u; // "A.", "F", "J.-P.", "JA", "Ch."
    const NAME_WORD = /^(?:\p{Lu}|[dDlLoO]['’]\p{Lu})[\p{L}\p{M}'’\-­‐‑¨´ˆ-˝]*\p{L}$/u;
    const SUFFIX = /^(?:jr|sr|ii|iii|iv)\.?$/i;
    const kind = word => INITIAL.test(word) ? 'initial' : NAME_WORD.test(word) ? 'name'
      : PARTICLES.has(word.toLowerCase()) ? 'particle' : GROUP_WORDS.has(word.toLowerCase()) ? 'group' : SUFFIX.test(word) ? 'suffix' : null;
    const words = text => text.split(/\s+/).filter(Boolean);
    // One author from its words; null once the words aren't a name (the title has begun).
    const person = (parts, given) => {
      if (!parts.length || parts.length > 7 || parts.some(word => !kind(word))) return null;
      // An organisation in capitals is a name too ("XLA").
      if (parts.length === 1 && /^\p{Lu}{2,}$/u.test(parts[0])) return {words: [surnameKey(parts[0])], key: surnameKey(parts[0]), initials: ''};
      if (!parts.some(word => kind(word) === 'name')) return null;
      const surname = parts.filter(word => kind(word) !== 'initial' && kind(word) !== 'suffix').map(surnameKey);
      return surname.length ? {words: surname, key: surname[surname.length - 1], initials: given.map(word => fold(word)[0]).join('')} : null;
    };
    // "and" as small capitals come out of OCR too: "Leone, N., And Pfeifer, G.", "GELFOND, M. AND LIFSCHITZ, V.".
    const SEPARATOR = /\s*,\s*(?:(?:and|And|AND)\s+|&\s*)?|\s*;\s*|\s+(?:and|And|AND)\s+|\s*&\s*/;
    const ENTRY_ET_AL = /(?:^|\s+)(?:et\.?\s*al\.?|others)$/i;
    const parseAuthors = body => {
      // "P.Städter" → "P. Städter", "L.van der Maaten" → "L. van der Maaten", "Ten- nenholtz" → "Tennenholtz". The
      // list ends at a stop after a word (not an initial), a quote, a year or "In:".
      const text = body.slice(0, 700).replace(BROKEN_WORD, '$1').replace(/­/g, '')
        .replace(/(?<![\p{L}.])(\p{Lu})\.(?=\p{L}\p{Ll})/gu, '$1. ');
      const stop = text.search(/(?<=\p{L}\p{L})\.(?=\s|$)|["“”]|\(\s*(?:19|20)\d{2}|\s(?:19|20)\d{2}[a-z]?(?=[.,:;)]|\s|$)|:\s/u);
      const pieces = text.slice(0, stop >= 0 ? stop : 300).split(SEPARATOR).map(piece => piece.trim()).filter(Boolean);
      const authors = [];
      let etal = false;
      if (pieces.length && ENTRY_ET_AL.test(pieces[pieces.length - 1])) {
        etal = true;
        pieces[pieces.length - 1] = pieces[pieces.length - 1].replace(ENTRY_ET_AL, '');
        if (!pieces[pieces.length - 1]) pieces.pop();
      }
      if (!pieces.length) return {authors, etal};
      const first = words(pieces[0]), second = pieces.length > 1 ? words(pieces[1]) : [];
      const initialsOnly = list => list.length > 0 && list.every(word => INITIAL.test(word));
      // "Smith JA, Doe B" (Vancouver).
      const vancouver = first.length >= 2 && /^\p{Lu}{1,3}$/u.test(first[first.length - 1]) && NAME_WORD.test(first[0]);
      // "Vaswani, A., Shazeer, N., and Polosukhin, I." or "Duchi, John, Hazan, Elad, and Singer, Yoram".
      // A short surname in small capitals ("LI, X. AND WU, Y.") reads like initials on its own.
      const surnameFirst = !vancouver && second.length > 0 && first.length <= 4
        && first.every(word => ['name', 'particle'].includes(kind(word)) || (first.length === 1 && /^\p{Lu}{2,3}$/u.test(word) && initialsOnly(second)))
        && (initialsOnly(second) || (first.length === 1 && second.length <= 2 && second.every(word => kind(word) === 'name' || INITIAL.test(word))
          && pieces.length % 2 === 0 && pieces.filter(piece => words(piece).length === 1).length * 2 >= pieces.length));
      if (surnameFirst) {
        const initialsGiven = initialsOnly(second);
        for (let at = 0; at < pieces.length && authors.length < 60; at += 2) {
          const given = at + 1 < pieces.length ? words(pieces[at + 1]) : [];
          const leading = [];
          for (const word of given) {
            if (INITIAL.test(word) || (!initialsGiven && kind(word) === 'name')) leading.push(word); else break;
          }
          const author = person(words(pieces[at]), leading);
          if (!author) break;
          authors.push(author);
          if (leading.length < given.length) break; // The title begins after the last initials.
        }
      } else {
        for (const piece of pieces) {
          let parts = words(piece);
          if (vancouver && parts.length > 1 && /^\p{Lu}{1,3}$/u.test(parts[parts.length - 1])) parts = parts.slice(0, -1);
          const author = person(parts, vancouver ? [] : parts.slice(0, -1).filter(word => ['initial', 'name'].includes(kind(word))));
          if (!author || authors.length >= 60) break;
          authors.push(author);
        }
      }
      return {authors, etal};
    };
    const parseEntry = (raw, implicit = null) => {
      const text = raw.replace(/\s+/g, ' ').trim();
      if (text.length < 8 || text.length > 4000) return null;
      const marker = /^(?:\[([^[\]\s]{1,24})\]|(\d{1,4})\.(?=\s))\s*/.exec(text);
      let number = null, label = null;
      if (marker?.[2]) number = Number(marker[2]);
      else if (marker && /^\d{1,4}$/.test(marker[1])) number = Number(marker[1]);
      else if (marker && /\p{L}/u.test(marker[1])) label = marker[1];
      else if (implicit !== null) number = implicit;
      const body = marker ? text.slice(marker[0].length) : text;
      let years = [...body.matchAll(ENTRY_YEAR)].map(match => ({year: match[1], suffix: match[2] || ''}));
      const arxiv = !years.length && /arXiv:?\s?(\d{2})(\d{2})\.\d{4,5}/i.exec(body);
      if (arxiv) years = [{year: '20' + arxiv[1], suffix: ''}];
      // Something else under the heading (a note, a footnote): no key, no year.
      if (number === null && label === null && !years.length) return null;
      return {text: body, number, label, years, ...parseAuthors(body)};
    };
    const index = entries => {
      const result = {numbers: new Map(), labels: new Map(), byKey: new Map()};
      for (const entry of entries) {
        if (entry.number !== null) result.numbers.set(entry.number, result.numbers.has(entry.number) ? null : entry);
        if (entry.label !== null) result.labels.set(entry.label, result.labels.has(entry.label) ? null : entry);
        const key = entry.authors[0]?.key;
        if (key && entry.years.length) result.byKey.set(key, [...(result.byKey.get(key) || []), entry]);
      }
      result.numbered = [...result.numbers.values()].filter(Boolean).length >= 2;
      result.labelled = [...result.labels.values()].some(Boolean);
      result.authorYear = result.byKey.size > 0;
      return result;
    };

    // In-text citations. Numbered "[16]", "[3, 5]", "[1–4]" and labelled "[Bel+15]"
    // link only when every key is in the bibliography.
    const NUMBERED = /\[\s*\d{1,4}(?:\s*[-–—]\s*\d{1,4})?(?:\s*[,;]\s*\d{1,4}(?:\s*[-–—]\s*\d{1,4})?)*\s*\]/g;
    const LABELLED = /\[([^[\]\n]{2,200})\]/g;
    // Author–year: names that end just before a year — "Vaswani et al., 2017", "Stadter et al, 2021",
    // "Kingma & Ba, 2015", "Gu, Goel, and Ré 2022", "van der Maaten and Hinton (2008)", "Tjong Kim Sang
    // and De Meulder, 2003", "Y. Li et al. 2023", "BIG-bench collaboration, 2021" — and further years
    // of the same names: "(Peters et al., 2017, 2018a)", "(Wu et al., 2022a,b)".
    const PARTICLE = String.raw`(?:[Vv]an|[Vv]on|[Dd]e|[Dd]er|[Dd]en|[Dd]el|[Dd]ella|[Dd]i|[Dd]a|[Dd]u|[Dd]os|[Dd]as|[Ll]a|[Ll]e|[Tt]en|[Tt]er|zu|bin|al|el)`;
    // Small-capital (ACM) citations print "[GELFOND AND LIFSCHITZ 1991]", "[EITER ET AL. 1997b]": those words are no names.
    // A surname may be hyphenated at a line end ("Ten-nenholtz", "Ten- nenholtz", "Ten-\nnenholtz"), carry a soft
    // hyphen or a Unicode one, or a spacing accent from OCR ("Ce´sar").
    const CAPITAL = String.raw`(?!(?:And|AND|ET|AL)\b)(?:\p{Lu}|[dDlLoO]['’]\p{Lu})`
      + String.raw`(?:[\p{L}\p{M}'’\-­‐‑¨´ˆ-˝]|[\-‐­]\s{1,3}(?!(?:and|et|und)\b)(?=\p{L}))*\p{L}`;
    const GROUP = String.raw`(?:collaboration|team|consortium|group|project|authors|contributors|community)`;
    const NAME = String.raw`(?:\p{Lu}\.\s?){0,3}(?:${PARTICLE}\s+){0,3}${CAPITAL}(?:\s+(?:${PARTICLE}\s+){0,3}(?:${CAPITAL}|\p{Lu}\.?(?=\s+\p{Lu})))*(?:\s+${GROUP})?`;
    const AND = String.raw`(?:and|And|AND|&)`;
    const ET_AL = String.raw`\s*,?\s*(?:${AND}\s*)?(?:e[tl]\.?\s*al|ET\.?\s*AL)\b\.?(?:['’]s)?`;
    const LIST = String.raw`${NAME}(?:\s*,\s*${NAME})*(?:\s*,?\s*${AND}\s+${NAME})?(?:${ET_AL})?`;
    const BEFORE_YEAR = new RegExp(String.raw`(?<![\p{L}\p{N}'’\-])(${LIST})(\s*,?\s*(?:[(\[]\s*)?)$`, 'u');
    const LIST_ET_AL = new RegExp(ET_AL + '$', 'u');
    const NAME_IN_LIST = new RegExp(NAME, 'gu');
    const YEAR = /(?<![\p{L}\p{N}.\/:\-–])((?:19|20)\d{2})([a-z])?(?![\p{L}\p{N}]|[-–]\d|\.\d)/gu;
    const MORE_SUFFIX = /^\s*,\s*([a-z])(?![\p{L}\p{N}])/u;
    const endsWith = (list, tail) => tail.length <= list.length && tail.every((word, i) => list[list.length - tail.length + i] === word);
    // The names of a cited list, each with its folded surname words and their offsets.
    const names = (list, offset) => [...list.replace(LIST_ET_AL, '').matchAll(NAME_IN_LIST)].map(match => {
      const name = {words: [], starts: [], initials: ''};
      let last = null;
      // A word broken by a hyphen and a line ("Ten- nenholtz") is one word.
      for (const word of match[0].matchAll(/(?:\S*?[\-‐­]\s{1,3}(?=\p{L}))*\S+/gu)) {
        if (/^(?:\p{Lu}\.?){1,2}$/u.test(word[0]) || /^(?:Jr|Sr|II|III|IV)\.?$/.test(word[0])) {
          if (!name.words.length) name.initials += fold(word[0])[0];
          last = word;
          continue;
        }
        name.words.push(surnameKey(word[0])); name.starts.push(offset + match.index + word.index);
      }
      // A two-letter surname in capitals ("[LI AND WU 2020]") is no pair of initials.
      if (!name.words.length && last && /^\p{Lu}{2}$/u.test(last[0])) {
        name.words.push(surnameKey(last[0])); name.starts.push(offset + match.index + last.index);
        name.initials = name.initials.slice(0, -1);
      }
      return name;
    }).filter(name => name.words.length);
    // The entry a name–year pair cites: first author (the longest matching end of
    // the cited name, so "Following Vaswani" is "Vaswani"), year, later names in
    // order, author count ("et al." or not), initials, suffix letter, entry order.
    const resolve = (index, cited, etal, year, suffix) => {
      const first = cited[0];
      const keyed = index.byKey.get(first.words[first.words.length - 1]) || [];
      let pool = [], used = first.words.length;
      for (let n = first.words.length; n >= 1 && !pool.length; n -= 1) {
        pool = keyed.filter(entry => endsWith(entry.authors[0].words, first.words.slice(-n)));
        used = n;
      }
      pool = pool.filter(entry => entry.years.some(value => value.year === year) && (() => {
        let at = 0;
        return cited.slice(1).every(name => {
          const found = entry.authors.findIndex((author, i) => i > at && author.key === name.words[name.words.length - 1]);
          at = found;
          return found > 0;
        });
      })());
      const narrow = test => { const kept = pool.filter(test); if (kept.length) pool = kept; };
      // "Qin, W. Sun, et al.": the names cited are the first authors, in their places.
      if (pool.length > 1) narrow(entry => cited.every((name, i) => entry.authors[i]?.key === name.words[name.words.length - 1]));
      if (pool.length > 1) narrow(entry => etal ? entry.etal || entry.authors.length > cited.length : !entry.etal && entry.authors.length === cited.length);
      if (pool.length > 1 && etal && cited.length === 1) narrow(entry => entry.etal || entry.authors.length >= 3);
      // "J. Ba et al." is Jimmy Ba, not Jimmy Lei Ba (cited "J. L. Ba").
      if (pool.length > 1 && first.initials) narrow(entry => entry.authors[0].initials.startsWith(first.initials[0]));
      if (pool.length > 1 && first.initials) narrow(entry => entry.authors[0].initials === first.initials);
      const suffixed = entry => entry.years.some(value => value.year === year && value.suffix);
      if (suffix) {
        const exact = pool.filter(entry => entry.years.some(value => value.year === year && value.suffix === suffix));
        const position = suffix.charCodeAt(0) - 97;
        if (exact.length) pool = exact;
        else if (pool.some(suffixed)) pool = [];
        // The bibliography prints "2020" where the text cites "2020a", "2020b": the letters follow entry order.
        else if (pool.length > 1) pool = position < pool.length ? [pool[position]] : [];
      } else if (pool.length > 1) narrow(entry => !suffixed(entry));
      // The same entry printed twice.
      if (pool.length > 1 && pool.every(entry => fold(entry.text).slice(0, 120) === fold(pool[0].text).slice(0, 120))) pool = [pool[0]];
      return {entry: pool.length === 1 ? pool[0] : null, status: pool.length === 1 ? 'linked' : pool.length ? 'ambiguous' : 'unmatched',
        start: first.starts[first.words.length - used]};
    };
    const authorYear = (text, index) => {
      const out = [], tokens = [];
      for (const match of text.matchAll(YEAR)) {
        if (match[2] === 's' && match[1].endsWith('0')) continue; // "the 1990s"
        tokens.push({start: match.index, end: match.index + match[0].length, year: match[1], suffix: match[2] || ''});
        for (let rest = match.index + match[0].length, more; match[2] && (more = MORE_SUFFIX.exec(text.slice(rest)));) {
          const at = rest + more[0].length - 1;
          tokens.push({start: at, end: at + 1, year: match[1], suffix: more[1]});
          rest = at + 1;
        }
      }
      let group = null, boundary = 0;
      const finish = () => {
        // "Vaswani et al. (2017)": a narrative citation with one year includes its closing parenthesis.
        if (group?.narrative && group.links.length === 1 && /^[)\]]/.test(text.slice(group.links[0].end))) group.links[0].end += 1;
        group = null;
      };
      for (const token of tokens) {
        if (group && /^\s*[,;]?\s*$/.test(text.slice(boundary, token.start))) {
          const result = resolve(index, group.cited, group.etal, token.year, token.suffix);
          const link = {start: token.start, end: token.end, entry: result.entry, status: result.status, label: `${group.label}, ${token.year}${token.suffix}`};
          out.push(link); group.links.push(link);
          boundary = token.end;
          continue;
        }
        finish();
        const from = Math.max(boundary, token.start - 200);
        boundary = token.end;
        const match = BEFORE_YEAR.exec(text.slice(from, token.start));
        if (!match) continue;
        const listStart = from + match.index, all = names(match[1], listStart);
        const etal = LIST_ET_AL.test(match[1]), narrative = /[(\[]/.test(match[2]);
        const before = text.slice(0, listStart);
        const inside = Math.max(before.lastIndexOf('('), before.lastIndexOf('[')) > Math.max(before.lastIndexOf(')'), before.lastIndexOf(']'));
        if (!all.length || !(narrative || inside || etal)) continue;
        // A leading word that is no author ("BiRNN, Schuster and Paliwal", "ELMo and Radford et al.") is dropped.
        let cited = all, result = resolve(index, all, etal, token.year, token.suffix);
        for (let drop = 1; result.status === 'unmatched' && drop < all.length; drop += 1) {
          const dropped = all[drop - 1];
          if (index.byKey.has(dropped.words[dropped.words.length - 1])) break;
          const retry = resolve(index, all.slice(drop), etal, token.year, token.suffix);
          if (retry.status !== 'unmatched') { result = retry; cited = all.slice(drop); }
        }
        const link = {start: result.start, end: token.end, entry: result.entry, status: result.status};
        group = {cited, etal, narrative, links: [link], label: text.slice(result.start, token.start).replace(/[\s,(\[]+$/, '')};
        out.push(link);
      }
      finish();
      return out;
    };
    // Every citation in a text, in order and not overlapping; status is
    // 'linked' (entry set), or for author–year 'ambiguous' / 'unmatched'.
    const scan = (text, index) => {
      const links = [];
      const keyed = (inner, offset, pattern) => [...inner.matchAll(pattern)].map(token =>
        ({start: offset + token.index, end: offset + token.index + token[0].length, value: token[0]}));
      if (index.numbered) for (const match of text.matchAll(NUMBERED)) {
        const tokens = keyed(match[0], match.index, /\d{1,4}/g);
        if (!tokens.every(token => index.numbers.get(Number(token.value)))) continue;
        // "[1–4]": both ends exist and form a short increasing range.
        let at = 0, valid = true;
        for (const piece of match[0].slice(1, -1).split(/[,;]/)) {
          const count = (piece.match(/\d{1,4}/g) || []).length;
          if (count === 2) {
            const from = Number(tokens[at].value), to = Number(tokens[at + 1].value);
            if (!(from < to && to - from <= 200)) valid = false;
          }
          at += count;
        }
        if (!valid) continue;
        tokens.forEach((token, i) => links.push({
          start: i === 0 ? match.index : token.start, end: i === tokens.length - 1 ? match.index + match[0].length : token.end,
          entry: index.numbers.get(Number(token.value)), status: 'linked', label: 'Reference ' + token.value,
        }));
      }
      if (index.labelled) for (const match of text.matchAll(LABELLED)) {
        const tokens = keyed(match[1], match.index + 1, /[^,;\s][^,;]*?(?=\s*(?:[,;]|$))/g);
        if (!tokens.length || !tokens.every(token => index.labels.get(token.value))) continue;
        tokens.forEach((token, i) => links.push({
          start: i === 0 ? match.index : token.start, end: i === tokens.length - 1 ? match.index + match[0].length : token.end,
          entry: index.labels.get(token.value), status: 'linked', label: 'Reference ' + token.value,
        }));
      }
      if (index.authorYear) links.push(...authorYear(text, index));
      // Links first; an unresolved author–year citation is reported only where nothing is linked.
      const ordered = [...links.filter(link => link.entry), ...links.filter(link => !link.entry)];
      const kept = [];
      for (const link of ordered) if (!kept.some(other => link.start < other.end && other.start < link.end)) kept.push(link);
      return kept.sort((a, b) => a.start - b.start);
    };
    return {BIBLIOGRAPHY, endsBibliography, parseEntry, index, scan};
  })();
  // END CITATION MATCHER

  // BEGIN FIGURE REFERENCES
  // Pure text logic, no DOM: the labels a caption gives its figure, table or algorithm ("Figure 3:", "Fig. 2.",
  // "Table A. 1", "TABLE II", "Algorithm 1 Training") and the references to them in the text ("Fig. 1",
  // "Figure 3(b)", "Figs. 2 and 3", "Tables 7–10", "Algorithm 1"), each number its own link. Kinds are read from
  // the label's word, not the element (Mathpix prints some tables as images and some figures as tables).
  // scripts/citation-harness.mjs evaluates this section unchanged in Node to measure it on real bundles.
  const FigureReferences = (() => {
    const NUMBER = String.raw`(?:[A-Z]\.?\s?\d{1,3}|\d{1,3}(?:\.\d{1,2})?|[IVX]{1,5}(?![\p{L}]))(?![\p{N}])(?!\.\d)`;
    const KIND = {figure: 'Figure', table: 'Table', algorithm: 'Algorithm'};
    const WORDS = {
      figure: String.raw`[Ff]igures?|FIGURES?|[Ff]igs?\.|FIGS?\.|[Ff]ig(?=\s*\d)`,
      table: String.raw`[Tt]ables?|TABLES?|[Tt]abs?\.|TABS?\.`,
      algorithm: String.raw`[Aa]lgorithms?|ALGORITHMS?|[Aa]lgs?\.|[Aa]lgo\.`,
    };
    const WORD = String.raw`(?:(${WORDS.figure})|(${WORDS.table})|(${WORDS.algorithm}))`;
    const kindOf = match => match[1] ? 'figure' : match[2] ? 'table' : 'algorithm';
    // "A. 1" and "A.1" are "A1"; a Roman numeral is kept as printed.
    const normal = number => number.replace(/\s/g, '').replace(/^([A-Z])\./, '$1');
    const key = (kind, number) => kind + ' ' + normal(number);
    // A caption's own label at its start (math is U+FFFC), and further labels with a colon inside it
    // ("Figure 3: Church samples. ￼ Figure 4: Bedroom samples."). A label is followed by ":", ".", "|", the end, or
    // a word that doesn't start in lower case ("Table 1 Parameter counts"; "Table 5 lists …" is prose); a paragraph
    // that is a caption needs ":", "." or "|" ("Fig. 4 shows …", "Figure 2 The model" are prose).
    const START = new RegExp(String.raw`^[\s⁣]*${WORD}[^\S\n]*(${NUMBER})[a-z]?(?:[^\S\n]*([:.|])|[^\S\n]*$|[^\S\n]*\n|[^\S\n]+(?=[^\s\p{Ll}])|(?=[\p{Lu}\uFFFC]))`, 'u');
    const INNER = new RegExp(String.raw`(?<=[.;)\]￼][^\S\n]*|\n)${WORD}[^\S\n]*(${NUMBER})[^\S\n]*:`, 'gu');
    const labels = (text, paragraph = false) => {
      const found = [], first = START.exec(text);
      if (first && (!paragraph || first[5])) found.push({kind: kindOf(first), number: normal(first[4]), primary: true});
      if (paragraph) return found;
      for (const match of text.matchAll(INNER)) {
        const label = {kind: kindOf(match), number: normal(match[4]), primary: false};
        if (!found.some(other => other.kind === label.kind && other.number === label.number)) found.push(label);
      }
      return found;
    };
    // References. A subfigure ("3(b)", "3b", "3a–c") belongs to its number's link; further numbers follow "and",
    // "or", "&" or a range ("Figures 2–4" links 2 and 4), and after a plural word also a comma ("Figs. 2, 3, and 5").
    const SUB = String.raw`(?:[^\S\n]?\([a-z](?:\s?[,\-–]\s?[a-z])*\)|[a-z](?:[\-–][a-z])?(?![\p{L}\p{N}]))?`;
    const REFERENCE = new RegExp(String.raw`(?<![\p{L}\p{N}])${WORD}[^\S\n]?(?:~| )?\s{0,2}(${NUMBER})(${SUB})`, 'gu');
    const MORE = new RegExp(String.raw`([^\S\n]*(?:,[^\S\n]*(?:(?:and|or|&)[^\S\n]+)?|(?:and|or|&)[^\S\n]+|[\-–—][^\S\n]*|to[^\S\n]+))(${NUMBER})(${SUB})`, 'uy');
    const scan = text => {
      const out = [];
      REFERENCE.lastIndex = 0;
      for (let match; (match = REFERENCE.exec(text));) {
        const kind = kindOf(match), plural = /s\.?$|S$/.test(match[1] || match[2] || match[3]);
        let previous = {start: match.index, end: match.index + match[0].length, kind, number: normal(match[4]),
          label: `${KIND[kind]} ${normal(match[4])}${match[5].replace(/\s/g, '')}`};
        out.push(previous);
        for (let more; (MORE.lastIndex = previous.end, more = MORE.exec(text));) {
          const joint = more[1].trim();
          if (joint.startsWith(',') && !plural) break; // "In Table 2, 3 runs …"
          if (/^(?:[\-–—]|to)$/.test(joint)) {
            const from = Number(previous.number), to = Number(normal(more[2]));
            if (!(from < to && to - from <= 20)) break;
          }
          const start = previous.end + more[1].length, number = normal(more[2]);
          previous = {start, end: previous.end + more[0].length, kind, number, label: `${KIND[kind]} ${number}${more[3].replace(/\s/g, '')}`};
          out.push(previous);
        }
        REFERENCE.lastIndex = previous.end;
      }
      return out;
    };
    return {labels, scan, key};
  })();
  // END FIGURE REFERENCES

  // A paragraph of references holds one entry per line; a line starting in
  // lower case continues the previous entry, unless it starts with a surname
  // ("van der Maaten, L. and …", "de Freitas, N., …").
  const PARTICLE_SURNAME = /^(?:(?:van|von|de|der|den|del|della|di|da|du|dos|das|la|le|ten|ter)\s+){1,3}\p{Lu}[\p{L}'’\-]+,\s/u;
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
      if (lines.length && /^[a-z(]/.test(text) && !PARTICLE_SURNAME.test(text)) lines[lines.length - 1].setEnd(value.endContainer, value.endOffset);
      else lines.push(value);
    }
    return lines;
  };
  const addReference = (element, range, implicit) => {
    const parsed = CitationMatcher.parseEntry(range.toString(), implicit);
    if (!parsed) return;
    const id = 'ref-' + (parsed.number ?? parsed.label ?? references.entries.length + 1);
    const entry = {...parsed, id, element, range};
    if (references.byID.has(id)) entry.id = id + '-' + (references.entries.length + 1);
    references.entries.push(entry); references.byID.set(entry.id, entry);
    element.setAttribute('data-sr-reference', entry.id);
  };
  const collectReferences = () => {
    const heading = [...document.querySelectorAll('h1,h2,h3,h4,h5,h6')].find(element => CitationMatcher.BIBLIOGRAPHY.test(element.textContent));
    if (!heading) return;
    const level = Number(heading.tagName[1]);
    for (let node = heading.nextElementSibling; node; node = node.nextElementSibling) {
      if (/^H[1-6]$/.test(node.tagName)) { if (Number(node.tagName[1]) <= level) break; continue; }
      if (node.matches(`[${CHROME}],.reader-footnotes,figure,.reader-table,pre,hr`)) continue;
      if (node.matches('p') && CitationMatcher.endsBibliography(node.textContent)) break;
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

  // BEGIN NAMED REFERENCES
  // arXiv often links only the number: “Figure <a>1</a>”, “Sec.&nbsp;<a>2.2</a>”, “Appendix <a>A</a>”, “§<a>3</a>”.
  // The name before the link (owner, build 71: “the entire Figure 1 should be a link (similar for Tables, Equations
  // etc)”), as words a paper uses for its own numbered parts.
  const NamedReferences = (() => {
    const NAME = String.raw`(?:Figures?|Figs?\.?|Tables?|Tabs?\.?|Equations?|Eqs?\.?|Algorithms?|Algs?\.?|Sections?|Secs?\.?|§§?`
      + String.raw`|Appendix|Appendices|Apps?\.|Lemmas?|Theorems?|Thms?\.|Corollary|Corollaries|Propositions?|Props?\.`
      + String.raw`|Definitions?|Defs?\.|Remarks?|Examples?|Assumptions?)`;
    // The name at the very end of the text before the link (then spaces, no-break spaces, an opening parenthesis).
    const PREFIX = new RegExp(String.raw`(?<![\p{L}\p{N}])(${NAME}[\s(]*)$`, 'iu');
    // The link's own text: a number (“1”, “2.2”, “A1”), an appendix letter (“A”, “A.1”) or a Roman numeral.
    const TARGET = /^[\s(]*(?:[A-Z]?\d|[A-Z](?:\.\d+)*[\s)]*$|[IVX]+[\s)]*$)/;
    return {
      /** Where the reference's name starts in `before` (the text just before a link reading `link`), or -1. */
      start(before, link) {
        if (!TARGET.test(link)) return -1;
        const match = PREFIX.exec(before);
        return match ? match.index : -1;
      },
    };
  })();
  // END NAMED REFERENCES

  // In-text citations are found in each block's text as a whole, so one may
  // span inline elements or a line break; each piece of it is wrapped in place.
  // Extend the paper's existing internal link over the adjacent name without changing text, target, block identity or
  // navigation. The name may be its own inline element (“<span>Sec.</span>&nbsp;<a>2.2</a>”, build 71).
  const expandNamedReferences = () => {
    for (const anchor of document.querySelectorAll('a[href^="#"]')) {
      const before = anchor.previousSibling;
      let moved = '';
      if (before?.nodeType === Node.TEXT_NODE && before.data.trim().replace(/\(/g, '')) {
        const at = NamedReferences.start(before.data, anchor.textContent);
        if (at < 0) continue;
        const prefix = before.splitText(at);
        moved = prefix.data;
        anchor.prepend(prefix);
      } else {
        // Only spaces (or nothing) between the link and an inline element holding just the name.
        const spacer = before?.nodeType === Node.TEXT_NODE ? before : null;
        const element = spacer ? spacer.previousSibling : before;
        if (element?.nodeType !== Node.ELEMENT_NODE || !element.matches('span,em,i,b,strong,small')
          || element.querySelector('a,math,img,svg,[data-reader-block],[data-reader-equation]')) continue;
        const text = element.textContent + (spacer?.data ?? '');
        if (NamedReferences.start(text, anchor.textContent) !== 0) continue;
        moved = text;
        if (spacer) anchor.prepend(spacer);
        anchor.prepend(element);
      }
      // If the opening parenthesis moved into the anchor, include its matching close.
      const after = anchor.nextSibling;
      if (moved.includes('(') && after?.nodeType === Node.TEXT_NODE && after.data.startsWith(')')) {
        anchor.append(document.createTextNode(')')); after.data = after.data.slice(1);
      }
    }
  };
  const SKIPPED = `math,.reader-equation,pre,code,a,h1,h2,h3,h4,h5,h6,.sr-cite,[${CHROME}]`;
  const BREAKS = /^(?:TD|TH|TR|TABLE|THEAD|TBODY|LI|UL|OL|P|DIV|FIGCAPTION|FIGURE|BLOCKQUOTE|IMG)$/;
  const inBibliography = node => {
    for (let element = node.parentElement; element && element !== document.body; element = element.parentElement) {
      if (references.members.has(element)) return true;
    }
    return false;
  };
  // A block's text with the text node at each offset; skipped elements and
  // cell or item boundaries become U+2063, which no citation spans.
  const blockText = block => {
    let text = '';
    const parts = [];
    const walk = element => {
      for (let node = element.firstChild; node; node = node.nextSibling) {
        if (node.nodeType === Node.TEXT_NODE) { parts.push({node, start: text.length}); text += node.data; continue; }
        if (node.nodeType !== Node.ELEMENT_NODE) continue;
        if (node.matches(SKIPPED) || node.hasAttribute('data-reader-block') || references.members.has(node)) { text += '⁣'; continue; }
        if (node.tagName === 'BR') { text += '\n'; continue; }
        const breaks = BREAKS.test(node.tagName);
        if (breaks) text += '⁣';
        walk(node);
        if (breaks) text += '⁣';
      }
    };
    walk(block);
    return {text, parts};
  };
  const wrapCitations = (parts, links) => {
    const first = new Set();
    for (const {node, start} of parts) {
      const end = start + node.data.length;
      const pieces = links.filter(link => link.start < end && link.end > start)
        .map(link => ({from: Math.max(link.start, start) - start, to: Math.min(link.end, end) - start, link}))
        .filter(piece => node.data.slice(piece.from, piece.to).trim());
      if (!pieces.length) continue;
      const fragment = document.createDocumentFragment();
      let cursor = 0;
      for (const {from, to, link} of pieces) {
        if (from > cursor) fragment.append(node.data.slice(cursor, from));
        const span = document.createElement('span');
        // A citation split by an inline element is one link: only its first piece takes focus.
        span.className = 'sr-cite'; span.setAttribute('role', 'link'); span.tabIndex = first.has(link) ? -1 : 0;
        // A figure, table or algorithm reference looks and behaves like a citation (FIGURE REFERENCES).
        if (link.figure) { span.classList.add('sr-figref'); span.setAttribute('data-sr-figure', link.figure); }
        else span.setAttribute('data-sr-cite', link.entry.id);
        if (link.label) span.setAttribute('aria-label', link.label);
        span.textContent = node.data.slice(from, to);
        fragment.append(span); cursor = to; first.add(link);
      }
      if (cursor < node.data.length) fragment.append(node.data.slice(cursor));
      node.replaceWith(fragment);
    }
  };
  const linkCitations = () => {
    if (!references.entries.length) return;
    references.index = CitationMatcher.index(references.entries);
    for (const block of document.querySelectorAll('[data-reader-block]')) {
      if (block.closest(SKIPPED) || block.matches('.sr-toc') || references.members.has(block) || inBibliography(block)) continue;
      const {text, parts} = blockText(block);
      if (!/[\d[]/.test(text)) continue;
      const links = CitationMatcher.scan(text, references.index).filter(link => link.entry);
      if (links.length) wrapCitations(parts, links);
    }
  };

  // Figures, tables and algorithms the text refers to ("Fig. 1", "Table 2", "Algorithm 1"), found by the labels
  // their own captions print. A label that two different elements carry links nowhere rather than to the wrong one.
  // id → {element, label, detail}: `detail` targets (a figure, a table, an algorithm's code block) open in the app's
  // figure view with "Go to figure"; a caption that is only a paragraph is jumped to directly, with Back.
  const figureTargets = new Map();
  // The figure views the app may open: the bundle's figures, tables and code blocks (fixtures: any such element).
  const detailIDs = new Set(config ? [...figureIDs, ...config.blocks.filter(block => block.kind === 'table' || block.kind === 'code').map(block => block.id)] : []);
  const DETAIL = 'figure,.reader-table,pre';
  // A bibliography entry (or a list of them). Text after the references that the bibliography's walk took in (an
  // appendix without its own heading) is still read for figures.
  const bibliographyEntry = element => !!element.closest('[data-sr-reference]') || !!element.querySelector('[data-sr-reference]');
  let figureLink = null; // {id, link}: the reference last tapped, flashed on Back after "Go to figure".
  const captionText = node => node.nodeType === Node.TEXT_NODE ? node.data : node.nodeType !== Node.ELEMENT_NODE ? ''
    : node.matches('[data-reader-equation],math') ? '￼' : node.tagName === 'BR' ? '\n' : [...node.childNodes].map(captionText).join('');
  // The same figure printed twice (Mistral's Figure 4) is one target.
  const sameCaption = list => list.every(item => item.caption.replace(/\s+/g, ' ').trim().slice(0, 160) === list[0].caption.replace(/\s+/g, ' ').trim().slice(0, 160));
  const collectFigureTargets = () => {
    const labelled = [];
    const consider = (element, caption, paragraph = false) => {
      if (!element?.id) return;
      const detail = !paragraph && element.matches(DETAIL) && (!config || detailIDs.has(element.id));
      for (const label of FigureReferences.labels(caption, paragraph)) {
        labelled.push({element, caption, detail, rank: paragraph ? 2 : label.primary ? 0 : 1, key: FigureReferences.key(label.kind, label.number),
          label: `${{figure: 'Figure', table: 'Table', algorithm: 'Algorithm'}[label.kind]} ${label.number}`});
      }
    };
    const figures = config ? config.figures.map(figure => document.getElementById(figure.id)) : [...document.querySelectorAll('figure[id]')];
    for (const figure of figures) {
      const caption = figure?.querySelector('figcaption');
      consider(figure, caption ? captionText(caption) : config?.figures.find(value => value.id === figure?.id)?.caption ?? '');
    }
    for (const table of document.querySelectorAll('.reader-table[id]')) {
      consider(table, [...table.querySelectorAll('.reader-caption')].map(captionText).join('\n'));
    }
    // An algorithm is a code block whose first line is its label ("Algorithm 1 Training").
    for (const code of document.querySelectorAll('pre[id]')) consider(code, captionText(code).trimStart().split('\n')[0]);
    const unlabelled = element => element && element.matches(DETAIL) && !labelled.some(item => item.element === element)
      && (!config || detailIDs.has(element.id));
    // A caption Mathpix kept as its own paragraph ("Table 6: Ablations …"): its unlabelled neighbour when only one side
    // has one (Mamba's Table 6), otherwise the paragraph itself.
    for (const paragraph of document.querySelectorAll('p[data-reader-block]')) {
      if (bibliographyEntry(paragraph) || paragraph.matches('.sr-toc,.reader-caption') || paragraph.closest(`${DETAIL},li,[${CHROME}]`)) continue;
      const caption = captionText(paragraph);
      if (!FigureReferences.labels(caption, true).length) continue;
      const neighbours = [paragraph.previousElementSibling, paragraph.nextElementSibling].filter(unlabelled);
      if (neighbours.length === 1) consider(neighbours[0], caption);
      else consider(paragraph, caption, true);
    }
    // Each key: the elements whose caption starts with it, else those that name it after a colon inside a
    // caption, else caption paragraphs. Several different ones → no link.
    const byKey = new Map();
    for (const item of labelled) byKey.set(item.key, [...(byKey.get(item.key) || []), item]);
    const resolved = new Map();
    for (const [key, items] of byKey) {
      const best = items.filter(item => item.rank === Math.min(...items.map(other => other.rank)));
      const distinct = [...new Set(best.map(item => item.element))];
      if (distinct.length === 1 || sameCaption(best)) resolved.set(key, best[0]);
    }
    return resolved;
  };
  const linkFigureReferences = () => {
    const targets = collectFigureTargets();
    if (!targets.size) return;
    for (const block of document.querySelectorAll('[data-reader-block]')) {
      if (block.closest(SKIPPED) || block.matches('.sr-toc') || bibliographyEntry(block)) continue;
      const {text, parts} = blockText(block);
      if (!/[\dIVX]/.test(text)) continue;
      const links = [];
      for (const found of FigureReferences.scan(text)) {
        const target = targets.get(FigureReferences.key(found.kind, found.number));
        // A caption's own label, or a mention of the figure inside it, is not a link to itself.
        if (!target || target.element === block || target.element.contains(block) || block.contains(target.element)) continue;
        figureTargets.set(target.element.id, target);
        links.push({...found, figure: target.element.id});
      }
      if (links.length) wrapCitations(parts, links);
    }
  };
  // A tapped figure reference: the app shows the figure (or table, or algorithm) with its caption and "Go to figure";
  // a caption that is only a paragraph is gone to directly, with Back.
  const openFigureReference = link => {
    const target = figureTargets.get(link.getAttribute('data-sr-figure'));
    if (!target) return;
    if (target.detail) {
      figureLink = {id: target.element.id, link};
      post({type: 'figureref', manifest_sha256: manifest, id: target.element.id, label: target.label});
      return;
    }
    const range = document.createRange(); range.selectNodeContents(target.element);
    jumpToReference({id: target.element.id, range}, link);
  };
  // BEGIN CONTENTS PARSER
  // Pure text logic, no DOM: a paper's own table of contents (or list of figures/tables), which
  // Mathpix keeps as one paragraph of lines like "2.1 Syntax ..... 3". U+FFFC stands for an inline
  // element (an equation). scripts/citation-harness.mjs reports every block it formats.
  const ContentsParser = (() => {
    const CAPTION_WORDS = String.raw`(?:table\s+of\s+contents|contents|list\s+of\s+(?:figures|tables|algorithms|listings))`;
    const CAPTION = new RegExp(String.raw`^\s*${CAPTION_WORDS}\s*:?(?=\s|$)`, 'i');
    const CAPTION_ONLY = new RegExp(String.raw`^\s*(?:[0-9]+\.?\s+)?${CAPTION_WORDS}\s*:?\s*$`, 'i');
    // "2.1", "3.1.1", "A", "G.1" ("G. 1" as OCR prints it), with an optional trailing period.
    const NUMBER = /^(\d{1,2}(?:\.\d{1,2}){0,4}|[A-Z](?:\s?\.\s?\d{1,2}){0,4})\.?(?=\s+\S)/u;
    // A dot leader (". . . .", ".....", "…", "·····") and the page: arabic, or lower-case roman.
    const LEADER = /(\s*(?:(?:\.\s*){3,}|(?:…\s*)+|(?:·\s*){3,}))(\d{1,4}|[ivxlc]{1,7})(?=\s|$)/gu;
    const normalNumber = value => value.replace(/\s+/g, '').toUpperCase();
    const depthOf = value => Math.min(4, (value.match(/\./g) || []).length);
    const numbered = (text, start, end) => {
      const match = NUMBER.exec(text.slice(start, end));
      return match ? {start, end: start + match[1].length, value: normalNumber(match[1])} : null;
    };
    const pageValue = value => /^\d+$/.test(value) ? Number(value) : null;
    // Most pages run forwards (OCR may garble one).
    const forwards = entries => {
      const pages = entries.map(entry => entry.page.number).filter(value => value !== null);
      let back = 0;
      for (let i = 1; i < pages.length; i += 1) if (pages[i] < pages[i - 1]) back += 1;
      return back * 5 <= Math.max(1, pages.length - 1);
    };
    // Section numbers in reading order: the next sibling, a first child, or the next of an
    // ancestor ("2.3" → "3"); letters start appendices.
    const follows = (previous, next) => {
      const a = previous.split('.'), b = next.split('.');
      const step = (x, y) => /^\d+$/.test(x) && /^\d+$/.test(y) ? Number(y) === Number(x) + 1
        : /^[A-Z]$/.test(x) && /^[A-Z]$/.test(y) ? y.charCodeAt(0) === x.charCodeAt(0) + 1 : /^\d+$/.test(x) && y === 'A';
      if (b.length === a.length + 1 && a.every((part, i) => part === b[i])) return b[b.length - 1] === '1' || b[b.length - 1] === '0';
      if (b.length > a.length) return false;
      return b.slice(0, -1).every((part, i) => part === a[i]) && step(a[b.length - 1], b[b.length - 1]);
    };
    const leaderEntries = (text, start) => {
      const entries = [];
      let cursor = start;
      LEADER.lastIndex = start;
      for (let match; (match = LEADER.exec(text));) {
        const lead = text.slice(cursor, match.index).search(/\S/);
        if (lead < 0) return null;
        const from = cursor + lead, label = text.slice(from, match.index);
        if (label.length > 200 || !/[\p{L}￼]/u.test(label) || (label.match(/\n/g) || []).length > 1) return null;
        const pageStart = match.index + match[1].length, end = match.index + match[0].length;
        entries.push({start: from, end, separator: text.slice(cursor, from), number: numbered(text, from, match.index),
          leader: {start: match.index, end: pageStart}, page: {start: pageStart, end, value: match[2], number: pageValue(match[2])}});
        cursor = end;
      }
      return text.slice(cursor).trim() ? null : entries;
    };
    // "1 Introduction 1" without leaders, one per line or run together: only after a "Contents"
    // caption, with section numbers in order and pages running forwards.
    const plainEntries = (text, start) => {
      const lines = /\n/.test(text.slice(start).trim());
      const NUM = String.raw`(?:\d{1,2}(?:\.\d{1,2}){0,4}|[A-Z](?:\s?\.\s?\d{1,2}){0,4})`;
      const ENTRY = lines
        ? new RegExp(String.raw`[^\S\n]*\n?[^\S\n]*((?:${NUM}\.?[^\S\n]+)?)([^\n]*?\S)([^\S\n]+)(\d{1,4})(?=[^\S\n]*(?:\n|$))`, 'uy')
        : new RegExp(String.raw`\s*(${NUM}\.?\s+)(.+?\S)(\s+)(\d{1,4})(?=\s+${NUM}\.?\s+\S|\s*$)`, 'uy');
      const entries = [];
      ENTRY.lastIndex = start;
      let cursor = start;
      for (let match; cursor < text.length && (match = ENTRY.exec(text));) {
        const end = match.index + match[0].length, pageStart = end - match[4].length;
        const from = pageStart - match[3].length - match[2].length - match[1].length;
        if (match[2].length > 200 || !/[\p{L}￼]/u.test(match[2])) return null;
        entries.push({start: from, end, separator: text.slice(cursor, from), number: match[1] ? numbered(text, from, pageStart) : null,
          leader: {start: pageStart - match[3].length, end: pageStart}, page: {start: pageStart, end, value: match[4], number: Number(match[4])}});
        cursor = end;
      }
      if (text.slice(cursor).trim() || entries.length < 4) return null;
      const numbers = entries.filter(entry => entry.number).map(entry => entry.number.value);
      if (numbers.length * 4 < entries.length * 3 || (!lines && numbers.length < entries.length)) return null;
      for (let i = 1; i < numbers.length; i += 1) if (!follows(numbers[i - 1], numbers[i])) return null;
      return entries.every((entry, i) => !i || entry.page.number >= entries[i - 1].page.number) ? entries : null;
    };
    // The entries of a contents block, or null when the text is anything else.
    const parse = (text, captioned) => {
      if (text.length > 20000) return null;
      const head = CAPTION.exec(text);
      const caption = head ? {start: text.search(/\S/), end: head[0].length} : null;
      const start = caption ? caption.end : 0;
      const rest = text.slice(start);
      let entries = leaderEntries(text, start);
      if (entries && entries.length) {
        // Several entries, each on its own line (a wrapped title may take two), or run together.
        if (entries.length < 3 || !forwards(entries)) return null;
        if (/\n/.test(rest.trim()) && entries.some((entry, i) => i > 0 && !/\n/.test(entry.separator))) return null;
        if (!/\n/.test(rest.trim()) && entries.length < 4 && !caption && !captioned) return null;
      } else if (caption || captioned) {
        entries = plainEntries(text, start);
        if (!entries) return null;
      } else return null;
      for (const entry of entries) entry.depth = entry.number ? depthOf(entry.number.value) : 0;
      return {caption, entries};
    };
    return {CAPTION_ONLY, NUMBER, normalNumber, parse};
  })();
  // END CONTENTS PARSER

  // BEGIN CONTENTS OUTLINE
  // Pure text logic, no DOM: the app's Contents sheet (docs/LEGACY_GAP_AUDIT.md #10). The paper's
  // title, "Abstract" and a printed "Contents" heading are left out (References stays). Each entry's
  // depth is its heading level's distance from the shallowest level shown. Where Mathpix flattened the
  // levels — a section and its own subsection share one level, as DPO's "A. 1" and "A" — a
  // numbered heading's depth comes from its number instead: "2.1.3" is two below "2", "A.1" one below
  // "A"; in a paper numbered I, II, … (IEEE), capital letters are one below and "1)" two below.
  // Port of the web app's inferDepthFromNumbering (lib/mathpix-cleanup.ts).
  const ContentsOutline = (() => {
    const MAX_DEPTH = 3;
    const fold = value => value.normalize('NFKD').replace(/[̀-ͯ]/g, '').toLowerCase()
      .replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
    const SKIPPED = /^(?:abstract|contents|table of contents)$/;
    const ROMAN = /^(?=[IVX])X{0,3}(?:IX|IV|V?I{0,3})$/;
    // "2", "2.1.3", "A", "A.1", "A. 1" (as OCR prints it), "IV"; then ".", ")" or a space before the title.
    const NUMBER = /^((?:\d{1,3}|[A-Z]|[IVX]{1,6})(?:\s?\.\s?\d{1,3}){0,4})(?:\s*[.)]\s*|\s+)(?=\S)/u;
    const numbering = title => {
      const match = NUMBER.exec(title.trim());
      if (!match) return null;
      const parts = match[1].split(/\s?\.\s?/);
      return {head: parts[0], below: parts.length - 1, key: parts.join('.'), parent: parts.slice(0, -1).join('.')};
    };
    // Roman numbering when the paper has a numeral only Roman can be (II, IV, …) and at least two of them.
    const romanScheme = numbers => {
      const romans = numbers.filter(value => value && ROMAN.test(value.head));
      return romans.length >= 2 && romans.some(value => value.head.length > 1 || value.head === 'V' || value.head === 'X');
    };
    const numberDepth = (value, roman) => {
      if (!roman) return value.below;
      const kind = /^\d/.test(value.head) ? 2 : ROMAN.test(value.head) ? 0 : 1;
      return kind + value.below;
    };
    // items: [{id, title, level}] in reading order → [{id, title, level, depth}] to show.
    const outline = (items, paperTitle) => {
      const title = paperTitle ? fold(paperTitle) : null;
      const shown = items.filter(item => {
        const folded = fold(item.title);
        return folded && !SKIPPED.test(folded) && folded !== title;
      });
      if (!shown.length) return [];
      const numbers = shown.map(item => numbering(item.title));
      const roman = romanScheme(numbers);
      // Flattened: one level holds a section and its own subsection ("A" and "A.1"; with Roman numbering,
      // a numeral and a letter or number). An unrelated "A Simple Baseline" beside "2.2" is not.
      const byLevel = new Map();
      shown.forEach((item, index) => {
        if (numbers[index]) byLevel.set(item.level, [...(byLevel.get(item.level) || []), numbers[index]]);
      });
      const flattened = [...byLevel.values()].some(values => roman
        ? new Set(values.map(value => numberDepth(value, true))).size > 1
        : values.some(value => value.parent && values.some(other => other.key === value.parent)));
      const top = Math.min(...shown.map(item => item.level));
      const depths = shown.map((item, index) => flattened && numbers[index] ? numberDepth(numbers[index], roman) : item.level - top);
      const least = Math.min(...depths);
      return shown.map((item, index) => ({...item, depth: Math.min(MAX_DEPTH, depths[index] - least)}));
    };
    return {outline, numbering};
  })();
  // END CONTENTS OUTLINE

  // A contents block becomes a list (one entry per line, indented by depth, the page muted on
  // the right) by wrapping its own text; an entry whose title is a heading of the paper (or a
  // numbered run-in head) jumps there with Back, like a citation. Paragraph text, IDs and
  // selections are unchanged. Row → {id, range, heading?, start?}.
  const contentsTargets = new WeakMap();
  const foldTitle = value => value.normalize('NFKD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/\\/g, ' ')
    .replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
  const plainText = node => {
    if (node.nodeType === Node.TEXT_NODE) return node.data;
    if (node.nodeType !== Node.ELEMENT_NODE) return '';
    if (node.matches('[data-reader-equation]')) return ' ' + (node.getAttribute('data-latex') || node.textContent) + ' ';
    return [...node.childNodes].map(plainText).join('');
  };
  const sectionTitle = text => {
    const trimmed = text.trim(), match = ContentsParser.NUMBER.exec(trimmed);
    return match ? {number: ContentsParser.normalNumber(match[1]), title: foldTitle(trimmed.slice(match[0].length))}
      : {number: null, title: foldTitle(trimmed)};
  };
  const headingFor = (sections, number, title, whole) => {
    if (!title) return null;
    let found = sections.filter(section => section.title === title && (!number || !section.number || section.number === number));
    if (found.length > 1 && number) found = found.filter(section => section.number === number);
    // "A Survey of …" is a title, not appendix A.
    if (!found.length && number) found = sections.filter(section => !section.number && section.title === whole);
    if (!found.length && number) {
      // The same number and nearly the same words (OCR, abbreviations).
      const words = new Set(title.split(' '));
      found = sections.filter(section => {
        if (section.number !== number) return false;
        const other = new Set(section.title.split(' '));
        const shared = [...words].filter(word => other.has(word)).length;
        return shared >= 2 && shared * 3 >= Math.max(words.size, other.size) * 2;
      });
    }
    return found.length === 1 ? found[0].element : null;
  };
  // Run-in subsection heads Mathpix keeps inside paragraphs ("3.3.1 Exams Scheduling. Let us…",
  // ACM style), found once at line starts: number → [{block, start, after}].
  const RUN_IN = /(?:^|\n)([^\S\n]*)(\d{1,2}(?:\s?\.\s?\d{1,2}){1,4})\.?[^\S\n]+(?=\S)/g;
  const runInHeads = () => {
    const found = new Map();
    for (const block of document.querySelectorAll('p[data-reader-block]')) {
      if (block.matches('.sr-toc') || references.members.has(block) || inBibliography(block) || block.closest(`figure,.reader-table,li,[${CHROME}]`)) continue;
      const text = block.textContent;
      for (const match of text.matchAll(RUN_IN)) {
        const number = ContentsParser.normalNumber(match[2]), start = match.index + (match[0].startsWith('\n') ? 1 : 0) + match[1].length;
        found.set(number, [...(found.get(number) || []), {block, text, start, after: match.index + match[0].length}]);
      }
    }
    return found;
  };
  const textRange = (block, start, end) => {
    const range = document.createRange(), walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT);
    let offset = 0, begun = false;
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const next = offset + node.data.length;
      if (!begun && start < next) { range.setStart(node, start - offset); begun = true; }
      if (begun && end <= next) { range.setEnd(node, end - offset); return range; }
      offset = next;
    }
    return null;
  };
  // The one line in the paper that starts with this number and title, then "." or ":" (not a leader).
  const runInFor = (heads, number, title) => {
    const words = title.match(/[\p{L}\p{N}]+/gu);
    if (!words || /￼/.test(title)) return null;
    const pattern = new RegExp(words.map(word => word.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join(String.raw`[^\p{L}\p{N}\n]+`)
      + String.raw`[)\]]?[^\S\n]*[.:](?![^\S\n]*\.)`, 'iuy');
    const found = (heads.get(number) || []).flatMap(head => {
      pattern.lastIndex = head.after;
      return pattern.test(head.text) ? [{...head, end: pattern.lastIndex}] : [];
    });
    if (found.length !== 1) return null;
    // Resolved when used: citation links later split the text nodes (the text itself never changes).
    const {block, start, end} = found[0];
    return textRange(block, start, end) && {id: block.id, start: true, get range() { return textRange(block, start, end); }};
  };
  const formatContents = () => {
    const linkable = [];
    for (const block of document.querySelectorAll('p[data-reader-block]')) {
      if (references.members.has(block) || inBibliography(block) || block.matches('.reader-authors,.reader-abstract')
        || block.closest(`figure,.reader-table,li,[${CHROME}]`)) continue;
      // The block's own children: text, line breaks and whole inline elements (an equation is one character).
      const atoms = [];
      let text = '', plain = true;
      for (const node of block.childNodes) {
        if (node.nodeType === Node.TEXT_NODE) { atoms.push({node, start: text.length, text: node.data}); text += node.data; }
        else if (node.nodeType === Node.ELEMENT_NODE && node.tagName === 'BR') { atoms.push({node, start: text.length, size: 1}); text += '\n'; }
        else if (node.nodeType === Node.ELEMENT_NODE && (node.matches('[data-reader-equation]') || !node.textContent.includes('\n'))) {
          atoms.push({node, start: text.length, size: 1}); text += '￼';
        } else plain = false;
      }
      const previous = block.previousElementSibling;
      const heading = !!previous && /^H[1-6]$/.test(previous.tagName) && ContentsParser.CAPTION_ONLY.test(previous.textContent) ? previous.textContent : '';
      if (!plain || (!heading && !/\.\s*\.\s*\.|…|·\s*·\s*·|contents|list\s+of/i.test(text))) continue;
      const parsed = ContentsParser.parse(text, !!heading);
      if (!parsed) continue;
      // A list of figures or tables is shown the same way; only a table of contents links to headings.
      const listing = /list\s+of/i.test(parsed.caption ? text.slice(parsed.caption.start, parsed.caption.end) : heading);
      const slice = (from, to) => {
        const nodes = [];
        for (const atom of atoms) {
          const end = atom.start + (atom.text?.length ?? atom.size);
          if (end <= from || atom.start >= to) continue;
          if (atom.text === undefined) { nodes.push(atom.node); continue; }
          const part = atom.text.slice(Math.max(from, atom.start) - atom.start, Math.min(to, end) - atom.start);
          if (part) nodes.push(document.createTextNode(part));
        }
        return nodes;
      };
      const words = (from, to) => slice(from, to).map(plainText).join('');
      const span = (name, nodes) => { const element = document.createElement('span'); element.className = name; element.append(...nodes); return element; };
      // Read everything needed before building, which moves the block's elements.
      const before = block.textContent, original = [...block.childNodes];
      const titles = parsed.entries.map(entry => {
        const whole = words(entry.start, entry.leader.start);
        return {whole: foldTitle(whole), title: foldTitle(entry.number ? words(entry.number.end, entry.leader.start) : whole),
          text: entry.number ? text.slice(entry.number.end, entry.leader.start) : ''};
      });
      const out = [], rows = [];
      let cursor = 0;
      if (parsed.caption) {
        out.push(...slice(0, parsed.caption.start), span('sr-toc-caption', slice(parsed.caption.start, parsed.caption.end)));
        cursor = parsed.caption.end;
      }
      for (const entry of parsed.entries) {
        out.push(...slice(cursor, entry.start));
        const label = entry.number
          ? span('sr-toc-label', [span('sr-toc-number', slice(entry.number.start, entry.number.end)), ...slice(entry.number.end, entry.leader.start)])
          : span('sr-toc-label', slice(entry.start, entry.leader.start));
        const leader = span('sr-toc-leader', slice(entry.leader.start, entry.leader.end));
        leader.setAttribute('aria-hidden', 'true');
        const row = span('sr-toc-entry', [label, leader, span('sr-toc-page', slice(entry.page.start, entry.page.end))]);
        row.setAttribute('data-sr-depth', String(entry.depth));
        out.push(row); rows.push({row, entry});
        cursor = entry.end;
      }
      out.push(...slice(cursor, text.length));
      block.replaceChildren(...out);
      if (block.textContent !== before) { block.replaceChildren(...original); continue; }
      block.classList.add('sr-toc');
      if (parsed.entries.some(entry => entry.depth > 0)) block.classList.add('sr-toc-nested');
      if (!listing) rows.forEach((row, i) => linkable.push({...row, ...titles[i]}));
    }
    // Links once every list is formatted, so no list is taken for run-in heads.
    if (!linkable.length) return;
    const sections = [...document.querySelectorAll('h1,h2,h3,h4,h5,h6')].filter(element => !element.closest(`[${CHROME}]`))
      .map(element => ({element, ...sectionTitle(plainText(element))}));
    let heads = null;
    for (const {row, entry, title, whole, text} of linkable) {
      const heading = headingFor(sections, entry.number?.value ?? null, title, whole);
      let target = null;
      if (heading) {
        const range = document.createRange(); range.selectNodeContents(heading);
        target = {id: heading.id, heading, range};
      } else if (entry.number?.value.includes('.')) target = runInFor(heads ??= runInHeads(), entry.number.value, text);
      if (!target) continue;
      contentsTargets.set(row, target);
      row.classList.add('sr-toc-link'); row.setAttribute('role', 'link'); row.tabIndex = 0;
      const name = row.querySelector('.sr-toc-label').textContent.replace(/\s+/g, ' ').trim();
      row.setAttribute('aria-label', `${name}, page ${entry.page.value}`);
    }
  };

  const installCitationStyle = () => {
    const style = document.createElement('style');
    style.textContent = [
      ':root{--sr-link:#5659d6;--sr-flash:rgba(99,102,241,.2)}@media(prefers-color-scheme:dark){:root{--sr-link:#a5a7ff;--sr-flash:rgba(165,180,252,.3)}}',
      // A larger tap target than the digits, without moving any text.
      '.sr-cite{color:var(--sr-link);text-decoration:none;cursor:pointer;border-radius:4px;padding:.45em .2em;margin:-.45em -.2em;-webkit-tap-highlight-color:var(--sr-flash)}',
      // Touch has no hover: a faint underline shows every citation (numbered or author–year) is a link.
      '@media(hover:none){.sr-cite{text-decoration:underline;text-decoration-thickness:1px;text-underline-offset:.2em;text-decoration-skip-ink:auto;'
        + 'text-decoration-color:color-mix(in srgb,var(--sr-link) 40%,transparent)}}',
      '.sr-cite:focus-visible{outline:2px solid var(--sr-link);outline-offset:1px}[data-sr-reference]{cursor:pointer}',
      '.sr-flash{position:absolute;z-index:-1;pointer-events:none;border-radius:8px;background:var(--sr-flash);transition:opacity .9s ease}.sr-flash.sr-flash-done{opacity:0}',
      '.sr-paper-line{font-size:.82rem;line-height:1.4;color:#666;margin:-.3em 0 1.2em;-webkit-user-select:none;user-select:none}',
      '@media(prefers-color-scheme:dark){.sr-paper-line{color:#9a9a9a}}@media(prefers-reduced-motion:reduce){.sr-flash{transition:none}}',
      // Less space above a section (owner, build 78: "The spacing in between sections is a bit too much, eg before
      // Generative Retrieval"): the bundle's reader.css gives h2 2em and h3–h6 1.6em; here 1.4em and 1.25em, about a
      // quarter less, for every paper already prepared too (the compiler's own CSS, and so its revision, is unchanged).
      'h2{margin-top:1.4em}h3,h4,h5,h6{margin-top:1.25em}',
      // A list item's own label (the paper's "•", "–", "(ii)", "a."; reader revision 23) hangs in the list's indent where
      // the list's marker would be, so a long item's lines align under its first; a label wider than the indent pushes
      // only its first line.
      'li.reader-custom-marker>.reader-marker:first-child{display:inline-block;min-width:1.5em;margin:0 0 0 -1.5em;padding-right:.45em;text-align:right}'
        + '[data-sr-abstract-list]>li>.reader-marker:first-child{display:none}',
      // Tags: small quiet chips under the paper line; the whole row is one tap target (padding) that opens Edit tags.
      '.sr-paper-tags{display:block;margin:1.5em 0 .75em;padding:.45em 0;cursor:pointer;-webkit-user-select:none;user-select:none;-webkit-tap-highlight-color:transparent}',
      '.sr-tag{font-size:.74rem;line-height:1.35;color:#5c5c63;background:rgba(120,120,128,.12);border-radius:999px;padding:.18em .7em;white-space:nowrap;max-width:100%;overflow:hidden;text-overflow:ellipsis}',
      '.sr-paper-tags h2{margin:0 0 .5em}.sr-paper-tags .sr-tag{display:inline-block;margin:0 .4em .4em 0}.sr-paper-tags .sr-tag-add{color:var(--sr-link)}.sr-keyword-source{display:block;font-size:.8em;color:var(--sr-muted,#777);margin-bottom:.5em}[data-sr-abstract-list]{padding-left:0;list-style:none;margin-left:0}[data-sr-abstract-list]>li{margin-left:0;padding-left:0}',
      '.sr-paper-tags .sr-tag:active{background:rgba(120,120,128,.22)}.sr-paper-tags:focus-visible,.sr-paper-tags .sr-tag:focus-visible{outline:2px solid var(--sr-link);outline-offset:2px;border-radius:8px}',
      '@media(prefers-color-scheme:dark){.sr-tag{color:#a1a1a8;background:rgba(120,120,128,.24)}.sr-paper-tags .sr-tag:active{background:rgba(120,120,128,.36)}}',
      // A paper's own contents: one entry per line, indented by depth, the page muted on the right.
      ':root{--sr-muted:#6b6b70}@media(prefers-color-scheme:dark){:root{--sr-muted:#9d9da3}}',
      '.sr-toc{font-size:.94rem;line-height:1.4}.sr-toc-caption{display:block;font-weight:650;margin-bottom:.35em}',
      '.sr-toc-entry{display:flex;align-items:baseline;padding:.22em 0}.sr-toc-label{flex:0 1 auto;min-width:0}',
      '.sr-toc-nested>.sr-toc-entry[data-sr-depth="0"]{font-weight:600}.sr-toc-nested>.sr-toc-entry[data-sr-depth="0"]:not(:first-child){margin-top:.3em}',
      '.sr-toc-entry[data-sr-depth="1"]{padding-left:1.25em}.sr-toc-entry[data-sr-depth="2"]{padding-left:2.5em}',
      '.sr-toc-entry[data-sr-depth="3"]{padding-left:3.5em}.sr-toc-entry[data-sr-depth="4"]{padding-left:4.25em}',
      '.sr-toc-leader{flex:1 0 1.25em;font-size:0;line-height:0;margin:0 .5em;border-bottom:1px dotted color-mix(in srgb,var(--sr-muted) 55%,transparent)}',
      '.sr-toc-page{flex:none;min-width:1.5em;text-align:right;color:var(--sr-muted);font-weight:400;font-size:.94em;font-variant-numeric:tabular-nums}',
      '.sr-toc-link{cursor:pointer;border-radius:6px;-webkit-tap-highlight-color:var(--sr-flash)}.sr-toc-link .sr-toc-label{color:var(--sr-link)}',
      '.sr-toc-link:focus-visible{outline:2px solid var(--sr-link);outline-offset:2px}',
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
  // BEGIN PAPER TAGS PLACE
  // The keywords row reads right after the abstract (owner, TestFlight 92, WorldCast 2610.20731v2: it sat under two
  // figures, between the abstract and the Introduction): before the first figure, table, caption or section that follows
  // the abstract's heading, so a teaser the paper keeps under its abstract comes after the row. `nodes` are the page's
  // top-level elements; null (no abstract heading before the first section) keeps the row before the first section.
  const paperTagsPlace = nodes => {
    const text = node => String(node.textContent || '').trim();
    const named = (node, name) => (' ' + String(node.className || '') + ' ').includes(' ' + name + ' ');
    const section = node => /^H[2-6]$/i.test(node.tagName) && !/^(abstract|contents|table of contents)$/i.test(text(node));
    const float = node => /^FIGURE$/i.test(node.tagName) || named(node, 'reader-table') || named(node, 'reader-caption');
    // The abstract's heading, or a model reading's abstract paragraph (`reader-abstract`).
    const abstract = nodes.findIndex(node => (/^(H[1-6]|P)$/i.test(node.tagName) && /^abstract[.:]?$/i.test(text(node))) || named(node, 'reader-abstract'));
    const first = nodes.findIndex(section);
    if (abstract < 0 || (first >= 0 && first < abstract)) return null;
    return nodes.slice(abstract + 1).find(node => section(node) || float(node)) ?? null;
  };
  // END PAPER TAGS PLACE
  // The paper's tags as chips under the paper line (or the title and authors). A chip offers a search for its keyword
  // (owner, builds 73 and 75: "an option right at the top to search ML papers based on this keyword"); anywhere else on
  // the row opens Edit keywords, without an "Edit" word (build 72).
  const installPaperTags = tags => {
    document.querySelector('[data-sr-paper-tags]')?.remove();
    const source = !Array.isArray(tags) && typeof tags?.source === 'string' ? tags.source.slice(0,80) : 'Gradstep';
    const values = Array.isArray(tags) ? tags : tags?.names;
    if (!Array.isArray(values)) return;
    const names = values.filter(tag => typeof tag === 'string' && tag.trim()).slice(0, 24).map(tag => tag.trim().slice(0, 60));
    const row = document.createElement('div');
    row.className = 'sr-paper-tags'; row.setAttribute(CHROME, ''); row.setAttribute('data-sr-paper-tags', '');
    if (names.length) { row.setAttribute('role', 'group'); row.setAttribute('aria-label', 'Keywords'); }
    else { row.setAttribute('role', 'button'); row.tabIndex = 0; row.setAttribute('aria-label', 'Add keywords'); }
    const label = document.createElement('h2'); label.textContent = 'Gradstep Keywords'; row.append(label);
    if (source !== 'Gradstep') { const origin = document.createElement('span'); origin.className = 'sr-keyword-source'; origin.textContent = source; row.append(origin); }
    // No keywords: a visible Add keywords chip, never a bare heading (owner, build 78: "No Gradstep keywords"; TAGS.md).
    if (!names.length) { const add = document.createElement('span'); add.className = 'sr-tag sr-tag-add'; add.textContent = 'Add keywords'; add.setAttribute('aria-hidden', 'true'); row.append(add); }
    for (const name of names) {
      const chip = document.createElement('span');
      chip.className = 'sr-tag'; chip.textContent = name; chip.setAttribute('data-sr-tag', name);
      chip.setAttribute('role', 'button'); chip.tabIndex = 0; chip.setAttribute('aria-label', name);
      chip.setAttribute('aria-description', 'Search papers for this keyword, or edit keywords');
      row.append(chip);
    }
    row.addEventListener('keydown', event => {
      if (event.key !== 'Enter' && event.key !== ' ') return;
      const chip = event.target instanceof Element ? event.target.closest('[data-sr-tag]') : null;
      event.preventDefault();
      post(chip ? {type:'tag', name: chip.getAttribute('data-sr-tag')} : {type:'tags'});
    });
    const place = paperTagsPlace([...document.body.children]);
    const heading = place ?? [...document.querySelectorAll('h2,h3,h4,h5,h6')].find(h => !/^(abstract|contents|table of contents)$/i.test(h.textContent.trim()));
    if (heading) heading.before(row);
    else document.body.append(row);
  };
  // arXiv sometimes wraps the abstract in a one-item list (FDE-Gym: "<p><strong>Abstract</strong></p><ul><li>…"), and the
  // compiler names a recovered abstract with an h6: read it at the body's full width (build 70: "the text needs to extend
  // just a bit more"), whether or not the paper has keywords.
  const markAbstractList = () => {
    for (const heading of document.querySelectorAll('h1,h2,h3,h4,h5,h6,p')) {
      const list = heading.nextElementSibling;
      if (/^abstract[.:]?$/i.test(heading.textContent.trim()) && list?.matches('ul,ol') && list.children.length === 1) list.setAttribute('data-sr-abstract-list', '');
    }
  };
  // Author names supplied by verified library metadata; only these exact names can leave the frame.
  const installAuthors = authors => {
    if (!Array.isArray(authors)) return;
    const names = authors.filter(a => typeof a === 'string' && a.length > 1 && a.length <= 256).sort((a,b) => b.length-a.length);
    for (const header of document.querySelectorAll('.reader-authors')) {
      for (const name of names) {
        const walker = document.createTreeWalker(header, NodeFilter.SHOW_TEXT);
        const nodes = []; while (walker.nextNode()) if (!walker.currentNode.parentElement.closest('button,a,.reader-affiliations')) nodes.push(walker.currentNode);
        for (const node of nodes) {
          const at = node.textContent.indexOf(name); if (at < 0) continue;
          const tail = node.splitText(at), rest = tail.splitText(name.length);
          const button = document.createElement('button'); button.type = 'button'; button.className = 'sr-author'; button.textContent = name;
          button.style.cssText = 'font:inherit;color:inherit;padding:0;border:0;background:none;text-decoration:underline;text-decoration-style:dotted;cursor:pointer';
          button.setAttribute('aria-label', 'More papers by ' + name);
          // The name's box: iPad and the Mac open the author's menu there (no prompt centred over the page).
          button.addEventListener('click', e => { e.preventDefault(); e.stopPropagation(); const r = button.getBoundingClientRect();
            post({type:'author', name, rect:{x:r.left, y:Math.max(0, r.top), width:r.width, height:Math.min(r.bottom, window.innerHeight) - Math.max(0, r.top)}}); });
          tail.replaceWith(button);
        }
      }
    }
  };
  window.__scienceReaderSetPaperTags = tags => {
    if (config?.figure_id) return false;
    const location = citationBack ? null : (lastPosition ?? window.__scienceReaderLocation());
    installPaperTags(tags);
    if (location) window.__scienceReaderRestore(location);
    return true;
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
    // A table or an algorithm shown on its own (a figure reference's view) keeps the page's table presentation.
    if (config && !figureIDs.has(config.figure_id)) installLayout();
    if (!config?.figure_id) {
      installCitationStyle(); collectReferences(); formatContents(); expandNamedReferences(); linkCitations(); linkFigureReferences();
      installPaperLine(window.__readerPaperLine);
      markAbstractList();
      installPaperTags(window.__readerPaperTags);
      installAuthors(window.__readerAuthors);
    }
    if (config?.figure_id) {
      // A figure, or a table or code block a figure reference names (FIGURE REFERENCES).
      if (!detailIDs.has(config.figure_id)) throw new Error('invalid_reader_figure');
      const figure = document.getElementById(config.figure_id);
      document.body.replaceChildren(figure);
      document.body.classList.add('reader-figure-detail');
      const style = document.createElement('style');
      // The figure on a margin of its own white background, so no ink sits on the edge of the white surface the
      // reader's dark styles draw it on (owner, 2026-10-21: "some margin around them").
      style.textContent = 'body.reader-figure-detail{max-width:none;padding:24px 18px 32px}body.reader-figure-detail figure{margin:0}body.reader-figure-detail img{max-width:100%;height:auto}'
        + 'body.reader-figure-detail figure > img:not(.reader-inline-image){box-sizing:border-box;padding:12px;background:#fff;border-radius:8px}';
      document.head.append(style);
    }
    await document.fonts.ready;
    await Promise.all([...document.images].map(image => image.decode()));
    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    if (config?.figure_id) { markScrollEdges(); return true; }
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
        return {id: heading.id, title: heading.title, level: heading.level};
      });
    } else {
      // Retain source anchors in the existing local navigation regressions.
      const counts = new Map();
      document.querySelectorAll('[id]').forEach(element => counts.set(element.id, (counts.get(element.id) || 0) + 1));
      const used = new Set(counts.keys());
      // The app's own rows (the keywords' heading) are not the paper's sections.
      items = [...document.querySelectorAll('h1,h2,h3')].filter(element => element.textContent.trim() && !element.closest(`[${CHROME}]`)).slice(0,500).map((element,index) => {
        let id = element.id;
        if (!id || id.length > 512 || /[\u0000-\u0020\u007f]/.test(id) || counts.get(id) !== 1) {
          const stem = 'sr-heading-' + index; let suffix = 0; id = stem;
          while (used.has(id)) id = stem + '-' + (++suffix);
          used.add(id);
        }
        headings.set(id,element);
        return {id,title:element.textContent.trim().slice(0,2000),level:Number(element.tagName[1])};
      });
      blocks.push(...document.querySelectorAll('h1,h2,h3,h4,h5,h6,p,li,figure,table,pre'));
    }
    post({type:'headings',items:ContentsOutline.outline(items, config?.title)});
    return true;
  })();
  // Attach a rejection observer immediately, even before didFinish awaits it.
  window.__scienceReaderReady.catch(() => post({type:'invalid'}));

  window.__scienceReaderJumpToHeading = (id,reduced) => {
    const element = headings.get(id);
    if (!element) return false;
    if (citationBack) endCitation();
    element.scrollIntoView({behavior:'instant',block:'start'});
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
  // The equation's edit menu closed without an action: unselect it, unless another one has been tapped since.
  window.__scienceReaderClearEquation = id => {
    if (!selectedEquation || selectedEquation.getAttribute('data-reader-equation') !== id) return false;
    clearEquation(); post({type:'selection',selection:{manifest_sha256:manifest,parts:[]}});
    return true;
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
  // Runs `then` once the page has stopped moving (four still frames). A long smooth scroll on a slow device is
  // waited out rather than cut short: where the jump landed must be the place it really stopped.
  const settled = then => {
    let last = NaN, still = 0;
    const started = performance.now();
    const tick = () => {
      still = Math.abs(window.scrollY - last) < 0.5 ? still + 1 : 0; last = window.scrollY;
      if (still >= 4 || performance.now() - started > 6000) then(); else requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  };
  // Whether the reader has scrolled, swiped or keyed since the last jump: Back outlives only their own scrolling,
  // never a smooth scroll still in flight or a programmatic restore (owner report, build 35: Back no longer there).
  let movedSinceJump = false;
  for (const type of ['wheel', 'touchstart', 'pointerdown', 'keydown']) {
    window.addEventListener(type, () => { movedSinceJump = true; }, {passive: true, capture: true});
  }
  // A tap or a scroll takes every flash away at once (owner, build 43: "if I click outside it, the highlight should
  // go away").
  const flashes = new Set();
  const clearFlashes = () => { for (const box of flashes) box.remove(); flashes.clear(); window.CSS?.highlights?.delete('sr-passage'); };
  for (const type of ['touchstart', 'pointerdown', 'keydown']) window.addEventListener(type, clearFlashes, {passive: true, capture: true});
  const flash = rect => {
    if (!rect || (!rect.width && !rect.height)) return;
    const box = document.createElement('div');
    box.className = 'sr-flash'; box.setAttribute(CHROME, ''); box.setAttribute('aria-hidden', 'true');
    Object.assign(box.style, {left: rect.left + window.scrollX - 8 + 'px', top: rect.top + window.scrollY - 6 + 'px',
      width: rect.width + 16 + 'px', height: rect.height + 12 + 'px'});
    document.body.append(box); flashes.add(box);
    setTimeout(() => box.classList.add('sr-flash-done'), 1600);
    setTimeout(() => { box.remove(); flashes.delete(box); }, 2700);
  };
  const scrollTarget = rect => {
    const limit = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
    return Math.min(limit, Math.max(0, window.scrollY + rect.top - Math.max(16, (window.innerHeight - rect.height) / 2)));
  };
  // A section (from the paper's own contents) goes to the top, as a Contents jump does.
  const sectionTarget = entry => {
    const limit = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
    const margin = entry.heading ? parseFloat(getComputedStyle(entry.heading).scrollMarginTop) || 0 : 22;
    return Math.min(limit, Math.max(0, window.scrollY + entry.range.getBoundingClientRect().top - margin));
  };
  const showReference = (entry, instant) => {
    const top = entry.heading || entry.start ? sectionTarget(entry) : scrollTarget(entry.range.getBoundingClientRect());
    window.scrollTo({top, behavior: 'instant'});
    if (citationBack) citationBack.landing = null;
    settled(() => {
      if (citationBack && citationBack.entry !== entry) return;
      if (citationBack) citationBack.landing = window.scrollY;
      if (!instant) flash(entry.range.getBoundingClientRect());
    });
  };
  const endCitation = () => {
    if (!citationBack) return;
    citationBack = null;
    post({type:'citation',state:'ended'});
    postPosition();
  };
  // The section the reader left (the nearest heading above the origin block), so Back can say where it goes
  // (owner, build 44: "it needs to say where that is"); nothing when the origin is the top of the paper, where
  // Back would only go to the title (owner, build 44: "I press Back and I get to the top of the Article???").
  const originLabel = location => {
    for (let i = Math.min(location.block, blocks.length - 1); i >= 0; i--) {
      const element = blocks[i];
      if (/^H[2-6]$/.test(element.tagName)) { const text = (element.textContent || '').replace(/\s+/g, ' ').trim(); return text.length > 44 ? text.slice(0, 43).trimEnd() + '…' : text; }
    }
    return '';
  };
  const atTheTop = location => location.y < 4;
  window.__scienceReaderEndCitation = () => { endCitation(); return true; };
  const jumpToReference = (entry, cite) => {
    // A second citation followed from the bibliography keeps the first place.
    const origin = citationBack?.origin ?? {location: window.__scienceReaderLocation(), cite};
    // An in-page link always offers Back (the reader was reading there, the top included); only a jump from a chat
    // citation into an unread paper has nowhere to go back to (`__scienceReaderGoToPassage`).
    citationBack = {origin, entry, landing: null}; movedSinceJump = false;
    showReference(entry, false);
    post({type:'citation',state:'jumped',id:entry.id,back:true,from:originLabel(origin.location)});
  };
  window.__scienceReaderCitationBack = () => {
    const back = citationBack;
    if (!back) return false;
    citationBack = null;
    window.scrollTo({top: locationY(back.origin.location), behavior: 'instant'});
    post({type:'citation',state:'ended'});
    settled(() => {
      postPosition();
      if (back.origin.cite?.isConnected) flash(back.origin.cite.getBoundingClientRect());
    });
    return true;
  };
  // Back stays offered until the reader scrolls two screens from where the jump landed, or comes back to the place
  // left by scrolling there themselves (owner feedback, build 21: "a 'return to reading location' option").
  const backOutlived = () => {
    if (citationBack?.landing == null || !movedSinceJump) return false;
    if (Math.abs(window.scrollY - citationBack.landing) > 2 * window.innerHeight) return true;
    const origin = locationY(citationBack.origin.location);
    return Math.abs(citationBack.landing - origin) > window.innerHeight / 2 && Math.abs(window.scrollY - origin) < window.innerHeight / 4;
  };
  window.addEventListener('scroll',() => {
    if (backOutlived()) endCitation();
    if (positionTimer || config?.figure_id) return;
    positionTimer = setTimeout(() => {positionTimer=null;postPosition();},120);
  },{passive:true});
  window.addEventListener('scrollend',() => {if (!config?.figure_id) postPosition();});
  // A new width (the iPad's divider dragged, the window turned or resized) reflows the text: the paragraph at the top
  // stays at the top, at the same point within it (owner, 2026-10-23: the divider is "a real drag"; WebKit has no CSS
  // scroll anchoring). The place is noted once a frame while scrolling and put back on each change of width. Only where
  // the host asks for it (`__scienceReaderKeepPlaceOnResize`, the iPad app); elsewhere a resize is left as it was.
  let widthAnchor = null, anchorFrame = 0, anchorWidth = window.innerWidth;
  window.addEventListener('scroll', () => {
    if (anchorFrame || !window.__scienceReaderKeepPlaceOnResize) return;
    anchorFrame = requestAnimationFrame(() => { anchorFrame = 0; widthAnchor = window.__scienceReaderLocation(); });
  }, {passive: true});
  window.addEventListener('resize', () => {
    if (window.innerWidth === anchorWidth) return;   // a height change (a keyboard, a bar) keeps its own behaviour
    anchorWidth = window.innerWidth;
    if (window.__scienceReaderKeepPlaceOnResize && widthAnchor && widthAnchor.y > 0) window.__scienceReaderRestore(widthAnchor);
  });

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
        // A contents leader is hidden from VoiceOver, not from the paper's text.
        if (node.matches('script,style,mjx-assistive-mml,[aria-hidden="true"]:not(.sr-toc-leader)') && !node.hasAttribute('data-reader-equation')) return;
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
        const parts = selectionParts();
        // The text around it lets a conversation find this passage again (passage anchors, end of this file).
        post({type:'selection',selection:{manifest_sha256:manifest,parts,context:parts.length ? passageContext() : null}});
      }
    },180);
  });
  // The selection at this moment, for an action chosen in the native edit menu (owner feedback, build 16 #5): the menu
  // can be open before the debounced report above arrives. A tapped equation when no text is selected; null for none.
  window.__scienceReaderSelectionNow = () => {
    if (!config || config.figure_id) return null;
    if (selectedEquation && (window.getSelection()?.isCollapsed ?? true)) {
      return {manifest_sha256:manifest,parts:[{kind:'equation',block_id:enclosingBlock(selectedEquation),
        equation_id:selectedEquation.getAttribute('data-reader-equation')}],context:passageContext(selectedEquation)};
    }
    const parts = selectionParts();
    return parts.length ? {manifest_sha256:manifest,parts,context:passageContext()} : null;
  };
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
    // edit menu as text selection; it does not send a question by itself.
    let gesture;
    document.addEventListener('pointerdown',event => {
      gesture = {id:event.pointerId,x:event.clientX,y:event.clientY,moved:false};
    },{passive:true});
    document.addEventListener('pointermove',event => {
      if (gesture?.id === event.pointerId && Math.hypot(event.clientX-gesture.x,event.clientY-gesture.y)>8) gesture.moved = true;
    },{passive:true});
    document.addEventListener('pointercancel',() => {if (gesture) gesture.moved = true;},{passive:true});
    // A keyword chip offers its search; the rest of the keyword row opens Edit keywords (capture: nothing else handles a
    // tap on them).
    document.addEventListener('click',event => {
      const element = event.target instanceof Element ? event.target : event.target.parentElement;
      if (!element?.closest('[data-sr-paper-tags]') || gesture?.moved) return;
      gesture = null; event.preventDefault(); event.stopPropagation();
      const chip = element.closest('[data-sr-tag]');
      post(chip ? {type:'tag', name: chip.getAttribute('data-sr-tag')} : {type:'tags'});
    },true);
    // Citations first (capture), so one inside a figure caption doesn't also open the figure.
    document.addEventListener('click',event => {
      const element = event.target instanceof Element ? event.target : event.target.parentElement;
      const cite = element?.closest('.sr-cite'), entry = cite && references.byID.get(cite.getAttribute('data-sr-cite'));
      // The paper's own in-page links (arXiv HTML: "[55]" to its bibliography entry, "Fig. 1", "Cited by: §1"): the
      // same jump and the same Back as a parsed citation (owner report, build 31: "Back to where you were is gone").
      const anchor = !cite && element?.closest('a[href^="#"]');
      if (anchor && !gesture?.moved && window.getSelection()?.isCollapsed) {
        let id = ''; try { id = decodeURIComponent(anchor.getAttribute('href').slice(1)); } catch { id = ''; }
        const target = id ? document.getElementById(id) : null;
        if (target) {
          gesture = null; event.preventDefault(); event.stopPropagation();
          if (selectedEquation) { clearEquation(); post({type:'selection',selection:{manifest_sha256:manifest,parts:[]}}); }
          const range = document.createRange(); range.selectNodeContents(target);
          jumpToReference({id: 'anchor:' + id, range, heading: /^H[1-6]$/.test(target.tagName) ? target : null}, anchor);
          return;
        }
      }
      // A figure, table or algorithm reference opens it (or goes to its caption).
      const figure = !entry && cite?.hasAttribute('data-sr-figure') && figureTargets.has(cite.getAttribute('data-sr-figure')) ? cite : null;
      // An entry of the paper's own contents goes to its section, with the same Back.
      const row = !entry && !figure && element?.closest('.sr-toc-link'), section = row && contentsTargets.get(row);
      if ((!entry && !figure && !section) || gesture?.moved || !window.getSelection()?.isCollapsed) return;
      gesture = null; event.preventDefault(); event.stopPropagation();
      if (selectedEquation) { clearEquation(); post({type:'selection',selection:{manifest_sha256:manifest,parts:[]}}); }
      if (figure) openFigureReference(figure); else jumpToReference(entry || section, entry ? cite : row);
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
        // Where it is on screen, so the native edit menu opens beside it (the same menu as selected text).
        const rect = equation.getBoundingClientRect();
        post({type:'selection',selection:{manifest_sha256:manifest,parts:[{kind:'equation',block_id:block,equation_id:id}],
          context:passageContext(equation)},menu:{x:rect.left,y:rect.top,width:rect.width,height:rect.height}});
      } else if (selectedEquation) {
        clearEquation(); post({type:'selection',selection:{manifest_sha256:manifest,parts:[]}});
      }
    });
    document.addEventListener('keydown',event => {
      if (event.key !== 'Enter' && event.key !== ' ') return;
      const link = event.target instanceof Element && event.target.matches('.sr-cite,.sr-toc-link') ? event.target : null;
      if (link?.hasAttribute('data-sr-figure')) { event.preventDefault(); event.stopPropagation(); openFigureReference(link); return; }
      const target = link && (link.matches('.sr-cite') ? references.byID.get(link.getAttribute('data-sr-cite')) : contentsTargets.get(link));
      if (target) { event.preventDefault(); event.stopPropagation(); jumpToReference(target, link); }
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

  // Figure gallery, "Show in paper" (docs/LEGACY_GAP_AUDIT.md #6): the figure is centered (from the top
  // when taller than the page), highlighted like a citation's reference, and native Back returns to the
  // place left; the saved reading position stays there until Back or two screens' scroll away. "Go to figure" from a
  // figure reference (`fromReference`) does the same for a table or an algorithm, and Back flashes the reference tapped.
  window.__scienceReaderShowFigure = (id, reduced, fromReference) => {
    if (!config || config.figure_id || !detailIDs.has(id) || (!fromReference && !figureIDs.has(id))) return false;
    const element = document.getElementById(id);
    if (!element) return false;
    const range = document.createRange(); range.selectNode(element);
    const link = fromReference && figureLink?.id === id && figureLink.link.isConnected ? figureLink.link : null;
    figureLink = null;
    jumpToReference({id, range}, link);
    return true;
  };

  // ---- Passage anchors: Go to passage and marks (docs/DECISIONS.md, "Passage-linked conversations") ----
  // A conversation started from a selection remembers its passage: block, quote and ~32 characters each side. The
  // paper's text is read here exactly as selections resolve it (text as shown, equations as their LaTeX, the same
  // separators), so a quote from this artifact is found verbatim; collapsed-whitespace, opening and context matches
  // cover another conversion of the paper. Marks are CSS custom highlights: no element is added or moved, so
  // selection, citations, figures and reading positions are untouched.
  const CONTEXT = 32;
  const equationSource = new Map(config?.equations.map(value => [value.id, value]) || []);
  // Contents › Equations (owner, build 59): an equation, centred and highlighted like a figure, with Back.
  window.__scienceReaderShowEquation = (id, reduced) => {
    if (!config || config.figure_id || !equationSource.has(id)) return false;
    const element = document.getElementById(id);
    if (!element) return false;
    const range = document.createRange(); range.selectNode(element.closest('[data-reader-block]') || element);
    jumpToReference({id, range}, null);
    return true;
  };
  const collapse = value => String(value || '').replace(/\s+/g, ' ').trim();
  let paperText = null;
  if (config && !config.figure_id) {
    new MutationObserver(() => { paperText = null; }).observe(document.body, {childList: true, subtree: true, characterData: true});
  }
  const readPaperText = () => {
    if (paperText) return paperText;
    const segments = [], textNodes = new Map(); let text = '';
    const push = (value, node, kind) => {
      if (kind === 'text') textNodes.set(node, segments.length);
      segments.push({start: text.length, length: value.length, node, kind}); text += value;
    };
    const walk = node => {
      if (node.nodeType === Node.ELEMENT_NODE) {
        if (node.hasAttribute(CHROME)) return;
        if (node.matches('script,style,mjx-assistive-mml,[aria-hidden="true"]:not(.sr-toc-leader)') && !node.hasAttribute('data-reader-equation')) return;
        const equation = node.getAttribute('data-reader-equation');
        if (equation) {
          const source = equationSource.get(equation);
          if (source) push(source.source_form === 'environment' ? '\n' + source.latex + '\n'
            : source.display ? '\n\\[' + source.latex + '\\]\n' : '\\(' + source.latex + '\\)', node, 'equation');
          return;
        }
        const inBlock = blockIDs.has(enclosingBlock(node));
        if (node.tagName === 'BR' && inBlock) push('\n', null, 'separator');
        for (const child of node.childNodes) walk(child);
        if (inBlock && (node.tagName === 'TD' || node.tagName === 'TH')) push('\t', null, 'separator');
        if (inBlock && (node.tagName === 'TR' || node.tagName === 'LI')) push('\n', null, 'separator');
        if (node.hasAttribute(key)) push('\n', null, 'separator');
      } else if (node.nodeType === Node.TEXT_NODE && node.length) {
        if (/^(TABLE|THEAD|TBODY|TFOOT|TR|UL|OL)$/.test(node.parentElement?.tagName || '') && !node.textContent.trim()) return;
        if (blockIDs.has(enclosingBlock(node))) push(node.textContent, node, 'text');
      }
    };
    walk(document.body);
    return paperText = {text, segments, content: segments.filter(segment => segment.node), textNodes, flat: null};
  };
  // The same text with whitespace runs collapsed, and where each character came from.
  const flatText = paper => {
    if (paper.flat) return paper.flat;
    const chars = [], map = []; let space = true;
    for (let index = 0; index < paper.text.length; index++) {
      const char = paper.text[index];
      if (/\s/.test(char)) { if (!space) { chars.push(' '); map.push(index); space = true; } }
      else { chars.push(char); map.push(index); space = false; }
    }
    map.push(paper.text.length);
    return paper.flat = {text: chars.join(''), map};
  };
  const flatIndex = (flat, raw) => {
    let low = 0, high = flat.map.length - 1;
    while (low < high) { const middle = (low + high) >> 1; if (flat.map[middle] >= raw) high = middle; else low = middle + 1; }
    return low;
  };
  const occurrences = (haystack, needle, limit, from = 0) => {
    const found = [];
    for (let at = needle ? haystack.indexOf(needle, from) : -1; at >= 0 && found.length < limit; at = haystack.indexOf(needle, at + 1)) found.push(at);
    return found;
  };
  // Where a DOM boundary point falls in the paper's text.
  const textOffset = (paper, container, offset) => {
    const own = paper.textNodes.get(container);
    if (own !== undefined) { const segment = paper.segments[own]; return segment.start + Math.min(offset, segment.length); }
    const point = document.createRange(); point.setStart(container, offset);
    // The first text or equation at or after the point (both are in document order).
    let low = 0, high = paper.content.length;
    while (low < high) {
      const middle = (low + high) >> 1;
      if (point.comparePoint(paper.content[middle].node, 0) >= 0) high = middle; else low = middle + 1;
    }
    return low < paper.content.length ? paper.content[low].start : paper.text.length;
  };
  // The text around the selection (or a tapped equation) for its anchor; null when it can't be read.
  function passageContext(element) {
    try {
      let range;
      if (element) { range = document.createRange(); range.selectNode(element); }
      else {
        const selection = window.getSelection();
        if (!selection || selection.rangeCount !== 1 || selection.isCollapsed) return null;
        range = selection.getRangeAt(0);
      }
      const paper = readPaperText();
      const start = textOffset(paper, range.startContainer, range.startOffset);
      const end = Math.max(start, textOffset(paper, range.endContainer, range.endOffset));
      return {prefix: Array.from(collapse(paper.text.slice(Math.max(0, start - 200), start))).slice(-CONTEXT).join(''),
              suffix: Array.from(collapse(paper.text.slice(end, end + 200))).slice(0, CONTEXT).join('')};
    } catch { return null; }
  }
  const segmentAt = (segments, index) => {
    let low = 0, high = segments.length - 1, found = -1;
    while (low <= high) { const middle = (low + high) >> 1; if (segments[middle].start <= index) { found = middle; low = middle + 1; } else high = middle - 1; }
    return found;
  };
  const rangeFor = (paper, start, end) => {
    const segments = paper.segments;
    let first = segmentAt(segments, start), last = segmentAt(segments, end - 1);
    while (first < segments.length && (first < 0 || !segments[first].node || segments[first].start + segments[first].length <= start)) first++;
    while (last >= 0 && (!segments[last].node || segments[last].start >= end)) last--;
    if (first >= segments.length || last < first) return null;
    const range = document.createRange(), a = segments[first], b = segments[last];
    if (a.kind === 'text') range.setStart(a.node, Math.max(0, start - a.start)); else range.setStartBefore(a.node);
    if (b.kind === 'text') range.setEnd(b.node, Math.min(b.length, end - b.start)); else range.setEndAfter(b.node);
    return range.collapsed ? null : range;
  };
  const blockSpan = (paper, id) => {
    const element = id && document.getElementById(id);
    if (!element || !element.hasAttribute(key)) return null;
    return {start: textOffset(paper, element, 0), end: textOffset(paper, element, element.childNodes.length)};
  };
  // Of several matches: the one in the anchored block, then the one with the same text around it.
  const choose = (paper, candidates, anchor, span, method) => {
    const prefix = collapse(anchor.prefix), suffix = collapse(anchor.suffix);
    let best = null, bestScore = -1;
    for (const candidate of candidates) {
      let score = span && candidate.start >= span.start && candidate.start < span.end ? 4 : 0;
      const before = collapse(paper.text.slice(Math.max(0, candidate.start - 120), candidate.start));
      const after = collapse(paper.text.slice(candidate.end, candidate.end + 120));
      if (prefix && before && (before.endsWith(prefix) || prefix.endsWith(before))) score += 2;
      if (suffix && after && (after.startsWith(suffix) || suffix.startsWith(after))) score += 2;
      if (score > bestScore) { best = candidate; bestScore = score; }
    }
    const range = best && rangeFor(paper, best.start, best.end);
    return range ? {range, method} : null;
  };
  // anchor: {quote, prefix, suffix, element, same}; `same` when it was made on this artifact (its block ID applies).
  // Exact quote → collapsed whitespace → (fuzzy only) the quote's first line and openings → the text around it.
  const resolvePassage = (anchor, fuzzy) => {
    const quote = String(anchor?.quote || '').trim();
    if (!config) return null;
    // A cited block (an answer's [¶N], resolved by the app to the block's ID): the whole block is the
    // passage when there is no quote, or when the quote cannot be found inside the open paper.
    const blockRange = () => {
      const element = typeof anchor?.block === 'string' && anchor.block ? document.getElementById(anchor.block) : null;
      if (!element || !element.hasAttribute(key)) return null;
      const range = document.createRange(); range.selectNodeContents(element);
      return range.collapsed ? null : {range, method: 'block'};
    };
    if (!quote) return blockRange();
    const paper = readPaperText(), flat = flatText(paper);
    const span = anchor.same ? blockSpan(paper, anchor.element) : null;
    const flatSpan = span && {start: flatIndex(flat, span.start), end: flatIndex(flat, span.end)};
    const fromFlat = (index, length) => ({start: flat.map[index], end: flat.map[index + length - 1] + 1});
    // In the anchored block first (a short quote can occur many times), then anywhere.
    const find = (haystack, needle, within, convert) => {
      if (within) {
        const local = occurrences(haystack, needle, 50, within.start).filter(index => index < within.end);
        if (local.length) return local.map(convert);
      }
      return occurrences(haystack, needle, 200).map(convert);
    };
    let found = find(paper.text, quote, span, index => ({start: index, end: index + quote.length}));
    if (found.length) return choose(paper, found, anchor, span, 'exact');
    const needle = collapse(quote);
    found = find(flat.text, needle, flatSpan, index => fromFlat(index, needle.length));
    if (found.length) return choose(paper, found, anchor, span, 'whitespace');
    if (!fuzzy) return blockRange();
    const firstLine = collapse(quote.split('\n').find(line => line.trim()) || '');
    for (const opening of [firstLine, needle.slice(0, 80), needle.slice(0, 60), needle.slice(0, 40), needle.slice(0, 25)]) {
      const part = opening.trim();
      if (part.length < 20 || part.length >= needle.length) continue;
      found = find(flat.text, part, flatSpan, index => fromFlat(index, part.length));
      if (found.length) return choose(paper, found, anchor, span, 'opening');
    }
    const prefix = collapse(anchor.prefix), suffix = collapse(anchor.suffix);
    if (prefix.length >= 8 && suffix.length >= 8) {
      for (const at of occurrences(flat.text, prefix, 50)) {
        let from = at + prefix.length, to = flat.text.indexOf(suffix, from);
        if (to < 0) break;
        if (to - from > Math.max(400, needle.length * 2)) continue;
        while (from < to && flat.text[from] === ' ') from++;
        while (to > from && flat.text[to - 1] === ' ') to--;
        if (to > from) return choose(paper, [fromFlat(from, to - from)], anchor, span, 'context');
      }
    }
    return blockRange();
  };
  const highlights = () => typeof Highlight !== 'undefined' && window.CSS?.highlights ? CSS.highlights : null;
  if (config && !config.figure_id) {
    const style = document.createElement('style');
    style.textContent = [
      ':root{--sr-mark:rgba(86,89,214,.5)}@media(prefers-color-scheme:dark){:root{--sr-mark:rgba(165,167,255,.55)}}',
      '::highlight(sr-chat-mark){text-decoration-line:underline;text-decoration-color:var(--sr-mark);text-decoration-thickness:2px;text-underline-offset:.24em}',
      '::highlight(sr-passage){background-color:transparent}',
      // Math is drawn, not text: a marked formula gets a line under it (inline) or beside it (display).
      '.sr-chat-mark-math{box-shadow:0 2px 0 var(--sr-mark)}.sr-chat-mark-display{box-shadow:-6px 0 0 -3px var(--sr-mark)}',
    ].join('');
    document.head.append(style);
  }

  // Go to passage: the same landing and Back as a citation; the passage is briefly tinted.
  window.__scienceReaderGoToPassage = anchor => {
    let found = null;
    try { found = resolvePassage(anchor, true); } catch { found = null; }
    if (!found) return {found: false};
    const entry = {id: 'passage', range: found.range};
    const origin = citationBack?.origin ?? {location: window.__scienceReaderLocation(), cite: null};
    const offersBack = !atTheTop(origin.location);
    citationBack = offersBack ? {origin, entry, landing: null} : null; movedSinceJump = false;
    window.scrollTo({top: scrollTarget(found.range.getBoundingClientRect()), behavior: 'instant'});
    settled(() => {
      if (citationBack && citationBack.entry !== entry) return;
      if (citationBack) citationBack.landing = window.scrollY;
      // Unlike a citation peek, the reader chose to go here: like a contents jump, this becomes the place
      // remembered (leaving the tab and coming back shows the passage); Back still returns to where they were.
      lastPosition = window.__scienceReaderLocation(); post({type: 'position', ...lastPosition});
      // A box over the whole passage, equations included (a CSS highlight painted around MathML and stayed:
      // owner, build 43, "the highlight kind of works but it excludes parts"), fading like a citation flash. The
      // found range stays registered as `sr-passage` without paint of its own (what was found, for Go to passage's
      // checks) and leaves with the box: after the fade, or at once on a tap.
      flash(found.range.getBoundingClientRect());
      const registry = highlights();
      if (!registry) return;
      registry.set('sr-passage', new Highlight(found.range));
      clearTimeout(passageTimer);
      passageTimer = setTimeout(() => registry.delete('sr-passage'), 2600);
    });
    post({type: 'citation', state: 'jumped', id: 'passage', back: offersBack, from: offersBack ? originLabel(origin.location) : ''});
    return {found: true, method: found.method};
  };

  let passageTimer;
  // Marks: passages with conversations on this paper. list: [{id, quote, prefix, suffix, element, same}].
  let marks = [];
  const markedMath = new Set();
  window.__scienceReaderSetMarks = list => {
    marks = [];
    for (const element of markedMath) element.classList.remove('sr-chat-mark-math', 'sr-chat-mark-display');
    markedMath.clear();
    const registry = highlights();
    registry?.delete('sr-chat-mark');
    if (!registry || !config || config.figure_id || !Array.isArray(list)) return 0;
    for (const anchor of list.slice(0, 500)) {
      let found = null;
      try { found = resolvePassage(anchor, false); } catch { found = null; }
      if (found) marks.push({id: String(anchor.id), range: found.range});
    }
    if (!marks.length) return 0;
    registry.set('sr-chat-mark', new Highlight(...marks.map(mark => mark.range)));
    for (const element of document.querySelectorAll('[data-reader-equation]')) {
      if (!marks.some(mark => mark.range.intersectsNode(element))) continue;
      element.classList.add(equationSource.get(element.getAttribute('data-reader-equation'))?.display ? 'sr-chat-mark-display' : 'sr-chat-mark-math');
      markedMath.add(element);
    }
    return marks.length;
  };
  // Two short touch taps in article text open Contents. Mouse double-click and long-press selection remain
  // native. This is separate from citation/figure/equation controls, which must never open Contents as well.
  if (!config?.figure_id) {
    const excluded = 'a,button,input,textarea,select,figure,math,[role="button"],.sr-cite,.sr-toc-link,[data-sr-reference],[data-sr-paper-tags],[data-reader-equation],[data-sr-chrome]';
    let down = null, first = null;
    const onSelection = (x, y) => {
      const selection = window.getSelection();
      if (!selection || selection.isCollapsed || !selection.rangeCount) return false;
      return [...selection.getRangeAt(0).getClientRects()].some(r => x >= r.left - 24 && x <= r.right + 24 && y >= r.top - 24 && y <= r.bottom + 24);
    };
    const article = target => {
      const node = target instanceof Element ? target : target?.parentElement;
      return node && !node.closest(excluded) && node.closest('p,h1,h2,h3,h4,h5,h6,li,blockquote,pre,section,article');
    };
    document.addEventListener('pointerdown', event => {
      if (event.pointerType !== 'touch' || !event.isPrimary || !article(event.target)) { down = first = null; return; }
      // An existing selection is being adjusted (a touch on or beside it), not a request to open Contents. A selection
      // left elsewhere (after Copy or Look Up) no longer swallows every double tap (owner, build 78: "the double tap
      // doesn't bring up table of contents anymore").
      if (!first && onSelection(event.clientX, event.clientY)) { down = null; return; }
      down = {id: event.pointerId, x: event.clientX, y: event.clientY, at: event.timeStamp};
    }, {passive: true});
    document.addEventListener('pointermove', event => {
      if (down?.id === event.pointerId && Math.hypot(event.clientX - down.x, event.clientY - down.y) > 8) down = first = null;
    }, {passive: true});
    document.addEventListener('pointercancel', () => { down = first = null; }, {passive: true});
    document.addEventListener('pointerup', event => {
      const tap = down; down = null;
      if (!tap || tap.id !== event.pointerId || event.timeStamp - tap.at > 250 || !article(event.target)) { first = null; return; }
      if (first && event.timeStamp - first.at < 400 && Math.hypot(event.clientX - first.x, event.clientY - first.y) < 24) {
        first = null; event.preventDefault(); window.getSelection()?.removeAllRanges();
        post({type:'contentsGesture', manifest_sha256:manifest});
      } else first = {x:event.clientX, y:event.clientY, at:event.timeStamp};
    }, {passive: false});
  }
  // The conversations marked at a point: the caret there is inside the mark and the point is on its text.
  // `line` gets the tapped line's box (iPad and the Mac open the passage's chats there).
  const marksAt = (x, y, line) => {
    const caret = document.caretRangeFromPoint?.(x, y);
    if (!caret) return [];
    const ids = [];
    for (const mark of marks) {
      if (ids.includes(mark.id)) continue;
      try { if (!mark.range.isPointInRange(caret.startContainer, caret.startOffset)) continue; } catch { continue; }
      const hit = [...mark.range.getClientRects()].find(rect => x >= rect.left - 2 && x <= rect.right + 2 && y >= rect.top - 4 && y <= rect.bottom + 4);
      if (hit) { ids.push(mark.id); if (line && !line.rect) line.rect = hit; }
    }
    return ids;
  };
  if (config && !config.figure_id) {
    let gesture = null;
    document.addEventListener('pointerdown', event => { gesture = {id: event.pointerId, x: event.clientX, y: event.clientY, moved: false}; }, {passive: true});
    document.addEventListener('pointermove', event => {
      if (gesture?.id === event.pointerId && Math.hypot(event.clientX - gesture.x, event.clientY - gesture.y) > 8) gesture.moved = true;
    }, {passive: true});
    document.addEventListener('pointercancel', () => { if (gesture) gesture.moved = true; }, {passive: true});
    // After the reader's own taps: links, citations, contents rows, figures, references, tags and math keep theirs.
    document.addEventListener('click', event => {
      const moved = gesture?.moved; gesture = null;
      if (moved || !marks.length || !window.getSelection()?.isCollapsed) return;
      const element = event.target instanceof Element ? event.target : event.target?.parentElement;
      if (!element || element.closest(`a,.sr-cite,.sr-toc-link,figure,[role="button"],[data-sr-reference],[data-sr-paper-tags],[data-reader-equation],[${CHROME}]`)) return;
      const line = {}, ids = marksAt(event.clientX, event.clientY, line);
      const r = line.rect;
      if (ids.length) post({type: 'marks', manifest_sha256: manifest, ids,
        rect: r ? {x: r.left, y: Math.max(0, r.top), width: r.width, height: Math.min(r.bottom, window.innerHeight) - Math.max(0, r.top)} : null});
    });
  }
  (() => {
  // Find in the paper, shared by native and browser: every match is a CSS custom highlight; the current one is
  // scrolled to the upper third. Text is matched case-insensitively across inline elements, never across blocks.
  const FIND = 'gradstep-find', CURRENT = 'gradstep-find-current', LIMIT = 1000;
  const BLOCK = 'p,li,h1,h2,h3,h4,h5,h6,figure,figcaption,table,td,th,pre,blockquote,dd,dt,div,section,math[display=block]';
  let findQuery = '', matches = [], current = -1;
  const lower = text => [...text].map(ch => { const l = ch.toLowerCase(); return l.length === ch.length ? l : ch; }).join('').replace(/\s/g, ' ');
  const highlights = () => (globalThis.CSS && CSS.highlights && typeof Highlight === 'function') ? CSS.highlights : null;
  function clearFind() {
    findQuery = ''; matches = []; current = -1;
    highlights()?.delete(FIND); highlights()?.delete(CURRENT);
    return {type: 'find', count: 0, index: -1, matches: []};
  }
  function search(query) {
    const segments = [];
    let flat = '', block = null;
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, { acceptNode: node =>
      !node.data || node.parentElement?.closest('script,style,template,[data-sr-chrome],mjx-assistive-mml,[aria-hidden="true"]') ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT });
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
    if (!query) return clearFind();
    if (query !== findQuery || !matches.length) {
      findQuery = query; matches = search(query);
      // Start from the reading place, like the system find bar.
      current = matches.findIndex(range => range.getBoundingClientRect().bottom > 0);
      if (current < 0) current = matches.length ? 0 : -1;
    } else if (Number.isInteger(direction)) current = Math.max(0, Math.min(matches.length - 1, direction));
    else if (direction === 'previous') current = (current - 1 + matches.length) % matches.length;
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
      if (citationBack) { citationBack = null; post({type:'citation',state:'ended',back:false}); }
      lastPosition = window.__scienceReaderLocation(); postPosition();
    }
    return { type: 'find', count: matches.length, index: current, matches: matches.map((range, index) => {
      const element = range.startContainer.parentElement;
      const block = element.closest('[data-reader-block]') ?? element.closest(BLOCK);
      const text = (block?.textContent ?? range.toString()).replace(/\s+/g, ' ').trim();
      const prefix = document.createRange(); prefix.selectNodeContents(block ?? element); prefix.setEnd(range.startContainer, range.startOffset);
      const offset = prefix.toString().replace(/\s+/g,' ').trimStart().length, start = Math.max(0, offset - 64);
      return {index, text: (start ? '…' : '') + text.slice(start, start + 200) + (text.length > start + 200 ? '…' : '')};
    })};
  }

  window.__scienceReaderFind = find;
  window.__scienceReaderFindClear = clearFind;
  })();

})();
