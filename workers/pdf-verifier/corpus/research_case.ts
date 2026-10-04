/** Replay an immutable diagnostic build against its immutable original runtime. */
import { identifier, loadResearch, read, root, sha256, type NumericAPI } from "./bundle.ts";

const expectedResearch = identifier(Deno.args[0]);
const manifestSHA256 = identifier(Deno.args[2]);
const selected = await loadResearch(expectedResearch);
const { identity, base, originalIdentity:frozenIdentity } = selected;
const inspector = await import(new URL("wasm.ts",base.url).href);
inspector.inspectMemory(selected.wasm);
const module = await WebAssembly.compile(new Uint8Array(selected.wasm));
inspector.inspectImports(module);
const factory = (await import(new URL("verifier-research.mjs",selected.url).href)).default;
const instance = await base.runtime.instantiate(factory,module);
const api = instance.api as NumericAPI & { _pdfv_research_metric(index:number):number };
const manifestBytes = await read(new URL("workers/pdf-verifier/corpus/manifest.json",root),262144);
if (await sha256(manifestBytes) !== manifestSHA256) throw new Error("corpus_manifest_changed");
const manifest = JSON.parse(new TextDecoder().decode(manifestBytes));
const id = Deno.args[1];
if (!/^v[0-9]+-[a-z]+[0-9]+[a-z]$/.test(id)) throw new Error("invalid_corpus_id");
const entry = manifest.papers.find((p: {id: string}) => p.id === id);
if (!entry || entry.file !== `pdf/${id}.pdf` || entry.bytes > 33554432) throw new Error("invalid_corpus_entry");
const path = new URL(`.artifacts/pdf-verifier/corpus/${entry.file}`, root);
const info = await Deno.lstat(path);
if (!info.isFile || info.isSymlink || info.size !== entry.bytes) throw new Error("corpus_binding_mismatch");
const bytes = await read(path,33554432);
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
  const warningCategories = Object.fromEntries((identity.warning_category_patterns as string[]).map((pattern:string,index:number):[string,number] =>
    [pattern,api._pdfv_research_metric(14+index) >>> 0]).filter((entry:[string,number]) => entry[1] > 0));
  const other = api._pdfv_research_metric(45) >>> 0;
  if (other) warningCategories.other_unclassified = other;
  const outcomes: Record<string,string> = {"-1":"malformed", "-2":"encrypted", "-3":"unsupported",
    "-4":"parser_resource_limit", "-5":"malformed", "-6":"internal_error", "-7":"input_limit", "-8":"page_limit"};
  console.log(JSON.stringify({id, researchOnly:true, hostedAdmitted:false,
    originalBuildIdentitySHA256:frozenIdentity, researchIdentitySHA256:expectedResearch, manifestSHA256,
    artifactSHA256:entry.sha256, resultCode, outcome:resultCode > 0 ? "verified" : outcomes[String(resultCode)] ?? "unknown",
    metrics, warningCategories}));
} finally { api._free(pointer); }
