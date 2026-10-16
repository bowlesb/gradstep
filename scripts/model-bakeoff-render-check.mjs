// Offline check of saved model output using the reader's pinned math and diagram engines.
import { readFileSync, readdirSync, writeFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { resolve } from 'node:path';
import { chromium } from '@playwright/test';
import temml from '../apps/web/node_modules/temml/dist/temml.mjs';

const root = resolve('.artifacts/bakeoff/runs');
const browser = await chromium.launch();
const page = await browser.newPage();
await page.route('**/*', route => route.abort());
await page.addScriptTag({ path: 'apps/apple/ScienceReader/Resources/mermaid.min.js' });
await page.evaluate(() => mermaid.initialize({ startOnLoad: false, securityLevel: 'strict' }));
let checked = 0, invalidMath = 0, invalidDiagrams = 0;
try {
  for (const model of existsSync(root) ? readdirSync(root) : []) for (const name of readdirSync(`${root}/${model}`)) {
    const path = `${root}/${model}/${name}`, record = JSON.parse(readFileSync(path, 'utf8'));
    if (record.error) continue;
    const sourceHash = createHash('sha256').update(JSON.stringify([record.text, record.tool_calls])).digest('hex');
    if (record.rendering?.source_hash === sourceHash) continue;
    const segments = [...(record.text ?? '').matchAll(/\\\(([\s\S]+?)\\\)|\\\[([\s\S]+?)\\\]/g)];
    const bad = segments.filter(m => {
      try { temml.renderToString(m[1] ?? m[2], { displayMode: m[2] !== undefined, throwOnError: true, trust: false, maxExpand: 1000 }); return false; }
      catch { return true; }
    }).map(m => (m[1] ?? m[2]).slice(0, 200));
    const diagram = record.tool_calls?.find(c => c.name === 'create_diagram');
    let drawing = null;
    if (diagram && record.checks?.diagram) {
      drawing = await page.evaluate(async source => {
        try { const { svg } = await mermaid.render('bakeoffDiagram', source); return { valid: !!svg.includes('<svg'), error: null }; }
        catch (error) { return { valid: false, error: String(error).slice(0, 500) }; }
        finally { document.body.replaceChildren(); }
      }, diagram.input.mermaid);
    }
    record.rendering = { source_hash: sourceHash, math_segments: segments.length, invalid_math: bad,
      diagram_valid: drawing?.valid ?? null, diagram_error: drawing?.error ?? null };
    writeFileSync(path, JSON.stringify(record, null, 1));
    checked++; invalidMath += bad.length; invalidDiagrams += drawing?.valid === false ? 1 : 0;
  }
} finally { await browser.close(); }
console.log(JSON.stringify({ newly_checked: checked, invalid_math: invalidMath, invalid_diagrams: invalidDiagrams }));
