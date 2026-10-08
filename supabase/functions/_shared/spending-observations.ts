// Closed, portable contract shared by the owner form and its Edge entrypoint.
// This module has no credentials, database client or privileged operations.
export const SPENDING_COMPONENTS = {
  tavily_subscription: 'Tavily subscription', domains: 'Domains, amortized',
  supabase_compute: 'Incremental Supabase plan and compute', cloud_run: 'Cloud Run processing',
  storage_egress: 'Storage and transfer overages', builds_registry: 'Builds and container registry',
  backups: 'Backup hosting', web_hosting: 'Web and admin hosting',
} as const;
export const SPENDING_MEASURES = ['commitment', 'forecast', 'invoice', 'metric'] as const;
export type SpendingComponent = keyof typeof SPENDING_COMPONENTS;
export type SpendingMeasure = typeof SPENDING_MEASURES[number];
export interface SpendingObservationDraft {
  component: SpendingComponent; period: string; measure: SpendingMeasure;
  amount_microusd: number | null; complete: boolean; evidence_reference: string;
}
export interface SpendingObservationRequest extends SpendingObservationDraft { request_id: string; observed_at: string }
export interface SpendingObservationReceipt { id: string; replayed: boolean }
export const MAX_OBSERVATION_MICROUSD = 10_000_000_000;
export const FIRST_OBSERVATION_MONTH = '2026-10';
export const canonicalUUID = (s: unknown): s is string => typeof s === 'string' && s.length === 36
  && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(s);
export const canonicalTimestamp = (s: unknown): s is string => typeof s === 'string' && s.length === 24
  && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(s) && Number.isFinite(Date.parse(s)) && new Date(s).toISOString() === s;
export function latestObservationMonth(now = new Date()): string {
  return new Date(Date.UTC(now.getUTCFullYear() + 1, now.getUTCMonth(), 1)).toISOString().slice(0, 7);
}
export class SpendingInputError extends Error {
  readonly code: 'invalid_request' | 'invalid_component' | 'invalid_period' | 'invalid_measure'
    | 'invalid_amount' | 'invalid_completeness' | 'invalid_evidence' | 'invalid_request_id' | 'invalid_observed_at';
  constructor(code: SpendingInputError['code']) { super(code); this.code = code; }
}
const fail = (code: SpendingInputError['code']): never => { throw new SpendingInputError(code); };
function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return fail('invalid_request');
  return value as Record<string, unknown>;
}
const draftKeys = ['component', 'period', 'measure', 'amount_microusd', 'complete', 'evidence_reference'];
function keys(fields: Record<string, unknown>, expected: string[]) {
  const present = Object.keys(fields);
  if (present.length !== expected.length || present.some(key => !expected.includes(key))) fail('invalid_request');
}
function fields(body: Record<string, unknown>, now: Date): SpendingObservationDraft {
  if (typeof body.component !== 'string' || !Object.hasOwn(SPENDING_COMPONENTS, body.component)) fail('invalid_component');
  if (typeof body.period !== 'string' || body.period.length !== 10 || !/^\d{4}-(0[1-9]|1[0-2])-01$/.test(body.period)
    || body.period < FIRST_OBSERVATION_MONTH + '-01' || body.period > latestObservationMonth(now) + '-01') fail('invalid_period');
  if (!SPENDING_MEASURES.includes(body.measure as SpendingMeasure)) fail('invalid_measure');
  if (body.amount_microusd !== null && (typeof body.amount_microusd !== 'number' || !Number.isSafeInteger(body.amount_microusd)
    || body.amount_microusd < 0 || body.amount_microusd > MAX_OBSERVATION_MICROUSD)) fail('invalid_amount');
  if (typeof body.complete !== 'boolean' || (body.complete && body.amount_microusd === null && body.measure !== 'metric')) fail('invalid_completeness');
  if (typeof body.evidence_reference !== 'string' || body.evidence_reference.length < 3 || body.evidence_reference.length > 256
    || body.evidence_reference.trim() !== body.evidence_reference || !/^[a-zA-Z0-9._:/ -]+$/.test(body.evidence_reference)) fail('invalid_evidence');
  // Fixed property order also makes the retry digest independent of caller object ordering.
  return { component: body.component as SpendingComponent, period: body.period as string, measure: body.measure as SpendingMeasure,
    amount_microusd: body.amount_microusd as number | null, complete: body.complete as boolean, evidence_reference: body.evidence_reference as string };
}
export function parseSpendingDraft(value: unknown, now = new Date()): SpendingObservationDraft {
  const body = object(value); keys(body, draftKeys); return fields(body, now);
}
export function parseSpendingObservation(value: unknown, now = new Date()): SpendingObservationRequest {
  const body = object(value); keys(body, [...draftKeys, 'request_id', 'observed_at']);
  const draft = fields(body, now);
  if (!canonicalUUID(body.request_id)) fail('invalid_request_id');
  if (!canonicalTimestamp(body.observed_at) || Date.parse(body.observed_at as string) > now.getTime() + 300_000
    || (body.observed_at as string) < '2026-10-01T00:00:00.000Z') fail('invalid_observed_at');
  return { ...draft, request_id: body.request_id as string, observed_at: body.observed_at as string };
}
export function spendingReceipt(value: unknown, requestID: string): SpendingObservationReceipt | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const body = value as Record<string, unknown>;
  return Object.keys(body).length === 2 && body.id === requestID && canonicalUUID(body.id) && typeof body.replayed === 'boolean'
    ? { id: body.id, replayed: body.replayed } : null;
}

/** Parse dollars exactly; multiplication of a binary decimal is not an accounting conversion. */
export function dollarsToMicrousd(value: string): number | null {
  if (!value.trim()) return null;
  if (value.trim() !== value || value.length > 12 || !/^(0|[1-9]\d{0,4})(\.\d{1,6})?$/.test(value)) return fail('invalid_amount');
  const [whole, fraction = ''] = value.split('.');
  const amount = Number(whole) * 1_000_000 + Number(fraction.padEnd(6, '0'));
  if (amount > MAX_OBSERVATION_MICROUSD) return fail('invalid_amount');
  return amount;
}
