import React, { useCallback, useEffect, useRef, useState } from 'react';
import { adminAccounts, rpc } from './backend';
import { once } from './mutations';

/** Owner-only Accounts tab (migration 028, functions/v1/admin-accounts). */
export type AccountStatus = 'active' | 'disabled' | 'closing' | 'closed';
export interface AdminAccount {
  id: string; email: string | null; synthetic: boolean; created_at: string; last_sign_in_at: string | null;
  providers: string[]; status: AccountStatus; roles: string[];
  plan: { plan: string; environment: string; expires_at: string } | null;
  credits: { available: number; reserved: number }; library_items: number;
}
/** Migration 0105 (review A9): an owner-authorized testing allowance, its monthly provider-cost cap and this month's spend. */
export interface TestingAllowance { account_id: string; enabled: boolean; monthly_cap_microusd: number | null; month_spend_microusd: number; updated_at: string }
export interface AccountList { generated_at: string; total: number; matched: number; accounts: AdminAccount[]; testing_allowances?: TestingAllowance[] }
export type AccountSort = 'created' | 'last_sign_in';
export interface AddTesterResult { account_id: string; email: string; created: boolean; status: AccountStatus; starting_credits: number; starting_granted: boolean }
export interface AccountsApi {
  list(search: string, sort: AccountSort, ascending: boolean): Promise<AccountList>;
  addTester(email: string, credits: number): Promise<AddTesterResult>;
  grant(accountID: string, credits: number, reason: string): Promise<{ credits: number; replayed: boolean }>;
  setSignIn(accountID: string, disabled: boolean, reason: string): Promise<{ disabled: boolean }>;
  /** Withdraws an address's invitation (migration 127): no new account can be created with it. */
  revokeAdmission(email: string, reason: string): Promise<{ existing_login: boolean }>;
  /** Owner testing allowance (migration 0105): owner or tester accounts only; `capUSD` null keeps the current cap. */
  setTestingAllowance?(accountID: string, enabled: boolean, capUSD: number | null, reason: string): Promise<{ enabled: boolean }>;
}

export const MAX_GRANT = 2000;
const CONFIRM_ABOVE = 500;

/** The real backend. Grants and sign-in changes keep their request ID until acknowledged, so a retry is applied once. */
export function liveAccountsApi(ownerID: string): AccountsApi {
  return {
    list: (search, sort, ascending) => rpc<AccountList>('v1_admin_accounts', { p_search: search || null, p_sort: sort, p_ascending: ascending, p_limit: 500 }),
    addTester: (email, credits) => adminAccounts<AddTesterResult>({ action: 'add_tester', email, credits }),
    grant: (account_id, credits, reason) => once(ownerID, 'admin-grant', { account_id, credits, reason },
      request_id => adminAccounts({ action: 'grant_credits', request_id, account_id, credits, reason })),
    setSignIn: (account_id, disabled, reason) => once(ownerID, 'admin-sign-in', { account_id, disabled, reason },
      request_id => adminAccounts({ action: 'set_sign_in', request_id, account_id, disabled, reason })),
    revokeAdmission: (email, reason) => adminAccounts({ action: 'revoke_admission', email, reason }),
    setTestingAllowance: (account_id, enabled, monthly_cap_usd, reason) => once(ownerID, 'admin-testing', { account_id, enabled, monthly_cap_usd, reason },
      request_id => adminAccounts({ action: 'set_testing_allowance', request_id, account_id, enabled, monthly_cap_usd, reason })),
  };
}

/** What the owner sends a new tester. Nothing is emailed by the admin site. */
export function testerInstructions(email: string): string {
  return `You're invited to the Gradstep private beta.

1. Install Gradstep from TestFlight (Apple sends that invitation separately).
2. Open Gradstep, choose "Continue with email" and enter ${email}.
3. Enter the six-digit code we email you from codes@gradstep.ai.

Always sign in with this address. Sign in with Apple or Google finds your account only if it uses the same address (Apple's "Hide My Email" does not).`;
}

const day = new Intl.DateTimeFormat(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
const full = new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' });
const METHODS: Record<string, string> = { email: 'Email', apple: 'Apple', google: 'Google' };
const STATUS: Record<AccountStatus, [string, string]> = {
  active: ['Active', 'positive'], disabled: ['Disabled', 'warning'], closing: ['Closing', ''], closed: ['Closed', ''],
};
const plural = (n: number, one: string, many = one + 's') => `${n.toLocaleString()} ${n === 1 ? one : many}`;
const label = (account: AdminAccount) => account.email ?? `deleted account ${account.id.slice(0, 8)}`;

type Dialog = { kind: 'grant' | 'disable' | 'enable' | 'testing'; account: AdminAccount };
const usd = (micro: number) => new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: 2 }).format(micro / 1e6);

