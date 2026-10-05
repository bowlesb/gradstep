/** One local, paused stored-readback verifier. No SQL, Storage or network API.
 *
 * The parent owns the inherited read-only stdin FD, absolute deadline and exact
 * child wait. This receiver's relative checks cannot interrupt synchronous WASM.
 * Captured files are trusted same-owner read-only inputs, not a hostile-owner
 * filesystem boundary. No parser module is imported before GO and payload hash.
 */
const BUILD = "39980de20b9cd8717d10318e8f0c0a8869bf184c1292fe31987fe34c6e707610";
const PROFILE_SHA = "c8478d6e1b1f7a8631132789a471a7f525123f40d2e893890254fb1660b54962";
const PROFILE_ID = "qpdf-wasm-pilot-v1";
const MAX_PDF = 5_242_880;
const MAX_INPUT = 16_384;
const MAX_CONTROL = 4_096;
const CHUNK = 65_536;
const ROOT = new URL("./", import.meta.url);
const ENCODER = new TextEncoder();
const DECODER = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });
const LIMITS = {
  "original_verifier.mjs": 65_536, "runtime.ts": 65_536, "wasm.ts": 65_536,
  "verifier.mjs": 65_536, "verifier.wasm": 2_097_152,
  "profile.json": 16_384, "identity.json": 16_384,
};
const REQUEST_KEYS = ["version", "kind", "job_id", "reservation_id", "source_id", "source_revision",
  "bucket", "path", "predecessor_operation_id", "predecessor_result_sha256", "candidate_sha256",
  "candidate_bytes", "input_spool_sha256", "byte_ceiling", "verification_profile_id", "build_sha256",
  "parser_profile_sha256", "verifier_host_policy_sha256", "storage_policy_sha256", "spool_policy_sha256",
  "stage_recipe_sha256"];
const BINDING_KEYS = ["reservation_id", "claim_id", "attempt_id", "purpose", "request_sha256",
  "binding_sha256", "capture_sha256"];
const REASONS = new Set(["input_mismatch", "input_changed", "bundle_changed", "receiver_failure", "deadline"]);
const OUTCOMES = new Set(["verified", "malformed", "encrypted", "unsupported", "parser_resource_limit",
  "resource_limit", "internal_error", "input_limit", "page_limit", "binding_mismatch"]);

class Refused extends Error {
  constructor(reason) { super(reason); this.reason = reason; }
}
function require(value, reason = "receiver_failure") {
  if (!value) throw new Refused(reason);
}
function record(value, keys) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
  const actual = Object.keys(value).sort(), expected = [...keys].sort();
  return actual.length === expected.length && actual.every((key, index) => key === expected[index]);
}
function integer(value, minimum, maximum) {
  return Number.isSafeInteger(value) && value >= minimum && value <= maximum;
}
function shaText(value) { return typeof value === "string" && value.length === 64 && /^[0-9a-f]{64}$/.test(value); }
function uuid(value) {
  return typeof value === "string" && value.length === 36 &&
    /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(value);
}
function decimal(value, positive = false) {
  if (typeof value !== "string" || !/^(0|[1-9][0-9]{0,19})$/.test(value)) return false;
  const number = BigInt(value);
  return number.toString() === value && number <= 18_446_744_073_709_551_615n && (!positive || number > 0n);
}
function canonical(value, depth = 0) {
  require(depth <= 32);
  if (Array.isArray(value)) return `[${value.map(item => canonical(item, depth + 1)).join(",")}]`;
  if (value !== null && typeof value === "object") {
    const keys = Object.keys(value).sort();
    require(keys.length <= 256);
    return `{${keys.map(key => `${JSON.stringify(key)}:${canonical(value[key], depth + 1)}`).join(",")}}`;
  }
  require(typeof value !== "number" || Number.isFinite(value));
  const encoded = JSON.stringify(value);
  require(encoded !== undefined);
  return encoded;
}
function parseCanonical(raw, trailingLF = false) {
  const text = DECODER.decode(raw);
  const value = JSON.parse(text);
  // Re-encoding also rejects duplicate keys, alternate escapes and whitespace.
  require(text === canonical(value) + (trailingLF ? "\n" : ""));
  return value;
}
async function sha(raw) {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", raw));
  return [...digest].map(byte => byte.toString(16).padStart(2, "0")).join("");
}
async function emit(value) {
  const bytes = ENCODER.encode(canonical(value) + "\n");
  require(bytes.length <= MAX_CONTROL);
  let written = 0;
  while (written < bytes.length) {
    const count = await Deno.stdout.write(bytes.subarray(written));
    require(integer(count, 1, bytes.length - written));
    written += count;
  }
}

