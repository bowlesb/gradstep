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
export interface PurchaseLedgerCursor {
  version: 1; account_id: string; recorded_at: string; environment: string; transaction_id: string;
}
export interface PurchaseTransaction {
  environment: 'Sandbox' | 'Production'; transaction_id: string; original_transaction_id: string;
  product_id: string; quantity: number; purchased_at: string; recorded_at: string; granted_at: string | null;
  expires_at: string | null; revoked_at: string | null;
  credits: { granted: number; balance: number; reserved: number; spendable: number;
    state: 'no_grant' | 'active' | 'spent' | 'not_started' | 'expired' | 'revoked';
    starts_at: string | null; expires_at: string | null; revoked_at: string | null };
  sandbox_decision: { recorded_at: string; period: string; requested_credits: number; granted_credits: number; credit_cap: number;
    reason: 'granted' | 'partial_allowance' | 'identity_missing' | 'account_allowance_exhausted' | 'apple_allowance_exhausted' | 'both_allowances_exhausted' } | null;
}
export interface PurchaseLedgerPage {
  generated_at: string; account_id: string; transactions: PurchaseTransaction[]; next_cursor: PurchaseLedgerCursor | null;
}
export interface PurchasesApi {
  list(filter: PurchaseFilter, reference: string | null): Promise<PurchaseObservations>;
  attempts(accountID: string, reference: string): Promise<PurchaseObservation[]>;
  transactions(accountID: string, cursor: PurchaseLedgerCursor | null): Promise<PurchaseLedgerPage>;
}
const moment = (value: string) => new Date(value).toLocaleString();
const name = (value: string) => value.replaceAll('_', ' ');
const stateName = (value: PurchaseSubmission['state']) => ({ pending: 'Credits pending', verifying: 'Verifying',
  interrupted: 'Interrupted · unconfirmed', refused: 'Not accepted', confirmed: 'Receipt recorded' })[value];

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
        <option value="confirmed">Receipt recorded</option><option value="all">All</option>
      </select></label></div>
      <p className="muted">Several signed submissions may describe one purchase. These counts are not sales or credit grants; a recorded receipt can grant zero credits.</p>
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
    {selected && <><section className="panel" aria-label="Verification attempts">
      <div className="section-heading"><h2 tabIndex={-1} ref={detailHeading}>Attempts</h2><button className="quiet"
        onClick={() => { setSelected(null); detailOpener.current?.focus(); }}>Close details</button></div>
      <p className="footnote" style={{ overflowWrap: 'anywhere' }}>Support reference: <code>{selected.reference}</code></p>
      <p className="muted">Most recent 50 attempts for this submission.</p>
      {detailError ? <p className="error" role="alert">{detailError}</p> : !attempts ? <p role="status">Loading attempts…</p> :
        <div className="table-scroll"><table><thead><tr><th>Received</th><th>Outcome</th><th>Step</th><th>Apple status</th><th>Transport</th></tr></thead>
          <tbody>{attempts.map(item => <tr key={item.id}><td>{moment(item.admitted_at)}</td><td>{name(item.outcome)}</td>
            <td>{item.stage ? name(item.stage) : '—'}</td><td>{item.apple_status ? name(item.apple_status) : '—'}</td>
            <td>{item.transport_code ? name(item.transport_code) : '—'}</td></tr>)}</tbody></table></div>}
    </section>
      <AccountPurchaseLedger key={selected.account_id + ':' + selected.reference} api={api} accountID={selected.account_id} />
    </>}
  </div>;
}

const bucketState = (value: PurchaseTransaction['credits']['state']) => ({ no_grant: 'No credits granted', active: 'Active credits',
  spent: 'Fully spent', not_started: 'Not yet available', expired: 'Credits expired', revoked: 'Credits revoked' })[value];
const allowanceReason = (value: NonNullable<PurchaseTransaction['sandbox_decision']>['reason']) => ({
  granted: 'Within the Sandbox allowance', partial_allowance: 'Limited by the Sandbox allowance',
  identity_missing: 'Verified Apple identity unavailable', account_allowance_exhausted: 'Account allowance exhausted',
  apple_allowance_exhausted: 'Apple identity allowance exhausted', both_allowances_exhausted: 'Account and Apple identity allowances exhausted',
})[value];
const productName = (id: string) => ({ 'com.sciencereader.ios.standard.monthly': 'Standard monthly',
  'com.sciencereader.ios.pro.monthly': 'Pro monthly', 'com.sciencereader.ios.credits.400': '400-credit pack' })[id] ?? id;