export function Accounts({ api, reloadKey }: { api: AccountsApi; reloadKey: number }) {
  const [search, setSearch] = useState(''); const [query, setQuery] = useState('');
  const [sort, setSort] = useState<AccountSort>('created'); const [ascending, setAscending] = useState(false);
  const [list, setList] = useState<AccountList | null>(null); const [loading, setLoading] = useState(false); const [error, setError] = useState('');
  const [notice, setNotice] = useState(''); const [dialog, setDialog] = useState<Dialog | null>(null); const [added, setAdded] = useState<AddTesterResult | null>(null);
  const generation = useRef(0);

  useEffect(() => { const timer = setTimeout(() => setQuery(search.trim()), 250); return () => clearTimeout(timer); }, [search]);
  const load = useCallback(async () => {
    const mine = ++generation.current; setLoading(true); setError('');
    try { const next = await api.list(query, sort, ascending); if (mine === generation.current) setList(next); }
    catch (e) { if (mine === generation.current) setError(e instanceof Error ? e.message : 'Accounts could not be loaded.'); }
    finally { if (mine === generation.current) setLoading(false); }
  }, [api, query, sort, ascending]);
  useEffect(() => { void load(); }, [load, reloadKey]);

  const sortBy = (next: AccountSort) => { if (next === sort) setAscending(a => !a); else { setSort(next); setAscending(false); } };
  const ariaSort = (column: AccountSort) => sort === column ? (ascending ? 'ascending' : 'descending') : undefined;
  const done = async (message: string) => { setDialog(null); setNotice(message); await load(); };
  const synthetic = list?.accounts.filter(a => a.synthetic).length ?? 0;
  const testing = new Map((list?.testing_allowances ?? []).map(t => [t.account_id, t]));

  return <div className="accounts">
    <AddTester add={api.addTester} onAdded={result => { setAdded(result); void load(); }} added={added} />
    <section className="panel" aria-labelledby="accounts-title">
      <div className="section-heading"><h2 id="accounts-title">Accounts</h2>
        {list && <span className="muted" role="status">{list.matched === list.total ? plural(list.total, 'account') : `${list.matched.toLocaleString()} of ${plural(list.total, 'account')}`}{synthetic ? ` · ${synthetic} test` : ''}</span>}</div>
      <div className="toolbar"><label className="search">Search by email<input type="search" value={search} maxLength={254} placeholder="name@example.org" autoComplete="off" spellCheck={false} onChange={e => setSearch(e.target.value)} /></label></div>
      {notice && <p className="notice success" role="status"><span aria-hidden="true">✓</span>{notice}<button className="quiet inline" onClick={() => setNotice('')}>Dismiss</button></p>}
      {error && <p className="error" role="alert">{error}</p>}
      <div className={'table-scroll' + (loading && list ? ' refetching' : '')}>
        <table className="accounts-table">
          <caption className="sr-only">Accounts, sorted by {sort === 'created' ? 'creation date' : 'last sign-in'}, {ascending ? 'oldest' : 'newest'} first</caption>
          <thead><tr>
            <th scope="col">Email</th><th scope="col">Status</th><th scope="col">Plan</th><th scope="col" className="num">Credits</th><th scope="col" className="num">Library</th><th scope="col">Sign-in</th>
            <th scope="col" aria-sort={ariaSort('created')}><button className="sort" onClick={() => sortBy('created')}>Created<SortMark active={sort === 'created'} ascending={ascending} /></button></th>
            <th scope="col" aria-sort={ariaSort('last_sign_in')}><button className="sort" onClick={() => sortBy('last_sign_in')}>Last sign-in<SortMark active={sort === 'last_sign_in'} ascending={ascending} /></button></th>
            <th scope="col"><span className="sr-only">Actions</span></th>
          </tr></thead>
          <tbody>{list?.accounts.map(account => <tr key={account.id} className={account.synthetic ? 'synthetic' : undefined}>
            <th scope="row"><span className={account.email ? 'email' : 'email muted'}>{label(account)}</span>
              {(account.roles.includes('owner') || account.synthetic || testing.get(account.id)?.enabled) && <span className="tags">{account.roles.includes('owner') && <span className="badge plain">Owner</span>}{account.synthetic && <span className="badge plain test" title="Synthetic login used by automated checks (@example.invalid)">Test</span>}
                {testing.get(account.id)?.enabled && <span className="badge plain" title="Owner-authorized testing allowance: credits refill automatically; the provider cost this month is capped">Unlimited testing · {usd(testing.get(account.id)!.month_spend_microusd)}{testing.get(account.id)!.monthly_cap_microusd == null ? ' this month, no account cap' : <> of {usd(testing.get(account.id)!.monthly_cap_microusd!)} this month</>}</span>}</span>}</th>
            <td><span className={'badge ' + STATUS[account.status][1]}>{STATUS[account.status][0]}</span></td>
            <td>{account.plan ? <>{account.plan.plan[0].toUpperCase() + account.plan.plan.slice(1)}{account.plan.environment === 'Sandbox' && <small>Sandbox</small>}</> : <span className="muted">—</span>}</td>
            <td className="num">{account.credits.available.toLocaleString()}{account.credits.reserved > 0 && <small>{account.credits.reserved.toLocaleString()} held</small>}</td>
            <td className="num">{account.library_items.toLocaleString()}</td>
            <td>{account.providers.length ? account.providers.map(p => METHODS[p] ?? p).join(', ') : <span className="muted">—</span>}</td>
            <td><time dateTime={account.created_at} title={full.format(new Date(account.created_at))}>{day.format(new Date(account.created_at))}</time></td>
            <td>{account.last_sign_in_at ? <time dateTime={account.last_sign_in_at} title={full.format(new Date(account.last_sign_in_at))}>{day.format(new Date(account.last_sign_in_at))}</time> : <span className="muted">Never</span>}</td>
            <td className="actions">{account.status === 'active' || account.status === 'disabled' ? <>
              <button className="secondary small" aria-label={`Grant credits to ${label(account)}`} onClick={() => setDialog({ kind: 'grant', account })}>Grant credits</button>
              {api.setTestingAllowance && (account.roles.includes('owner') || account.roles.includes('tester') || account.synthetic || testing.get(account.id)?.enabled)
                && <button className="secondary small" aria-label={`Testing allowance for ${label(account)}`} onClick={() => setDialog({ kind: 'testing', account })}>Testing</button>}
              {account.status === 'disabled'
                ? <button className="secondary small" aria-label={`Enable sign-in for ${label(account)}`} onClick={() => setDialog({ kind: 'enable', account })}>Enable</button>
                : !account.roles.includes('owner') && <button className="secondary small danger" aria-label={`Disable sign-in for ${label(account)}`} onClick={() => setDialog({ kind: 'disable', account })}>Disable</button>}
            </> : null}</td>
          </tr>)}</tbody>
        </table>
      </div>
      {list && !list.accounts.length && <p className="empty">{query ? 'No account email contains that text.' : 'No accounts yet.'}</p>}
      {list && list.accounts.length < list.matched && <p className="notice" role="status">Showing the first {list.accounts.length.toLocaleString()} of {plural(list.matched, 'matching account')}{sort === 'created' ? (ascending ? ', oldest first' : ', newest first') : ''}. Search by email to find others.</p>}
      {!list && loading && <p className="empty" role="status">Loading accounts…</p>}
      <p className="footnote">Test accounts (<code>@example.invalid</code>) are synthetic logins created by automated checks. Credits are those available now; held credits belong to work in progress. Deleting an account stays in the app (Settings › Delete account).</p>
    </section>
    <WithdrawInvitation revoke={api.revokeAdmission} />
    {dialog?.kind === 'grant' && <GrantDialog account={dialog.account} onCancel={() => setDialog(null)}
      onGrant={async (credits, reason) => { const r = await api.grant(dialog.account.id, credits, reason); await done(`${r.replayed ? 'Already granted' : 'Granted'} ${plural(r.credits, 'credit')} to ${label(dialog.account)}.`); }} />}
    {dialog?.kind === 'testing' && api.setTestingAllowance && <TestingDialog account={dialog.account} current={testing.get(dialog.account.id) ?? null} onCancel={() => setDialog(null)}
      onConfirm={async (enabled, cap, reason) => { const r = await api.setTestingAllowance!(dialog.account.id, enabled, cap, reason); await done(`${r.enabled ? 'Testing allowance on' : 'Testing allowance off'} for ${label(dialog.account)}.`); }} />}
    {(dialog?.kind === 'disable' || dialog?.kind === 'enable') && <SignInDialog account={dialog.account} disable={dialog.kind === 'disable'} onCancel={() => setDialog(null)}
      onConfirm={async reason => { const r = await api.setSignIn(dialog.account.id, dialog.kind === 'disable', reason); await done(`${r.disabled ? 'Disabled' : 'Enabled'} sign-in for ${label(dialog.account)}.`); }} />}
  </div>;
}

