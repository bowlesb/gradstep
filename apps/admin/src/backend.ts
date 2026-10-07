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

// The admin-accounts Edge function (owner with MFA). Error codes map to plain messages;
// anything unexpected means the change was not confirmed.
const accountErrors: Record<string, string> = {
  owner_mfa_required: 'An owner account with two-factor authentication is required.',
  rate_limited: 'Too many account changes this hour. Try again later.',
  invalid_email: 'Enter a valid email address.',
  invalid_credits: 'Credits must be a whole number up to 2,000.',
  invalid_reason: 'Enter a reason of 3 to 500 characters on one line.',
  account_unavailable: 'This account no longer exists.',
  account_closed: 'This account is being deleted or has been deleted.',
  owner_cannot_be_disabled: 'Owner accounts cannot be disabled here.',
  request_id_conflict: 'This change conflicts with an earlier one. Reload and try again.',
  sign_in_change_unconfirmed: 'The change was recorded but sign-in could not be updated. Try again.',
};
export async function adminAccounts<T>(body: Record<string, unknown>): Promise<T> {
  if (!backend || !url || !key) throw new Error('The backend has not been configured for this build.');
  const { data } = await backend.auth.getSession();
  if (!data.session) throw new Error('Sign in again to continue.');
  let response: Response;
  try {
    response = await fetch(new URL('/functions/v1/admin-accounts', url), { method: 'POST', cache: 'no-store', signal: AbortSignal.timeout(30_000),
      headers: { apikey: key, Authorization: `Bearer ${data.session.access_token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  } catch { throw new Error('The request could not be completed. Your change was not confirmed.'); }
  const json = await response.json().catch(() => null) as { code?: string } | null;
  if (!response.ok) throw new Error(accountErrors[json?.code ?? ''] ?? 'The request could not be completed. Your change was not confirmed.');
  return json as T;
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

export type Pipeline = {
  policy: { enabled: boolean; max_ocr_pages: number; renderer_version: string };
  stages: Record<string, number>;
  papers: { id: string; source: string; title: string | null; private: boolean; stage: string; error_code: string | null; failures: number; interested: number; updated_at: string }[];
  attempts: { id: string; paper_id: string; state: string; page_limit: number; pages_reported: number | null; provider_job_id: string | null; error_code: string | null; created_at: string; finished_at: string | null }[];
};

// v1_admin_pipeline_metrics (migration 022). Days without events are absent from `daily`.
export interface PipelineMetrics {
  since: string; generated_at: string;
  /** Exact over the window (migration 023); absent from older servers. */
  summary?: { started: number; ready: number; failed: number; cancelled: number; ready_p50_s: number | null; ready_p90_s: number | null };
  daily: { day: string; started: number; ready: number; failed: number; cancelled: number; ready_p50_s: number | null; ready_p90_s: number | null }[];
  stages: { stage: string; count: number; p50_s: number | null; p90_s: number | null; failed: number }[];
  crashes: Record<string, number>;
  failure_causes: Record<string, number>;
  recent_failures: { at: string; kind: 'crash' | 'import' | 'stage'; source: string | null; stage: string | null; error_code: string | null; private: boolean | null }[];
  stuck: { id: string; source: string; private: boolean; stage: string; since: string; minutes: number; claims: number; crashes: number; leased: boolean }[];
}
