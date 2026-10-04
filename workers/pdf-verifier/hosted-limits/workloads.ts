/** Fixed synthetic workload bounds. No HTTP input can change these values. */
export const LIMITS = Object.freeze({
  cpuIterationsPerChunk: 262_144, cpuMaxChunks: 32_768, cpuWallMS: 8_000,
  memoryStepPages: 128, memoryMaxSteps: 40, memoryWallMS: 10_000,
  memoryYieldMS: 100, touchStride: 4_096,
  backgroundStepMS: 10_000, backgroundMaxTicks: 45, backgroundWallMS: 450_000,
});
export const SEED = 0x12345678;
export type WorkResult = {
  event: 'fallback' | 'allocation_refused'; cpu_chunks: number; memory_steps: number;
  wasm_linear_bytes: number; checksum: number | null;
};
export type Clock = {
  now(): number;
  monotonic(): number;
  sleep(ms: number): Promise<void>;
  cancelled(): boolean;
};
export type Start = { wall: number; monotonic: number };
export type Synthetic = {
  cpu_chunk(seed: number): number;
  chunk_iterations(): number;
  memory: { readonly buffer: ArrayBufferLike; grow(pages: number): number };
};

function guard(clock: Clock, start: Start, duration: number): boolean {
  const wall = clock.now(), monotonic = clock.monotonic();
  if (!Number.isFinite(wall) || !Number.isFinite(monotonic) || wall < start.wall || monotonic < start.monotonic) {
    throw new Error('workload_clock_invalid');
  }
  if (clock.cancelled()) throw new Error('workload_cancelled');
  return wall - start.wall >= duration || monotonic - start.monotonic >= duration;
}

/** No promise yield inside a chunk. Deadline checks run between finite chunks. */
export function runCPU(module: Synthetic, clock: Clock, start: Start): WorkResult {
  if (module.chunk_iterations() !== LIMITS.cpuIterationsPerChunk || module.memory.buffer.byteLength !== 0) {
    throw new Error('synthetic_abi_mismatch');
  }
  let value = SEED, chunks = 0;
  while (chunks < LIMITS.cpuMaxChunks && !guard(clock, start, LIMITS.cpuWallMS)) {
    value = module.cpu_chunk(value) >>> 0;
    chunks += 1;
  }
  return { event: 'fallback', cpu_chunks: chunks, memory_steps: 0, wasm_linear_bytes: 0, checksum: value };
}

/** Retain one memory and touch every 4 KiB of every newly allocated region. */
export async function runMemory(module: Synthetic, clock: Clock, start: Start): Promise<WorkResult> {
  if (module.memory.buffer.byteLength !== 0) throw new Error('synthetic_abi_mismatch');
  let steps = 0, bytes = 0;
  const result = (event: WorkResult['event']): WorkResult => ({
    event, cpu_chunks: 0, memory_steps: steps, wasm_linear_bytes: bytes, checksum: null,
  });
  while (steps < LIMITS.memoryMaxSteps && !guard(clock, start, LIMITS.memoryWallMS)) {
    const expected = bytes + LIMITS.memoryStepPages * 65_536;
    try {
      const previous = module.memory.grow(LIMITS.memoryStepPages);
      if (previous * 65_536 !== bytes || module.memory.buffer.byteLength !== expected) {
        throw new Error('synthetic_memory_mismatch');
      }
    } catch (error) {
      if (error instanceof RangeError) return result('allocation_refused');
      throw new Error('synthetic_memory_failed');
    }
    const view = new Uint8Array(module.memory.buffer);
    for (let offset = bytes; offset < expected; offset += LIMITS.touchStride) view[offset] = 0x5a;
    bytes = expected;
    steps += 1;
    // Give the host's supervisor a chance to observe retained memory. This is
    // not a guarantee about its sampling interval or accounting policy.
    await clock.sleep(LIMITS.memoryYieldMS);
  }
  return result('fallback');
}

export async function runBackground(clock: Clock, start: Start, heartbeat: () => void): Promise<void> {
  for (let tick = 0; tick < LIMITS.backgroundMaxTicks; tick += 1) {
    if (guard(clock, start, LIMITS.backgroundWallMS)) return;
    const remaining = Math.min(LIMITS.backgroundWallMS - (clock.now() - start.wall),
      LIMITS.backgroundWallMS - (clock.monotonic() - start.monotonic));
    if (!Number.isFinite(remaining) || remaining <= 0) return;
    await clock.sleep(Math.min(LIMITS.backgroundStepMS, remaining));
    if (guard(clock, start, LIMITS.backgroundWallMS)) return;
    heartbeat();
  }
}
