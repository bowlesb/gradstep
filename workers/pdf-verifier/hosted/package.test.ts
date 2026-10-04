import assert from 'node:assert/strict';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createVerifier, sha256, type ModuleFactory } from '../runtime.ts';
import { CASES } from './handler.ts';

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
  const assets = await import(pathToFileURL(resolve(source, 'assets.ts')).href);
  const factory = (await import(pathToFileURL(resolve(source, 'verifier.mjs')).href)).default as ModuleFactory;
  const decode = (value: string) => Uint8Array.from(atob(value), character => character.charCodeAt(0));
  const verifier = await createVerifier({ factory, wasm: decode(assets.wasmBase64), wasmSHA256: assets.wasmSHA256,
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