class Control {
  constructor(file) { this.file = file; this.pending = new Uint8Array(); }
  async line(maximum) {
    const output = new Uint8Array(maximum);
    let used = 0;
    while (used < maximum) {
      let part = this.pending;
      this.pending = new Uint8Array();
      if (part.length === 0) {
        const buffer = new Uint8Array(Math.min(4_096, maximum - used));
        const count = await this.file.read(buffer);
        require(integer(count, 1, buffer.length));
        part = buffer.subarray(0, count);
      }
      const newline = part.indexOf(10);
      const length = newline < 0 ? part.length : newline + 1;
      require(used + length <= maximum);
      output.set(part.subarray(0, length), used);
      used += length;
      if (newline >= 0) {
        this.pending = part.slice(length);
        return output.subarray(0, used);
      }
    }
    throw new Refused("receiver_failure");
  }
  async eof() {
    require(this.pending.length === 0);
    require(await this.file.read(new Uint8Array(1)) === null);
  }
}

function sourceID(value) {
  if (typeof value !== "string" || value.length > 128) return false;
  const modern = /^([0-9]{2})([0-9]{2})\.([0-9]{4,5})$/.exec(value);
  if (modern && modern[0] === value) {
    const [, yy, mm, serial] = modern, year = Number(yy), month = Number(mm);
    return month >= 1 && month <= 12 && year >= 7 && !(year === 7 && month < 4) &&
      Number(serial) > 0 && serial.length === (year < 15 ? 4 : 5);
  }
  const historic = /^([a-z][a-z0-9-]*)\/([0-9]{2})([0-9]{2})([0-9]{3})$/.exec(value);
  if (!historic || historic[0] !== value) return false;
  const [, , yy, mm, serial] = historic, year = Number(yy), month = Number(mm);
  return month >= 1 && month <= 12 && Number(serial) > 0 && !(year > 7 && year < 91) &&
    !(year === 91 && month < 7) && !(year === 7 && month > 3);
}
function inode(value) {
  return record(value, ["device", "inode"]) && decimal(value.device) && decimal(value.inode, true);
}
async function inputRecord(raw) {
  const value = parseCanonical(raw, true);
  require(record(value, ["format", "local_fixture_only", "claim_id", "request", "request_sha256", "spool_descriptor"]) &&
    value.format === "original-verifier-input-v1" && value.local_fixture_only === true &&
    uuid(value.claim_id) && shaText(value.request_sha256));
  const request = value.request;
  require(record(request, REQUEST_KEYS) && request.version === 1 && request.kind === "original_verify");
  for (const key of ["job_id", "reservation_id", "predecessor_operation_id", "verification_profile_id"]) require(uuid(request[key]));
  for (const key of ["predecessor_result_sha256", "candidate_sha256", "input_spool_sha256", "build_sha256",
    "parser_profile_sha256", "verifier_host_policy_sha256", "storage_policy_sha256", "spool_policy_sha256", "stage_recipe_sha256"]) require(shaText(request[key]));
  require(sourceID(request.source_id) && integer(request.source_revision, 1, 2_147_483_647) &&
    request.bucket === "paper-assets" && request.path === `originals/${request.reservation_id}/original.pdf` &&
    integer(request.candidate_bytes, 1, MAX_PDF) && request.byte_ceiling === request.candidate_bytes &&
    request.build_sha256 === BUILD && request.parser_profile_sha256 === PROFILE_SHA &&
    value.claim_id !== request.predecessor_operation_id && ENCODER.encode(canonical(request)).length <= 2_048);
  require(typeof value.spool_descriptor === "string");
  const rawDescriptor = ENCODER.encode(value.spool_descriptor);
  require(rawDescriptor.length > 0 && rawDescriptor.length <= 4_096);
  const descriptor = parseCanonical(rawDescriptor, true);
  require(record(descriptor, [...BINDING_KEYS, "format", "bytes", "sha256", "producer", "guardian"]) &&
    descriptor.format === "original-spool-v1" && descriptor.purpose === "stored_readback");
  for (const key of ["reservation_id", "claim_id", "attempt_id"]) require(uuid(descriptor[key]));
  for (const key of ["request_sha256", "binding_sha256", "capture_sha256", "sha256"]) require(shaText(descriptor[key]));
  require(inode(descriptor.producer) && inode(descriptor.guardian) &&
    canonical(descriptor.producer) !== canonical(descriptor.guardian) &&
    integer(descriptor.bytes, 1, MAX_PDF) && descriptor.reservation_id === request.reservation_id &&
    descriptor.claim_id === request.predecessor_operation_id && descriptor.sha256 === request.candidate_sha256 &&
    descriptor.bytes === request.candidate_bytes && await sha(rawDescriptor) === request.input_spool_sha256);
  return { value, descriptor, inputSHA: await sha(ENCODER.encode(canonical(value))) };
}

