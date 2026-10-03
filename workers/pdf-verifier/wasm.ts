/** Inspect the binary, rather than trusting a compiler flag or build manifest. */
export function inspectMemory(bytes: Uint8Array): { minimumPages: number; maximumPages: number } {
  let cursor = 0;
  const fail = () => { throw new Error("invalid_verifier_memory"); };
  const byte = () => cursor < bytes.length ? bytes[cursor++] : fail();
  const u32 = () => {
    let result = 0;
    for (let shift = 0; shift <= 28; shift += 7) {
      const value = byte();
      if (shift === 28 && (value & 0xf0)) fail();
      result += (value & 0x7f) * 2 ** shift;
      if (!(value & 0x80)) return result;
    }
    return fail();
  };
  const header = [0, 97, 115, 109, 1, 0, 0, 0];
  if (!header.every((value) => byte() === value)) fail();
  let memory: { minimumPages: number; maximumPages: number } | undefined;
  while (cursor < bytes.length) {
    const section = byte();
    const length = u32();
    const end = cursor + length;
    if (end > bytes.length) fail();
    if (section === 5) {
      // One defined memory32, unshared, with an explicit equal min/max.
      if (memory || u32() !== 1 || u32() !== 1) fail();
      memory = { minimumPages: u32(), maximumPages: u32() };
      if (cursor !== end || memory.minimumPages !== 1024 || memory.maximumPages !== 1024) fail();
    }
    cursor = end;
  }
  if (!memory) fail();
  return memory!;
}

export function inspectImports(module: WebAssembly.Module): void {
  // qpdf uses the pinned, hashed Emscripten glue for its function imports.
  // Never permit imported memory, tables, globals or shared host state.
  for (const value of WebAssembly.Module.imports(module)) {
    if (value.kind !== "function" || value.module !== "a") throw new Error("invalid_verifier_import");
  }
  if (WebAssembly.Module.exports(module).filter((value) => value.kind === "memory").length !== 1) {
    throw new Error("invalid_verifier_memory_export");
  }
}