function SortMark({ active, ascending }: { active: boolean; ascending: boolean }) {
  return <span className={'sort-mark' + (active ? ' active' : '')} aria-hidden="true">{active ? (ascending ? '↑' : '↓') : '↕'}</span>;
}

function AddTester({ add, onAdded, added }: { add: AccountsApi['addTester']; onAdded: (result: AddTesterResult) => void; added: AddTesterResult | null }) {
  const [email, setEmail] = useState(''); const [credits, setCredits] = useState('1000'); const [busy, setBusy] = useState(false); const [error, setError] = useState('');
  const [confirming, setConfirming] = useState(false);
  const amount = Number(credits); const valid = /\S+@\S+\.\S+/.test(email.trim()) && Number.isInteger(amount) && amount >= 0 && amount <= MAX_GRANT;
  const submit = async () => { const result = await add(email.trim(), amount); setEmail(''); setConfirming(false); onAdded(result); };
  return <section className="panel" aria-labelledby="add-title">
    <h2 id="add-title">Add a tester</h2>
    <p className="muted">Sign-up is invite-only. This creates the tester's sign-in with the email already confirmed and nothing is emailed: send them the instructions below and add them to TestFlight in App Store Connect. Adding an existing email changes nothing and shows its account.</p>
    <form className="inline-form" onSubmit={async event => {
      event.preventDefault(); if (!valid) return;
      if (amount > CONFIRM_ABOVE) { setConfirming(true); return; }
      setBusy(true); setError('');
      try { await submit(); } catch (e) { setError((e as Error).message); } finally { setBusy(false); }
    }}>
      <label className="grow">Email<input type="email" required maxLength={254} autoComplete="off" spellCheck={false} value={email} onChange={e => setEmail(e.target.value)} placeholder="name@example.org" /></label>
      <label className="narrow">Starting credits<input type="number" inputMode="numeric" min={0} max={MAX_GRANT} step={1} required value={credits} onChange={e => setCredits(e.target.value)} aria-describedby="credits-help" /></label>
      <button disabled={busy || !valid}>{busy ? 'Adding…' : 'Add tester'}</button>
    </form>
    <p id="credits-help" className="muted field-help">0–{MAX_GRANT.toLocaleString()}, granted once per account. Testers normally start with 1,000.</p>
    {error && <p className="error" role="alert">{error}</p>}
    {added && <AddedTester result={added} />}
    {confirming && <ConfirmAdd email={email.trim()} credits={amount} onCancel={() => setConfirming(false)} onConfirm={submit} />}
  </section>;
}

