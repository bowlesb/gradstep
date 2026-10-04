/** Research only. Numeric observations from a separate wrapper, no policy changes. */
import { instantiate, sha256, type ModuleFactory, type NumericAPI } from "../runtime.ts";
import { inspectImports, inspectMemory } from "../wasm.ts";

const root = new URL("../../../", import.meta.url);
const original = new URL(".artifacts/pdf-verifier/dist/", root);
const research = new URL(".artifacts/pdf-verifier/corpus/research/", root);
const frozenIdentity = "2fea7b1c8f842c4c9402720a2f5c4ad8e9b7c343bcea5c6ee29210f1606028b0";
const originalIdentityBytes = await Deno.readFile(new URL("identity.json", original));
if (await sha256(originalIdentityBytes) !== frozenIdentity) throw new Error("frozen_identity_changed");
const originalIdentity = JSON.parse(new TextDecoder().decode(originalIdentityBytes));
for (const [file, key] of [["runtime.ts", "runtime_sha256"], ["wasm.ts", "memory_inspector_sha256"]]) {
  if (await sha256(await Deno.readFile(new URL(`workers/pdf-verifier/${file}`, root))) !== originalIdentity[key]) {
    throw new Error("frozen_imported_source_changed");
  }
}
const identityBytes = await Deno.readFile(new URL("identity.json", research));
const identity = JSON.parse(new TextDecoder().decode(identityBytes));
if (!identity.research_only || identity.hosted_admitted !== false || identity.limits_changed !== false ||
    identity.original_build_identity_sha256 !== frozenIdentity) throw new Error("invalid_research_identity");
for (const [url, expected] of [
  [new URL("verifier-research.cpp", research), identity.wrapper_sha256],
  [new URL("verifier-research.mjs", research), identity.javascript_sha256],
  [new URL("workers/pdf-verifier/corpus/research_build.py", root), identity.instrumentation_recipe_sha256],
] as const) {
  if (await sha256(await Deno.readFile(url)) !== expected) throw new Error("research_identity_mismatch");
}
const wasm = await Deno.readFile(new URL("verifier-research.wasm", research));
if (await sha256(wasm) !== identity.wasm_sha256) throw new Error("research_wasm_mismatch");
inspectMemory(wasm);
const module = await WebAssembly.compile(wasm);
inspectImports(module);
const factory = (await import(new URL("verifier-research.mjs", research).href)).default as ModuleFactory;
const { api: base } = await instantiate(factory, module);
const api = base as NumericAPI & { _pdfv_research_metric(index: number): number };
const manifest = JSON.parse(await Deno.readTextFile(new URL("workers/pdf-verifier/corpus/manifest.json", root)));
const id = Deno.args[0];
if (!/^v[0-9]+-[a-z]+[0-9]+[a-z]$/.test(id)) throw new Error("invalid_corpus_id");
const entry = manifest.papers.find((p: {id: string}) => p.id === id);
if (!entry || entry.file !== `pdf/${id}.pdf` || entry.bytes > 33554432) throw new Error("invalid_corpus_entry");
const path = new URL(`.artifacts/pdf-verifier/corpus/${entry.file}`, root);
const info = await Deno.lstat(path);
if (!info.isFile || info.isSymlink || info.size !== entry.bytes) throw new Error("corpus_binding_mismatch");
const bytes = await Deno.readFile(path);
if (await sha256(bytes) !== entry.sha256) throw new Error("corpus_hash_mismatch");
const pointer = api._malloc(bytes.length);
if (!pointer) throw new Error("research_allocation_failure");
try {
  api.HEAPU8.set(bytes, pointer);
  const resultCode = api._pdfv_verify(pointer, bytes.length);
  const names = ["stage", "terminal_line", "limit_kind", "stream_bytes_attempted", "content_bytes_attempted",
    "content_objects_attempted", "object_count", "current_object_id", "exception_code", "warning_count",
    "warning_code_mask", "filter_mask", "global_limit_errors", "exception_byte_offset"];
  const metrics = Object.fromEntries(names.map((name,index) => [name,api._pdfv_research_metric(index) >>> 0]));
  metrics.warnings_after_object_resolution = api._pdfv_research_metric(46) >>> 0;
  const warningCategories = Object.fromEntries(identity.warning_category_patterns.map((pattern:string,index:number) =>
    [pattern,api._pdfv_research_metric(14+index) >>> 0]).filter((entry:[string,number]) => entry[1] > 0));
  const other = api._pdfv_research_metric(45) >>> 0;
  if (other) warningCategories.other_unclassified = other;
  const outcomes: Record<string,string> = {"-1":"malformed", "-2":"encrypted", "-3":"unsupported",
    "-4":"parser_resource_limit", "-5":"malformed", "-6":"internal_error", "-7":"input_limit", "-8":"page_limit"};
  console.log(JSON.stringify({id, researchOnly:true, hostedAdmitted:false,
    originalBuildIdentitySHA256:frozenIdentity, researchIdentitySHA256:await sha256(identityBytes),
    artifactSHA256:entry.sha256, resultCode, outcome:resultCode > 0 ? "verified" : outcomes[String(resultCode)] ?? "unknown",
    metrics, warningCategories}));
} finally { api._free(pointer); }