/** One page only. Parent identity remounts on a different submission/account; each request owns its result. */
function AccountPurchaseLedger({ api, accountID }: { api: PurchasesApi; accountID: string }) {
  const [cursor, setCursor] = useState<PurchaseLedgerCursor | null>(null);
  const [retry, setRetry] = useState(0);
  const [page, setPage] = useState<PurchaseLedgerPage | null>(null);
  const [error, setError] = useState(false);
  useEffect(() => {
    let active = true;
    setPage(null); setError(false);
    api.transactions(accountID, cursor).then(result => {
      if (result.account_id !== accountID || result.transactions.length > 50) throw Error('invalid_account_ledger');
      if (active) setPage(result);
    }).catch(() => { if (active) setError(true); });
    return () => { active = false; };
  }, [api, accountID, cursor, retry]);
  return <section className="panel purchase-ledger" aria-label="Account transaction ledger">
    <div className="section-heading"><h2>Account transaction ledger</h2>
      {cursor && <button className="quiet" onClick={() => setCursor(null)}>Newest transactions</button>}</div>
    <p className="muted">Account-wide records, not a match to this submission. Each page shows balances when loaded.</p>
    <p className="footnote purchase-account">Account <code>{accountID}</code></p>
    {error ? <div><p className="error" role="alert">Account transactions could not load. Try again.</p>
      <button className="secondary" onClick={() => setRetry(n => n + 1)}>Retry transactions</button></div>
      : !page ? <p role="status">Loading account transactions…</p> : <>
        <p className="muted">{page.transactions.length} transactions · Balances read {moment(page.generated_at)}</p>
        {!page.transactions.length && <p className="empty">No recorded transactions for this account.</p>}
        {page.transactions.map(transaction => <article className="purchase-transaction" key={transaction.environment + ':' + transaction.transaction_id}
          aria-label={'Transaction ' + transaction.environment + ' ' + transaction.transaction_id}>
          <div className="purchase-transaction-heading"><strong>{productName(transaction.product_id)}</strong>
            <span className="badge plain">{transaction.environment}</span><span className="muted">{bucketState(transaction.credits.state)}</span></div>
          <dl className="purchase-balances">
            <div><dt>Originally granted</dt><dd>{transaction.credits.granted.toLocaleString()}</dd></div>
            <div><dt>Spendable now</dt><dd>{transaction.credits.spendable.toLocaleString()}</dd></div>
            <div><dt>Reserved</dt><dd>{transaction.credits.reserved.toLocaleString()}</dd></div>
          </dl>
          {transaction.credits.reserved > 0 && ['expired', 'revoked'].includes(transaction.credits.state) &&
            <p className="muted">Reserved credits remain held for work already in progress.</p>}
          {transaction.sandbox_decision && <p className="purchase-allowance">
            {allowanceReason(transaction.sandbox_decision.reason)}<br />
            <span className="muted">Requested {transaction.sandbox_decision.requested_credits.toLocaleString()} · Granted {transaction.sandbox_decision.granted_credits.toLocaleString()}
              {' · '}{transaction.sandbox_decision.period.slice(0, 7)} UTC allowance</span></p>}
          {transaction.environment === 'Sandbox' && !transaction.sandbox_decision &&
            <p className="muted">No recorded Sandbox allowance decision.</p>}
          <details><summary>Transaction details</summary><dl className="purchase-record-details">
            <dt>Transaction ID</dt><dd><code>{transaction.transaction_id}</code></dd>
            <dt>Original transaction</dt><dd><code>{transaction.original_transaction_id}</code></dd>
            <dt>Product</dt><dd>{transaction.product_id} · Quantity {transaction.quantity}</dd>
            <dt>Recorded</dt><dd>{moment(transaction.recorded_at)}</dd>
            <dt>Purchased</dt><dd>{moment(transaction.purchased_at)}</dd>
            <dt>Grant recorded</dt><dd>{transaction.granted_at ? moment(transaction.granted_at) : 'No grant'}</dd>
            <dt>Remaining balance</dt><dd>{transaction.credits.balance.toLocaleString()} credits, including reservations; availability depends on expiry and revocation.</dd>
            <dt>Credit expiry</dt><dd>{transaction.credits.expires_at ? moment(transaction.credits.expires_at) : 'None'}</dd>
            <dt>Credit revocation</dt><dd>{transaction.credits.revoked_at ? moment(transaction.credits.revoked_at) : 'None'}</dd>
            <dt>Receipt expiry</dt><dd>{transaction.expires_at ? moment(transaction.expires_at) : 'None'}</dd>
            <dt>Receipt revocation</dt><dd>{transaction.revoked_at ? moment(transaction.revoked_at) : 'None'}</dd>
          </dl></details>
        </article>)}
        {page.next_cursor && <button className="secondary" onClick={() => setCursor(page.next_cursor)}>Older transactions</button>}
      </>}
  </section>;
}