/** An invitation outlives a deleted account (migration 091); this withdraws one, for example a mistyped address or a
 * tester who left. It never signs out a current login: Disable sign-in does that. */
function WithdrawInvitation({ revoke }: { revoke: AccountsApi['revokeAdmission'] }) {
  const [email, setEmail] = useState(''); const [reason, setReason] = useState(''); const [notice, setNotice] = useState('');
  const [busy, setBusy] = useState(false); const [error, setError] = useState('');
  const valid = /\S+@\S+\.\S+/.test(email.trim()) && reason.trim().length >= 3;
  return <section className="panel" aria-labelledby="withdraw-title">
    <h2 id="withdraw-title">Withdraw an invitation</h2>
    <p className="muted">No new account can then be created with this address, even after its account was deleted. Adding the tester again restores it. A current sign-in is stopped with Disable.</p>
    <form className="inline-form" onSubmit={event => {
      event.preventDefault(); if (!valid || busy) return; setNotice(''); setError(''); setBusy(true);
      const address = email.trim();
      void revoke(address, reason.trim()).then(r => {
        setNotice(r.existing_login ? `Withdrawn. ${address} still has an account: disable its sign-in to stop it.` : `Withdrawn for ${address}.`);
        setEmail(''); setReason('');
      }, (e: unknown) => setError((e as Error).message)).finally(() => setBusy(false));
    }}>
      <label className="grow">Email<input type="email" required maxLength={254} autoComplete="off" spellCheck={false} value={email} onChange={e => setEmail(e.target.value)} placeholder="name@example.org" /></label>
      <label className="grow">Reason<input required minLength={3} maxLength={500} value={reason} onChange={e => setReason(e.target.value)} placeholder="Recorded in the audit log; no personal details" /></label>
      <button className="danger" disabled={busy || !valid}>{busy ? 'Withdrawing…' : 'Withdraw'}</button>
    </form>
    {notice && <p className="notice success" role="status"><span aria-hidden="true">✓</span>{notice}</p>}
    {error && <p className="error" role="alert">{error}</p>}
  </section>;
}

