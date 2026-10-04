import assert from "node:assert/strict";
import { instantiate, type ModuleFactory, type NumericAPI } from "../runtime.ts";

const memoryBytes = 67108864;

function unsigned(value: number): number[] {
  const bytes: number[] = [];
  do {
    const part = value & 0x7f;
    value = Math.floor(value / 128);
    bytes.push(part | (value ? 0x80 : 0));
  } while (value);
  return bytes;
}

/** Small actual Wasm modules exercise export descriptors without generated glue. */
function moduleWithMemory(names = ["heap"], pages = 1024): WebAssembly.Module {
  const memory = [1, 1, ...unsigned(pages), ...unsigned(pages)];
  const exports = [names.length, ...names.flatMap((name) => {
    const encoded = new TextEncoder().encode(name);
    return [...unsigned(encoded.length), ...encoded, 2, 0];
  })];
  return new WebAssembly.Module(Uint8Array.from([
    0, 97, 115, 109, 1, 0, 0, 0,
    5, ...unsigned(memory.length), ...memory,
    7, ...unsigned(exports.length), ...exports,
  ]));
}

function apiFor(memory: WebAssembly.Memory): NumericAPI {
  return {
    HEAPU8: new Uint8Array(memory.buffer),
    _pdfv_abi: () => 1,
    _pdfv_parser_version: () => 120402,
    _pdfv_stack_bytes: () => 2097152,
    _pdfv_verify: () => { throw new Error("No PDF parse belongs in an ABI test"); },
    _malloc: () => { throw new Error("No allocation belongs in an ABI test"); },
    _free: () => { throw new Error("No free belongs in an ABI test"); },
  };
}

function factoryWith(change: (api: NumericAPI) => void = () => {}): ModuleFactory {
  return (options) => {
    let api: NumericAPI | undefined;
    options.instantiateWasm({}, (instance) => {
      api = apiFor(instance.exports.heap as WebAssembly.Memory);
      change(api);
    });
    assert.ok(api);
    return api;
  };
}

Deno.test("ABI binds the heap to the descriptor-selected actual instance memory", async () => {
  const result = await instantiate(factoryWith(), moduleWithMemory());
  assert.equal(result.memory.buffer.byteLength, memoryBytes);
  assert.equal(result.api.HEAPU8.buffer, result.memory.buffer);
  assert.equal(result.api.HEAPU8.byteOffset, 0);
  assert.equal(result.api.HEAPU8.byteLength, memoryBytes);
});

Deno.test("zero or duplicate memory export descriptors reject before invoking glue", async () => {
  for (const names of [[], ["heap", "alias"]]) {
    let called = false;
    const factory: ModuleFactory = () => { called = true; throw new Error("unexpected factory"); };
    await assert.rejects(instantiate(factory, moduleWithMemory(names)), /invalid_verifier_memory_export/);
    assert.equal(called, false);
  }
});

Deno.test("a correct-size unrelated heap cannot satisfy the instance binding", async () => {
  await assert.rejects(instantiate(factoryWith((api) => {
    api.HEAPU8 = new Uint8Array(memoryBytes);
  }), moduleWithMemory()), /verifier_abi_mismatch/);
});

Deno.test("detached, truncated and offset heap views reject without a parse", async () => {
  const alterations: Array<(api: NumericAPI) => void> = [
    (api) => {
      const buffer = new ArrayBuffer(memoryBytes);
      api.HEAPU8 = new Uint8Array(buffer);
      structuredClone(buffer, { transfer: [buffer] });
      assert.equal(api.HEAPU8.byteLength, 0);
    },
    (api) => { api.HEAPU8 = new Uint8Array(api.HEAPU8.buffer, 0, memoryBytes - 1); },
    (api) => { api.HEAPU8 = new Uint8Array(new ArrayBuffer(memoryBytes + 1), 1, memoryBytes); },
  ];
  for (const change of alterations) {
    await assert.rejects(instantiate(factoryWith(change), moduleWithMemory()), /verifier_abi_mismatch/);
  }
});

Deno.test("descriptor selection still rejects a wrong-size exported memory", async () => {
  await assert.rejects(instantiate(factoryWith(), moduleWithMemory(["heap"], 1023)), /verifier_abi_mismatch/);
});

Deno.test("ABI version, parser version and fixed stack checks all remain mandatory", async () => {
  for (const name of ["_pdfv_abi", "_pdfv_parser_version", "_pdfv_stack_bytes"] as const) {
    await assert.rejects(instantiate(factoryWith((api) => {
      api[name] = () => 0;
    }), moduleWithMemory()), /verifier_abi_mismatch/);
  }
});
