import React, { useEffect, useRef, useState } from 'react';
import { adminSpendingObservation, rpc, type Budget } from './backend';
import { SpendingEntry } from './spending-entry';
import type { SpendingObservationRequest, SpendingObservationReceipt } from '../../../supabase/functions/_shared/spending-observations.ts';

type Cursor = { created_at: string; account_id: string; id: string };
type RecordCursor = { at: string; id: string };
type RecordKind = 'events' | 'credits' | 'adjustments' | 'legacy_usage';
type Units = Record<string, number>;
export interface SpendingSummary {
  since: string; generated_at: string; account_id: string | null; coverage_started_at: string; budget: Budget | null;
  attempts: { total: number; admitted: number; unknown: number; denied: number; reported_microusd: number; estimated_microusd: number; held_microusd: number };
  unresolved: { total: number; held_microusd: number; aged_over_hour: number; oldest_at: string | null };
  providers: Array<{ provider: string; model: string; route: string; attempts: number; reported_microusd: number; estimated_microusd: number; held_microusd: number; prepaid_used: number; prepaid_held: number }>;
  provider_group_limit: number;
  customers: { settled_credits: number; platform_funded_operations: number; held_credits: number };
  legacy: { usage_records: number; estimated_microusd: number; reconciliation_microusd: number };
  allowances: Array<{ id: string; provider: string; starts_at: string; ends_at: string; limit_units: number; baseline_units: number; spent_units: number; reserved_units: number; enabled: boolean; overage_disabled: boolean; observed_at: string; evidence_reference: string }>;
  forecast: { period: string; operating_limit_microusd: number; provider_allocation_microusd: number | null; overhead_allocation_microusd: number; funded_plan_microusd: number | null; complete: boolean; missing_components: number;
    components: Array<{ id: string; label: string; observation_id: string | null; measure: string | null; amount_microusd: number | null; complete: boolean | null; observed_at: string | null; source: string | null; evidence_reference: string | null }> };
  external_observations: Array<{ id: string; component: string; measure: string; amount_microusd: number | null; complete: boolean; observed_at: string; source: string; evidence_reference: string; units: Units }>;
  anomalies: { budget_paused: boolean; budget_eighty_percent: boolean; forecast_incomplete: boolean; funded_plan_over_budget: boolean; tavily_unverified: boolean; native_search_gated: boolean; attempt_capacity_eighty_percent: boolean };
  /** Encrypted note images (migration 095); absent before it. */
  note_assets?: NoteAssetUsage;
  /** Granted provider attempts in the rolling window (migration 0100, review A2); absent before it. */
  attempt_capacity?: AttemptCapacity;
  /** Migration 0162: OpenRouter attempts settled at $0 in the window (no output, no record after 12 tries), the ceilings
   * that were assumed zero, and those a late record corrected (at the record's cost); absent before it. */
  assumed_zero?: { attempts: number; ceiling_microusd: number; corrected: number; corrected_microusd: number };
}
export interface AttemptCapacity { window_hours: number; platform_used: number; platform_limit: number; account_limit: number;
  busiest_account_id: string | null; busiest_account_used: number; eighty_percent: boolean }