function sameStat(before, after, reason = "input_changed") {
  for (const key of ["isFile", "size", "dev", "ino", "uid", "gid", "mode", "nlink"]) {
    require(before[key] === after[key], reason);
  }
  for (const key of ["mtime", "ctime"]) {
    require((before[key]?.getTime() ?? null) === (after[key]?.getTime() ?? null), reason);
  }
}
async function boundedFile(name, maximum) {
  const path = new URL(name, ROOT);
  const before = await Deno.lstat(path);
  require(before.isFile && !before.isSymlink && integer(before.size, 1, maximum) &&
    (before.mode === null || (before.mode & 0o7777) === 0o400), "bundle_changed");
  const file = await Deno.open(path, { read: true });
  try {
    sameStat(before, await file.stat(), "bundle_changed");
    const raw = new Uint8Array(before.size + 1);
    let count = 0;
    while (count < raw.length) {
      const received = await file.read(raw.subarray(count, Math.min(raw.length, count + CHUNK)));
      if (received === null) break;
      require(integer(received, 1, Math.min(CHUNK, raw.length - count)), "bundle_changed");
      count += received;
    }
    require(count === before.size, "bundle_changed");
    sameStat(before, await file.stat(), "bundle_changed");
    return raw.subarray(0, count);
  } finally { file.close(); }
}
async function manifest(expectedSHA) {
  require(ROOT.protocol === "file:" && ROOT.pathname !== "/");
  const directory = new URL(ROOT.href);
  directory.pathname = directory.pathname.replace(/\/$/, "");
  const root = await Deno.lstat(directory);
  require(root.isDirectory && !root.isSymlink && (root.mode === null || (root.mode & 0o7777) === 0o500));
  const raw = await boundedFile("bundle.json", MAX_INPUT);
  require(await sha(raw) === expectedSHA);
  const value = parseCanonical(raw);
  require(record(value, ["format", "local_fixture_only", "hosted_admitted", "entrypoint", "build_identity_sha256",
    "profile_id", "profile_sha256", "files", "payload_bytes", "deno"]) &&
    value.format === "original-verifier-bundle-v1" && value.local_fixture_only === true &&
    value.hosted_admitted === false && value.entrypoint === "original_verifier.mjs" &&
    value.build_identity_sha256 === BUILD && value.profile_id === PROFILE_ID && value.profile_sha256 === PROFILE_SHA &&
    record(value.files, Object.keys(LIMITS)));
  let payload = 0;
  for (const [name, maximum] of Object.entries(LIMITS)) {
    const entry = value.files[name];
    require(record(entry, ["bytes", "sha256"]) && integer(entry.bytes, 1, maximum) && shaText(entry.sha256));
    payload += entry.bytes;
  }
  require(integer(value.payload_bytes, 1, 2_097_152) && payload === value.payload_bytes);
  const deno = value.deno;
  require(record(deno, ["path", "bytes", "sha256", "identity"]) && typeof deno.path === "string" &&
    deno.path.startsWith("/") && !/[\u0000-\u001f\u007f]/.test(deno.path) &&
    !deno.path.split("/").slice(1).some(part => part === "" || part === "." || part === "..") &&
    ENCODER.encode(deno.path).length <= 4_096 && integer(deno.bytes, 1, 268_435_456) && shaText(deno.sha256) &&
    record(deno.identity, ["device", "inode", "uid", "gid", "mode", "mtime_ns", "ctime_ns"]));
  for (const key of ["device", "inode", "mtime_ns", "ctime_ns"]) require(decimal(deno.identity[key], key === "inode"));
  require(integer(deno.identity.uid, 0, 4_294_967_295) && integer(deno.identity.gid, 0, 4_294_967_295) &&
    integer(deno.identity.mode, 0, 0o7777) && (deno.identity.mode & 0o111) !== 0 && (deno.identity.mode & 0o7022) === 0);
  const names = [];
  for await (const entry of Deno.readDir(ROOT)) {
    require(names.length < 8);
    names.push(entry.name);
  }
  const expectedNames = [...Object.keys(LIMITS), "bundle.json"].sort();
  names.sort();
  require(names.length === expectedNames.length && names.every((name, index) => name === expectedNames[index]));
  return value;
}
function goRecord(raw, input, bundleSHA) {
  const value = parseCanonical(raw, true);
  require(record(value, ["format", "claim_id", "execution_id", "binding_sha256", "input_sha256", "bundle_sha256", "deadline_ns", "budget_ms"]) &&
    value.format === "original-verifier-go-v1" && value.claim_id === input.value.claim_id && uuid(value.execution_id) &&
    shaText(value.binding_sha256) && value.input_sha256 === input.inputSHA && value.bundle_sha256 === bundleSHA &&
    typeof value.deadline_ns === "string" && /^[1-9][0-9]{0,19}$/.test(value.deadline_ns) &&
    BigInt(value.deadline_ns).toString() === value.deadline_ns && integer(value.budget_ms, 1, 5_000));
  return value;
}

