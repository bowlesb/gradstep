#!/usr/bin/env node
// The iPhone/iPad distribution must omit the local answering runtime and catalogue.
// DeviceModels contains the separately authorized, on-device PDF extraction models.
import { readdirSync, statSync } from 'node:fs';
import { basename, join, resolve } from 'node:path';
import { execFileSync } from 'node:child_process';
const app = resolve(process.argv[2] ?? '');
if (!app.endsWith('.app') || !statSync(app).isDirectory()) throw Error('Pass the built iOS .app');
function files(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap(e => {
    const path = join(dir, e.name);
    if (e.isSymbolicLink()) throw Error(`Unexpected application symlink: ${e.name}`);
    return e.isDirectory() ? [path, ...files(path)] : [path];
  });
}
const forbidden = files(app).filter(path => /(?:^|\/)(?:LocalAI[^/]*|[^/]*mlx[^/]*)(?:\/|$)/i.test(path.slice(app.length))
  || /\.safetensors$/.test(path) || basename(path) === 'models.json');
if (forbidden.length) throw Error(`Local answering resources in iOS app: ${forbidden.map(x => x.slice(app.length + 1)).join(', ')}`);
const executable = execFileSync('/usr/libexec/PlistBuddy', ['-c', 'Print :CFBundleExecutable', join(app, 'Info.plist')], { encoding: 'utf8' }).trim();
if (!/^[A-Za-z0-9_-]+$/.test(executable)) throw Error('Unexpected executable name');
const binary = join(app, executable);
const symbols = execFileSync('nm', ['-j', binary], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, stdio: ['ignore', 'pipe', 'pipe'] });
if (/(?:\$s(?:3MLX|6MLXLLM|6MLXVLM|11MLXLMCommon|7LocalAI)|\b_mlx_|__ZN3mlx)/.test(symbols))
  throw Error('Local answering runtime symbols remain in the iOS executable');
const libraries = execFileSync('otool', ['-L', binary], { encoding: 'utf8' });
if (/\/(?:MLX|LocalAI)[^/]*\.(?:framework|dylib)/i.test(libraries)) throw Error('Local answering library remains linked');
console.log('iOS model boundary passed: no local answering runtime, catalog or weights.');
