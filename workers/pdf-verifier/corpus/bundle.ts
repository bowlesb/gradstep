/** Bootstrap with built-in primitives only; verify bundle bytes before importing them. */
export const root = new URL("../../../", import.meta.url);
const buildStore = new URL(".artifacts/pdf-verifier/builds/", root);
const researchStore = new URL(".artifacts/pdf-verifier/corpus/research-builds/", root);
type JSONRecord = Record<string, unknown>;

export type NumericAPI = {
  HEAPU8: Uint8Array;
  _malloc(length: number): number;
  _free(pointer: number): void;
  _pdfv_verify(pointer: number, length: number): number;
};
export type ModuleFactory = (...args: unknown[]) => unknown;
type Measurement = { outcome: string; pages?: number; [key: string]: unknown };
type Runtime = {
  createVerifier(options: JSONRecord): Promise<{ verify(input: Uint8Array, binding: {sha256: string; bytes: number}): Promise<Measurement> }>;
  instantiate(factory: ModuleFactory, module: WebAssembly.Module): Promise<{api: NumericAPI}>;
};
export type Bundle = { url: URL; identity: JSONRecord; profile: JSONRecord; runtime: Runtime; wasm: Uint8Array };

function require(value: unknown, code: string): asserts value {
  if (!value) throw new Error(code);
}
export function identifier(value: unknown): string {
  require(typeof value === "string" && /^[0-9a-f]{64}$/.test(value), "invalid_build_identity");
  return value;
}
export async function sha256(raw: Uint8Array): Promise<string> {
  return [...new Uint8Array(await crypto.subtle.digest("SHA-256", new Uint8Array(raw)))].map(x => x.toString(16).padStart(2,"0")).join("");
}
function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value !== null && typeof value === "object") {
    const entries = value as JSONRecord;
    return `{${Object.keys(entries).sort().map(key => `${JSON.stringify(key)}:${canonical(entries[key])}`).join(",")}}`;
  }
  require(!(typeof value === "number" && !Number.isFinite(value)), "nonfinite_bundle_number");
  const encoded = JSON.stringify(value);
  require(encoded !== undefined,"invalid_bundle_value");
  return encoded;
}
function parse(raw: Uint8Array): JSONRecord {
  require(raw.length <= 262144, "bundle_json_limit");
  const value = JSON.parse(new TextDecoder("utf-8",{fatal:true}).decode(raw));
  require(value !== null && typeof value === "object" && !Array.isArray(value), "invalid_bundle_json");
  canonical(value);
  return value;
}
export async function read(url: URL, maximum = 16*1024*1024): Promise<Uint8Array> {
  const before = await Deno.lstat(url);
  require(before.isFile && !before.isSymlink && before.size <= maximum, "invalid_bundle_file");
  const file = await Deno.open(url,{read:true});
  try {
    const info = await file.stat();
    require(info.isFile && info.size === before.size && info.size <= maximum && info.ino === before.ino, "bundle_file_changed");
    const bytes = new Uint8Array(info.size+1);
    let count = 0;
    while (count < bytes.length) {
      const received = await file.read(bytes.subarray(count));
      if (received === null) break;
      require(received > 0,"bundle_read_stalled");
      count += received;
    }
    require(count === info.size,"bundle_file_changed");
    return bytes.subarray(0,count);
  } finally { file.close(); }
}
async function directory(url: URL, names?: Set<string>) {
  const info = await Deno.lstat(url);
  require(info.isDirectory && !info.isSymlink,"invalid_bundle_directory");
  if (names) {
    const observed = new Set<string>();
    for await (const entry of Deno.readDir(url)) observed.add(entry.name);
    require(observed.size === names.size && [...observed].every(name => names.has(name)),"bundle_file_set_mismatch");
  }
}
async function files(url: URL, expected: string, mapping: Record<string,string>, identity: JSONRecord,
    extra: string[]): Promise<Map<string,Uint8Array>> {
  const manifest = parse(await read(new URL("bundle.json",url),262144));
  require(Object.keys(manifest).sort().join(",") === "files,format,identity_sha256" && manifest.format === 1 &&
    manifest.identity_sha256 === expected && manifest.files !== null && typeof manifest.files === "object", "invalid_bundle_manifest");
  const hashes = manifest.files as Record<string,unknown>;
  const names = new Set([...Object.keys(mapping),...extra]);
  require(Object.keys(hashes).length === names.size && Object.keys(hashes).every(name => names.has(name)),"bundle_file_set_mismatch");
  await directory(url,new Set([...names,"bundle.json"]));
  const values = new Map<string,Uint8Array>();
  for (const name of names) {
    const raw = await read(new URL(name,url));
    const hash = await sha256(raw);
    require(hash === identifier(hashes[name]),"bundle_file_mismatch");
    if (mapping[name]) require(hash === identifier(identity[mapping[name]]),"bundle_source_mismatch");
    values.set(name,raw);
  }
  require(await sha256(values.get("identity.json")!) === expected,"bundle_identity_mismatch");
  return values;
}

