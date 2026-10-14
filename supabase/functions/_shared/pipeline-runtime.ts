// Metadata pipeline wiring (Edge Functions under Deno, the Cloud Run worker under Node):
// the service-role RPC adapter. No Storage adapter exists here any more: the server neither
// reads nor writes PDFs, reader assets or upload chunks (docs/architecture/HTML_FIRST_READER.md).
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { PipelineRPCError } from './pipeline-error.ts';

export type PipelineRPC = <T>(name: string, params: Record<string, unknown>) => Promise<T>;

/** An environment variable under Deno or Node. */
export function runtimeEnv(name: string): string | undefined {
  const scope = globalThis as { Deno?: { env: { get(key: string): string | undefined } }; process?: { env: Record<string, string | undefined> } };
  return scope.Deno ? scope.Deno.env.get(name) : scope.process?.env[name];
}

export function pipelineService(): SupabaseClient {
  const url = runtimeEnv('SUPABASE_URL'), key = runtimeEnv('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !key) throw new Error('service_unavailable');
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    global: { fetch: (input: RequestInfo | URL, init?: RequestInit) => fetch(input, { ...init, signal: init?.signal ?? AbortSignal.timeout(60_000) }) } });
}

export function rpcAdapter(client: SupabaseClient): PipelineRPC {
  return async <T>(name: string, params: Record<string, unknown>): Promise<T> => {
    const { data, error } = await client.rpc(name, params);
    if (error) {
      const code = /^[a-z_]{1,64}$/.test(error.message) ? error.message : 'database_error';
      throw new PipelineRPCError(code);
    }
    return data as T;
  };
}