export interface NoteAssetUsage {
  period: string;
  limits: { max_blob_bytes: number; account_bytes: number; account_objects: number; environment_bytes: number; account_download_bytes_month: number;
    environment_download_bytes_month: number; account_verify_bytes_month: number; environment_verify_bytes_month: number };
  stored: { bytes: number; objects: number; ready_bytes: number; ready_objects: number; pending_bytes: number; pending_objects: number; oldest_pending_at: string | null; accounts: number };
  month: { download_bytes: number; downloads: number; verify_bytes: number; verifies: number };
  account: { bytes: number; objects: number; pending_objects: number; download_bytes: number; verify_bytes: number } | null;
}
export interface SpendingOperation {
  id: string; account_id: string; kind: string; state: string; created_at: string; settled_at: string | null;
  credit_ceiling: number; actual_credits: number | null; spend_ceiling_microusd: number; settled_microusd: number | null;
  provider_liability_microusd: number; attempt_accounting: boolean; attempts: number; current_provider_microusd: number;
}
export interface SpendingDetail {
  operation: Omit<SpendingOperation, 'settled_microusd' | 'attempts' | 'current_provider_microusd'> & { actual_microusd: number | null; period: string; rate_version: string };
  account: { id: string; closed: boolean; spending_suspended: boolean };
  attempts: Array<{ id: string; provider: string; route: string; model: string; state: string; provider_request_id: string | null; actual_microusd: number | null; ceiling_microusd: number; actual_units: Units; reserved_units: Units; failure_code: string | null; created_at: string; dispatched_at?: string | null; finished_at?: string | null; transport_metadata?: Record<string, unknown>; receipt_metadata?: Record<string, unknown>; pricing_snapshot: Record<string, unknown> }>;
  record_counts: Record<RecordKind, number>;
}
export interface SpendingRecords { kind: RecordKind; records: Array<{ at: string; key: string; entry: Record<string, unknown> }>; next: RecordCursor | null }
export interface SpendingApi {
  record(ownerID: string, observation: SpendingObservationRequest): Promise<SpendingObservationReceipt>;
  summary(days: number, account: string | null): Promise<SpendingSummary>;
  operations(days: number, account: string | null, cursor: Cursor | null, unresolved: boolean): Promise<{ operations: SpendingOperation[]; next: Cursor | null }>;
  detail(account: string, operation: string): Promise<SpendingDetail>;
  records(account: string, operation: string, kind: RecordKind, cursor: RecordCursor | null): Promise<SpendingRecords>;
}
export const liveSpendingApi: SpendingApi = {
  record: adminSpendingObservation,
  summary: (days, account) => rpc('v1_admin_spending', { p_days: days, p_account_id: account }),
  operations: (days, account, cursor, unresolved) => rpc('v1_admin_spending_operations', { p_days: days, p_account_id: account,
    p_before_created_at: cursor?.created_at ?? null, p_before_account_id: cursor?.account_id ?? null, p_before_id: cursor?.id ?? null, p_limit: 25, p_unresolved_only: unresolved }),
  detail: (account, operation) => rpc('v1_admin_spending_operation', { p_account_id: account, p_operation_id: operation }),
  records: (account, operation, kind, cursor) => rpc('v1_admin_spending_records', { p_account_id: account, p_operation_id: operation, p_kind: kind,
    p_before_at: cursor?.at ?? null, p_before_id: cursor?.id ?? null, p_limit: 50 }),
};
const money = (n: number | null | undefined) => n == null ? 'Not recorded' : new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: 6 }).format(n / 1e6);
const date = (s: string | null | undefined) => s ? new Date(s).toLocaleString() : '—';
const name = (s: string) => s.replaceAll('_', ' ');
const short = (s: string) => s.slice(0, 8);
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const recordNames: Record<RecordKind, string> = { events: 'Attempt history', credits: 'Customer credits', adjustments: 'Reconciliation', legacy_usage: 'Earlier usage records' };
const errorText = (e: unknown) => e instanceof Error ? e.message : 'Spending records could not be loaded.';

/** Review A2: provider attempts are limited per rolling window; at 80% new AI work is close to being refused. */
function AttemptCapacityNotice({ capacity }: { capacity: AttemptCapacity }) {
  const window = `${capacity.window_hours} hours`;
  return <div className="notice" role="alert">
    {capacity.platform_used >= capacity.platform_limit * 0.8 && <>Provider attempts in the last {window}: {capacity.platform_used.toLocaleString()} of {capacity.platform_limit.toLocaleString()} for the whole service. </>}
    {capacity.busiest_account_id && capacity.busiest_account_used >= capacity.account_limit * 0.8 && <>Account {short(capacity.busiest_account_id)} used {capacity.busiest_account_used.toLocaleString()} of its {capacity.account_limit.toLocaleString()} attempts in the last {window}. </>}
    At the limit, new AI work is refused until older attempts leave the window.
  </div>;
}

