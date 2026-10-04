/** Reproduce the exact Supabase v1.77.0 constructor patch in child processes.
 * No parent/global runtime mutation or hosted request. The historical runtime
 * is loaded only from its checked immutable bundle, never from current source.
 * Upstream tree: e847536d7b276428415d7cf9877803d99a16fde5,
 * ext/runtime/js/bootstrap.js:650–672.
 */
import assert from 'node:assert/strict';
import { sha256, type ModuleFactory } from '../runtime.ts';

const root = new URL('../../../', import.meta.url);
const baseline = '2fea7b1c8f842c4c9402720a2f5c4ad8e9b7c343bcea5c6ee29210f1606028b0';

async function child(mode: string, implementation: string, correctedBuild?: string) {
  assert.ok(mode === 'native' || mode === 'supabase_v1_77_0');
  assert.ok(implementation === 'baseline' || implementation === 'corrected');
  const bundle = new URL(`.artifacts/pdf-verifier/builds/${baseline}/`, root);
  const identityBytes = await Deno.readFile(new URL('identity.json', bundle));
  assert.equal(await sha256(identityBytes), baseline);
  const identity = JSON.parse(new TextDecoder().decode(identityBytes));
  for (const [path, expected] of [
    ['runtime.ts', identity.runtime_sha256], ['wasm.ts', identity.memory_inspector_sha256],
    ['verifier.mjs', identity.javascript_sha256], ['verifier.wasm', identity.wasm_sha256],
  ]) assert.equal(await sha256(await Deno.readFile(new URL(path, bundle))), expected);
  let runtimeURL = implementation === 'baseline' ? new URL('runtime.ts', bundle) : new URL('../runtime.ts', import.meta.url);
  let runtimeBuild: string | null = implementation === 'baseline' ? baseline : null;
  if (implementation === 'corrected' && correctedBuild) {
    assert.match(correctedBuild, /^[0-9a-f]{64}$/);
    const correctedBundle = new URL(`.artifacts/pdf-verifier/builds/${correctedBuild}/`, root);
    const raw = await Deno.readFile(new URL('identity.json', correctedBundle));
    assert.equal(await sha256(raw), correctedBuild);
    const corrected = JSON.parse(new TextDecoder().decode(raw));
    // This regression corrects only JavaScript host compatibility. Keep the
    // parser, policy, inspector and executable code bound to the old build.
    for (const key of ['wasm_sha256', 'javascript_sha256', 'wrapper_sha256', 'memory_inspector_sha256', 'profile_sha256']) {
      assert.equal(corrected[key], identity[key]);
    }
    runtimeURL = new URL('runtime.ts', correctedBundle);
    assert.equal(await sha256(await Deno.readFile(runtimeURL)), corrected.runtime_sha256);
    assert.equal(await sha256(await Deno.readFile(new URL('wasm.ts', correctedBundle))), corrected.memory_inspector_sha256);
    runtimeBuild = correctedBuild;
  }
  const runtimeSHA256 = await sha256(await Deno.readFile(runtimeURL));
  const { createVerifier } = await import(runtimeURL.href) as typeof import('../runtime.ts');
  const originalMemoryConstructor = WebAssembly.Memory;
  let scheduledMemoryChecks = 0;
  if (mode === 'supabase_v1_77_0') {
    // The body is the upstream patch, with only its host op represented by a
    // counter. It runs solely in this short-lived child process.
    const ops = { op_schedule_mem_check() { scheduledMemoryChecks += 1; } };
    const wasmMemoryCtor = globalThis.WebAssembly.Memory;
    const wasmMemoryPrototypeGrow = wasmMemoryCtor.prototype.grow;
    function patchedWasmMemoryPrototypeGrow(this: WebAssembly.Memory, delta: number) {
      const mem = wasmMemoryPrototypeGrow.call(this, delta);
      ops.op_schedule_mem_check();
      return mem;
    }
    wasmMemoryCtor.prototype.grow = patchedWasmMemoryPrototypeGrow;
    function patchedWasmMemoryCtor(maybeOpts: WebAssembly.MemoryDescriptor) {
      if (typeof maybeOpts === 'object' && maybeOpts['shared'] === true) {
        throw new TypeError('Creating a shared memory is not supported');
      }
      return new wasmMemoryCtor(maybeOpts);
    }
    Reflect.set(globalThis, 'SharedArrayBuffer', globalThis.ArrayBuffer);
    Reflect.set(globalThis.WebAssembly, 'Memory', patchedWasmMemoryCtor);
  }
  const originalFactory = (await import(new URL('verifier.mjs', bundle).href)).default as ModuleFactory;
  const observed = {
    factory_calls: 0, instantiation_callbacks: 0, memory_export_count: 0,
    memory_instanceof_global: false, memory_instanceof_original: false,
    memory_byte_length: 0, heap_u8_byte_length: 0, abi: 0, parser_version: 0, stack_bytes: 0,
  };
  const factory: ModuleFactory = async options => {
    observed.factory_calls += 1;
    const api = await originalFactory({ ...options, instantiateWasm(imports, receive) {
      // Delegate to the unchanged runtime's existing instantiation. Do not
      // create an extra instance, replace exports, or fix the failing check.
      return options.instantiateWasm(imports, instance => {
        observed.instantiation_callbacks += 1;
        const memories = Object.values(instance.exports).filter(value => value instanceof originalMemoryConstructor) as WebAssembly.Memory[];
        observed.memory_export_count = memories.length;
        if (memories.length === 1) {
          observed.memory_instanceof_global = memories[0] instanceof WebAssembly.Memory;
          observed.memory_instanceof_original = memories[0] instanceof originalMemoryConstructor;
          observed.memory_byte_length = memories[0].buffer.byteLength;
        }
        receive(instance);
      });
    } });
    // These three pinned, constant numeric ABI functions do not parse input.
    observed.heap_u8_byte_length = api.HEAPU8.byteLength;
    observed.abi = api._pdfv_abi();
    observed.parser_version = api._pdfv_parser_version();
    observed.stack_bytes = api._pdfv_stack_bytes();
    return api;
  };
  const verifier = await createVerifier({ factory,
    wasm: await Deno.readFile(new URL('verifier.wasm', bundle)),
    wasmSHA256: identity.wasm_sha256, profile: identity.profile, profileSHA256: identity.profile_sha256 });
  const fixtures = JSON.parse(await Deno.readTextFile(new URL('.artifacts/pdf-verifier/fixtures/manifest.json', root)));
  const fixture = fixtures.find((value: { name: string }) => value.name === 'pages-1');
  const input = await Deno.readFile(new URL('.artifacts/pdf-verifier/fixtures/pages-1.pdf', root));
  assert.equal(await sha256(input), fixture.sha256);
  let outcome: string, pages: number | null = null;
  try {
    const result = await verifier.verify(input, fixture);
    outcome = result.outcome; pages = result.pages ?? null;
  } catch (error) {
    assert.ok(error instanceof Error && error.message === 'verifier_abi_mismatch');
    outcome = 'verifier_abi_mismatch';
  }
  console.log(JSON.stringify({ mode, implementation, baseline, runtime_build: runtimeBuild,
    runtime_sha256: runtimeSHA256, outcome, pages, ...observed, scheduled_memory_checks: scheduledMemoryChecks }));
}