async function payload(input, checkBudget) {
  const expected = input.value.request;
  // Some Deno stdin implementations expose only read/readable. In that case
  // the parent's fcntl/fstat/offset checks remain the descriptor authority.
  const before = typeof Deno.stdin.stat === "function" ? await Deno.stdin.stat() : null;
  if (before !== null) {
    require(before.isFile && before.size === expected.candidate_bytes, "input_mismatch");
    for (const [key, recorded] of [["dev", "device"], ["ino", "inode"]]) {
      if (before[key] !== null && before[key] !== undefined) {
        require(integer(before[key], key === "ino" ? 1 : 0, Number.MAX_SAFE_INTEGER) &&
          String(before[key]) === input.descriptor.guardian[recorded], "input_changed");
      }
    }
  }
  checkBudget();
  const raw = new Uint8Array(expected.candidate_bytes);
  let count = 0;
  while (count < raw.length) {
    const received = await Deno.stdin.read(raw.subarray(count, Math.min(raw.length, count + CHUNK)));
    checkBudget();
    require(integer(received, 1, Math.min(CHUNK, raw.length - count)), "input_mismatch");
    count += received;
  }
  require(await Deno.stdin.read(new Uint8Array(1)) === null, "input_mismatch");
  checkBudget();
  if (before !== null) sameStat(before, await Deno.stdin.stat());
  require(await sha(raw) === expected.candidate_sha256, "input_mismatch");
  checkBudget();
  return raw;
}
async function assets(packageManifest, checkBudget) {
  try {
    const files = new Map();
    for (const [name, limit] of Object.entries(LIMITS)) {
      const raw = await boundedFile(name, limit);
      require(raw.length === packageManifest.files[name].bytes && await sha(raw) === packageManifest.files[name].sha256, "bundle_changed");
      files.set(name, raw);
      checkBudget();
    }
    require(await sha(files.get("identity.json")) === BUILD, "bundle_changed");
    const identity = parseCanonical(files.get("identity.json"));
    const profile = JSON.parse(DECODER.decode(files.get("profile.json")));
    const fields = { "runtime.ts": "runtime_sha256", "wasm.ts": "memory_inspector_sha256",
      "verifier.mjs": "javascript_sha256", "verifier.wasm": "wasm_sha256" };
    for (const [name, key] of Object.entries(fields)) require(identity[key] === packageManifest.files[name].sha256, "bundle_changed");
    require(identity.profile_sha256 === PROFILE_SHA && canonical(profile) === canonical(identity.profile) &&
      await sha(ENCODER.encode(canonical(profile))) === PROFILE_SHA && profile.id === PROFILE_ID &&
      profile.hosted_admitted === false, "bundle_changed");
    return { identity, profile, wasm: files.get("verifier.wasm") };
  } catch (error) {
    if (error instanceof Refused && error.reason === "deadline") throw error;
    throw new Refused("bundle_changed");
  }
}
function measurement(value, input, identity) {
  const keys = ["outcome", "bytes", "profileID", "profileSHA256", "wasmSHA256", "elapsedMS", "sha256"];
  require(value !== null && typeof value === "object" && OUTCOMES.has(value.outcome));
  require(record(value, value.outcome === "verified" ? [...keys, "pages"] : keys) &&
    value.bytes === input.value.request.candidate_bytes && value.sha256 === input.value.request.candidate_sha256 &&
    value.profileID === PROFILE_ID && value.profileSHA256 === PROFILE_SHA && value.wasmSHA256 === identity.wasm_sha256 &&
    typeof value.elapsedMS === "number" && Number.isFinite(value.elapsedMS) && value.elapsedMS >= 0);
  if (value.outcome === "verified") require(integer(value.pages, 1, 50));
  return value; // Preserve the frozen measurement; do not invent host metrics.
}

