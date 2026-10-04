import assert from 'node:assert/strict';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import type { Synthetic } from './workloads.ts';
import type { ModuleFactory } from '../runtime.ts';

const selectedPath = Deno.args[0];
if (!selectedPath) throw new Error('An explicit local package result path is required');
const selected = JSON.parse(await Deno.readTextFile(selectedPath));
const root = resolve(selected.directory), source = resolve(root, 'supabase/functions', selected.function);
const sha = async (bytes: Uint8Array) => Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', new Uint8Array(bytes))), x => x.toString(16).padStart(2, '0')).join('');
const raw = await Deno.readFile(resolve(root, 'source-manifest.json'));
assert.equal(await sha(raw), selected.source_manifest_sha256);
const manifest = JSON.parse(new TextDecoder().decode(raw));
const assets = await import(pathToFileURL(resolve(source, 'assets.ts')).href);
const decode = (value: string) => Uint8Array.from(atob(value), x => x.charCodeAt(0));

Deno.test('all deployed sources, captured recipes/assets and CLI config retain exact packaged bytes', async () => {
  let bytes = 0;
  for (const [name, expected] of Object.entries(manifest.source_files)) {
    const raw = await Deno.readFile(resolve(source, name));
    assert.equal(await sha(raw), expected, name); bytes += raw.byteLength;
  }
  for (const [name, expected] of Object.entries(manifest.captured_files)) {
    assert.equal(await sha(await Deno.readFile(resolve(root, 'captured', name))), expected, name);
  }
  assert.equal(await sha(await Deno.readFile(resolve(root, 'supabase/config.toml'))), manifest.supabase_config_sha256);
  assert.equal(bytes, manifest.source_bytes); assert.ok(bytes <= 3_000_000);
  assert.deepEqual(assets.config, selected.config); assert.deepEqual(manifest.requests, selected.requests);
  assert.equal(await sha(decode(assets.wasmBase64)), assets.wasmSHA256);
  assert.equal(await sha(decode(assets.fixture.base64)), manifest.recovery_fixture_sha256);
});

Deno.test('real synthetic WASM is import-free, finite, checksum-correct and memory-capped', async () => {
  const bytes = decode(assets.syntheticBase64);
  assert.equal(await sha(bytes), manifest.synthetic_sha256);
  const compiled = await WebAssembly.compile(bytes);
  assert.deepEqual(WebAssembly.Module.imports(compiled), []);
  const module = (await WebAssembly.instantiate(compiled)).exports as unknown as Synthetic;
  assert.equal(module.chunk_iterations(), 262_144); assert.equal(module.memory.buffer.byteLength, 0);
  assert.equal(module.cpu_chunk(manifest.synthetic_seed) >>> 0, manifest.synthetic_first_checksum);
  assert.equal(module.memory.grow(128), 0); assert.equal(module.memory.buffer.byteLength, 8_388_608);
  assert.equal(module.memory.grow(4992), 128); assert.equal(module.memory.buffer.byteLength, 335_544_320);
  assert.throws(() => module.memory.grow(1), RangeError);
});

Deno.test('exact pinned qpdf artifact verifies only the unchanged one-page recovery fixture', async () => {
  const identityRaw = await Deno.readFile(resolve(root, 'captured/verifier-identity.json'));
  assert.equal(await sha(identityRaw), manifest.build_sha256);
  const identity = JSON.parse(new TextDecoder().decode(identityRaw));
  for (const [name, key] of [['runtime.ts', 'runtime_sha256'], ['wasm.ts', 'memory_inspector_sha256'], ['verifier.mjs', 'javascript_sha256']]) {
    assert.equal(manifest.source_files[name], identity[key]);
  }
  const { createVerifier } = await import(pathToFileURL(resolve(source, 'runtime.ts')).href);
  const factory = (await import(pathToFileURL(resolve(source, 'verifier.mjs')).href)).default as ModuleFactory;
  const verifier = await createVerifier({ factory, wasm: decode(assets.wasmBase64), wasmSHA256: assets.wasmSHA256,
    profile: assets.profile, profileSHA256: assets.profileSHA256 });
  const result = await verifier.verify(decode(assets.fixture.base64), assets.fixture);
  assert.equal(result.outcome, 'verified'); assert.equal(result.pages, 1); assert.equal(result.sha256, assets.fixture.sha256);
  assert.equal(assets.profile.hosted_admitted, false);
});
