import * as esbuild from '../../node_modules/esbuild/lib/main.js';
import { builtinModules } from 'node:module';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { resolve, relative, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { fixtures } from './fixtures.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const directory = resolve(root, '.artifacts/chat-typesetter-component');
const sha = value => createHash('sha256').update(value).digest('hex');
const builtins = new Set(builtinModules.flatMap(name => [name, `node:${name}`]));
const mathjaxVersion = JSON.parse(readFileSync(resolve(root, 'workers/reader-renderer/node_modules/mathjax-full/package.json'))).version;
if (mathjaxVersion !== '3.2.2') throw new Error('unreviewed_mathjax_version');
mkdirSync(directory, { recursive: true });
const result = await esbuild.build({ absWorkingDir: root,
  entryPoints: ['scripts/chat-renderer-proof/typesetter.mjs'], bundle: true,
  platform: 'browser', format: 'iife', target: 'es2020', write: false, metafile: true,
  logLevel: 'silent', plugins: [{ name: 'reject-node', setup(build) {
    build.onResolve({ filter: /.*/ }, args => builtins.has(args.path)
      ? { errors: [{ text: `Node dependency refused: ${args.path}` }] } : undefined);
  } }] });
const disabled = Object.keys(result.metafile.inputs).filter(path => path.startsWith('(disabled):'));
const external = Object.values(result.metafile.outputs).flatMap(output => output.imports).filter(item => item.external);
if (disabled.length || external.length || result.warnings.length) throw new Error('graph_not_closed');
const bundle = result.outputFiles[0].contents;
writeFileSync(resolve(directory, 'typesetter.js'), bundle);
const fixtureData = JSON.stringify(fixtures);
writeFileSync(resolve(directory, 'fixtures.json'), fixtureData);
const license = 'workers/reader-renderer/node_modules/mathjax-full/LICENSE';
const licenseBytes = readFileSync(resolve(root, license));
writeFileSync(resolve(directory, 'MATHJAX-LICENSE'), licenseBytes);
const packages = new Set(Object.keys(result.metafile.inputs).filter(path => path.includes('/node_modules/'))
  .map(path => path.split('/node_modules/')[1].split('/')[0]));
if (packages.size !== 1 || !packages.has('mathjax-full')) throw new Error('unreviewed_dependency');
const report = { format: 1, scope: 'local component experiment; no shipping renderer or hostile-input isolation claim',
  node: process.version, esbuild: esbuild.version, mathjax: mathjaxVersion, bytes: bundle.length, sha256: sha(bundle),
  fixturesSHA256: sha(fixtureData),
  harnesses: ['build.mjs', 'browser.mjs', 'fixtures.mjs', 'webkit.swift'].map(name => {
    const path = `scripts/chat-renderer-proof/${name}`;
    return { path, sha256: sha(readFileSync(resolve(root, path))) };
  }),
  lockfiles: ['package-lock.json', 'workers/reader-renderer/package-lock.json'].map(path => ({ path, sha256: sha(readFileSync(resolve(root, path))) })),
  license: { path: license, sha256: sha(licenseBytes) },
  inputs: Object.keys(result.metafile.inputs).map(path => ({ path: relative(root, resolve(root, path)), sha256: sha(readFileSync(resolve(root, path))) })),
  disabled, external, warnings: result.warnings };
writeFileSync(resolve(directory, 'build.json'), JSON.stringify(report, null, 2) + '\n');
writeFileSync(resolve(directory, 'metafile.json'), JSON.stringify(result.metafile, null, 2) + '\n');
console.log(JSON.stringify({ directory: relative(root, directory), bytes: report.bytes, sha256: report.sha256, closedGraph: true }));
