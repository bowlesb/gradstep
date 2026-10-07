import React, { useEffect, useRef, useState } from 'react';

export interface PurchaseObservation {
  id: string; admitted_at: string; finished_at: string | null; outcome: string;
  stage: string | null; apple_status: string | null; transport_code: string | null;
}
export interface PurchaseSubmission {
  account_id: string; reference: string; first_at: string; last_at: string; finished_at: string | null;
  attempts: number; state: 'pending' | 'verifying' | 'interrupted' | 'refused' | 'confirmed';
  outcome: string; stage: string | null; apple_status: string | null; transport_code: string | null;
}
export interface PurchaseObservations {
  generated_at: string; matched: number; counts: Record<string, number>; submissions: PurchaseSubmission[];
  readiness: { retained: number; policy: { retention_days: number; account_rows: number; environment_rows: number };
    cleanup: { active: boolean; schedule: string | null; expected_command: boolean } };
}
export type PurchaseFilter = 'unconfirmed' | 'refused' | 'confirmed' | 'all';
export interface PurchasesApi {
  list(filter: PurchaseFilter, reference: string | null): Promise<PurchaseObservations>;
  attempts(accountID: string, reference: string): Promise<PurchaseObservation[]>;
}
const moment = (value: string) => new Date(value).toLocaleString();
const name = (value: string) => value.replaceAll('_', ' ');
const stateName = (value: PurchaseSubmission['state']) => ({ pending: 'Credits pending', verifying: 'Verifying',
  interrupted: 'Interrupted · unconfirmed', refused: 'Not accepted', confirmed: 'Confirmed' })[value];

