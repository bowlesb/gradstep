/** Local-only isolated process measurement. Never deploy this file. */
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import type { Synthetic } from './workloads.ts';
import type { Clock } from './workloads.ts';

const selected = JSON.parse(await Deno.readTextFile(Deno.args[0]));
const name = Deno.args[1];
if (!['cpu-wasm', 'memory-wasm'].includes(name)) throw new Error('invalid_local_case');
const source = resolve(selected.directory, 'supabase/functions', selected.function);
const { runCPU, runMemory } = await import(pathToFileURL(resolve(source, 'workloads.ts')).href) as typeof import('./workloads.ts');
const assets = await import(pathToFileURL(resolve(source, 'assets.ts')).href);
const bytes = Uint8Array.from(atob(assets.syntheticBase64), x => x.charCodeAt(0));
const digest = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)), x => x.toString(16).padStart(2, '0')).join('');
if (digest !== assets.syntheticSHA256) throw new Error('synthetic_identity_mismatch');
const module = (await WebAssembly.instantiate(bytes)).instance.exports as unknown as Synthetic;
const checksumStart = performance.now(), checksum = module.cpu_chunk(0x12345678) >>> 0;
const chunkWallMS = performance.now() - checksumStart;
const clock: Clock = { now: Date.now, monotonic: () => performance.now(),
  sleep: ms => new Promise(resolve => setTimeout(resolve, ms)), cancelled: () => false };
const start = { wall: clock.now(), monotonic: clock.monotonic() };
const result = name === 'cpu-wasm' ? runCPU(module, clock, start) : await runMemory(module, clock, start);
console.log(JSON.stringify({ case: name, runtime: { ...Deno.version }, synthetic_sha256: digest,
  source_manifest_sha256: selected.source_manifest_sha256, result, first_chunk_checksum: checksum,
  first_chunk_wall_ms: chunkWallMS, workload_wall_ms: performance.now() - start.monotonic,
  memory_snapshot_after_work: Deno.memoryUsage(), cpu_ms: null, peak_memory_bytes: null, hosted_admitted: false }));
