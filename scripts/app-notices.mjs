#!/usr/bin/env node
// Writes the full license notices of the JavaScript the Apple app ships, for Settings › About › Acknowledgements
// (apps/apple/ScienceReader/Resources/Licenses/):
// - License-Mermaid.txt: the vendored Mermaid browser build (scripts/vendor-mermaid.mjs) and every package it bundles
//   (Mermaid's production dependencies, type packages excluded; the minified file keeps only a few of their notices).
// - License-Reader.txt: the packages esbuild bundles into the on-device reader scripts (arxiv-reader.js,
//   arxiv-source-metadata.js, device-pdf-reader.js; scripts/build-arxiv-compiler.mjs, build-device-pdf-compiler.mjs).
// MIT, ISC, BSD, Apache and EPL require their copyright and license notices to ship with the app. Each package's own
// license file is copied, with where its source is published (EPL-2.0 asks that recipients be told). Run again after
// vendoring Mermaid or changing the reader's dependencies.
//   node scripts/app-notices.mjs [--root=<checkout with node_modules>]
import { createRequire } from 'node:module';
import { existsSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const argument = process.argv.find(a => a.startsWith('--root='));
const root = (argument ? argument.slice('--root='.length) : fileURLToPath(new URL('../', import.meta.url))).replace(/\/?$/, '/');
const modules = join(root, 'node_modules');
const output = name => new URL(`../apps/apple/ScienceReader/Resources/Licenses/${name}`, import.meta.url);

/** The package directory `name` resolves to from `from` (nested node_modules first, as Node resolves). */
function resolve(name, from) {
  for (let dir = from; dir.startsWith(modules) && dir !== modules; dir = dirname(dir)) {
    const candidate = join(dir, 'node_modules', name);
    if (existsSync(join(candidate, 'package.json'))) return candidate;
  }
  const top = join(modules, name);
  return existsSync(join(top, 'package.json')) ? top : null;
}

/** Where the package's source is published. */
function source(pkg) {
  const raw = typeof pkg.repository === 'string' ? pkg.repository : pkg.repository?.url;
  if (!raw) return pkg.homepage ?? null;
  return raw.replace(/^git\+/, '').replace(/^git:\/\//, 'https://').replace(/^ssh:\/\/git@/, 'https://').replace(/\.git$/, '')
    .replace(/^github:/, 'https://github.com/').replace(/^([\w-]+\/[\w.-]+)$/, 'https://github.com/$1');
}

/** One notice per package (and per distinct license text), `first` leading, the rest by name. Versions are named only
 * for `versioned` packages: a prebuilt bundle fixed its dependencies' versions when it was published. */
function notices(dirs, { first, versioned }) {
  const entries = [];
  for (const dir of dirs) {
    const pkg = JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8'));
    const file = readdirSync(dir).find(f => /^(licen[cs]e|copying)(\.(md|txt|mit))?$/i.test(f));
    const license = typeof pkg.license === 'string' ? pkg.license : pkg.license?.type ?? 'see the package';
    const text = file ? readFileSync(join(dir, file), 'utf8').trim() : `License: ${license} (the package ships no license file).`;
    if (entries.some(e => e.name === pkg.name && e.text === text)) continue;
    entries.push({ name: pkg.name, version: versioned(pkg.name) ? pkg.version : null, license, text, source: source(pkg) });
  }
  entries.sort((a, b) => (a.name === first ? -1 : b.name === first ? 1 : a.name.localeCompare(b.name)));
  return entries.map(e => `${e.name}${e.version ? ` ${e.version}` : ''} (${e.license})\n${'='.repeat(60)}\n`
    + (e.source ? `Source: ${e.source}\n\n` : '') + `${e.text}\n`).join('\n\n');
}

// Mermaid: its production dependencies, recursively.
const mermaid = new Map();
(function visit(dir) {
  const pkg = JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8'));
  if (mermaid.has(`${pkg.name}@${pkg.version}`)) return;
  mermaid.set(`${pkg.name}@${pkg.version}`, dir);
  for (const name of Object.keys(pkg.dependencies ?? {})) {
    if (name.startsWith('@types/')) continue;
    const child = resolve(name, dir);
    if (child) visit(child);
  }
})(join(modules, 'mermaid'));
writeFileSync(output('License-Mermaid.txt'), 'Mermaid and the libraries its browser build bundles\n\n'
  + notices(mermaid.values(), { first: 'mermaid', versioned: name => name === 'mermaid' }));

// The reader scripts: exactly the packages esbuild bundles, by the build scripts' own resolution.
const { build } = createRequire(join(root, 'package.json'))('esbuild');
const rootPackages = { name: 'root-packages', setup(b) {
  b.onResolve({ filter: /^[^./]/ }, args => args.path.startsWith('node:') || args.pluginData === 'root' ? undefined
    : b.resolve(args.path, { kind: args.kind, resolveDir: root, importer: args.importer, pluginData: 'root' }));
} };
const alias = { 'node:crypto': join(root, 'scripts/arxiv-compiler/crypto.ts'), 'node:zlib': join(root, 'scripts/arxiv-compiler/zlib.ts') };
const reader = new Set();
for (const entry of ['device-compiler.ts', 'source-metadata-entry.ts', 'device-pdf-compiler.ts']) {
  const result = await build({ absWorkingDir: root, entryPoints: [`supabase/functions/_shared/reader/${entry}`], bundle: true, platform: 'browser',
    target: 'es2022', format: 'iife', write: false, metafile: true, alias, plugins: [rootPackages], logLevel: 'silent' });
  for (const input of Object.keys(result.metafile.inputs)) {
    const at = input.lastIndexOf('node_modules/');
    if (at < 0) continue;
    const parts = input.slice(at + 'node_modules/'.length).split('/');
    reader.add(join(root, input.slice(0, at), 'node_modules', ...(parts[0].startsWith('@') ? parts.slice(0, 2) : parts.slice(0, 1))));
  }
}
writeFileSync(output('License-Reader.txt'), 'The libraries in the scripts that prepare papers for reading on this device\n\n'
  + notices(reader, { first: 'htmlparser2', versioned: () => true }));
console.log(`Mermaid: ${mermaid.size} packages; reader scripts: ${[...reader].map(d => d.split('node_modules/').pop()).join(', ')}`);