export function Spending({ ownerID, api = liveSpendingApi, reloadKey = 0 }: { ownerID: string; api?: SpendingApi; reloadKey?: number }) {
  const [days, setDays] = useState(30), [account, setAccount] = useState<string | null>(null), [draft, setDraft] = useState('');
  const [summary, setSummary] = useState<SpendingSummary | null>(null), [error, setError] = useState(''), [retry, setRetry] = useState(0);
  const [selected, setSelected] = useState<{ account: string; operation: string } | null>(null);
  const detailTrigger = useRef<HTMLButtonElement | null>(null);
  useEffect(() => {
    let current = true; setSummary(null); setError(''); setSelected(null);
    api.summary(days, account).then(value => { if (current) setSummary(value); }, e => { if (current) setError(errorText(e)); });
    return () => { current = false; };
  }, [api, days, account, reloadKey, retry]);
  return <div className="spending">
    <form className="toolbar" onSubmit={event => { event.preventDefault(); const value = draft.trim(); if (value && !uuid.test(value)) { setError('Enter a complete account ID.'); return; } setError(''); setAccount(value.toLowerCase() || null); }}>
      <label>Period<select value={days} onChange={e => setDays(Number(e.target.value))}><option value={7}>Last 7 days</option><option value={30}>Last 30 days</option><option value={90}>Last 90 days</option></select></label>
      <label className="account-filter">Account ID<input value={draft} onChange={e => setDraft(e.target.value)} placeholder="All accounts" spellCheck={false} /></label>
      <button type="submit" className="quiet">Apply filter</button>
      {account && <button type="button" className="quiet" onClick={() => { setDraft(''); setAccount(null); }}>Clear account</button>}
    </form>
    {error && <div className="error" role="alert">{error} <button className="quiet inline" onClick={() => setRetry(n => n + 1)}>Retry</button></div>}
    {!summary && !error && <p role="status">Loading spending…</p>}
    {summary && <>
      <div className="metrics">
        <CostMetric title="Reported provider cost" value={money(summary.attempts.reported_microusd)} note={`${summary.attempts.total} tracked attempts`} />
        <CostMetric title="Unresolved liability" value={money(summary.unresolved.held_microusd)} note={`${summary.unresolved.total} unresolved attempts, across all dates`} />
        <CostMetric title="Customer credits used" value={summary.customers.settled_credits.toLocaleString()} note={`${summary.customers.held_credits} credits still held`} />
        <CostMetric title="Estimated provider cost" value={money(summary.attempts.estimated_microusd)} note="Conservative estimates, not invoices" />
      </div>
      {(summary.unresolved.aged_over_hour > 0 || summary.anomalies.budget_paused || summary.anomalies.budget_eighty_percent) && <div className="notice" role="status">
        {summary.anomalies.budget_paused ? 'New provider spending is paused. ' : summary.anomalies.budget_eighty_percent ? 'At least 80% of the provider budget is used or held. ' : ''}
        {summary.unresolved.aged_over_hour > 0 && `${summary.unresolved.aged_over_hour} unresolved attempts are more than an hour old.`}
      </div>}
      {summary.attempt_capacity?.eighty_percent && <AttemptCapacityNotice capacity={summary.attempt_capacity} />}
      <section className="panel"><div className="section-heading"><h2>Provider attempts</h2><small className="muted">Requests started since {new Date(summary.since).toLocaleDateString()}</small></div>
        <div className="table-scroll"><table><thead><tr><th>Provider / model</th><th>Feature</th><th className="num">Attempts</th><th className="num">Reported</th><th className="num">Estimated</th><th className="num">Held</th><th className="num">Prepaid units</th></tr></thead><tbody>
          {summary.providers.map(row => <tr key={[row.provider, row.model, row.route].join(':')}><td>{row.provider}<small>{row.model}</small></td><td>{name(row.route)}</td><td className="num">{row.attempts}</td><td className="num">{money(row.reported_microusd)}</td><td className="num">{money(row.estimated_microusd)}</td><td className="num">{money(row.held_microusd)}</td><td className="num">{row.provider === 'tavily' ? `${row.prepaid_used} used · ${row.prepaid_held} held` : '—'}</td></tr>)}
        </tbody></table></div>
        {!summary.providers.length && <p className="empty">No tracked provider attempts in this period.</p>}
        {summary.providers.length >= summary.provider_group_limit && <p className="muted">Showing the {summary.provider_group_limit} busiest provider/model groups. Filter by account for a narrower view.</p>}
        {!!summary.assumed_zero?.attempts && <p className="muted">Assumed zero: {summary.assumed_zero.attempts} OpenRouter attempt{summary.assumed_zero.attempts === 1 ? '' : 's'} settled at $0 with {money(summary.assumed_zero.ceiling_microusd)} of ceilings released; nothing reached us and OpenRouter had no record after 12 tries. Counted as estimates, never as reported cost{summary.assumed_zero.corrected ? `; ${summary.assumed_zero.corrected} later corrected to OpenRouter's cost (${money(summary.assumed_zero.corrected_microusd)})` : ''}.</p>}
        <p className="muted">Attempt tracking began {date(summary.coverage_started_at)}. Earlier records: {summary.legacy.usage_records}, estimated {money(summary.legacy.estimated_microusd)}, adjustments {money(summary.legacy.reconciliation_microusd)}. They may not include every retry.</p>
      </section>
      <OperationList key={`${days}:${account}:${reloadKey}:${retry}`} api={api} days={days} account={account} onSelect={(value, trigger) => { detailTrigger.current = trigger; setSelected(value); }} />
      {selected && <OperationDetail key={`${selected.account}:${selected.operation}`} api={api} selected={selected} onClose={() => { setSelected(null); detailTrigger.current?.focus(); }} />}
      <section className="panel"><h2>Search allowance</h2>
        {!summary.allowances.length && <p className="notice">Tavily is gated until its billing period, usage baseline and overage setting are verified.</p>}
        {summary.allowances.map(a => <div className="allowance-row" key={a.id}><strong>{a.provider}</strong><span>{new Date(a.starts_at).toLocaleDateString()} – {new Date(a.ends_at).toLocaleDateString()}</span><span>{a.baseline_units + a.spent_units} used + {a.reserved_units} held / {a.limit_units}</span><span className="badge">{a.enabled ? 'Enabled' : 'Paused'}</span><small className="muted">Baseline {a.baseline_units}; evidence {a.evidence_reference}, checked {date(a.observed_at)}</small></div>)}
      </section>
      {summary.note_assets && <NoteImages usage={summary.note_assets} account={account} />}
      <Forecast summary={summary} />
      <p className="footnote">Customer refunds do not erase possible provider charges. These records contain financial metadata; private prompts, chats and papers are not included.</p>
    </>}
    <SpendingEntry ownerID={ownerID} record={api.record} onRecorded={() => setRetry(n => n + 1)} />
  </div>;
}
function CostMetric({ title, value, note }: { title: string; value: string; note: string }) {
  return <section className="metric"><p>{title}</p><strong>{value}</strong><small>{note}</small></section>;
}