export function Purchases({ api, reloadKey }: { api: PurchasesApi; reloadKey: number }) {
  const [filter, setFilter] = useState<PurchaseFilter>('unconfirmed');
  const [search, setSearch] = useState('');
  const [reference, setReference] = useState<string | null>(null);
  const [data, setData] = useState<PurchaseObservations | null>(null);
  const [selected, setSelected] = useState<PurchaseSubmission | null>(null);
  const [attempts, setAttempts] = useState<PurchaseObservation[] | null>(null);
  const [error, setError] = useState('');
  const [detailError, setDetailError] = useState('');
  const [loading, setLoading] = useState(false);
  const generation = useRef(0);
  const detailHeading = useRef<HTMLHeadingElement>(null);
  const detailOpener = useRef<HTMLButtonElement | null>(null);
  useEffect(() => {
    const request = ++generation.current;
    setLoading(true); setError(''); setData(null); setSelected(null);
    api.list(filter, reference).then(value => { if (generation.current === request) setData(value); })
      .catch(() => { if (generation.current === request) setError('Purchase diagnostics could not load. Try Refresh.'); })
      .finally(() => { if (generation.current === request) setLoading(false); });
    return () => { generation.current++; };
  }, [api, reloadKey, filter, reference]);
  useEffect(() => {
    let active = true;
    setAttempts(null); setDetailError('');
    if (selected) detailHeading.current?.focus();
    if (selected) void api.attempts(selected.account_id, selected.reference)
      .then(value => { if (active) setAttempts(value); })
      .catch(() => { if (active) setDetailError('Attempts could not load. Close this detail and try again.'); });
    return () => { active = false; };
  }, [api, selected]);
  const cleanup = data?.readiness.cleanup;
  return <div className="purchase-diagnostics">
    <section className="panel">
      <div className="section-heading"><h2>Purchase verification</h2><label>Status <select aria-label="Purchase status" value={filter}
        onChange={event => setFilter(event.target.value as PurchaseFilter)}>
        <option value="unconfirmed">Unconfirmed</option><option value="refused">Not accepted</option>
        <option value="confirmed">Confirmed</option><option value="all">All</option>
      </select></label></div>
      <p className="muted">A submission is a signed copy sent by the app. Several copies may describe one purchase; these counts do not measure sales.</p>
      <form className="inline-form" onSubmit={event => {
        event.preventDefault(); const code = search.trim().toLowerCase(); setReference(code || null);
        if (code) setFilter('all');
      }}>
        <label>Support code<input aria-label="Support code" value={search} onChange={event => setSearch(event.target.value)}
          pattern="[a-fA-F0-9]{12,64}" maxLength={64} placeholder="Paste the code from a report" /></label>
        <button disabled={loading}>Find</button>
        {reference && <button type="button" className="quiet" onClick={() => { setSearch(''); setReference(null); }}>Clear</button>}
      </form>
      {error && <p className="error" role="alert">{error}</p>}
      {loading && <p role="status">Loading purchase diagnostics…</p>}
      {cleanup && (!cleanup.active || !cleanup.expected_command || cleanup.schedule !== '17 * * * *') &&
        <p className="error" role="alert">Observation cleanup is not ready. Review the database schedule before deploying purchase verification.</p>}
      {data && <>
        <p className="muted">{data.matched.toLocaleString()} matching submissions · Last {data.readiness.policy.retention_days} days</p>
        <div className="table-scroll"><table><thead><tr><th>Submission</th><th>Status</th><th>Last step</th><th>Attempts</th><th>Last received</th></tr></thead>
          <tbody>{data.submissions.map(row => <tr key={row.account_id + row.reference}>
            <td><button className="quiet" onClick={event => { detailOpener.current = event.currentTarget; setSelected(row); }} aria-label={'View attempts ' + row.reference.slice(0, 16)}><code>{row.reference.slice(0, 16)}</code></button>
              <br /><small className="muted" title={row.account_id}>Account {row.account_id.slice(0, 8)}</small></td>
            <td>{stateName(row.state)}</td><td>{row.stage ? name(row.stage) : row.state === 'confirmed' ? 'Recorded' : 'Awaiting result'}{row.apple_status && <><br /><small>{name(row.apple_status)}</small></>}
              {row.transport_code && <><br /><small>{name(row.transport_code)}</small></>}</td>
            <td>{row.attempts}</td><td>{moment(row.last_at)}</td>
          </tr>)}</tbody></table></div>
        {!data.submissions.length && <p className="empty">No matching purchase submissions.</p>}
        {data.matched > data.submissions.length && <p className="muted">Showing the latest {data.submissions.length}. Use a support code to find a specific submission.</p>}
        <p className="footnote">{data.readiness.retained.toLocaleString()} of {data.readiness.policy.environment_rows.toLocaleString()} retained attempts.
          Expired records and records for closed accounts are deleted. Interrupted attempts do not change credit grants.</p>
      </>}
    </section>
    {selected && <section className="panel" aria-label="Verification attempts">
      <div className="section-heading"><h2 tabIndex={-1} ref={detailHeading}>Attempts</h2><button className="quiet"
        onClick={() => { setSelected(null); detailOpener.current?.focus(); }}>Close details</button></div>
      <p className="footnote" style={{ overflowWrap: 'anywhere' }}>Support reference: <code>{selected.reference}</code></p>
      <p className="muted">Most recent 50 attempts. Credit grants remain in the verified transaction ledger.</p>
      {detailError ? <p className="error" role="alert">{detailError}</p> : !attempts ? <p role="status">Loading attempts…</p> :
        <div className="table-scroll"><table><thead><tr><th>Received</th><th>Outcome</th><th>Step</th><th>Apple status</th><th>Transport</th></tr></thead>
          <tbody>{attempts.map(item => <tr key={item.id}><td>{moment(item.admitted_at)}</td><td>{name(item.outcome)}</td>
            <td>{item.stage ? name(item.stage) : '—'}</td><td>{item.apple_status ? name(item.apple_status) : '—'}</td>
            <td>{item.transport_code ? name(item.transport_code) : '—'}</td></tr>)}</tbody></table></div>}
    </section>}
  </div>;
}
