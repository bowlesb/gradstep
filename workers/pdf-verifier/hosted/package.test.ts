import assert from 'node:assert/strict';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import type { ModuleFactory } from '../runtime.ts';
import { CASES } from './handler.ts';

async function sha256(bytes: Uint8Array): Promise<string> {
  const hash = await crypto.subtle.digest('SHA-256', new Uint8Array(bytes));
  return Array.from(new Uint8Array(hash), value => value.toString(16).padStart(2, '0')).join('');
}

Deno.test('staged source manifest and base64 fixtures retain the exact reviewed verifier bytes', async () => {
  const selected = JSON.parse(await Deno.readTextFile('.artifacts/pdf-verifier/hosted-local-package.json'));
  const root = resolve(selected.directory);
  const source = resolve(root, 'supabase/functions', selected.function);
  const bytes = await Deno.readFile(resolve(root, 'source-manifest.json'));
  assert.equal(await sha256(bytes), selected.source_manifest_sha256);
  const manifest = JSON.parse(new TextDecoder().decode(bytes));
  let size = 0;
  for (const [name, expected] of Object.entries(manifest.source_files)) {
    const raw = await Deno.readFile(resolve(source, name));
    assert.equal(await sha256(raw), expected, name); size += raw.length;
  }
  assert.equal(size, manifest.source_bytes); assert.ok(size <= 3_000_000);
  assert.match(manifest.build_sha256, /^[0-9a-f]{64}$/);
  const identityBytes = await Deno.readFile(resolve('.artifacts/pdf-verifier/builds', manifest.build_sha256, 'identity.json'));
  assert.equal(await sha256(identityBytes), manifest.build_sha256);
  const identity = JSON.parse(new TextDecoder().decode(identityBytes));
  for (const [name, key] of [['runtime.ts', 'runtime_sha256'], ['wasm.ts', 'memory_inspector_sha256'],
    ['verifier.mjs', 'javascript_sha256']]) {
    assert.equal(manifest.source_files[name], identity[key]);
  }
  const assets = await import(pathToFileURL(resolve(source, 'assets.ts')).href);
  assert.equal(assets.config.buildSHA256, manifest.build_sha256);
  const { createVerifier } = await import(pathToFileURL(resolve(source, 'runtime.ts')).href) as typeof import('../runtime.ts');
  const { inspectMemory } = await import(pathToFileURL(resolve(source, 'wasm.ts')).href) as typeof import('../wasm.ts');
  const factory = (await import(pathToFileURL(resolve(source, 'verifier.mjs')).href)).default as ModuleFactory;
  const decode = (value: string) => Uint8Array.from(atob(value), character => character.charCodeAt(0));
  const wasm = decode(assets.wasmBase64);
  assert.equal(await sha256(wasm), identity.wasm_sha256);
  assert.deepEqual(inspectMemory(wasm), { minimumPages: 1024, maximumPages: 1024 });
  const verifier = await createVerifier({ factory, wasm, wasmSHA256: assets.wasmSHA256,
    profile: assets.profile, profileSHA256: assets.profileSHA256 });
  assert.deepEqual(Object.keys(assets.fixtures), [...CASES]);
  for (const name of [...CASES, 'pages-1']) {
    const fixture = assets.fixtures[name], input = decode(fixture.base64);
    assert.equal(input.length, fixture.bytes); assert.equal(await sha256(input), fixture.sha256);
    const result = await verifier.verify(input, fixture);
    assert.equal(result.outcome, fixture.expected, name);
    assert.equal(result.pages ?? null, fixture.pages, name);
    assert.equal(result.sha256, fixture.sha256, name);
  }
});
