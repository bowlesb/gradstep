import assert from "node:assert/strict";
import { canonicalProfile, sha256, type ModuleFactory, type Profile } from "../runtime.ts";

export const root = new URL("../../../", import.meta.url);
export const artifacts = new URL(".artifacts/pdf-verifier/", root);
export type Fixture = { name: string; file: string; bytes: number; sha256: string; expected: string; pages?: number };

function require(value: unknown, code: string): asserts value {
  if (!value) throw new Error(code);
}

async function read(path: URL, maximum = 16 * 1024 * 1024): Promise<Uint8Array> {
  const info = await Deno.lstat(path);
  require(info.isFile && !info.isSymlink && info.size <= maximum, "invalid_test_bundle_file");
  const bytes = await Deno.readFile(path);
  require(bytes.length <= maximum, "invalid_test_bundle_file");
  return bytes;
}

/** Current is only a local test selector. Remote packaging pins its own digest. */
export async function load(expectedBuild?: string) {
  const pointer = JSON.parse(new TextDecoder().decode(await read(new URL("current-build.json", artifacts), 1024)));
  require(pointer && Object.keys(pointer).sort().join() === "format,identity_sha256" && pointer.format === 1 &&
    typeof pointer.identity_sha256 === "string" && /^[0-9a-f]{64}$/.test(pointer.identity_sha256), "invalid_current_build");
  const buildID = pointer.identity_sha256 as string;
  require(expectedBuild === undefined || expectedBuild === buildID, "current_build_changed_during_smoke");
  const bundle = new URL(`builds/${buildID}/`, artifacts);
  const info = await Deno.lstat(bundle);
  require(info.isDirectory && !info.isSymlink, "invalid_test_bundle_directory");
  const identityRaw = await read(new URL("identity.json", bundle), 262144);
  require(await sha256(identityRaw) === buildID, "test_bundle_identity_mismatch");
  const identity = JSON.parse(new TextDecoder().decode(identityRaw));
  const sources: Record<string, string> = {
    "verifier.cpp": "wrapper_sha256", "runtime.ts": "runtime_sha256", "wasm.ts": "memory_inspector_sha256",
    "build.py": "build_recipe_sha256", "dependencies.lock.json": "dependencies_sha256",
  };
  if (identity.build_store_sha256 !== undefined) sources["build_store.py"] = "build_store_sha256";
  const bound: Record<string, string> = { ...sources, "verifier.wasm": "wasm_sha256", "verifier.mjs": "javascript_sha256", "libqpdf.a": "qpdf_library_sha256" };
  const names = [...Object.keys(bound), "identity.json", "build.json", "profile.json"].sort();
  const manifest = JSON.parse(new TextDecoder().decode(await read(new URL("bundle.json", bundle), 262144)));
  require(manifest && Object.keys(manifest).sort().join() === "files,format,identity_sha256" && manifest.format === 1 &&
    manifest.identity_sha256 === buildID && manifest.files && typeof manifest.files === "object" &&
    Object.keys(manifest.files).sort().join() === names.join(), "invalid_test_bundle_manifest");
  const present: string[] = [];
  for await (const entry of Deno.readDir(bundle)) present.push(entry.name);
  require(present.sort().join() === [...names, "bundle.json"].sort().join(), "test_bundle_file_set_mismatch");
  const files = new Map<string, Uint8Array>();
  for (const name of names) {
    const expected = manifest.files[name];
    require(typeof expected === "string" && /^[0-9a-f]{64}$/.test(expected), "invalid_test_bundle_manifest");
    const bytes = await read(new URL(name, bundle));
    require(await sha256(bytes) === expected, "test_bundle_file_mismatch");
    if (name in bound) require(expected === identity[bound[name]], "test_bundle_source_mismatch");
    if (name !== "libqpdf.a") files.set(name, bytes);
  }
  const build = JSON.parse(new TextDecoder().decode(files.get("build.json")!));
  require(build.build_identity_sha256 === buildID, "test_bundle_provenance_mismatch");
  for (const [key, value] of Object.entries(identity)) assert.deepEqual(build[key], value, "test_bundle_provenance_mismatch");
  const profile = JSON.parse(new TextDecoder().decode(files.get("profile.json")!)) as Profile;
  assert.deepEqual(profile, identity.profile, "test_bundle_profile_mismatch");
  require(await sha256(canonicalProfile(profile)) === identity.profile_sha256, "test_bundle_profile_mismatch");
  // A checked historical bundle does not certify newer working code. Local
  // tests fail until the builder captures those exact sources in a new build.
  for (const [name, key] of Object.entries(sources)) {
    require(await sha256(await read(new URL(`workers/pdf-verifier/${name}`, root))) === identity[key],
      "stale_build_rebuild_before_testing");
  }
  const liveProfile = JSON.parse(new TextDecoder().decode(await read(new URL("workers/pdf-verifier/profile.json", root), 262144)));
  require(await sha256(canonicalProfile(liveProfile)) === build.profile_sha256, "stale_profile_rebuild_before_testing");
  const wasm = files.get("verifier.wasm")!;
  const factory = (await import(new URL("verifier.mjs", bundle).href)).default as ModuleFactory;
  const { createVerifier } = await import(new URL("runtime.ts", bundle).href) as typeof import("../runtime.ts");
  const verifier = await createVerifier({ factory, wasm, wasmSHA256: identity.wasm_sha256,
    profile, profileSHA256: identity.profile_sha256 });
  const fixtures = JSON.parse(await Deno.readTextFile(new URL("fixtures/manifest.json", artifacts))) as Fixture[];
  return { build, buildID, bundle, wasm, factory, verifier, fixtures };
}

export async function fixtureBytes(fixture: Fixture) {
  return await Deno.readFile(new URL(`fixtures/${fixture.file}`, artifacts));
}
