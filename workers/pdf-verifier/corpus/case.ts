/** One isolated, read-only Deno corpus case. No network/env/write/subprocess permissions. */
import { canonicalProfile, createVerifier, sha256, type ModuleFactory, type Profile } from "../runtime.ts";

const expectedIdentity = "2fea7b1c8f842c4c9402720a2f5c4ad8e9b7c343bcea5c6ee29210f1606028b0";
const root = new URL("../../../", import.meta.url);
const artifact = new URL(".artifacts/pdf-verifier/", root);
const started = performance.now();
const identityBytes = await Deno.readFile(new URL("dist/identity.json", artifact));
if (await sha256(identityBytes) !== expectedIdentity) throw new Error("unreviewed_verifier_identity");
const identity = JSON.parse(new TextDecoder().decode(identityBytes));
for (const [file, key] of [["verifier.cpp", "wrapper_sha256"], ["runtime.ts", "runtime_sha256"],
    ["wasm.ts", "memory_inspector_sha256"], ["build.py", "build_recipe_sha256"], ["dependencies.lock.json", "dependencies_sha256"]]) {
  if (await sha256(await Deno.readFile(new URL(`workers/pdf-verifier/${file}`, root))) !== identity[key]) throw new Error("stale_source_identity");
}
const profile = JSON.parse(await Deno.readTextFile(new URL("workers/pdf-verifier/profile.json", root))) as Profile;
if (await sha256(canonicalProfile(profile)) !== identity.profile_sha256 || profile.hosted_admitted !== false) throw new Error("unreviewed_profile");
const wasm = await Deno.readFile(new URL("dist/verifier.wasm", artifact));
const glue = await Deno.readFile(new URL("dist/verifier.mjs", artifact));
if (await sha256(glue) !== identity.javascript_sha256) throw new Error("unreviewed_generated_glue");
const factory = (await import(new URL("dist/verifier.mjs", artifact).href)).default as ModuleFactory;
const verifier = await createVerifier({ factory, wasm, wasmSHA256: identity.wasm_sha256, profile, profileSHA256: identity.profile_sha256 });
const coldLoadMS = performance.now() - started;
const manifest = JSON.parse(await Deno.readTextFile(new URL("workers/pdf-verifier/corpus/manifest.json", root)));
const identifier = Deno.args[0];
if (!/^v[0-9]+-[a-z]+[0-9]+[a-z]$/.test(identifier)) throw new Error("invalid_corpus_id");
const entry = manifest.papers.find((row: {id:string}) => row.id === identifier);
if (!entry || entry.file !== `pdf/${identifier}.pdf` || entry.bytes > 33554432) throw new Error("invalid_corpus_entry");
const file = new URL(`corpus/${entry.file}`, artifact);
const info = await Deno.lstat(file);
if (!info.isFile || info.isSymlink || info.size !== entry.bytes) throw new Error("corpus_file_binding_mismatch");
const bytes = await Deno.readFile(file);
if (await sha256(bytes) !== entry.sha256) throw new Error("corpus_hash_mismatch");
const measurement = await verifier.verify(bytes, { sha256: entry.sha256, bytes: entry.bytes });
if (measurement.outcome !== "verified" && measurement.pages !== undefined) throw new Error("failure_exposed_page_count");
console.log(JSON.stringify({ id: identifier, buildIdentitySHA256: expectedIdentity, artifactSHA256: entry.sha256,
  coldLoadMS, measurement, memoryPostRunSnapshot: Deno.memoryUsage(), memoryIsPeak: false }));
