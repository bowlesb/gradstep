import { createClient } from '@supabase/supabase-js';

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const key = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;
export const environment = (import.meta.env.VITE_ENVIRONMENT as string | undefined) ?? 'staging';
export const backend = url && key ? createClient(url, key, {
  auth: { flowType: 'pkce', persistSession: true, autoRefreshToken: true, storageKey: `science-reader.admin.${environment}` },
}) : null;

export async function attachmentImage(id: string, signal: AbortSignal): Promise<Blob> {
  if (!backend || !url || !key) throw new Error('The backend is unavailable.');
  const { data } = await backend.auth.getSession();
  if (!data.session) throw new Error('Sign in again to view this screenshot.');
  const endpoint = new URL('/functions/v1/support-assets', url);
  endpoint.searchParams.set('attachment_id', id);
  const response = await fetch(endpoint, { signal, headers: { apikey: key, Authorization: `Bearer ${data.session.access_token}` }, cache: 'no-store' });
  if (!response.ok || !['image/png', 'image/jpeg'].includes(response.headers.get('content-type') ?? '')) throw new Error('This screenshot could not be loaded. Check your access and try again.');
  const blob = await response.blob();
  if (blob.size > 5 * 1024 * 1024) throw new Error('The screenshot exceeds the permitted size.');
  return blob;
}

export async function rpc<T>(name: string, parameters: Record<string, unknown> = {}): Promise<T> {
  if (!backend) throw new Error('The backend has not been configured for this build.');
  const { data, error } = await backend.rpc(name, parameters);
  if (error) {
    const errors: Record<string, string> = {
      owner_mfa_required: 'An owner account with two-factor authentication is required.',
      operator_required: 'This action requires an authorized operator.',
      report_unavailable: 'This report is not available to your account.',
      fixed_build_required: 'Enter the build that contains the fix.',
      budget_not_configured: 'Provider spending has not been configured.',
    };
    throw new Error(errors[error.message] ?? 'The request could not be completed. Your changes were not confirmed.');
  }
  return data as T;
}

export interface AccountContext { account_id: string; roles: string[]; operator_verified: boolean }
export interface Budget { period: string; limit_microusd: number; spent_microusd: number; reserved_microusd: number; work_enabled: boolean }
export interface Overview {
  accounts: number; library_items: number; shared_documents: number; shared_documents_reused: number;
  budgets: Budget[]; jobs: Record<string, number>; subscriptions: Record<string, number>; open_reports: number;
  usage: Array<{ provider: string; model: string; calls: number; estimated_microusd: number }>;
  sync_storage?: { ciphertext_bytes: number; event_count: number; environment_bytes: number; environment_events: number; account_bytes: number; account_events: number };
  sync_transfers?: { period: string; policy: { account_bytes: number; environment_bytes: number }; months: Array<{ period: string; reserved_bytes: number; requests: number }> };
}
export interface Report { id: string; title: string; note: string; account_id: string; status: string; app_version: string; build: string; fixed_build?: string; screen: string; os_version: string; created_at: string }
export interface Thread { report: Report; messages: Array<{ id: string; body: string; is_operator: boolean; created_at: string }>; attachments: Array<{ id: string; object_id: string }> }
