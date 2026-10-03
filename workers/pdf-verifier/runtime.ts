import { inspectImports, inspectMemory } from "./wasm.ts";

export type NumericAPI = {
  HEAPU8: Uint8Array;
  _pdfv_abi(): number;
  _pdfv_parser_version(): number;
  _pdfv_stack_bytes(): number;
  _pdfv_verify(pointer: number, length: number): number;
  _malloc(length: number): number;
  _free(pointer: number): void;
};
export type ModuleFactory = (options: {
  instantiateWasm(imports: WebAssembly.Imports, receive: (instance: WebAssembly.Instance) => void): WebAssembly.Exports;
  print(message: string): void;
  printErr(message: string): void;
  onAbort(reason: unknown): void;
}) => NumericAPI | Promise<NumericAPI>;

export type Profile = {
  id: string; abi: number; parser: string; parser_version: string;
  input_bytes: number; pages: number; wasm_memory_bytes: number; wasm_stack_bytes: number;
  hosted_admitted: boolean;
  [key: string]: unknown;
};
export type Failure = "malformed" | "encrypted" | "unsupported" | "parser_resource_limit" | "resource_limit" |
  "internal_error" | "input_limit" | "page_limit" | "binding_mismatch";
export type Measurement = {
  outcome: "verified" | Failure;
  pages?: number;
  sha256?: string;
  bytes: number;
  profileID: string;
  profileSHA256: string;
  wasmSHA256: string;
  elapsedMS: number;
};

export async function sha256(bytes: Uint8Array): Promise<string> {
  const hash = await crypto.subtle.digest("SHA-256", new Uint8Array(bytes));
  return Array.from(new Uint8Array(hash), (value) => value.toString(16).padStart(2, "0")).join("");
}

export function canonicalProfile(profile: Profile): Uint8Array {
  // The versioned profile is flat; reject nested values rather than producing
  // a digest that depends on a JSON serializer's nested-object key ordering.
  const sorted = Object.fromEntries(Object.keys(profile).sort().map((key) => {
    const value = profile[key];
    if (value !== null && typeof value === "object") throw new Error("invalid_profile");
    return [key, value];
  }));
  return new TextEncoder().encode(JSON.stringify(sorted));
}

/** Only trusted, pinned generated glue may be supplied. Never evaluate document code. */
export async function instantiate(
  factory: ModuleFactory, module: WebAssembly.Module,
): Promise<{ api: NumericAPI; memory: WebAssembly.Memory; abortReason: () => unknown }> {
  let memory: WebAssembly.Memory | undefined;
  let aborted: unknown;
  const api = await factory({
    instantiateWasm(imports, receive) {
      const instance = new WebAssembly.Instance(module, imports);
      memory = Object.values(instance.exports).find((value) => value instanceof WebAssembly.Memory) as WebAssembly.Memory;
      receive(instance);
      return instance.exports;
    },
    print() {}, printErr() {}, // No PDF strings or parser diagnostics enter logs.
    onAbort(reason) { aborted = reason; },
  });
  if (!memory || memory.buffer.byteLength !== 67108864 || api.HEAPU8.byteLength !== 67108864 ||
      api._pdfv_abi() !== 1 || api._pdfv_parser_version() !== 120402 || api._pdfv_stack_bytes() !== 2097152) {
    throw new Error("verifier_abi_mismatch");
  }
  return { api, memory, abortReason: () => aborted };
}

/** Local executor only. Authentication, storage read, leases and receipts belong to the job host. */
export async function createVerifier(options: {
  factory: ModuleFactory; wasm: Uint8Array; wasmSHA256: string;
  profile: Profile; profileSHA256: string;
}) {
  // Capture mutable caller-owned buffers/scalars before the first await.
  const wasm = new Uint8Array(options.wasm);
  const factory = options.factory;
  const profile = { ...options.profile };
  const wasmSHA256 = options.wasmSHA256;
  const profileSHA256 = options.profileSHA256;
  if (profile.id !== "qpdf-wasm-pilot-v1" || profile.abi !== 1 || profile.parser !== "qpdf" ||
      profile.parser_version !== "12.4.2" || profile.input_bytes !== 5242880 || profile.pages !== 50 ||
      profile.wasm_memory_bytes !== 67108864 || profile.wasm_stack_bytes !== 2097152 ||
      profile.parser_nesting !== 64 || profile.container_entries !== 50000 || profile.indirect_objects !== 50000 ||
      profile.highest_object_number !== 50000 || profile.checked_stream_bytes !== 33554432 ||
      profile.checked_page_content_bytes !== 33554432 || profile.page_content_objects !== 1000000 ||
      profile.stream_filters !== 8 || profile.parser_errors !== 1 || profile.recovery !== false ||
      profile.encryption !== false || profile.warnings !== false || profile.header_at_zero !== true ||
      profile.final_eof_required !== true || profile.page_count_source !== "resolved_page_tree" ||
      profile.stream_checks !== "all_indirect_streams_decodable_no_raw_retry" || profile.hosted_admitted !== false) {
    throw new Error("invalid_profile");
  }
  if (await sha256(wasm) !== wasmSHA256 || await sha256(canonicalProfile(profile)) !== profileSHA256) {
    throw new Error("verifier_build_mismatch");
  }
  inspectMemory(wasm);
  const module = await WebAssembly.compile(wasm);
  inspectImports(module);
  let busy = false;
  return {
    async verify(input: Uint8Array, expected: { sha256: string; bytes: number }): Promise<Measurement> {
      if (busy) throw new Error("one_verification_at_a_time");
      busy = true;
      const start = performance.now();
      const base = { bytes: input.byteLength, profileID: profile.id, profileSHA256, wasmSHA256 };
      const result = (outcome: Measurement["outcome"], hash?: string, pages?: number): Measurement => ({
        ...base, outcome, ...(hash ? { sha256: hash } : {}), ...(pages ? { pages } : {}),
        elapsedMS: performance.now() - start,
      });
      try {
        if (input.byteLength > profile.input_bytes) return result("input_limit");
        // The fetched object's identity and bytes cannot change during hashing.
        const bytes = new Uint8Array(input);
        const expectedHash = expected.sha256;
        const expectedBytes = expected.bytes;
        const hash = await sha256(bytes);
        if (hash !== expectedHash || bytes.length !== expectedBytes) return result("binding_mismatch", hash);
        const instance = await instantiate(factory, module); // Fresh heap per document; compiled code may be reused.
        let pointer = 0;
        let healthy = true;
        try {
          pointer = instance.api._malloc(bytes.length || 1);
          if (!pointer) return result("resource_limit", hash);
          instance.api.HEAPU8.set(bytes, pointer);
          const code = instance.api._pdfv_verify(pointer, bytes.length);
          if (Number.isInteger(code) && code > 0 && code <= profile.pages) return result("verified", hash, code);
          const failures: Record<number, Failure> = {
            [-1]: "malformed", [-2]: "encrypted", [-3]: "unsupported", [-4]: "parser_resource_limit",
            [-5]: "malformed", [-6]: "internal_error", [-7]: "input_limit", [-8]: "page_limit",
          };
          return result(failures[code] ?? "internal_error", hash);
        } catch {
          healthy = false;
          // A trapped or aborted parse cannot yield a success or partial receipt.
          const reason = instance.abortReason();
          return result(reason === "OOM" || (typeof reason === "string" && reason.startsWith("stack overflow"))
            ? "resource_limit" : "internal_error", hash);
        } finally {
          if (healthy && pointer && instance.abortReason() === undefined) instance.api._free(pointer);
        }
      } finally { busy = false; }
    },
  };
}
