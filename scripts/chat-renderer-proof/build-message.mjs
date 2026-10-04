import * as esbuild from '../../node_modules/esbuild/lib/main.js';
import { builtinModules } from 'node:module';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { resolve, relative, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { messageFixtures } from './message-fixtures.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const directory = resolve(root, '.artifacts/chat-message-component');
const deps = resolve(root, 'workers/reader-renderer/node_modules');
const sha = value => createHash('sha256').update(value).digest('hex');
const builtins = new Set(builtinModules.flatMap(name => [name, `node:${name}`]));
const approved = { 'mathjax-full': '3.2.2', 'markdown-it': '9.1.0', 'uc.micro': '1.0.6',
  'linkify-it': '2.2.0', mdurl: '1.0.1', punycode: '2.3.1', entities: '1.1.2', saxes: '6.0.0', xmlchars: '2.2.0' };
mkdirSync(directory, { recursive: true });
const result = await esbuild.build({ absWorkingDir: root,
  entryPoints: ['scripts/chat-renderer-proof/message-probe.mjs'], bundle: true,
  platform: 'browser', format: 'iife', target: 'es2020', write: false, metafile: true,
  logLevel: 'silent', plugins: [{ name: 'closed-message-graph', setup(build) {
    build.onResolve({ filter: /.*/ }, args => {
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
  if (approved[data.name] !== data.version) throw new Error(`unreviewed_message_dependency:${data.name}@${data.version}`);
  const licenseFile = ({ punycode: 'LICENSE-MIT.txt', 'uc.micro': 'LICENSE.txt' })[data.name] ?? 'LICENSE';
  // The installed saxes tarball omits LICENSE; retain the exact tagged upstream
  // license locally so this build never needs to fetch code or notices.
  const licensePath = data.name === 'saxes' ? 'scripts/chat-renderer-proof/licenses/saxes-6.0.0-LICENSE' : `${path}/${licenseFile}`;
  const license = readFileSync(resolve(root, licensePath));
  writeFileSync(resolve(directory, `${data.name}-LICENSE`), license);
  return { name: data.name, version: data.version, licensePath, licenseSHA256: sha(license),
    ...(data.name === 'saxes' ? { licenseSource: 'https://raw.githubusercontent.com/lddubeau/saxes/v6.0.0/LICENSE' } : {}) };
});
if (packages.length !== Object.keys(approved).length) throw new Error('unexpected_message_graph');
const bundle = result.outputFiles[0].contents, fixtureData = JSON.stringify(messageFixtures);
writeFileSync(resolve(directory, 'message.js'), bundle);
writeFileSync(resolve(directory, 'fixtures.json'), fixtureData);
const report = { format: 1, scope: 'authored completed-message DOM/copy proof; no shipping renderer or hard resource isolation',
  node: process.version, esbuild: esbuild.version, bytes: bundle.length, sha256: sha(bundle),
  fixturesSHA256: sha(fixtureData), packages,
  harnesses: ['build-message.mjs', 'browser.mjs', 'message-fixtures.mjs', 'webkit.swift', 'output-policy.test.mjs'].map(name => {
    const path = `scripts/chat-renderer-proof/${name}`;
    return { path, sha256: sha(readFileSync(resolve(root, path))) };
  }),
  lockfiles: ['package-lock.json', 'workers/reader-renderer/package-lock.json'].map(path => ({ path, sha256: sha(readFileSync(resolve(root, path))) })),
  inputs: inputs.map(path => ({ path: relative(root, resolve(root, path)), sha256: sha(readFileSync(resolve(root, path))) })),
  disabled, external, warnings: result.warnings };
writeFileSync(resolve(directory, 'build.json'), JSON.stringify(report, null, 2) + '\n');
writeFileSync(resolve(directory, 'metafile.json'), JSON.stringify(result.metafile, null, 2) + '\n');
console.log(JSON.stringify({ directory: relative(root, directory), bytes: report.bytes, sha256: report.sha256,
  packages: packages.map(item => item.name), closedGraph: true }));
