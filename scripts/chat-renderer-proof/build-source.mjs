import * as esbuild from '../../node_modules/esbuild/lib/main.js';
import { builtinModules } from 'node:module';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { resolve, relative, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { sourceFixtures } from './source-fixtures.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const directory = resolve(root, '.artifacts/chat-source-component');
const deps = resolve(root, 'workers/reader-renderer/node_modules');
const sha = value => createHash('sha256').update(value).digest('hex');
const builtins = new Set(builtinModules.flatMap(name => [name, `node:${name}`]));
const markdownVersion = JSON.parse(readFileSync(resolve(deps, 'markdown-it/package.json'))).version;
if (markdownVersion !== '9.1.0') throw new Error('unreviewed_markdown_version');
const allowedPackages = new Set(['markdown-it', 'entities', 'linkify-it', 'mdurl', 'punycode', 'uc.micro']);
mkdirSync(directory, { recursive: true });
const result = await esbuild.build({ absWorkingDir: root,
  entryPoints: ['scripts/chat-renderer-proof/source-probe.mjs'], bundle: true,
  platform: 'browser', format: 'iife', target: 'es2020', write: false, metafile: true,
  logLevel: 'silent', plugins: [{ name: 'closed-source-graph', setup(build) {
    build.onResolve({ filter: /.*/ }, args => {
      // Real installed browser implementation, never an empty Node stub.
      if (args.path === 'punycode') return { path: resolve(deps, 'punycode/punycode.js') };
      if (builtins.has(args.path)) return { errors: [{ text: `Node dependency refused: ${args.path}` }] };
    });
  } }] });
const inputs = Object.keys(result.metafile.inputs);
const disabled = inputs.filter(path => path.startsWith('(disabled):'));
const external = Object.values(result.metafile.outputs).flatMap(output => output.imports).filter(item => item.external);
if (disabled.length || external.length || result.warnings.length) throw new Error('graph_not_closed');
const packageRoots = new Set(inputs.flatMap(path => {
  const match = [...path.matchAll(/(?:^|\/)node_modules\/(?:@[^/]+\/)?[^/]+/g)].at(-1);
  return match ? [path.slice(0, match.index + match[0].length)] : [];
}));
const packages = [...packageRoots].map(path => {
  const data = JSON.parse(readFileSync(resolve(root, path, 'package.json')));
  if (!allowedPackages.has(data.name)) throw new Error('unreviewed_source_dependency');
  // The pinned tokenizer graph must have no typesetter, Mathpix or HTML parser.
  const licenseFile = ({ punycode: 'LICENSE-MIT.txt', 'uc.micro': 'LICENSE.txt' })[data.name] ?? 'LICENSE';
  const licensePath = `${path}/${licenseFile}`;
  const license = readFileSync(resolve(root, licensePath));
  writeFileSync(resolve(directory, `${data.name}-LICENSE`), license);
  return { name: data.name, version: data.version, licensePath, licenseSHA256: sha(license) };
});
const bundle = result.outputFiles[0].contents;
// Foundation refuses JSON strings containing isolated surrogate escapes.
// Keep those negative fixtures transportable as explicit UTF-16 code units;
// only the JS test adapter reconstructs them, immediately before admission.
const packagedFixtures = sourceFixtures.map(fixture => {
  if (fixture.source.isWellFormed()) return fixture;
  const { source, ...rest } = fixture;
  return { ...rest, sourceCodeUnits: Array.from({ length: source.length }, (_, index) => source.charCodeAt(index)) };
});
const fixtureData = JSON.stringify(packagedFixtures);
writeFileSync(resolve(directory, 'tokenizer.js'), bundle);
writeFileSync(resolve(directory, 'fixtures.json'), fixtureData);
const report = { format: 1, scope: 'source-only parser/copy proof; no renderer, HTML output, layout or customer input',
  node: process.version, esbuild: esbuild.version, markdown: markdownVersion,
  bytes: bundle.length, sha256: sha(bundle), fixturesSHA256: sha(fixtureData), packages,
  sourceCodeUnitFixtures: packagedFixtures.filter(item => item.sourceCodeUnits).map(item => item.id),
  explicitBrowserResolution: { punycode: 'workers/reader-renderer/node_modules/punycode/punycode.js' },
  harnesses: ['build-source.mjs', 'browser.mjs', 'source-fixtures.mjs', 'tokenizer.test.mjs', 'webkit.swift'].map(name => {
    const path = `scripts/chat-renderer-proof/${name}`;
    return { path, sha256: sha(readFileSync(resolve(root, path))) };
  }),
  lockfiles: ['package-lock.json', 'workers/reader-renderer/package-lock.json'].map(path => ({ path, sha256: sha(readFileSync(resolve(root, path))) })),
  inputs: inputs.map(path => ({ path: relative(root, resolve(root, path)), sha256: sha(readFileSync(resolve(root, path))) })),
  disabled, external, warnings: result.warnings };
writeFileSync(resolve(directory, 'build.json'), JSON.stringify(report, null, 2) + '\n');
writeFileSync(resolve(directory, 'metafile.json'), JSON.stringify(result.metafile, null, 2) + '\n');
console.log(JSON.stringify({ directory: relative(root, directory), bytes: report.bytes, sha256: report.sha256, packages: packages.map(item => item.name), closedGraph: true }));