function OperationList({ api, days, account, onSelect }: { api: SpendingApi; days: number; account: string | null; onSelect(value: { account: string; operation: string }, trigger: HTMLButtonElement): void }) {
  const [onlyUnknown, setOnlyUnknown] = useState(false), [rows, setRows] = useState<SpendingOperation[]>([]), [cursor, setCursor] = useState<Cursor | null>(null);
  const [busy, setBusy] = useState(false), [error, setError] = useState(''), [retry, setRetry] = useState(0), generation = useRef(0);
  useEffect(() => {
    const token = ++generation.current; setRows([]); setCursor(null); setBusy(true); setError('');
    api.operations(days, account, null, onlyUnknown).then(page => { if (token === generation.current) { setRows(page.operations); setCursor(page.next); } }, e => { if (token === generation.current) setError(errorText(e)); }).finally(() => { if (token === generation.current) setBusy(false); });
    return () => { generation.current++; };
  }, [api, days, account, onlyUnknown, retry]);
  const next = async () => {
    if (!cursor || busy) return; const token = generation.current; setBusy(true); setError('');
    try { const page = await api.operations(days, account, cursor, onlyUnknown); if (token === generation.current) { setRows(old => [...old, ...page.operations.filter(row => !old.some(x => x.id === row.id && x.account_id === row.account_id))]); setCursor(page.next); } }
    catch (e) { if (token === generation.current) setError(errorText(e)); }
    finally { if (token === generation.current) setBusy(false); }
  };
  return <section className="panel"><div className="section-heading"><h2>Investigate an operation</h2><label className="check"><input type="checkbox" checked={onlyUnknown} onChange={e => setOnlyUnknown(e.target.checked)} />Unresolved only, all dates</label></div>
    {error && <p className="error" role="alert">{error} <button className="quiet inline" onClick={() => setRetry(n => n + 1)}>Retry</button></p>}
    <div className="table-scroll"><table><thead><tr><th>Operation</th><th>Account</th><th>Started</th><th>State</th><th className="num">Credits</th><th className="num">Provider cost</th><th className="num">Held</th></tr></thead><tbody>{rows.map(row => <tr key={`${row.account_id}:${row.id}`}>
      <td><button className="quiet inline" onClick={event => onSelect({ account: row.account_id, operation: row.id }, event.currentTarget)}>{name(row.kind)} · {short(row.id)}</button><small>{row.attempts} attempts{!row.attempt_accounting ? ' · legacy coverage' : ''}</small></td><td><code title={row.account_id}>{short(row.account_id)}</code></td><td>{date(row.created_at)}</td><td>{name(row.state)}</td><td className="num">{row.actual_credits ?? `≤ ${row.credit_ceiling}`}</td><td className="num">{money(row.attempt_accounting ? row.current_provider_microusd : row.settled_microusd)}</td><td className="num">{money(row.state === 'settled' ? row.provider_liability_microusd : row.spend_ceiling_microusd)}</td>
    </tr>)}</tbody></table></div>
    {busy && <p role="status">Loading operations…</p>}{!busy && !error && !rows.length && <p className="empty">No matching operations.</p>}
    {cursor && <button className="quiet" disabled={busy} onClick={() => void next()}>Load more operations</button>}
  </section>;
}

