import { createClient } from '@supabase/supabase-js';
import { spendingReceipt, type SpendingObservationRequest, type SpendingObservationReceipt } from '../../../supabase/functions/_shared/spending-observations.ts';

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

const observationErrors: Record<string, string> = {
  authentication_required: 'Sign in again, then retry the same entry.',
  account_unavailable: 'This owner account is unavailable. The entry was not confirmed.',
  owner_mfa_required: 'An owner account with two-factor authentication is required.',
  rate_limited: 'Too many spending requests. Wait a minute, then retry the same entry.',
  invalid_component: 'This cost component is unavailable.',
  invalid_period: 'Choose a reporting month from October 2026 through twelve months ahead.',
  invalid_measure: 'Choose a supported observation type.',
  invalid_amount: 'Enter USD from 0 to 10,000 with at most six decimal places, or leave it unknown.',
  invalid_completeness: 'A complete commitment, forecast or invoice needs a known amount.',
  invalid_evidence: 'Use a reference of 3–256 letters, numbers, spaces or . _ : / - characters.',
  invalid_observed_at: 'The observation time was refused. Check this device’s clock before continuing.',
  observation_id_conflict: 'This entry conflicts with its recorded receipt. Keep its request ID for review; do not resubmit it as a new entry.',
  observation_capacity: 'This component has reached its monthly evidence-entry limit. Review its existing records.',
};
const unconfirmedObservation = 'The observation was not confirmed. Retry the same entry; it will not be added twice.';
export async function adminSpendingObservation(ownerID: string, body: SpendingObservationRequest): Promise<SpendingObservationReceipt> {
  if (!backend || !url || !key) throw new Error('The backend has not been configured for this build.');
  const { data } = await backend.auth.getSession();
  if (!data.session || data.session.user.id !== ownerID) throw new Error('Sign in as the same owner, then retry this entry.');
  let response: Response, value: unknown;
  try {
    response = await fetch(new URL('/functions/v1/admin-spending', url), { method: 'POST', cache: 'no-store', redirect: 'error', signal: AbortSignal.timeout(30_000),
      headers: { apikey: key, Authorization: `Bearer ${data.session.access_token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    if ((response.headers.get('content-type') ?? '').split(';')[0].trim().toLowerCase() !== 'application/json' || !response.body) throw new Error();
    const reader = response.body.getReader(); const parts: Uint8Array[] = []; let count = 0;
    try { for (;;) { const { done, value } = await reader.read(); if (done) break; count += value.length;
      if (count > 2048) { await reader.cancel().catch(() => {}); throw new Error(); } parts.push(value); } }
    finally { reader.releaseLock(); }
    const joined = new Uint8Array(count); let offset = 0; for (const part of parts) { joined.set(part, offset); offset += part.length; }
    value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(joined));
  } catch { throw new Error(unconfirmedObservation); }
  if (!response.ok) {
    const code = value && typeof value === 'object' && !Array.isArray(value) ? (value as { code?: unknown }).code : null;
    throw new Error(typeof code === 'string' && Object.hasOwn(observationErrors, code) ? observationErrors[code] : unconfirmedObservation);
  }
  const result = spendingReceipt(value, body.request_id);
  if (!result) throw new Error(unconfirmedObservation);
  return result;
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

/** v1_admin_health (migration 069, docs/architecture/ADMIN_HEALTH.md): daily series over the window, UTC days. */
export interface Health {
  generated_at: string; since: string; today: string; days: number; month_start: string;
  people: { accounts: number; new_in_window: number; active_7d: number; active_30d: number; returning_7d: number;
    daily: { day: string; new: number; active: number; active_7d: number }[] };
  use: { papers_added: number; chat_answers: number; chatting_accounts: number; podcasts_started: number;
    daily: { day: string; papers: number; chats: number; chatting: number; podcasts: number }[] };
  reliability: { papers_failed: number; paper_failure_codes: Record<string, number>; chats_unsettled: number; podcasts_ready: number;
    podcasts_failed: number; podcast_failure_codes: Record<string, number>; reports_open: number;
    daily: { day: string; papers_failed: number; podcasts_failed: number; reports: number }[] };
  money: { month_to_date_microusd: number; window_microusd: number; by_provider: Record<string, number>; credits_consumed: number; credits_granted: number;
    chat_cache: { read_tokens: number; write_tokens: number; input_tokens: number };
    daily: { day: string; microusd: number; by_provider: Record<string, number>; credits_consumed: number }[] };
  /** Migration 073 (RESILIENCE.md): outside providers' failures per day, the last hour, and breakers open now. Absent on older servers. */
  providers?: {
    daily: { day: string; by_provider: Record<string, { calls: number; failed: number; throttled: number; breaker_open: number }> }[];
    last_hour: { provider: string; calls: number; failed: number; throttled: number; breaker_open: number; latency_ms_avg: number | null }[];
    breakers: { provider: string; state: 'open' | 'half_open'; reopen_at: string | null }[];
  };
  /** Migration 079 (RESILIENCE.md fix 1): operations whose provider cost passed their ceiling. Recorded, never a pause by
   * itself; more than `pause_after` within `window_minutes` pause the month (the tripwire). Absent on older servers. */
  anomalies?: {
    pause_after: number; window_minutes: number; in_window: number; last_24h: number; last_24h_test: number;
    recent: { at: string; kind: 'attempt_over_ceiling' | 'operation_over_ceiling'; operation_kind: string; ceiling_microusd: number;
      observed_microusd: number; paused_month: boolean; test_account: boolean }[];
  };
  /** Migration 079 (CHAT.md "When an answer stops early"): chat answers by how they ended over the window, the provider
   * cost Gradstep absorbed, and real accounts over the daily number of unpaid early endings (never blocked). */
  early_endings?: {
    attention_daily: number; answers: number; uncharged: number; absorbed_microusd: number; by_ending: Record<string, number>;
    today: { uncharged: number; absorbed_microusd: number };
    accounts_over_today: { account_id: string; uncharged: number; absorbed_microusd: number }[];
  };
  /** Migration 084: requests a provider refused for the account's own balance (Anthropic "credit balance is too low",
   * DeepSeek 402), last hour and day. Absent on older servers. */
  provider_billing?: { last_hour: number; last_24h: number; last_at: string | null; by_provider: Record<string, number> };
}

/** v1_admin_provider_hours (migration 073): one row per hour and provider. */
export interface ProviderHour { hour: string; provider: string; calls: number; ok: number; throttled: number; failed: number; rejected: number;
  breaker_open: number; latency_ms_avg: number | null; latency_ms_max: number | null; retry_after_max_s: number | null }
