import assert from 'node:assert/strict';
import { LIMITS, runBackground, runCPU, runMemory, type Clock, type Synthetic } from './workloads.ts';

function clock() {
  const state = { time: 0, cancelled: false, sleeps: 0 };
  const value: Clock = { now: () => state.time, monotonic: () => state.time,
    sleep: async ms => { state.sleeps++; state.time += ms; }, cancelled: () => state.cancelled };
  return { state, value };
}
Deno.test('CPU has a finite total iteration ceiling even with a nonadvancing clock', () => {
  const { value } = clock(); let calls = 0;
  const module: Synthetic = { cpu_chunk: n => { calls++; return n + 1; }, chunk_iterations: () => 262_144,
    memory: new WebAssembly.Memory({ initial: 0, maximum: 5120 }) };
  const result = runCPU(module, value, { wall: 0, monotonic: 0 });
  assert.equal(result.cpu_chunks, 32_768); assert.equal(calls * LIMITS.cpuIterationsPerChunk, 2 ** 33);
});
Deno.test('CPU checks cancellation and deadline between fixed chunks', () => {
  const { state, value } = clock(); let calls = 0;
  const module: Synthetic = { cpu_chunk: n => { calls++; state.time = 8000; return n; }, chunk_iterations: () => 262_144,
    memory: new WebAssembly.Memory({ initial: 0, maximum: 5120 }) };
  assert.equal(runCPU(module, value, { wall: 0, monotonic: 0 }).cpu_chunks, 1);
  state.cancelled = true;
  assert.throws(() => runCPU(module, value, { wall: 0, monotonic: 0 }), /workload_cancelled/);
  assert.equal(calls, 1);
});
Deno.test('memory touches each newly allocated page and stops on deadline before next growth', async () => {
  const { state, value } = clock();
  value.sleep = async () => { state.time = 10_000; };
  const memory = new WebAssembly.Memory({ initial: 0, maximum: 5120 });
  const result = await runMemory({ memory } as Synthetic, value, { wall: 0, monotonic: 0 });
  assert.equal(result.memory_steps, 1); assert.equal(result.wasm_linear_bytes, 8 * 1024 * 1024);
  const bytes = new Uint8Array(memory.buffer);
  for (let offset = 0; offset < bytes.length; offset += 4096) assert.equal(bytes[offset], 0x5a);
});
Deno.test('allocation failure retains only the known previously allocated count', async () => {
  const { value } = clock();
  const memory = new WebAssembly.Memory({ initial: 0, maximum: 0 });
  const result = await runMemory({ memory } as Synthetic, value, { wall: 0, monotonic: 0 });
  assert.equal(result.event, 'allocation_refused'); assert.equal(result.wasm_linear_bytes, 0); assert.equal(result.memory_steps, 0);
});
Deno.test('background suspension resumes only to stop, not to schedule extra work', async () => {
  const { state, value } = clock(); let heartbeats = 0;
  value.sleep = async () => { state.sleeps++; state.time = 900_000; };
  await runBackground(value, { wall: 0, monotonic: 0 }, () => heartbeats++);
  assert.equal(state.sleeps, 1); assert.equal(heartbeats, 0);
});
Deno.test('clock failure is explicit and cannot create an unbounded timer', async () => {
  const { state, value } = clock(); state.time = NaN;
  await assert.rejects(() => runBackground(value, { wall: 0, monotonic: 0 }, () => {}), /workload_clock_invalid/);
  assert.equal(state.sleeps, 0);
});