function AddedTester({ result }: { result: AddTesterResult }) {
  const [copied, setCopied] = useState(false); const text = testerInstructions(result.email);
  const summary = result.created ? `Created a sign-in for ${result.email}.` : `${result.email} already has an account (${STATUS[result.status][0].toLowerCase()}).`;
  const grant = result.starting_granted ? ` Granted ${plural(result.starting_credits, 'starting credit')}.`
    : result.starting_credits ? ` Its ${plural(result.starting_credits, 'starting credit')} were granted earlier.` : ' No starting credits.';
  return <div className="added" role="status">
    <p><strong>{summary}</strong>{grant}</p>
    <label>Instructions to send the tester<textarea readOnly rows={8} value={text} onFocus={e => e.currentTarget.select()} /></label>
    <button type="button" className="secondary" onClick={() => void navigator.clipboard?.writeText(text).then(() => setCopied(true), () => setCopied(false))}>{copied ? 'Copied' : 'Copy instructions'}</button>
  </div>;
}

/** A modal built on <dialog>: focus stays inside, Escape cancels, focus returns to the opener. */
function Modal({ title, onCancel, children }: { title: string; onCancel: () => void; children: React.ReactNode }) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => { const dialog = ref.current; const opener = document.activeElement as HTMLElement | null; dialog?.showModal(); return () => { dialog?.close(); opener?.focus?.(); }; }, []);
  return <dialog ref={ref} className="modal" aria-labelledby="modal-title" onCancel={event => { event.preventDefault(); onCancel(); }}>
    <h2 id="modal-title">{title}</h2>{children}
  </dialog>;
}

function useAction() {
  const [busy, setBusy] = useState(false); const [error, setError] = useState('');
  const run = async (action: () => Promise<void>) => { setBusy(true); setError(''); try { await action(); } catch (e) { setError((e as Error).message); setBusy(false); } };
  return { busy, error, run };
}

function ConfirmAdd({ email, credits, onCancel, onConfirm }: { email: string; credits: number; onCancel: () => void; onConfirm: () => Promise<void> }) {
  const { busy, error, run } = useAction();
  return <Modal title="Add tester?" onCancel={onCancel}>
    <p>Create a sign-in for <strong>{email}</strong> (if it has none) and grant <strong>{plural(credits, 'starting credit')}</strong>. Grants above {CONFIRM_ABOVE} credits are confirmed.</p>
    {error && <p className="error" role="alert">{error}</p>}
    <div className="modal-actions"><button type="button" className="secondary" onClick={onCancel}>Cancel</button><button type="button" autoFocus disabled={busy} onClick={() => void run(onConfirm)}>{busy ? 'Adding…' : 'Add tester'}</button></div>
  </Modal>;
}

function GrantDialog({ account, onCancel, onGrant }: { account: AdminAccount; onCancel: () => void; onGrant: (credits: number, reason: string) => Promise<void> }) {
  const [credits, setCredits] = useState('100'); const [reason, setReason] = useState(''); const [confirming, setConfirming] = useState(false);
  const { busy, error, run } = useAction();
  const amount = Number(credits); const valid = Number.isInteger(amount) && amount >= 1 && amount <= MAX_GRANT && reason.trim().length >= 3;
  return <Modal title="Grant credits" onCancel={onCancel}>
    <p>To <strong>{label(account)}</strong>, who has {plural(account.credits.available, 'credit')} available. Granted credits never expire and are recorded in the audit log.</p>
    <form onSubmit={event => { event.preventDefault(); if (!valid) return; if (amount > CONFIRM_ABOVE && !confirming) setConfirming(true); else void run(() => onGrant(amount, reason.trim())); }}>
      <label>Credits<input type="number" inputMode="numeric" min={1} max={MAX_GRANT} step={1} required autoFocus disabled={confirming} value={credits} onChange={e => setCredits(e.target.value)} /></label>
      <label>Reason<input required minLength={3} maxLength={500} disabled={confirming} value={reason} onChange={e => setReason(e.target.value)} placeholder="Recorded in the audit log; no personal details" /></label>
      {confirming && <p className="notice" role="alert"><span aria-hidden="true">!</span>Grant {plural(amount, 'credit')} to {label(account)}? This is more than {CONFIRM_ABOVE}.</p>}
      {error && <p className="error" role="alert">{error}</p>}
      <div className="modal-actions"><button type="button" className="secondary" onClick={confirming ? () => setConfirming(false) : onCancel}>{confirming ? 'Back' : 'Cancel'}</button>
        <button disabled={busy || !valid}>{busy ? 'Granting…' : confirming ? 'Confirm grant' : `Grant ${Number.isInteger(amount) && amount > 0 ? amount.toLocaleString() + ' ' : ''}credits`}</button></div>
    </form>
  </Modal>;
}