export async function loadBundle(expected: string, store = buildStore): Promise<Bundle> {
  identifier(expected);
  await directory(store);
  const url = new URL(`${expected}/`,store);
  await directory(url);
  const identityRaw = await read(new URL("identity.json",url),262144);
  require(await sha256(identityRaw) === expected,"bundle_identity_mismatch");
  const identity = parse(identityRaw);
  const mapping: Record<string,string> = {"runtime.ts":"runtime_sha256","wasm.ts":"memory_inspector_sha256",
    "verifier.cpp":"wrapper_sha256","build.py":"build_recipe_sha256","dependencies.lock.json":"dependencies_sha256",
    "verifier.wasm":"wasm_sha256","verifier.mjs":"javascript_sha256","libqpdf.a":"qpdf_library_sha256"};
  if (identity.build_store_sha256 !== undefined) mapping["build_store.py"] = "build_store_sha256";
  const values = await files(url,expected,mapping,identity,["identity.json","profile.json","build.json"]);
  const profile = parse(values.get("profile.json")!);
  require(canonical(profile) === canonical(identity.profile) &&
    await sha256(new TextEncoder().encode(canonical(profile))) === identity.profile_sha256,"bundle_profile_mismatch");
  const provenance = parse(values.get("build.json")!);
  require(provenance.build_identity_sha256 === expected && Object.entries(identity).every(([key,value]) =>
    canonical(provenance[key]) === canonical(value)),"bundle_provenance_mismatch");
  const runtime = await import(new URL("runtime.ts",url).href) as Runtime;
  return {url,identity,profile,runtime,wasm:values.get("verifier.wasm")!};
}

export async function loadResearch(expected: string, store = researchStore, baseStore = buildStore) {
  identifier(expected);
  await directory(store);
  const url = new URL(`${expected}/`,store);
  await directory(url);
  const raw = await read(new URL("identity.json",url),262144);
  require(await sha256(raw) === expected,"research_identity_mismatch");
  const identity = parse(raw);
  require(identity.research_only === true && identity.hosted_admitted === false && identity.limits_changed === false,"invalid_research_identity");
  const originalIdentity = identifier(identity.original_build_identity_sha256);
  const base = await loadBundle(originalIdentity,baseStore);
  for (const [researchKey,baseKey] of [["original_wrapper_sha256","wrapper_sha256"],
    ["profile_sha256","profile_sha256"],["qpdf_library_sha256","qpdf_library_sha256"]]) {
    require(identity[researchKey] === base.identity[baseKey],"research_base_mismatch");
  }
  const values = await files(url,expected,{"research_build.py":"instrumentation_recipe_sha256",
    "verifier-research.cpp":"wrapper_sha256","verifier-research.mjs":"javascript_sha256",
    "verifier-research.wasm":"wasm_sha256"},identity,["identity.json","provenance.json"]);
  require(canonical(parse(values.get("provenance.json")!).identity) === canonical(identity),"research_provenance_mismatch");
  return {url,identity,base,originalIdentity,wasm:values.get("verifier-research.wasm")!};
}