function OperationDetail({ api, selected, onClose }: { api: SpendingApi; selected: { account: string; operation: string }; onClose(): void }) {
  const [detail, setDetail] = useState<SpendingDetail | null>(null), [error, setError] = useState(''), [retry, setRetry] = useState(0);
  const [kind, setKind] = useState<RecordKind>('events'); const heading = useRef<HTMLHeadingElement>(null);
  useEffect(() => { heading.current?.focus(); let live = true; setError(''); setDetail(null);
    api.detail(selected.account, selected.operation).then(value => { if (live) setDetail(value); }, e => { if (live) setError(errorText(e)); }); return () => { live = false; };
  }, [api, selected.account, selected.operation, retry]);
  return <section className="panel spending-detail" aria-labelledby="spending-detail-title"><div className="section-heading"><h2 id="spending-detail-title" tabIndex={-1} ref={heading}>Operation details</h2><button className="quiet" onClick={onClose}>Close details</button></div>
    <p className="identifier">{selected.operation}<br /><span className="muted">Account {selected.account}</span></p>
    {error && <p className="error" role="alert">{error} <button className="quiet inline" onClick={() => setRetry(n => n + 1)}>Retry</button></p>}
    {!detail && !error && <p role="status">Loading operation…</p>}
    {detail && <><p>{name(detail.operation.kind)} · {name(detail.operation.state)} · {date(detail.operation.created_at)}{detail.account.closed ? ' · Account closed' : detail.account.spending_suspended ? ' · Spending suspended' : ''}</p>
      <p className="muted">Customer debit: {detail.operation.actual_credits ?? 'pending'} credits. Settlement snapshot: {money(detail.operation.actual_microusd)}. Remaining vendor liability: {money(detail.operation.provider_liability_microusd)}. Later corrections appear in Reconciliation.</p>
      {detail.attempts.map(a => <details className="attempt-detail" key={a.id}><summary><strong>{a.provider}</strong> · {name(a.route)} · {name(a.state)} <span>{a.actual_microusd == null ? `${money(a.ceiling_microusd)} ceiling` : money(a.actual_microusd)}</span></summary>
        <dl><dt>Attempt</dt><dd>{a.id}</dd><dt>Account</dt><dd>{selected.account}</dd><dt>Admitted</dt><dd>{new Date(a.created_at).toISOString()}</dd><dt>Dispatched</dt><dd>{a.dispatched_at ? new Date(a.dispatched_at).toISOString() : "Not recorded"}</dd><dt>Finished</dt><dd>{a.finished_at ? new Date(a.finished_at).toISOString() : "Pending"}</dd><dt>Provider request</dt><dd>{a.provider_request_id ?? 'Not returned'}</dd><dt>Model</dt><dd>{a.model}</dd><dt>Outcome</dt><dd>{a.failure_code ? name(a.failure_code) : name(a.state)}</dd><dt>Reserved units</dt><dd>{unitText(a.reserved_units)}</dd><dt>Reported units</dt><dd>{unitText(a.actual_units)}</dd></dl>
        <details><summary>OpenRouter attribution and receipt</summary><pre>{JSON.stringify({ transport: a.transport_metadata ?? {}, receipt: a.receipt_metadata ?? {} }, null, 2)}</pre></details>
        <details><summary>Recorded pricing</summary><pre>{JSON.stringify(a.pricing_snapshot, null, 2)}</pre></details>
      </details>)}
      <div className="toolbar record-tabs" role="group" aria-label="Financial record section">{(Object.keys(recordNames) as RecordKind[]).map(k => <button className={kind === k ? '' : 'quiet'} aria-pressed={kind === k} key={k} onClick={() => setKind(k)}>{recordNames[k]} ({detail.record_counts[k]})</button>)}</div>
      <RecordList key={kind} api={api} selected={selected} kind={kind} />
    </>}
  </section>;
}
const unitText = (units: Units) => Object.entries(units).map(([key, value]) => `${name(key)}: ${value.toLocaleString()}`).join(' · ') || 'None recorded';
function RecordList({ api, selected, kind }: { api: SpendingApi; selected: { account: string; operation: string }; kind: RecordKind }) {
  const [page, setPage] = useState<SpendingRecords | null>(null), [error, setError] = useState(''), [busy, setBusy] = useState(false), [retry, setRetry] = useState(0);
  const generation = useRef(0);
  useEffect(() => { const token = ++generation.current; setPage(null); setError(''); setBusy(true);
    api.records(selected.account, selected.operation, kind, null).then(value => { if (token === generation.current) setPage(value); }, e => { if (token === generation.current) setError(errorText(e)); }).finally(() => { if (token === generation.current) setBusy(false); });
    return () => { generation.current++; };
  }, [api, selected.account, selected.operation, kind, retry]);
  const next = async () => { if (!page?.next || busy) return; const token = generation.current; setBusy(true); setError('');
    try { const value = await api.records(selected.account, selected.operation, kind, page.next); if (token === generation.current) setPage(old => old ? { ...value, records: [...old.records, ...value.records.filter(r => !old.records.some(x => x.key === r.key))] } : value); }
    catch (e) { if (token === generation.current) setError(errorText(e)); } finally { if (token === generation.current) setBusy(false); }
  };
  return <div>{error && <p role="alert" className="error">{error} <button className="quiet inline" onClick={() => setRetry(n => n + 1)}>Retry</button></p>}
    {page?.records.map(row => <details className="financial-record" key={row.key}><summary><time>{date(row.at)}</time> · {name(String(row.entry.state ?? row.entry.kind ?? (kind === 'adjustments' ? 'cost adjustment' : 'usage')))}</summary><pre>{JSON.stringify(row.entry, null, 2)}</pre></details>)}
    {busy && <p role="status">Loading records…</p>}{page && !page.records.length && <p className="empty">No records in this section.</p>}
    {page?.next && <button className="quiet" disabled={busy} onClick={() => void next()}>Load older records</button>}
  </div>;
}
const size = (n: number) => n < 1024 ? `${n} B` : n < 1024 ** 2 ? `${(n / 1024).toFixed(1)} KiB` : n < 1024 ** 3 ? `${(n / 1024 ** 2).toFixed(1)} MiB` : `${(n / 1024 ** 3).toFixed(2)} GiB`;
const share = (used: number, limit: number) => `${size(used)} of ${size(limit)} (${limit ? Math.round(used / limit * 100) : 0}%)`;
/** Storage and transfer the server enforces for encrypted note images; it cannot see what they show. */
function NoteImages({ usage, account }: { usage: NoteAssetUsage; account: string | null }) {
  const { limits, stored, month } = usage;
  const full = stored.bytes >= limits.environment_bytes * 0.8 || month.download_bytes >= limits.environment_download_bytes_month * 0.8;
  return <section className="panel"><div className="section-heading"><h2>Note images</h2><small className="muted">Encrypted · {new Date(usage.period + 'T00:00:00Z').toLocaleDateString(undefined, { month: 'long', year: 'numeric', timeZone: 'UTC' })} (UTC)</small></div>
    {full && <p className="notice" role="status">At least 80% of the note image storage or this month's download allowance is used.</p>}
    <div className="table-scroll"><table><thead><tr><th>Whole service</th><th className="num">Used</th><th>Detail</th></tr></thead><tbody>
      <tr><td>Stored</td><td className="num">{share(stored.bytes, limits.environment_bytes)}</td><td>{stored.objects.toLocaleString()} objects across {stored.accounts.toLocaleString()} accounts</td></tr>
      <tr><td>Uploads not yet verified</td><td className="num">{size(stored.pending_bytes)}</td><td>{stored.pending_objects.toLocaleString()} objects{stored.oldest_pending_at ? ` · oldest ${date(stored.oldest_pending_at)}` : ''}; they count against storage</td></tr>
      <tr><td>Downloads this month</td><td className="num">{share(month.download_bytes, limits.environment_download_bytes_month)}</td><td>{month.downloads.toLocaleString()} downloads, charged before reading</td></tr>
      <tr><td>Upload read-backs this month</td><td className="num">{share(month.verify_bytes, limits.environment_verify_bytes_month)}</td><td>{month.verifies.toLocaleString()} checks of stored bytes</td></tr>
    </tbody></table></div>
    {account && usage.account && <p>This account: {share(usage.account.bytes, limits.account_bytes)} stored in {usage.account.objects.toLocaleString()} of {limits.account_objects.toLocaleString()} objects ({usage.account.pending_objects} not yet verified);
      downloads {share(usage.account.download_bytes, limits.account_download_bytes_month)}; read-backs {share(usage.account.verify_bytes, limits.account_verify_bytes_month)}.</p>}
    <p className="muted">Per account: {size(limits.account_bytes)} and {limits.account_objects.toLocaleString()} objects stored, {size(limits.account_download_bytes_month)} downloaded a month; each object at most {size(limits.max_blob_bytes)}. Byte counts are the server's admission records, not a Supabase invoice.</p>
  </section>;
}
function Forecast({ summary }: { summary: SpendingSummary }) {
  const forecast = summary.forecast;
  return <section className="panel"><div className="section-heading"><h2>Operating budget</h2><span className="badge">{money(forecast.operating_limit_microusd)} / month</span></div>
    {!forecast.complete && <p className="notice">Forecast incomplete: {forecast.missing_components} cost components need current evidence.</p>}
    {summary.anomalies.funded_plan_over_budget && <p className="error" role="alert">Recorded allocations exceed the operating budget.</p>}
    <p>Recorded plan: <strong>{money(forecast.funded_plan_microusd)}</strong>, including the full {money(forecast.provider_allocation_microusd)} provider allocation.</p>
    <p className="muted">Whole service, independent of the account filter. Allocations are planning amounts; usage measurements and vendor invoices are recorded separately. This is not a vendor-enforced dollar cap.</p>
    <div className="table-scroll"><table><thead><tr><th>Component</th><th className="num">Monthly allocation</th><th>Evidence</th></tr></thead><tbody>{forecast.components.map(c => <tr key={c.id}><td>{c.label}</td><td className="num">{money(c.amount_microusd)}</td><td>{c.evidence_reference ?? 'Needs evidence'}<small>{c.observed_at ? `${c.measure} · ${date(c.observed_at)}` : 'Not verified'}</small></td></tr>)}</tbody></table></div>
    <details className="table-view"><summary>Recent invoices and infrastructure observations</summary>{summary.external_observations.length ? summary.external_observations.map(o => <article key={o.id}><strong>{name(o.component)} · {name(o.measure)}</strong><p>{money(o.amount_microusd)} · {date(o.observed_at)} · {o.complete ? 'Complete observation' : 'Partial observation'}</p><p className="muted">{o.source} · {o.evidence_reference} · {unitText(o.units)}</p></article>) : <p className="empty">No external cost observations have been recorded this month.</p>}</details>
  </section>;
}