async function main() {
  let controlFile = null;
  let accepted = null;
  let result = null;
  try {
    require(Deno.args.length === 2 && /^[1-9][0-9]{0,9}$/.test(Deno.args[0]) &&
      integer(Number(Deno.args[0]), 3, 2_147_483_647) && String(Number(Deno.args[0])) === Deno.args[0] &&
      shaText(Deno.args[1]));
    const controlFD = Deno.args[0], bundleSHA = Deno.args[1];
    require(Deno.build.os === "darwin" || Deno.build.os === "linux");
    const path = Deno.build.os === "linux" ? `/proc/self/fd/${controlFD}` : `/dev/fd/${controlFD}`;
    controlFile = await Deno.open(path, { read: true });
    const control = new Control(controlFile);
    const input = await inputRecord(await control.line(MAX_INPUT));
    const packageManifest = await manifest(bundleSHA);
    await emit({ format: "original-verifier-ready-v1", claim_id: input.value.claim_id,
      input_sha256: input.inputSHA, bundle_sha256: bundleSHA, process_id: Deno.pid });
    const go = goRecord(await control.line(MAX_CONTROL), input, bundleSHA);
    const goSHA = await sha(ENCODER.encode(canonical(go)));
    await control.eof();
    const started = performance.now();
    accepted = { input, go, bundleSHA, goSHA };
    const closing = controlFile;
    controlFile = null;
    closing.close();
    const checkBudget = () => require(performance.now() - started < go.budget_ms, "deadline");
    checkBudget();
    const raw = await payload(input, checkBudget);
    const loaded = await assets(packageManifest, checkBudget);
    checkBudget();
    // Computed URLs are intentional: Deno must not preload the parser while
    // waiting for authority. These exact files were checked above.
    const runtimeURL = new URL("runtime.ts", ROOT).href;
    const glueURL = new URL("verifier.mjs", ROOT).href;
    const runtime = await import(runtimeURL);
    const factory = (await import(glueURL)).default;
    checkBudget();
    const verifier = await runtime.createVerifier({ factory, wasm: loaded.wasm,
      wasmSHA256: loaded.identity.wasm_sha256, profile: loaded.profile, profileSHA256: PROFILE_SHA });
    checkBudget();
    const parsed = await verifier.verify(raw, { sha256: input.value.request.candidate_sha256,
      bytes: input.value.request.candidate_bytes });
    checkBudget();
    result = { kind: "parsed", reason: null, parser_result: measurement(parsed, input, loaded.identity) };
  } catch (error) {
    if (accepted === null) { Deno.exitCode = 2; return; }
    result = { kind: "refused", reason: error instanceof Refused && REASONS.has(error.reason)
      ? error.reason : "receiver_failure", parser_result: null };
  } finally {
    if (controlFile !== null) {
      const closing = controlFile;
      controlFile = null;
      try { closing.close(); } catch { Deno.exitCode = 2; }
    }
  }
  try {
    await emit({ format: "original-verifier-result-v1", local_fixture_only: true,
      claim_id: accepted.input.value.claim_id, execution_id: accepted.go.execution_id,
      request_sha256: accepted.input.value.request_sha256, input_sha256: accepted.input.inputSHA,
      bundle_sha256: accepted.bundleSHA, go_sha256: accepted.goSHA, ...result });
  } catch { Deno.exitCode = 2; }
}

// All errors, including malformed UTF-8/JSON or module failures, stay finite.
try { await main(); } catch { Deno.exitCode = 2; }
