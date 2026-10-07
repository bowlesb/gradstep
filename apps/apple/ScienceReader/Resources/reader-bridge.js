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
  const references = {entries: [], byID: new Map(), members: new Set(), index: null};
  let citationBack = null; // {origin:{location,cite}, entry, landing}

  // BEGIN CITATION MATCHER
  // Pure text logic, no DOM: parses bibliography entries and finds in-text
  // citations with their offsets. scripts/citation-harness.mjs evaluates this
  // section unchanged in Node to measure it on real bundles.
  const CitationMatcher = (() => {
    const fold = value => value.normalize('NFKD').replace(/[̀-ͯ]/g, '').replace(/[‘’]/g, "'").toLowerCase();
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
    const NAME_WORD = /^(?:\p{Lu}|[dDlLoO]['’]\p{Lu})[\p{L}\p{M}'’\-]*\p{L}$/u;
    const SUFFIX = /^(?:jr|sr|ii|iii|iv)\.?$/i;
    const kind = word => INITIAL.test(word) ? 'initial' : NAME_WORD.test(word) ? 'name'
      : PARTICLES.has(word.toLowerCase()) ? 'particle' : GROUP_WORDS.has(word.toLowerCase()) ? 'group' : SUFFIX.test(word) ? 'suffix' : null;
    const words = text => text.split(/\s+/).filter(Boolean);
    // One author from its words; null once the words aren't a name (the title has begun).
    const person = (parts, given) => {
      if (!parts.length || parts.length > 7 || parts.some(word => !kind(word))) return null;
      // An organisation in capitals is a name too ("XLA").
      if (parts.length === 1 && /^\p{Lu}{2,}$/u.test(parts[0])) return {words: [fold(parts[0])], key: fold(parts[0]), initials: ''};
      if (!parts.some(word => kind(word) === 'name')) return null;
      const surname = parts.filter(word => kind(word) !== 'initial' && kind(word) !== 'suffix').map(fold);
      return surname.length ? {words: surname, key: surname[surname.length - 1], initials: given.map(word => fold(word)[0]).join('')} : null;
    };
    const SEPARATOR = /\s*,\s*(?:and\s+|&\s*)?|\s*;\s*|\s+and\s+|\s*&\s*/;
    const ENTRY_ET_AL = /(?:^|\s+)(?:et\.?\s*al\.?|others)$/i;
    const parseAuthors = body => {
      // "P.Städter" → "P. Städter", "L.van der Maaten" → "L. van der Maaten". The list ends at a stop
      // after a word (not an initial), a quote, a year or "In:".
      const text = body.slice(0, 700).replace(/(?<![\p{L}.])(\p{Lu})\.(?=\p{L}\p{Ll})/gu, '$1. ');
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
      const surnameFirst = !vancouver && second.length > 0 && first.length <= 4 && first.every(word => ['name', 'particle'].includes(kind(word)))
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
    const CAPITAL = String.raw`(?:\p{Lu}|[dDlLoO]['’]\p{Lu})[\p{L}\p{M}'’\-]*\p{L}`;
    const GROUP = String.raw`(?:collaboration|team|consortium|group|project|authors|contributors|community)`;
    const NAME = String.raw`(?:\p{Lu}\.\s?){0,3}(?:${PARTICLE}\s+){0,3}${CAPITAL}(?:\s+(?:${PARTICLE}\s+){0,3}(?:${CAPITAL}|\p{Lu}\.?(?=\s+\p{Lu})))*(?:\s+${GROUP})?`;
    const ET_AL = String.raw`\s*,?\s*(?:(?:and|&)\s*)?e[tl]\.?\s*al\b\.?(?:['’]s)?`;
    const LIST = String.raw`${NAME}(?:\s*,\s*${NAME})*(?:\s*,?\s*(?:and|&)\s+${NAME})?(?:${ET_AL})?`;
    const BEFORE_YEAR = new RegExp(String.raw`(?<![\p{L}\p{N}'’\-])(${LIST})(\s*,?\s*(?:[(\[]\s*)?)$`, 'u');
    const LIST_ET_AL = new RegExp(ET_AL + '$', 'u');
    const NAME_IN_LIST = new RegExp(NAME, 'gu');
    const YEAR = /(?<![\p{L}\p{N}.\/:\-–])((?:19|20)\d{2})([a-z])?(?![\p{L}\p{N}]|[-–]\d|\.\d)/gu;
    const MORE_SUFFIX = /^\s*,\s*([a-z])(?![\p{L}\p{N}])/u;
    const endsWith = (list, tail) => tail.length <= list.length && tail.every((word, i) => list[list.length - tail.length + i] === word);
    // The names of a cited list, each with its folded surname words and their offsets.
    const names = (list, offset) => [...list.replace(LIST_ET_AL, '').matchAll(NAME_IN_LIST)].map(match => {
      const name = {words: [], starts: [], initials: ''};
      for (const word of match[0].matchAll(/\S+/g)) {
        if (/^(?:\p{Lu}\.?){1,2}$/u.test(word[0]) || /^(?:Jr|Sr|II|III|IV)\.?$/.test(word[0])) {
          if (!name.words.length) name.initials += fold(word[0])[0];
          continue;
        }
        name.words.push(fold(word[0])); name.starts.push(offset + match.index + word.index);
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

  // In-text citations are found in each block's text as a whole, so one may
  // span inline elements or a line break; each piece of it is wrapped in place.
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
        span.setAttribute('data-sr-cite', link.entry.id);
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
      if (block.closest(SKIPPED) || references.members.has(block) || inBibliography(block)) continue;
      const {text, parts} = blockText(block);
      if (!/[\d[]/.test(text)) continue;
      const links = CitationMatcher.scan(text, references.index).filter(link => link.entry);
      if (links.length) wrapCitations(parts, links);
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