/** Review A9: the testing allowance names the acting owner, applies only to owner/tester accounts and caps the month. */
function TestingDialog({ account, current, onCancel, onConfirm }: { account: AdminAccount; current: TestingAllowance | null; onCancel: () => void;
  onConfirm: (enabled: boolean, capUSD: number | null, reason: string) => Promise<void> }) {
  const on = !!current?.enabled;
  const [cap, setCap] = useState(String((current?.monthly_cap_microusd ?? 25_000_000) / 1e6)); const [reason, setReason] = useState('');
  const { busy, error, run } = useAction();
  const amount = Number(cap), valid = reason.trim().length >= 3 && (on || (Number.isFinite(amount) && amount >= 0 && amount <= 50));
  return <Modal title={on ? 'End the testing allowance?' : 'Turn on the testing allowance'} onCancel={onCancel}>
    <p>{on ? <>For <strong>{label(account)}</strong>: unused testing credits are removed; work in progress still settles. Purchased credits are untouched.</>
      : <>For <strong>{label(account)}</strong>: credits refill automatically before each paid request, and its provider cost this month may not pass the cap. The platform budget still applies. Owner and tester accounts only.</>}</p>
    <form onSubmit={event => { event.preventDefault(); if (valid) void run(() => onConfirm(!on, on ? null : amount, reason.trim())); }}>
      {!on && <label>Monthly cap (USD of provider cost)<input type="number" inputMode="decimal" min={0} max={50} step={0.01} required value={cap} onChange={e => setCap(e.target.value)} /></label>}
      <label>Reason<input required minLength={3} maxLength={200} autoFocus value={reason} onChange={e => setReason(e.target.value)} placeholder="Recorded in the audit log; no personal details" /></label>
      {error && <p className="error" role="alert">{error}</p>}
      <div className="modal-actions"><button type="button" className="secondary" onClick={onCancel}>Cancel</button>
        <button className={on ? 'danger' : undefined} disabled={busy || !valid}>{busy ? 'Saving…' : on ? 'End allowance' : 'Turn on'}</button></div>
    </form>
  </Modal>;
}

function SignInDialog({ account, disable, onCancel, onConfirm }: { account: AdminAccount; disable: boolean; onCancel: () => void; onConfirm: (reason: string) => Promise<void> }) {
  const [reason, setReason] = useState(''); const { busy, error, run } = useAction();
  return <Modal title={disable ? 'Disable sign-in?' : 'Enable sign-in?'} onCancel={onCancel}>
    {disable
      ? <p><strong>{label(account)}</strong> won't be able to sign in or renew a session. A session already open ends when its access token expires (up to an hour). Their library, credits and history are kept, and you can enable sign-in again at any time.</p>
      : <p><strong>{label(account)}</strong> will be able to sign in again with their usual method.</p>}
    <form onSubmit={event => { event.preventDefault(); if (reason.trim().length >= 3) void run(() => onConfirm(reason.trim())); }}>
      <label>Reason<input required minLength={3} maxLength={500} autoFocus value={reason} onChange={e => setReason(e.target.value)} placeholder="Recorded in the audit log; no personal details" /></label>
      {error && <p className="error" role="alert">{error}</p>}
      <div className="modal-actions"><button type="button" className="secondary" onClick={onCancel}>Cancel</button>
        <button className={disable ? 'danger' : undefined} disabled={busy || reason.trim().length < 3}>{busy ? 'Saving…' : disable ? 'Disable sign-in' : 'Enable sign-in'}</button></div>
    </form>
  </Modal>;
}
