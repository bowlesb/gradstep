#!/usr/bin/env node
// Citation-linking measurement on real reader bundles (docs/architecture/READER_RENDERER.md).
//
//   node scripts/citation-harness.mjs [--bridge=path/to/reader-bridge.js] [--json=out.json]
//        [--sample=30] [--seed=1] [--examples=5] [--dump=dir] [bundle-dir ...]
//
// Each bundle's index.html is opened in headless WebKit (Playwright; the iOS engine) and the
// reader bridge under test (--bridge, default the app's) runs on it as in the app, in fixture
// mode: no bundle config, which only skips the bundle index checks. Block text must not change.
//
// Ground truth is an independent oracle, not the bridge's citation grammar. Every year in the
// text outside the bibliography is a candidate; its window (the text since the previous year,
// ";" or ")") is compared with each entry's first author (the entry's first segment) and years.
// One entry left, after the year's suffix letter and the most author words in common, is the
// expected target: "linked" means a bridge link covers that year and points at that entry.
// The bibliography itself is found with the current matcher's rules (BIBLIOGRAPHY heading,
// appendix stop), so every bridge version is measured on the same candidates.
//
// The pure matcher (the bridge's CITATION MATCHER section) is evaluated unchanged here and in
// the page; with it the report also lists citations it parsed but left ambiguous or unmatched.
// Bracketed citations ("[Gelfond and Lifschitz 1991]", ACM style) get their own total.
//
// The report also lists every block the bridge formatted as the paper's own contents (or list
// of figures/tables): its caption, entries, entries linked to a heading or run-in head, and
// links whose target disagrees with the entry (number or most words). Any formatted block that
// is not a real contents list is a false positive.
//
// Bundle arguments are bundle folders or folders of them (one level). Default bundles:
// .artifacts/cite-bundles/ and .artifacts/bundles/. One bundle per title unless --all-titles.
import { readFileSync, readdirSync, existsSync, writeFileSync, statSync, mkdirSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { webkit } from 'playwright';

const root = resolve(new URL('..', import.meta.url).pathname);
const argv = process.argv.slice(2);
const args = Object.fromEntries(argv.filter(a => a.startsWith('--')).map(a => { const [k, v] = a.slice(2).split('='); return [k, v ?? 'true']; }));
const current = readFileSync(join(root, 'apps/apple/ScienceReader/Resources/reader-bridge.js'), 'utf8');
const bridgePath = resolve(args.bridge ?? join(root, 'apps/apple/ScienceReader/Resources/reader-bridge.js'));
const bridge = readFileSync(bridgePath, 'utf8');
const EXAMPLES = Number(args.examples ?? 5);

const matcherOf = source => source.match(/\/\/ BEGIN CITATION MATCHER\n([\s\S]*?)\/\/ END CITATION MATCHER/)?.[1] ?? null;
const rules = matcherOf(current);
if (!rules) throw new Error('the app bridge has no CITATION MATCHER section');
const subjectMatcher = matcherOf(bridge);
const Citations = subjectMatcher ? new Function(`${subjectMatcher}\nreturn CitationMatcher;`)() : null;

// Figure, table and algorithm references ("Fig. 1", "Table 2"): the current rules find the candidates, so every
// bridge version is measured on the same ones; each link's target caption is checked independently below.
const figureRulesOf = source => source.match(/\/\/ BEGIN FIGURE REFERENCES\n([\s\S]*?)\/\/ END FIGURE REFERENCES/)?.[1] ?? null;
const figureRules = figureRulesOf(current);

// Measurement only: expose the bridge's reference list to read entry texts, and (bridges that
// format a paper's own contents) each contents link's heading.
const instrumented = bridge.replace('const references = {', 'const references = window.__srAudit = {')
  .replace('const contentsTargets = new WeakMap();', 'const contentsTargets = window.__srContents = new WeakMap();');
if (!instrumented.includes('window.__srAudit')) throw new Error('bridge has no references table to observe');

const dirs = [];
const visit = (dir, depth) => {
  for (const name of readdirSync(dir).sort()) {
    const path = join(dir, name);
    if (!statSync(path).isDirectory()) continue;
    if (existsSync(join(path, 'index.html'))) dirs.push(path); else if (depth < 1) visit(path, depth + 1);
  }
};
const named = argv.filter(a => !a.startsWith('--')).map(a => resolve(a));
for (const dir of named) if (existsSync(join(dir, 'index.html'))) dirs.push(dir); else visit(dir, 0);
if (!named.length) for (const base of ['.artifacts/cite-bundles', '.artifacts/bundles'].map(path => join(root, path))) if (existsSync(base)) visit(base, 0);

// ---- oracle ----
const fold = value => value.normalize('NFKD').replace(/[̀-ͯ]/g, '').replace(/[‘’]/g, "'").toLowerCase();
const YEAR = /(?<![\p{L}\p{N}.:/\-–])((?:19|20)\d{2})([a-z])?(?![\p{L}\p{N}]|[-–]\d|\.\d)/gu;
const STOP = new Set(['the', 'in', 'and', 'et', 'al', 'see', 'of', 'for', 'we', 'on', 'to', 'by', 'with', 'from', 'as', 'an', 'is',
  'are', 'this', 'that', 'our', 'these', 'table', 'figure', 'fig', 'section', 'appendix', 'eq', 'also', 'eg', 'ie', 'cf', 'which', 'it']);
const tokens = text => (fold(text).match(/\p{L}[\p{L}']+/gu) || []).filter(word => !STOP.has(word));
const capitalTokens = text => (text.match(/\p{Lu}[\p{L}'’\-]*\p{L}/gu) || []).flatMap(word => tokens(word));
const entryInfo = entry => {
  const text = entry.text.replace(/^\s*(?:\[[^\]]{1,24}\]|\d{1,4}\.)\s*/, '').replace(/(\p{Lu})\.(?=\p{Lu}\p{Ll})/gu, '$1. ');
  const years = [...text.matchAll(YEAR)].map(match => ({ year: match[1], suffix: match[2] || '' }));
  const first = /^(.*?)(?:,|\s(?:and|&)\s|(?<=\p{L}{2})\.(?:\s|$)|\(|\s(?:19|20)\d{2})/u.exec(text)?.[1] ?? text.slice(0, 40);
  const head = text.slice(0, Math.max(40, text.search(/(?:19|20)\d{2}/)));
  return { ...entry, years, first: new Set(tokens(first)), head: new Set(tokens(head.slice(0, 300))) };
};
const oracle = (blocks, entries) => {
  const out = [];
  for (const block of blocks) {
    let previousEnd = 0, previousWindow = null;
    for (const match of block.text.matchAll(YEAR)) {
      const start = match.index, year = match[1], suffix = match[2] || '';
      let from = Math.max(previousEnd, start - 70);
      const cut = Math.max(block.text.lastIndexOf(';', start), block.text.lastIndexOf(')', start - 1), block.text.lastIndexOf('⁣', start));
      if (cut >= from) from = cut + 1;
      // Inside "( … year": the window starts at the parenthesis, unless only the year follows it ("Name (2017)").
      const open = Math.max(block.text.lastIndexOf('(', start), block.text.lastIndexOf('[', start));
      if (open >= from && /\p{Lu}/u.test(block.text.slice(open, start))) from = open + 1;
      const between = block.text.slice(previousEnd, start);
      let window = block.text.slice(from, start);
      if (previousWindow && previousEnd && /^[\s,]*(?:and\s+)?[(\[]?$/.test(between)) window = previousWindow;
      const words = new Set(capitalTokens(window));
      previousEnd = start + match[0].length; previousWindow = window;
      if (!words.size) continue;
      let found = entries.filter(entry => entry.years.some(value => value.year === year) && [...entry.first].some(word => words.has(word)));
      if (suffix && found.some(entry => entry.years.some(value => value.year === year && value.suffix === suffix))) {
        found = found.filter(entry => entry.years.some(value => value.year === year && value.suffix === suffix));
      }
      if (found.length > 1) {
        // The first author is named first.
        const order = capitalTokens(window);
        const position = entry => order.findIndex(word => entry.first.has(word));
        const best = Math.min(...found.map(position));
        found = found.filter(entry => position(entry) === best);
      }
      if (found.length > 1) {
        const score = entry => [...words].filter(word => entry.head.has(word)).length;
        const best = Math.max(...found.map(score));
        found = found.filter(entry => score(entry) === best);
      }
      // The same entry printed twice is one target.
      if (found.length > 1 && found.every(entry => fold(entry.text).slice(0, 120) === fold(found[0].text).slice(0, 120))) found = [found[0]];
      const context = block.text.slice(Math.max(0, start - 60), start + 12).replace(/\s+/g, ' ').replace(/⁣/g, '¦');
      const looksCited = /et\s+al|[(\[][^()\[\]]*$/.test(window) || /^[a-z]?\s*[)\]]/.test(block.text.slice(previousEnd, previousEnd + 3));
      out.push({ block: block.id, start, end: previousEnd, year, suffix, found, context, looksCited });
    }
  }
  return out;
};

// ---- run ----
const browser = await webkit.launch();
const results = [], samples = [], seen = new Set();
for (const dir of dirs) {
  const html = join(dir, 'index.html');
  const title = (readFileSync(html, 'utf8').match(/<title>([^<]*)/)?.[1] ?? dir).trim();
  if (seen.has(title) && !args["all-titles"]) continue;
  seen.add(title);
  const context = await browser.newContext({ bypassCSP: true, viewport: { width: 390, height: 844 } });
  const page = await context.newPage();
  await page.goto(pathToFileURL(html).href);
  await page.evaluate(() => {
    window.webkit = { messageHandlers: { reader: { postMessage() {} } } };
    window.__before = new Map([...document.querySelectorAll('[data-reader-block]')].map(element => [element.id, element.textContent]));
  });
  const started = Date.now();
  await page.evaluate(instrumented);
  await page.evaluate(() => Promise.race([window.__scienceReaderReady, new Promise(resolve => setTimeout(resolve, 8000))]));
  const elapsed = Date.now() - started;
  const state = await page.evaluate(([rulesSource, figureSource]) => {
    const rules = new Function(`${rulesSource}\nreturn CitationMatcher;`)();
    const audit = window.__srAudit;
    // The bibliography by the current rules (the same walk as collectReferences).
    const members = new Set();
    const heading = [...document.querySelectorAll('h1,h2,h3,h4,h5,h6')].find(element => rules.BIBLIOGRAPHY.test(element.textContent));
    if (heading) {
      const level = Number(heading.tagName[1]);
      for (let node = heading.nextElementSibling; node; node = node.nextElementSibling) {
        if (/^H[1-6]$/.test(node.tagName)) { if (Number(node.tagName[1]) <= level) break; continue; }
        if (node.matches('[data-sr-chrome],.reader-footnotes,figure,.reader-table,pre,hr')) continue;
        if (node.matches('p') && rules.endsBibliography(node.textContent)) break;
        members.add(node);
      }
    }
    const inBibliography = node => { for (let e = node; e; e = e.parentElement) if (members.has(e)) return true; return false; };
    const changed = [...document.querySelectorAll('[data-reader-block]')].filter(element => window.__before.get(element.id) !== element.textContent).length;
    // Block text exactly as the bridge builds it (blockText), with the links found in it.
    const skipped = 'math,.reader-equation,pre,code,a,h1,h2,h3,h4,h5,h6,[data-sr-chrome]';
    const breaks = /^(?:TD|TH|TR|TABLE|THEAD|TBODY|LI|UL|OL|P|DIV|FIGCAPTION|FIGURE|BLOCKQUOTE|IMG)$/;
    const blocks = [];
    for (const element of document.querySelectorAll('[data-reader-block]')) {
      if (element.closest(skipped) || inBibliography(element)) continue;
      let text = '';
      const cites = [], figrefs = [];
      const walk = parent => {
        for (let node = parent.firstChild; node; node = node.nextSibling) {
          if (node.nodeType === Node.TEXT_NODE) { text += node.data; continue; }
          if (node.nodeType !== Node.ELEMENT_NODE) continue;
          if (node.matches(skipped) || node.hasAttribute('data-reader-block') || members.has(node)) { text += '⁣'; continue; }
          if (node.tagName === 'BR') { text += '\n'; continue; }
          const cite = node.matches('.sr-cite:not(.sr-figref)') ? { start: text.length, target: node.getAttribute('data-sr-cite') } : null;
          const figref = node.matches('.sr-figref') ? { start: text.length, target: node.getAttribute('data-sr-figure'), label: node.getAttribute('aria-label') } : null;
          const isBreak = breaks.test(node.tagName);
          if (isBreak) text += '⁣';
          walk(node);
          if (isBreak) text += '⁣';
          if (cite) cites.push({ ...cite, end: text.length });
          if (figref) figrefs.push({ ...figref, end: text.length });
        }
      };
      walk(element);
      // Pieces of one citation split by an inline element are one link.
      const merged = [];
      for (const cite of cites) {
        const last = merged[merged.length - 1];
        if (last && last.target === cite.target && !text.slice(last.end, cite.start).replace(/\s/g, '')) last.end = cite.end;
        else merged.push(cite);
      }
      blocks.push({ id: element.id, container: element.matches("figure,.reader-table,pre"), text, cites: merged.map(cite => ({ ...cite, text: text.slice(cite.start, cite.end) })),
        figrefs: figrefs.map(figref => ({ ...figref, text: text.slice(figref.start, figref.end) })) });
    }
    // Figure references: the candidates the current rules find, and each linked target's own caption text.
    const figureCandidates = [];
    if (figureSource) {
      const Figures = new Function(`${figureSource}\nreturn FigureReferences;`)();
      for (const block of blocks) {
        for (const found of Figures.scan(block.text)) figureCandidates.push({ block: block.id, start: found.start, end: found.end, key: Figures.key(found.kind, found.number),
          context: block.text.slice(Math.max(0, found.start - 40), found.end + 25).replace(/\s+/g, ' ').replace(/⁣/g, '¦') });
      }
    }
    const captionOf = element => {
      if (!element) return '';
      if (element.matches('figure')) return element.querySelector('figcaption')?.textContent ?? '';
      if (element.matches('.reader-table')) return [...element.querySelectorAll('.reader-caption')].map(node => node.textContent).join('\n');
      return element.textContent;
    };
    const figureCaptions = Object.fromEntries([...new Set(blocks.flatMap(block => block.figrefs.map(figref => figref.target)))]
      .map(id => { const element = document.getElementById(id); return [id, { caption: captionOf(element).slice(0, 2000), tag: element?.tagName ?? null,
        neighbours: [element?.previousElementSibling, element?.nextElementSibling].map(node => node?.matches('p') ? node.textContent.slice(0, 300) : '') }]; }));
    const entries = audit.entries.map(entry => ({ id: entry.id, text: entry.text, number: entry.number, label: entry.label }));
    // The paper's own contents lists the bridge formatted, with each heading link's target.
    const contents = [...document.querySelectorAll('.sr-toc')].map(block => ({ id: block.id,
      caption: (block.querySelector('.sr-toc-caption')?.textContent ?? (/^H[1-6]$/.test(block.previousElementSibling?.tagName) ? block.previousElementSibling.textContent : '')).trim(),
      rows: [...block.querySelectorAll(':scope > .sr-toc-entry')].map(row => ({
        label: row.querySelector('.sr-toc-label').textContent.replace(/\s+/g, ' ').trim(), page: row.querySelector('.sr-toc-page').textContent,
        depth: Number(row.getAttribute('data-sr-depth')), linked: row.classList.contains('sr-toc-link'),
        target: window.__srContents?.get(row)?.range.toString().replace(/\s+/g, ' ').trim() ?? null })) }));
    return { changed, blocks, entries, contents, cites: document.querySelectorAll('.sr-cite:not(.sr-figref)').length, figureCandidates, figureCaptions };
  }, [rules, figureRules]);
  await context.close();

  if (args.dump) {
    mkdirSync(resolve(args.dump), { recursive: true });
    writeFileSync(join(resolve(args.dump), title.replace(/[^\p{L}\p{N}]+/gu, '-').slice(0, 40) + '.json'), JSON.stringify(state));
  }
  const entries = state.entries.map(entryInfo);
  const byID = new Map(entries.map(entry => [entry.id, entry]));
  const candidates = oracle(state.blocks, entries);
  const cites = state.blocks.flatMap(block => block.cites.map(cite => ({ ...cite, block: block.id, context: block.text })));
  const isYearCite = cite => /(?:19|20)\d{2}[a-z]?[)\]]?$|^[a-z]$/.test(cite.text);
  const covering = candidate => cites.find(cite => cite.block === candidate.block && cite.start <= candidate.start && candidate.start < cite.end);
  const row = { title, dir: dir.replace(root + '/', ''), entries: entries.length, links: state.cites, ms: elapsed, changed: state.changed,
    candidates: 0, unique: 0, linked: 0, wrong: 0, missed: 0, ambiguous: 0, ambiguousLinked: 0, extra: 0, uncited: 0,
    examples: { missed: [], wrong: [], ambiguous: [], extra: [], unmatched: [] } };
  // Bracketed citations ("[Gelfond and Lifschitz 1991]", ACM style) are counted on their own too.
  const textOf = new Map(state.blocks.map(block => [block.id, block.text]));
  const bracketed = candidate => {
    const open = [];
    for (const char of textOf.get(candidate.block).slice(Math.max(0, candidate.start - 300), candidate.start)) {
      if (char === '[' || char === '(') open.push(char); else if ((char === ']' || char === ')') && open.length) open.pop();
    }
    return open[open.length - 1] === '[';
  };
  Object.assign(row, { bracketUnique: 0, bracketLinked: 0 });
  // Contents lists: entries, heading links, and links whose heading disagrees with the entry.
  const words = value => new Set(fold(value).replace(/^\s*(?:\d{1,2}(?:\.\d{1,2})*|[a-z](?:\s?\.\s?\d{1,2})*)\.?\s+/, '').match(/[\p{L}\p{N}]+/gu) || []);
  const numberOf = value => /^\s*(\d{1,2}(?:\.\d{1,2})*|[A-Z](?:\s?\.\s?\d{1,2})*)\.?\s/.exec(value)?.[1].replace(/\s/g, '') ?? null;
  Object.assign(row, { contents: state.contents.length, contentsEntries: 0, contentsLinked: 0, contentsSuspect: 0 });
  row.examples.contents = state.contents.map(list => `${list.caption || '(no caption)'}: ${list.rows.length} entries, ${list.rows.filter(entry => entry.linked).length} linked; `
    + list.rows.slice(0, 3).map(entry => `${'  '.repeat(entry.depth)}${entry.label} … ${entry.page}`).join(' | '));
  for (const list of state.contents) {
    for (const entry of list.rows) {
      row.contentsEntries += 1;
      if (!entry.linked) continue;
      row.contentsLinked += 1;
      const a = words(entry.label), b = words(entry.target ?? ''), shared = [...a].filter(word => b.has(word)).length;
      const numbers = [numberOf(entry.label), numberOf(entry.target ?? '')];
      if (!entry.target || (numbers[0] && numbers[1] && numbers[0] !== numbers[1].toUpperCase()) || shared * 2 < Math.max(a.size, b.size)) {
        row.contentsSuspect += 1;
        (row.examples.contentsSuspect ??= []).push(`${entry.label} → ${entry.target}`);
      }
    }
  }
  // Figure references: candidates (the current rules), linked ones, and links whose target's caption (or, for a caption
  // paragraph beside it, that paragraph) does not print the label the link names. The oracle reads the link's own text.
  Object.assign(row, { figureCandidates: state.figureCandidates.length, figureLinks: 0, figureLinked: 0, figureSuspect: 0 });
  row.examples.figureUnlinked = []; row.examples.figureSuspect = [];
  const ORACLE_WORDS = { f: String.raw`fig(?:ure)?s?\.?`, t: String.raw`tab(?:le)?s?\.?`, a: String.raw`alg(?:orithm|o)?s?\.?` };
  for (const block of state.blocks) {
    let kind = null;
    for (const figref of block.figrefs) {
      row.figureLinks += 1;
      const text = figref.text.replace(/[ ~]/g, ' ');
      const word = /^\s*([A-Za-z]+)/.exec(text)?.[1].toLowerCase();
      if (word && /^(?:fig|tab|alg)/.test(word)) kind = word[0];
      const number = /([A-Z]\.?\s?\d{1,3}|\d{1,3}(?:\.\d{1,2})?|[IVX]{1,5})(?![\d])/.exec(text.replace(/^\s*(?:fig|tab|alg)[A-Za-z]*\.?/i, ''))?.[1];
      const target = state.figureCaptions[figref.target];
      // At the caption's start, or later with a colon ("… FID=7.89 Figure 4: Bedroom samples").
      const digits = number && number.replace(/\s/g, '').replace(/\./g, '\\.').replace(/^([A-Z])(?:\\\.)?(?=\d)/, '$1\\.?\\s?');
      const printed = number && kind && new RegExp(String.raw`^\s*${ORACLE_WORDS[kind]}\s*${digits}(?![\d])|\s${ORACLE_WORDS[kind]}\s*${digits}(?![\d])\s*:`, 'i');
      const ok = printed && [target?.caption ?? '', ...(target?.tag === 'P' ? [] : target?.neighbours ?? [])].some(caption => printed.test(caption.trim()));
      if (!ok) { row.figureSuspect += 1; row.examples.figureSuspect.push(`"${figref.text}" → ${target?.tag} "${(target?.caption ?? '').slice(0, 70)}"`); }
    }
  }
  for (const candidate of state.figureCandidates) {
    const block = state.blocks.find(value => value.id === candidate.block);
    // A caption's own label ("Figure 3: …" where a caption starts) is not a reference.
    if (/(?:^|[⁣\n])[^\S\n]*$/.test(block.text.slice(0, candidate.start)) && (block.container || /^[^\S\n]*[:.|]/.test(block.text.slice(candidate.end)))) { row.figureCandidates -= 1; continue; }
    if (block.figrefs.some(figref => figref.start <= candidate.start && candidate.start < figref.end)) row.figureLinked += 1;
    else if (row.examples.figureUnlinked.length < EXAMPLES) row.examples.figureUnlinked.push(`${candidate.key}: …${candidate.context}…`);
  }
  const covered = new Set();
  for (const candidate of candidates) {
    const cite = covering(candidate);
    if (cite) covered.add(cite);
    if (candidate.found.length === 1 && bracketed(candidate)) {
      row.bracketUnique += 1;
      if (cite?.target === candidate.found[0].id) row.bracketLinked += 1;
    }
    if (!candidate.found.length) {
      if (candidate.looksCited) { row.uncited += 1; if (row.examples.unmatched.length < EXAMPLES) row.examples.unmatched.push(candidate.context); }
      continue;
    }
    row.candidates += 1;
    if (candidate.found.length > 1) {
      row.ambiguous += 1;
      if (cite && !candidate.found.some(entry => entry.id === cite.target)) {
        row.wrong += 1; row.examples.wrong.push(`${candidate.context} → ${byID.get(cite.target)?.text.slice(0, 70)}`);
      } else {
        if (cite) row.ambiguousLinked += 1;
        if (row.examples.ambiguous.length < EXAMPLES) row.examples.ambiguous.push(`${candidate.context} ⇒ ${candidate.found.map(entry => entry.text.slice(0, 40)).join(' | ')}${cite ? ` [linked: ${byID.get(cite.target)?.text.slice(0, 40)}]` : ''}`);
      }
      continue;
    }
    row.unique += 1;
    const expected = candidate.found[0];
    if (cite?.target === expected.id) row.linked += 1;
    else if (cite) { row.wrong += 1; row.examples.wrong.push(`${candidate.context} → ${byID.get(cite.target)?.text.slice(0, 70)} (expected ${expected.text.slice(0, 50)})`); }
    else { row.missed += 1; if (row.examples.missed.length < EXAMPLES) row.examples.missed.push(`${candidate.context} ⇒ ${expected.text.slice(0, 60)}`); }
  }
  for (const cite of cites.filter(isYearCite)) {
    const context = cite.context.slice(Math.max(0, cite.start - 50), cite.end + 15).replace(/\s+/g, ' ').replace(/⁣/g, '¦');
    samples.push({ paper: title, cite: cite.text.replace(/\s+/g, ' '), context, entry: byID.get(cite.target)?.text.slice(0, 150) });
    if (!covered.has(cite)) { row.extra += 1; if (row.examples.extra.length < EXAMPLES) row.examples.extra.push(`"${cite.text}" in …${context}… → ${byID.get(cite.target)?.text.slice(0, 60)}`); }
  }
  if (Citations) {
    const index = Citations.index(state.entries.map(entry => Citations.parseEntry(entry.text)).filter(Boolean));
    for (const block of state.blocks) {
      for (const found of Citations.scan(block.text, index)) {
        if (found.entry) continue;
        row[`matcher_${found.status}`] = (row[`matcher_${found.status}`] ?? 0) + 1;
        const list = row.examples[`matcher_${found.status}`] ??= [];
        if (list.length < EXAMPLES) list.push(block.text.slice(Math.max(0, found.start - 10), found.end + 5).replace(/\s+/g, ' '));
      }
    }
  }
  results.push(row);
}
await browser.close();

const pct = (a, b) => b ? `${(100 * a / b).toFixed(1)}%` : '–';
const lines = ['| Paper | Entries | Links (all styles) | Author–year candidates | Unambiguous | Linked | Missed | Wrong | Oracle-ambiguous (linked) | Rate |',
  '|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|'];
const total = { candidates: 0, unique: 0, linked: 0, missed: 0, wrong: 0, ambiguous: 0, ambiguousLinked: 0, links: 0, changed: 0 };
for (const row of results) {
  for (const key of Object.keys(total)) total[key] += row[key];
  lines.push(`| ${row.title.length > 46 ? row.title.slice(0, 45) + '…' : row.title} | ${row.entries} | ${row.links} | ${row.candidates} | ${row.unique} | ${row.linked} | ${row.missed} | ${row.wrong} | ${row.ambiguous} (${row.ambiguousLinked}) | ${pct(row.linked, row.unique)} |`);
}
lines.push(`| **All (${results.length} papers)** | | ${total.links} | ${total.candidates} | ${total.unique} | ${total.linked} | ${total.missed} | ${total.wrong} | ${total.ambiguous} (${total.ambiguousLinked}) | **${pct(total.linked, total.unique)}** |`);
console.log(`Bridge: ${bridgePath.replace(root + '/', '')}\n`);
console.log(lines.join('\n'));
console.log(`\nBlocks with changed text: ${total.changed}. Slowest paper: ${Math.max(...results.map(row => row.ms))} ms (bridge ready, headless WebKit).`);
const bracket = results.reduce((sum, row) => [sum[0] + row.bracketLinked, sum[1] + row.bracketUnique, sum[2] + (row.bracketUnique ? 1 : 0)], [0, 0, 0]);
console.log(`Bracketed author–year citations ("[Name and Name 1991]"): ${bracket[0]} of ${bracket[1]} unambiguous linked (${pct(bracket[0], bracket[1])}, ${bracket[2]} papers).`);
const listed = results.filter(row => row.contents);
console.log(`\nContents lists formatted: ${listed.reduce((sum, row) => sum + row.contents, 0)} in ${listed.length} of ${results.length} papers; `
  + `${listed.reduce((sum, row) => sum + row.contentsEntries, 0)} entries, ${listed.reduce((sum, row) => sum + row.contentsLinked, 0)} linked to a heading, `
  + `${listed.reduce((sum, row) => sum + row.contentsSuspect, 0)} links whose heading disagrees with the entry.`);
const figureTotal = results.reduce((sum, row) => [sum[0] + row.figureCandidates, sum[1] + row.figureLinked, sum[2] + row.figureLinks, sum[3] + row.figureSuspect,
  sum[4] + (row.figureLinks ? 1 : 0)], [0, 0, 0, 0, 0]);
console.log(`Figure, table and algorithm references ("Fig. 1", "Tables 2 and 3"): ${figureTotal[1]} of ${figureTotal[0]} found linked (${pct(figureTotal[1], figureTotal[0])}), `
  + `${figureTotal[2]} links in ${figureTotal[4]} papers, ${figureTotal[3]} whose target's caption doesn't print the label.`);
for (const row of results) {
  const shown = Object.entries(row.examples).filter(([, list]) => list.length);
  if (!shown.length) continue;
  console.log(`\n## ${row.title}${Citations ? ` (matcher: ${row.matcher_ambiguous ?? 0} ambiguous, ${row.matcher_unmatched ?? 0} unmatched)` : ''}`);
  for (const [kind, list] of shown) for (const value of list) console.log(`- ${kind}: ${value}`);
}
if (args.sample) {
  let seed = Number(args.seed ?? 1);
  const random = () => (seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648;
  const picked = samples.map(value => [random(), value]).sort((a, b) => a[0] - b[0]).slice(0, Number(args.sample)).map(([, value]) => value);
  console.log(`\n## Spot check: ${picked.length} random author–year links of ${samples.length}`);
  picked.forEach((value, i) => console.log(`${i + 1}. [${value.paper.slice(0, 22)}] "${value.cite}" in "…${value.context}…" → ${value.entry}`));
}
if (args.json) writeFileSync(resolve(args.json), JSON.stringify({ bridge: bridgePath.replace(root + '/', ''), results, total }, null, 2));
