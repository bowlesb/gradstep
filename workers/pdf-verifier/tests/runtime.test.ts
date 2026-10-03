import assert from "node:assert/strict";
import { createVerifier, sha256 } from "../runtime.ts";
import { inspectMemory } from "../wasm.ts";
import { fixtureBytes, load } from "./load.ts";

Deno.test("binary memory declaration is fixed, memory32 and unshared", async () => {
  const { wasm } = await load();
  assert.deepEqual(inspectMemory(wasm), { minimumPages: 1024, maximumPages: 1024 });
  const fake = Uint8Array.from([0,97,115,109,1,0,0,0,5,5,1,0,128,8,0]);
  assert.throws(() => inspectMemory(fake));
  assert.throws(() => inspectMemory(wasm.subarray(0, 10)));
});

Deno.test("owned PDF and expected identity survive caller mutation during hashing", async () => {
  const { verifier, fixtures } = await load();
  const fixture = fixtures.find((value) => value.name === "pages-1")!;
  const input = await fixtureBytes(fixture);
  const expected = { sha256: fixture.sha256, bytes: fixture.bytes };
  const result = verifier.verify(input, expected);
  input.fill(0); expected.sha256 = "0".repeat(64); expected.bytes = 0;
  assert.equal((await result).outcome, "verified");
  assert.equal((await result).sha256, fixture.sha256);
});

Deno.test("binding mismatch and byte cap cannot produce verified pages", async () => {
  const { verifier, fixtures } = await load();
  const fixture = fixtures.find((value) => value.name === "pages-1")!;
  const wrong = await verifier.verify(await fixtureBytes(fixture), { ...fixture, sha256: "0".repeat(64) });
  assert.equal(wrong.outcome, "binding_mismatch"); assert.equal(wrong.pages, undefined);
  const large = await verifier.verify(new Uint8Array(5242881), { sha256: "0".repeat(64), bytes: 5242881 });
  assert.equal(large.outcome, "input_limit"); assert.equal(large.pages, undefined);
});

Deno.test("one executor refuses overlapping requests; separate instances isolate qpdf globals", async () => {
  const { verifier, fixtures } = await load();
  const nested = fixtures.find((value) => value.name === "parser-nesting")!;
  const valid = fixtures.find((value) => value.name === "pages-1")!;
  const badBytes = await fixtureBytes(nested), goodBytes = await fixtureBytes(valid);
  const first = verifier.verify(badBytes, nested);
  await assert.rejects(verifier.verify(goodBytes, valid), /one_verification_at_a_time/);
  const other = await load();
  const results = await Promise.all([first, other.verifier.verify(goodBytes, valid)]);
  assert.equal(results[0].outcome, "parser_resource_limit");
  assert.equal(results[1].outcome, "verified");
  assert.equal((await verifier.verify(goodBytes, valid)).outcome, "verified");
});

Deno.test("altered module bytes or profile cannot pass the pinned build binding", async () => {
  const { factory, wasm, build } = await load();
  const options = { factory, wasm, wasmSHA256: build.wasm_sha256, profile: build.profile, profileSHA256: build.profile_sha256 };
  const changed = new Uint8Array(wasm); changed[changed.length - 1] ^= 1;
  await assert.rejects(createVerifier({ ...options, wasm: changed }), /verifier_build_mismatch/);
  await assert.rejects(createVerifier({ ...options, profile: { ...build.profile, pages: 250 } }), /invalid_profile/);
  await assert.rejects(createVerifier({ ...options, profile: { ...build.profile, checked_stream_bytes: 67108864 } }), /invalid_profile/);
  assert.equal(await sha256(wasm), build.wasm_sha256);
});
