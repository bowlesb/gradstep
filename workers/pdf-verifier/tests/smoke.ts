import assert from "node:assert/strict";
import { instantiate } from "../runtime.ts";
import { fixtureBytes, load } from "./load.ts";

const start = performance.now();
const { buildID, wasm, factory, verifier, fixtures } = await load(Deno.args[2]);
const coldLoadMS = performance.now() - start;
const name = Deno.args[0] ?? "pages-1";
if (name === "probe-oom" || name === "probe-stack") {
  const instance = await instantiate(factory, await WebAssembly.compile(wasm));
  assert.throws(() => instance.memory.grow(1), RangeError);
  if (name === "probe-oom") {
    assert.throws(() => instance.api._malloc(67108864));
    assert.equal(instance.abortReason(), "OOM");
  } else {
    // Force the production module's own instrumented stack guard, without
    // compiling extra test functions or adding a parser input path.
    const guardedAPI = instance.api as typeof instance.api & { ___set_stack_limits(base: number, end: number): void };
    guardedAPI.___set_stack_limits(0, 0);
    assert.throws(() => instance.api._pdfv_verify(0, 0));
    assert.ok(String(instance.abortReason()).startsWith("stack overflow"));
  }
  assert.equal(instance.memory.buffer.byteLength, 67108864);
  const fixture = fixtures.find((value) => value.name === "pages-1")!;
  const next = await verifier.verify(await fixtureBytes(fixture), fixture);
  assert.equal(next.outcome, "verified");
  console.log(JSON.stringify({ buildID, name, coldLoadMS, next, memory: Deno.memoryUsage() }));
} else {
  const fixture = fixtures.find((value) => value.name === name);
  if (!fixture) throw new Error("unknown_fixture");
  const bytes = await fixtureBytes(fixture);
  const measurements = [];
  for (let index = 0; index < (Deno.args[1] === "warm" ? 5 : 1); index++) {
    const result = await verifier.verify(bytes, fixture);
    assert.equal(result.outcome, fixture.expected, fixture.name);
    if (result.outcome === "verified") assert.equal(result.pages, fixture.pages);
    else assert.equal(result.pages, undefined);
    assert.equal(result.sha256, fixture.sha256);
    measurements.push(result);
  }
  // The decompression OOM must also leave a subsequent fresh parse healthy.
  if (fixture.expected === "resource_limit" || fixture.expected === "parser_resource_limit") {
    const next = fixtures.find((value) => value.name === "pages-1")!;
    assert.equal((await verifier.verify(await fixtureBytes(next), next)).outcome, "verified");
  }
  console.log(JSON.stringify({ buildID, name, coldLoadMS, measurements, memory: Deno.memoryUsage() }));
}
