// Paper pipeline wiring (Edge Functions under Deno, the Cloud Run worker under Node):
// service-role RPC and Storage adapters.
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { BUCKET, PipelineRPCError, type PipelineDeps } from './pipeline.ts';

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

export function rpcAdapter(client: SupabaseClient): PipelineDeps['rpc'] {
  return async <T>(name: string, params: Record<string, unknown>): Promise<T> => {
    const { data, error } = await client.rpc(name, params);
    if (error) {
      const code = /^[a-z_]{1,64}$/.test(error.message) ? error.message : 'database_error';
      throw new PipelineRPCError(code);
    }
    return data as T;
  };
}

/** Readers' uploads (migration 031): their own private bucket, read once and then deleted. */
export const UPLOAD_BUCKET = 'paper-uploads';
export function uploadStorageAdapter(client: SupabaseClient): NonNullable<PipelineDeps['uploads']> {
  const bucket = () => client.storage.from(UPLOAD_BUCKET);
  return {
    async download(path, maximumBytes) {
      const { data, error } = await bucket().download(path);
      if (error || !data) {
        const status = Number((error as { statusCode?: unknown; status?: unknown } | null)?.statusCode ?? (error as { status?: unknown } | null)?.status);
        if (status === 404 || status === 400 || /not.?found/i.test(error?.message ?? '')) throw new Error('storage_object_missing');
        throw new Error('storage_download_failed');
      }
      if (data.size > maximumBytes) throw new Error('storage_object_too_large');
      return new Uint8Array(await data.arrayBuffer());
    },
    async remove(paths) {
      // Removing an object that is already gone succeeds.
      const { error } = await bucket().remove(paths);
      if (error) throw new Error('storage_remove_failed');
    },
  };
}

export function storageAdapter(client: SupabaseClient): PipelineDeps['storage'] {
  const bucket = () => client.storage.from(BUCKET);
  return {
    async upload(path, bytes, contentType) {
      // Paths are content-addressed (sha256 in the path), so an overwrite can
      // only ever write identical bytes.
      const { error } = await bucket().upload(path, bytes, { contentType, upsert: true, cacheControl: '31536000' });
      if (error) throw new Error('storage_upload_failed');
    },
    async download(path, maximumBytes) {
      const { data, error } = await bucket().download(path);
      if (error || !data) throw new Error('storage_download_failed');
      if (data.size > maximumBytes) throw new Error('storage_object_too_large');
      return new Uint8Array(await data.arrayBuffer());
    },
    async signedURL(path, seconds) {
      const { data, error } = await bucket().createSignedUrl(path, seconds);
      if (error || !data?.signedUrl) throw new Error('storage_sign_failed');
      return data.signedUrl;
    },
  };
}
