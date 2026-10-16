// Gradstep podcast worker entry (docs/architecture/PAPER_PODCASTS.md). The HTTP
// parent (server.ts, POST /podcast) runs this in a worker thread with the same
// hard deadline as the paper pipeline and awaits it before replying: no detached
// work under request-based billing. One job (or one stage of a staged job) per request.
import { installEgressGuard } from '../../supabase/functions/_shared/egress.ts';
import { accountProviderFetch, installProviderHealth } from '../../supabase/functions/_shared/provider-health.ts';
import { parentPort, workerData } from 'node:worker_threads';
import { createHash, randomUUID } from 'node:crypto';
import { createAnthropicClient } from '../../supabase/functions/_shared/anthropic.ts';
import { pipelineService, rpcAdapter, runtimeEnv } from '../../supabase/functions/_shared/pipeline-runtime.ts';
import { boundedStorageDownload } from '../../supabase/functions/_shared/reader-delivery.ts';
import { anthropicScriptProvider } from '../../supabase/functions/_shared/podcast-script.ts';
import { deepseekScriptProvider } from '../../supabase/functions/_shared/deepseek.ts';
import { impersonatedTokenSource, vertexSpeechProvider } from '../../supabase/functions/_shared/podcast-speech.ts';
import { runPodcast, type PodcastDeps, type PodcastRunResult } from '../../supabase/functions/_shared/podcast-worker.ts';
import { ffmpegEncoder } from './podcast-encode.ts';
// No request from this thread (its own realm and fetch) may reach arXiv (docs/architecture/ARXIV_DEVICE_ONLY.md); such requests are refused (EGRESS_ARXIV=block, the default).
installEgressGuard('pipeline-worker/podcast');
// Provider calls are counted per hour and fail fast while a provider's breaker is open (docs/architecture/RESILIENCE.md).
installProviderHealth('pipeline-worker/podcast', pipelineService);

/** Leaves time for recording a failure before the parent's 840 s hard limit. */
export const PODCAST_BUDGET_MS = 780_000;
const log = (event: string, fields: Record<string, unknown> = {}) => console.log(JSON.stringify({ event, ...fields }));

/** Real providers only when every credential is present; otherwise generated jobs are not claimed (fixtures still run). */
export function podcastDeps(): PodcastDeps & { generated: boolean } {
  const service = pipelineService();
  const url = runtimeEnv('SUPABASE_URL'), key = runtimeEnv('SUPABASE_SERVICE_ROLE_KEY');
  // The claimed job's owner: a fault drill (FAULT_INJECTION=on, a test account only) reaches this job's provider calls.
  let owner: string | null = null;
  const providerFetch = accountProviderFetch('pipeline-worker/podcast', () => owner, () => service);
  if (!url || !key) throw new Error('service_unavailable');
  const anthropicKey = runtimeEnv('ANTHROPIC_API_KEY');
  const speechAccount = runtimeEnv('PODCAST_SPEECH_SERVICE_ACCOUNT'), project = runtimeEnv('PODCAST_GCP_PROJECT') ?? 'gradstep';
  // Each call's own window (AbortSignal) bounds it: up to 680 s for a staged twenty-minute draft, inside this request's budget.
  const script = anthropicKey ? anthropicScriptProvider(createAnthropicClient({ apiKey: anthropicKey, maxRetries: 0, timeout: PODCAST_BUDGET_MS, fetch: providerFetch })) : null;
  // DeepSeek (2026-10-14): the version-4 profiles' script provider; a profile without its key fails script_unavailable.
  const deepseekKey = runtimeEnv('DEEPSEEK_API_KEY');
  const deepseek = deepseekKey ? deepseekScriptProvider({ apiKey: deepseekKey, fetch: providerFetch }) : null;
  const speech = speechAccount ? vertexSpeechProvider({ project, tokens: impersonatedTokenSource(speechAccount), timeoutMs: PODCAST_BUDGET_MS, fetch: providerFetch }) : null;
  return {
    generated: !!(script && speech),
    rpc: rpcAdapter(service),
    scriptProviders: { ...(script ? { anthropic: script } : {}), ...(deepseek ? { deepseek } : {}) },
    storage: {
      download: (bucket, path, maximum) => boundedStorageDownload(url, key, bucket, path, maximum),
      async upload(bucket, path, bytes, contentType) {
        // One immutable write per granted plan entry; never an overwrite. No CDN caching.
        const { error } = await service.storage.from(bucket).upload(path, bytes, { contentType, upsert: false, cacheControl: '0' });
        if (error) throw new Error('storage_upload_failed');
      },
      async remove(bucket, paths) {
        // Finished episodes' paper text (migration 076); an object already gone is not an error.
        const { error } = await service.storage.from(bucket).remove(paths);
        if (error) throw new Error('storage_remove_failed');
      },
    },
    script, speech, encoder: ffmpegEncoder(),
    onClaim: claim => { owner = claim.owner_id; },
    sha256Hex: async bytes => createHash('sha256').update(bytes).digest('hex'),
    uuid: () => randomUUID(), now: () => Date.now(),
    log: (event, fields = {}) => log(event, fields),
  };
}

export async function runPodcastOnce(make: () => PodcastDeps & { generated: boolean } = podcastDeps, now: () => number = Date.now)
  : Promise<PodcastRunResult & { ms: number }> {
  const started = now();
  const deps = make();
  const result = await runPodcast(deps, started + PODCAST_BUDGET_MS, { generated: deps.generated });
  return { ...result, ms: now() - started };
}

// Only the HTTP parent's explicitly created worker runs this entry point.
if (parentPort && workerData?.pipelineRun === 1 && workerData.entryPoint === import.meta.url) {
  try { parentPort.postMessage({ ok: true, result: await runPodcastOnce() }); }
  catch (error) {
    const code = error instanceof Error && /^[a-z_]{1,64}$/.test(error.message) ? error.message : 'unexpected';
    parentPort.postMessage({ ok: false, code });
  }
}