if (Deno.args[0] === '--child') {
  await child(Deno.args[1], Deno.args[2], Deno.args[3]);
} else {
  const correctedBuild = Deno.args[0] === '--corrected-build' ? Deno.args[1] : undefined;
  if (correctedBuild) assert.match(correctedBuild, /^[0-9a-f]{64}$/);
  Deno.test('frozen failure and corrected success are isolated from the host constructor identity', async () => {
    const parentMemory = WebAssembly.Memory;
    for (const implementation of ['baseline', 'corrected']) for (const mode of ['native', 'supabase_v1_77_0']) {
      const output = await new Deno.Command(Deno.execPath(), {
        args: ['run', '--allow-read', import.meta.url, '--child', mode, implementation, ...(correctedBuild ? [correctedBuild] : [])],
        stdout: 'piped', stderr: 'piped',
      }).output();
      assert.equal(output.code, 0, new TextDecoder().decode(output.stderr));
      const result = JSON.parse(new TextDecoder().decode(output.stdout));
      const succeeds = implementation === 'corrected' || mode === 'native';
      assert.match(result.runtime_sha256, /^[0-9a-f]{64}$/);
      assert.deepEqual(result, {
        mode, implementation, baseline, runtime_build: implementation === 'baseline' ? baseline : correctedBuild ?? null,
        runtime_sha256: result.runtime_sha256, outcome: succeeds ? 'verified' : 'verifier_abi_mismatch', pages: succeeds ? 1 : null,
        factory_calls: 1, instantiation_callbacks: 1, memory_export_count: 1,
        memory_instanceof_global: mode === 'native', memory_instanceof_original: true,
        memory_byte_length: 67108864, heap_u8_byte_length: 67108864, abi: 1, parser_version: 120402,
        stack_bytes: 2097152, scheduled_memory_checks: 0,
      });
      console.log(JSON.stringify(result));
    }
    assert.equal(WebAssembly.Memory, parentMemory);
  });
}
