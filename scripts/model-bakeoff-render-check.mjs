// Offline check of saved model output using the reader's pinned math and diagram engines.
import { readFileSync, readdirSync, writeFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { resolve } from 'node:path';
import { chromium } from '@playwright/test';
import { buildSync } from 'esbuild';

const root = resolve('.artifacts/bakeoff/runs');
const browser = await chromium.launch();
const page = await browser.newPage();
await page.route('**/*', route => route.abort());
const renderer = buildSync({ entryPoints: ['apps/web/src/lib/markdown.ts'], bundle: true, format: 'iife',
  globalName: 'BakeoffMarkdown', write: false, logLevel: 'silent' }).outputFiles[0].text;
const rendererHash = createHash('sha256').update(renderer).digest('hex');
await page.addScriptTag({ content: renderer });
await page.addScriptTag({ path: 'apps/apple/ScienceReader/Resources/mermaid.min.js' });
await page.evaluate(() => mermaid.initialize({ startOnLoad: false, securityLevel: 'strict' }));
let checked = 0, invalidMath = 0, invalidDiagrams = 0;
try {
  for (const model of existsSync(root) ? readdirSync(root) : []) for (const name of readdirSync(`${root}/${model}`)) {
    const path = `${root}/${model}/${name}`, record = JSON.parse(readFileSync(path, 'utf8'));
    if (record.error) continue;
    const sourceHash = createHash('sha256').update(JSON.stringify([record.text, record.tool_calls, rendererHash])).digest('hex');
    if (record.rendering?.source_hash === sourceHash) continue;
    // Use the app parser, including dollar delimiters and environments, rather than a partial regex.
    const math = await page.evaluate(text => {
      const box = document.createElement('div'); box.innerHTML = BakeoffMarkdown.renderMarkdown(text);
      return { segments: box.querySelectorAll('math').length,
        bad: [...box.querySelectorAll('merror,.temml-error,.math-source')].map(e => e.textContent.slice(0, 200)) };
    }, record.text ?? '');
    const bad = math.bad;
    const diagram = record.tool_calls?.find(c => c.name === 'create_diagram');
    let drawing = null;
    if (diagram && record.checks?.diagram) {
      drawing = await page.evaluate(async source => {
        try { const { svg } = await mermaid.render('bakeoffDiagram', source); return { valid: !!svg.includes('<svg'), error: null }; }
        catch (error) { return { valid: false, error: String(error).slice(0, 500) }; }
        finally { document.body.replaceChildren(); }
      }, diagram.input.mermaid);
    }
    record.rendering = { source_hash: sourceHash, renderer_sha256: rendererHash, math_segments: math.segments, invalid_math: bad,
      diagram_valid: drawing?.valid ?? null, diagram_error: drawing?.error ?? null };
    writeFileSync(path, JSON.stringify(record, null, 1));
    checked++; invalidMath += bad.length; invalidDiagrams += drawing?.valid === false ? 1 : 0;
  }
} finally { await browser.close(); }
console.log(JSON.stringify({ newly_checked: checked, invalid_math: invalidMath, invalid_diagrams: invalidDiagrams }));
