// Run the shipped browser figure preparation locally. No network, credentials or inference.
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { build } from 'esbuild';
import { chromium } from '@playwright/test';

const [directory, ordinal] = process.argv.slice(2);
const index = JSON.parse(readFileSync(resolve(directory, 'reader.json')));
const manifest = JSON.parse(readFileSync(resolve(directory, 'manifest.json')));
const figure = index.figures[Number(ordinal) - 1];
if (!figure) throw new Error('Unknown figure');
const images = figure.asset_paths.map(path => [path, readFileSync(resolve(directory, path)).toString('base64')]);
const bundle = await build({ entryPoints: ['apps/web/src/lib/chat-figures.ts'], bundle: true, write: false, format: 'iife', globalName: 'FigurePrep', platform: 'browser' });
const browser = await chromium.launch();
try {
  const page = await browser.newPage();
  await page.route('**/*', route => route.abort());
  await page.addScriptTag({ content: bundle.outputFiles[0].text });
  const result = await page.evaluate(async ({ index, manifest, figure, images }) => {
    const contents = new Map(images.map(([path, data]) => [path, Uint8Array.from(atob(data), c => c.charCodeAt(0))]));
    return await FigurePrep.figureImage({ index, manifest, contents }, figure, 'F1');
  }, { index, manifest, figure, images });
  if (!result) throw new Error('Browser could not prepare this figure');
  process.stdout.write(JSON.stringify(result));
} finally { await browser.close(); }
