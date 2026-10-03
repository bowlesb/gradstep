import { canonicalProfile, createVerifier, sha256, type ModuleFactory, type Profile } from "../runtime.ts";

export const root = new URL("../../../", import.meta.url);
export const artifacts = new URL(".artifacts/pdf-verifier/", root);
export type Fixture = { name: string; file: string; bytes: number; sha256: string; expected: string; pages?: number };

export async function load() {
  const build = JSON.parse(await Deno.readTextFile(new URL("dist/build.json", artifacts)));
  for (const [file, expected] of [["verifier.cpp", build.wrapper_sha256], ["runtime.ts", build.runtime_sha256],
      ["wasm.ts", build.memory_inspector_sha256], ["build.py", build.build_recipe_sha256]]) {
    if (await sha256(await Deno.readFile(new URL(`workers/pdf-verifier/${file}`, root))) !== expected) {
      throw new Error("stale_build_rebuild_before_testing");
    }
  }
  const profile = JSON.parse(await Deno.readTextFile(new URL("workers/pdf-verifier/profile.json", root))) as Profile;
  if (await sha256(canonicalProfile(profile)) !== build.profile_sha256) throw new Error("stale_profile_rebuild_before_testing");
  const wasm = await Deno.readFile(new URL("dist/verifier.wasm", artifacts));
  const javascript = await Deno.readFile(new URL("dist/verifier.mjs", artifacts));
  if (await sha256(javascript) !== build.javascript_sha256) throw new Error("generated_glue_mismatch");
  const factory = (await import(new URL("dist/verifier.mjs", artifacts).href)).default as ModuleFactory;
  const verifier = await createVerifier({ factory, wasm, wasmSHA256: build.wasm_sha256,
    profile: build.profile as Profile, profileSHA256: build.profile_sha256 });
  const fixtures = JSON.parse(await Deno.readTextFile(new URL("fixtures/manifest.json", artifacts))) as Fixture[];
  return { build, wasm, factory, verifier, fixtures };
}

export async function fixtureBytes(fixture: Fixture) {
  return await Deno.readFile(new URL(`fixtures/${fixture.file}`, artifacts));
}
