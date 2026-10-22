import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import type { Session } from '@supabase/supabase-js';
import { attachmentImage, backend, environment, rpc, type AccountContext, type Health as HealthData, type Overview, type ProviderHour, type Pipeline, type PipelineMetrics, type Report, type Thread } from './backend';
import { mutate } from './mutations';
import { Reliability } from './reliability';
import { Health, HEALTH_WINDOWS } from './health';
import { ProviderHours } from './provider-hours';
import { Spending } from './spending';
import { Accounts, liveAccountsApi } from './accounts';
import { Costs } from './costs';
import { SpendVsIncome } from './spend-income';
import { Purchases, type PurchasesApi, type PurchaseObservations, type PurchaseObservation, type PurchaseLedgerPage } from './purchases';
import { WorkflowChecksPanel, type WorkflowChecks } from './checks';
import { Brand, Shell } from './shell';
import { currentBudget } from './budget-period';
import './style.css';

const loadMetrics = (days: number) => rpc<PipelineMetrics>('v1_admin_pipeline_metrics', { p_days: days });
const loadHealth = (days: number) => rpc<HealthData>('v1_admin_health', { p_days: days });
const loadProviderHours = (hours: number) => rpc<ProviderHour[]>('v1_admin_provider_hours', { p_hours: hours });
const loadChecks = () => rpc<WorkflowChecks>('v1_admin_workflow_checks', { p_days: 14 });
const purchasesApi: PurchasesApi = {
  list: (filter, reference) => rpc<PurchaseObservations>('v1_admin_store_verifications', { p_filter: filter, p_reference: reference }),
  attempts: (accountID, reference) => rpc<PurchaseObservation[]>('v1_admin_store_verification_attempts', { p_account_id: accountID, p_reference: reference }),
  transactions: (accountID, cursor) => rpc<PurchaseLedgerPage>('v1_admin_store_account_transactions', { p_account_id: accountID, p_cursor: cursor, p_limit: 25 }),
};

const dollars = (micro: number) => new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', minimumFractionDigits: 2, maximumFractionDigits: 4 }).format(micro / 1_000_000);
const date = (value: string) => new Date(value).toLocaleString();
const statusName = (value: string) => value.replaceAll('_', ' ');
const bytes = (value: number) => value >= 1024 ** 3 ? `${(value / 1024 ** 3).toFixed(2)} GiB` : `${(value / 1024 ** 2).toFixed(2)} MiB`;

// The address names the page (#health/30, #support), so a bookmark or the apps' "Operations dashboard" link opens it.
const OWNER_TABS = ['Health', 'Overview', 'Spend vs income', 'Spending', 'Costs', 'Processing', 'Reliability', 'Accounts', 'Purchases', 'Support'];
const decodeHash = (value: string) => { try { return decodeURIComponent(value); } catch { return value; } };
function fromHash(): { tab: string | null; days: number } {
  // Tab names may contain spaces ("Spend vs income"), which a browser shows percent-encoded in the address.
  const [name, days] = decodeHash(location.hash.replace(/^#/, '')).split('/');
  const tab = OWNER_TABS.find(t => t.toLowerCase() === (name ?? '').toLowerCase()) ?? null;
  return { tab, days: HEALTH_WINDOWS.includes(Number(days)) ? Number(days) : 30 };
}

function App() {
  const [session, setSession] = useState<Session | null>(null);
  const [account, setAccount] = useState<AccountContext | null>(null);
  const [error, setError] = useState(() => oauthReturnError());
  const [tab, setTab] = useState(() => fromHash().tab ?? 'Health');
  const [healthDays, setHealthDays] = useState(() => fromHash().days);
  const [overview, setOverview] = useState<Overview | null>(null);
  const [pipeline, setPipeline] = useState<Pipeline | null>(null);
  const [reports, setReports] = useState<Report[]>([]);
  const [loading, setLoading] = useState(false);
  const [reloads, setReloads] = useState(0);
  const currentUser = useRef<string | null>(null);
  const refreshGeneration = useRef(0);
  const accountsApi = useMemo(() => liveAccountsApi(session?.user.id ?? ''), [session?.user.id]);

  useEffect(() => {
    const target = '#' + encodeURIComponent(tab.toLowerCase()) + (tab === 'Health' ? '/' + healthDays : '');
    if (location.hash !== target) history.replaceState(null, '', target);
  }, [tab, healthDays]);
  useEffect(() => {
    const follow = () => { const next = fromHash(); if (next.tab) setTab(next.tab); setHealthDays(next.days); };
    addEventListener('hashchange', follow); return () => removeEventListener('hashchange', follow);
  }, []);

  useEffect(() => {
    if (!backend) return;
    const { data } = backend.auth.onAuthStateChange((_event, next) => {
      currentUser.current = next?.user.id ?? null;
      refreshGeneration.current += 1;
      setSession(next);
    });
    return () => data.subscription.unsubscribe();
  }, []);

  const refresh = useCallback(async () => {
    if (!session) return;
    const generation = ++refreshGeneration.current;
    const active = () => currentUser.current === session.user.id && generation === refreshGeneration.current;
    setLoading(true); setError('');
    try {
      const context = await rpc<AccountContext>('v1_account_context');
      if (!active()) return;
      setAccount(context);
      if (context.operator_verified) {
        const results = await Promise.all([
          context.roles.includes('owner') ? rpc<Overview>('v1_admin_overview') : Promise.resolve(null),
          rpc<Report[]>('v2_reports'),
          context.roles.includes('owner') ? rpc<Pipeline>('v1_admin_pipeline').catch(() => null) : Promise.resolve(null),
        ]);
        if (!active()) return;
        setOverview(results[0]); setReports(results[1]); setPipeline(results[2]);
        if (!context.roles.includes('owner')) setTab('Support');
      }
    } catch (e) { if (active()) setError(e instanceof Error ? e.message : 'The dashboard could not refresh.'); }
    finally { if (active()) setLoading(false); }
  }, [session]);

  useEffect(() => {
    if (!session || account?.account_id !== session.user.id) { setAccount(null); setOverview(null); setReports([]); }
    void refresh(); return () => { refreshGeneration.current += 1; };
  }, [refresh]);

  if (!session) return <SignIn error={error} setError={setError} />;
  if (!account || account.account_id !== session.user.id) return <div className="auth-shell"><div className="auth-card"><Brand /><p role="status">Checking operator access…</p>{error && <p className="error" role="alert">{error}</p>}<button disabled={loading} onClick={() => void refresh()}>Retry</button><button className="quiet" onClick={() => void backend?.auth.signOut()}>Sign out</button></div></div>;
  if (account && !account.roles.some(role => ['owner', 'support'].includes(role))) {
    return <div className="auth-shell"><div className="auth-card"><Brand /><h1>Operator access required</h1><p>This account can use the reader, but it has not been granted administration access.</p><button onClick={() => void backend?.auth.signOut()}>Sign out</button></div></div>;
  }
  if (account && !account.operator_verified) return <TwoFactor onVerified={refresh} />;
  const owner = account.roles.includes('owner');
  return <Shell tabs={owner ? OWNER_TABS : ['Support']} tab={tab} onTab={setTab}
    counts={{ Support: overview?.open_reports }} email={session.user.email ?? ''} onSignOut={() => void backend?.auth.signOut()}
    loading={loading} onRefresh={() => { setReloads(n => n + 1); void refresh(); }}>
      {error && <div className="error" role="alert">{error}</div>}
      {loading && !account ? <p role="status">Checking operator access…</p> : null}
      {tab === 'Health' && owner && <Health key={account.account_id} load={loadHealth} budget={currentBudget(overview?.budgets)} reloadKey={reloads} days={healthDays} onDays={setHealthDays} />}
      {tab === 'Overview' && overview && <>
        <div className="metrics"><Metric label="Accounts" value={overview.accounts} /><Metric label="Library items" value={overview.library_items} /><Metric label="Shared documents" value={overview.shared_documents} /><Metric label="Reused by multiple accounts" value={overview.shared_documents_reused} /></div>
        <BudgetPanel overview={overview} onChanged={refresh} />
        <HistoryCapacity overview={overview} />
        <div className="two-columns"><section className="panel"><h2>Subscriptions</h2><Counts values={overview.subscriptions} empty="No verified subscriptions yet." /></section><section className="panel"><h2>Processing queue</h2><Counts values={overview.jobs} empty="No processing jobs yet." /></section></div>
        <p className="footnote">This dashboard contains service metadata and reports shared with support. Private chats and notes are not available to administrators.</p>
      </>}
      {tab === 'Spend vs income' && owner && <SpendVsIncome key={account.account_id} reloadKey={reloads} />}
      {tab === 'Spending' && owner && <Spending key={account.account_id} ownerID={account.account_id} reloadKey={reloads} />}
      {tab === 'Costs' && owner && <Costs key={account.account_id} reloadKey={reloads} />}
      {tab === 'Processing' && <PipelinePanel pipeline={pipeline} />}
      {tab === 'Reliability' && owner && <><WorkflowChecksPanel load={loadChecks} reloadKey={reloads} /><Reliability key={account.account_id} load={loadMetrics} reloadKey={reloads} /><ProviderHours load={loadProviderHours} reloadKey={reloads} /></>}
      {tab === 'Accounts' && owner && <Accounts key={account.account_id} api={accountsApi} reloadKey={reloads} />}
      {tab === 'Purchases' && owner && <Purchases key={account.account_id} api={purchasesApi} reloadKey={reloads} />}
      {tab === 'Support' && <Support key={account.account_id} accountID={account.account_id} reports={reports} refresh={refresh} />}
  </Shell>;
}

function PipelinePanel({ pipeline }: { pipeline: Pipeline | null }) {
  if (!pipeline) return <section className="panel"><Empty text="Pipeline status is unavailable." /></section>;
  const uncertain = pipeline.attempts.filter(a => a.state === 'uncertain');
  return <>
    <section className="panel"><div className="section-heading"><h2>Paper pipeline</h2><span className={'badge ' + (pipeline.policy.enabled ? 'positive' : '')}>{pipeline.policy.enabled ? 'Running' : 'Stopped'}</span></div>
      <Counts values={pipeline.stages} empty="No papers have been imported." />
      <p className="muted">OCR is capped at {pipeline.policy.max_ocr_pages} pages per paper; reader renderer {pipeline.policy.renderer_version}.</p>
      {uncertain.length > 0 && <p className="error" role="alert">{uncertain.length} historical paid OCR submission(s) are uncertain and keep their credit hold until an operator reconciles them.</p>}
    </section>
    <section className="panel"><h2>Recent papers</h2>
      <table><thead><tr><th>Paper</th><th>Stage</th><th>Interested</th><th>Updated</th></tr></thead><tbody>{pipeline.papers.map(p => <tr key={p.id}>
        <td><strong>{p.title ?? p.source}</strong><br /><small className="muted">{p.source}{p.private ? ' · private' : ''}</small></td>
        <td>{statusName(p.stage)}{p.error_code ? <><br /><small className="muted">{statusName(p.error_code)}{p.failures ? ` (${p.failures})` : ''}</small></> : null}</td>
        <td>{p.interested}</td><td>{date(p.updated_at)}</td></tr>)}</tbody></table>
      {!pipeline.papers.length && <Empty text="No papers yet." />}
    </section>
    <section className="panel"><h2>Paid OCR attempts (retired)</h2>
      <p className="muted">History only: server OCR stopped on 2026-10-13 (every PDF is processed on the device); no new attempts are made.</p>
      <table><thead><tr><th>State</th><th>Pages</th><th>Provider job</th><th>Created</th></tr></thead><tbody>{pipeline.attempts.map(a => <tr key={a.id}>
        <td>{statusName(a.state)}{a.error_code ? <><br /><small className="muted">{statusName(a.error_code)}</small></> : null}</td>
        <td>{a.pages_reported ?? '—'} / {a.page_limit}</td><td><code>{a.provider_job_id ?? '—'}</code></td><td>{date(a.created_at)}</td></tr>)}</tbody></table>
      {!pipeline.attempts.length && <Empty text="No paid OCR attempts yet." />}
    </section>
  </>;
}

function Empty({ text }: { text: string }) { return <p className="empty">{text}</p>; }
function Metric({ label, value }: { label: string; value: number }) { return <section className="metric"><p>{label}</p><strong>{value.toLocaleString()}</strong></section>; }
function Counts({ values, empty }: { values: Record<string, number>; empty: string }) {
  return Object.keys(values).length ? <dl className="counts">{Object.entries(values).map(([label, value]) => <div key={label}><dt>{statusName(label)}</dt><dd>{value}</dd></div>)}</dl> : <Empty text={empty} />;
}

function HistoryCapacity({ overview }: { overview: Overview }) {
  const storage = overview.sync_storage, transfers = overview.sync_transfers;
  if (!storage || !transfers) return null;
  const month = transfers.months.find(value => value.period === transfers.period);
  return <div className="two-columns">
    <section className="panel"><h2>Encrypted history storage</h2>
      <p><strong>{bytes(storage.ciphertext_bytes)}</strong> of {bytes(storage.environment_bytes)}</p>
      <progress value={storage.ciphertext_bytes} max={storage.environment_bytes} aria-label="Encrypted history storage used" />
      <p className="muted">{storage.event_count.toLocaleString()} of {storage.environment_events.toLocaleString()} events. Each account is limited to {bytes(storage.account_bytes)} and {storage.account_events.toLocaleString()} events.</p>
    </section>
    <section className="panel"><h2>History downloads this month</h2>
      <p><strong>{bytes(month?.reserved_bytes ?? 0)}</strong> of {bytes(transfers.policy.environment_bytes)}</p>
      <progress value={month?.reserved_bytes ?? 0} max={transfers.policy.environment_bytes} aria-label="History download allowance used" />
      <p className="muted">{(month?.requests ?? 0).toLocaleString()} responses, including a conservative overhead allowance. Each account has {bytes(transfers.policy.account_bytes)} per UTC month. These counters cover history sync; the provider invoice includes other traffic.</p>
    </section>
  </div>;
}

function SignIn({ error, setError }: { error: string; setError: (text: string) => void }) {
  const [email, setEmail] = useState(''); const [password, setPassword] = useState(''); const [busy, setBusy] = useState(false);
  return <div className="auth-shell"><form className="auth-card" onSubmit={async event => {
    event.preventDefault(); if (!backend) return; setBusy(true); setError('');
    const result = await backend.auth.signInWithPassword({ email, password });
    if (result.error) setError('Sign-in was not accepted. Check your email, password, and account confirmation.');
    setBusy(false);
  }}><Brand /><span className="environment">{environment}</span><h1>Administration</h1><p>Sign in with your operator account. Two-factor authentication is required.</p>
    <label>Email<input type="email" autoComplete="username" required value={email} onChange={e => setEmail(e.target.value)} /></label>
    <label>Password<input type="password" autoComplete="current-password" required value={password} onChange={e => setPassword(e.target.value)} /></label>
    {error && <p className="error" role="alert">{error}</p>}
    {!backend && <p className="muted">This build needs its backend configuration before sign-in is available.</p>}
    <button type="submit" disabled={busy || !backend}>{busy ? 'Signing in…' : 'Sign in'}</button>
    <p className="muted">Account made with Google or Apple? Continue with the Google account for the same address (Apple sign-in isn't set up for websites yet).</p>
    <button type="button" className="quiet" disabled={busy || !backend} onClick={() => void oauth()}>Continue with Google</button>
  </form></div>;

  // The reader app's Google sign-in (PKCE; supabase-js exchanges the returned code on load). A provider signs in to the same
  // account when it uses the same verified address; two-factor authentication follows as for a password.
  async function oauth() {
    if (!backend) return; setBusy(true); setError('');
    const result = await backend.auth.signInWithOAuth({ provider: 'google', options: { redirectTo: window.location.origin } });
    if (result.error) { setError('Google sign-in could not start. Try again.'); setBusy(false); }
  }
}

/** A provider's refusal returned in the address (removed once read), in plain words. */
export function oauthReturnError(): string {
  const query = new URLSearchParams(window.location.search), fragment = new URLSearchParams(window.location.hash.slice(1));
  const error = query.get('error') ?? fragment.get('error');
  if (!error) return '';
  window.history.replaceState(null, '', window.location.pathname);
  const description = query.get('error_description') ?? fragment.get('error_description') ?? '';
  if (/invitation|signup/i.test(description)) return 'This address has no Gradstep account. Use the address your reader account uses.';
  return 'Sign-in was not completed. Try again.';
}

function TwoFactor({ onVerified }: { onVerified: () => Promise<void> }) {
  const [factor, setFactor] = useState(''); const [qr, setQR] = useState(''); const [code, setCode] = useState('');
  const [error, setError] = useState(''); const [busy, setBusy] = useState(false);
  useEffect(() => { void backend?.auth.mfa.listFactors().then(({ data }) => { const first = data?.totp.find(item => item.status === 'verified'); if (first) setFactor(first.id); }); }, []);
  async function enroll() {
    if (!backend) return; setBusy(true); setError('');
    // D10: an abandoned, never-verified enrolment would block a new one with the same name; remove it first.
    const listed = await backend.auth.mfa.listFactors();
    for (const stale of listed.data?.all.filter(f => f.factor_type === 'totp' && f.status === 'unverified') ?? []) await backend.auth.mfa.unenroll({ factorId: stale.id });
    const { data, error } = await backend.auth.mfa.enroll({ factorType: 'totp', friendlyName: 'Gradstep administration' });
    if (error) setError('Authenticator setup could not start. Try again.');
    else { setFactor(data.id); setQR(data.totp.qr_code.startsWith('data:') ? data.totp.qr_code : 'data:image/svg+xml,' + encodeURIComponent(data.totp.qr_code)); }
    setBusy(false);
  }
  return <div className="auth-shell"><form className="auth-card" onSubmit={async event => {
    event.preventDefault(); if (!backend) return; setBusy(true); setError('');
    const { error } = await backend.auth.mfa.challengeAndVerify({ factorId: factor, code });
    if (error) setError('The code was not accepted. Try the current code from your authenticator.');
    else await onVerified(); setBusy(false);
  }}><Brand /><h1>Verify your sign-in</h1><p>Use an authenticator app to protect access to reports and spending controls.</p>
    {qr && <img className="qr" src={qr} alt="Scan this QR code with your authenticator app" />}
    {!factor ? <button type="button" onClick={() => void enroll()} disabled={busy}>Set up authenticator</button> : <><label>Six-digit code<input inputMode="numeric" autoComplete="one-time-code" pattern="[0-9]{6}" required value={code} onChange={e => setCode(e.target.value.replace(/\D/g, '').slice(0, 6))} /></label><button disabled={busy || code.length !== 6}>{busy ? 'Verifying…' : 'Verify'}</button></>}
    {error && <p className="error" role="alert">{error}</p>}
    <button type="button" className="quiet" onClick={() => void backend?.auth.signOut()}>Sign out</button>
  </form></div>;
}

function BudgetPanel({ overview, onChanged }: { overview: Overview; onChanged: () => Promise<void> }) {
  const budget = currentBudget(overview.budgets); const [reason, setReason] = useState(''); const [busy, setBusy] = useState(false); const [error, setError] = useState('');
  return <section className="panel"><div className="section-heading"><h2>Provider spending</h2><span className={'badge ' + (budget?.work_enabled ? 'positive' : '')}>{budget?.work_enabled ? 'Enabled' : 'Paused'}</span></div>
    {!budget ? <Empty text="No provider budget is configured. Paid processing is disabled." /> : <>
      <div className="budget-values"><div><span>Incurred</span><strong>{dollars(budget.spent_microusd)}</strong></div><div><span>Reserved in flight</span><strong>{dollars(budget.reserved_microusd)}</strong></div><div><span>Environment limit</span><strong>{dollars(budget.limit_microusd)}</strong></div></div>
      <progress max={Math.max(1, budget.limit_microusd)} value={Math.min(budget.limit_microusd, budget.spent_microusd + budget.reserved_microusd)} aria-label="Incurred and reserved provider spending" />
      <p className="muted">This is the {environment} provider allocation. The $100 total operating budget also includes infrastructure, backups, and contingency.</p>
      <form className="inline-form" onSubmit={async event => { event.preventDefault(); setBusy(true); setError(''); try { await rpc('v1_admin_pause_work', { p_paused: budget.work_enabled, p_reason: reason }); setReason(''); await onChanged(); } catch (e) { setError((e as Error).message); } finally { setBusy(false); } }}>
        <label>Reason for change<input minLength={3} maxLength={1000} required value={reason} onChange={e => setReason(e.target.value)} placeholder="Recorded in the audit log" /></label>
        <button disabled={busy || reason.trim().length < 3}>{budget.work_enabled ? 'Pause new paid work' : 'Resume within limit'}</button>
      </form>{error && <p className="error" role="alert">{error}</p>}
    </>}
  </section>;
}

const REPORT_PAGE = 50;
function Support({ accountID, reports, refresh }: { accountID: string; reports: Report[]; refresh: () => Promise<void> }) {
  const [selected, setSelected] = useState<string | null>(null); const [thread, setThread] = useState<Thread | null>(null);
  // D10: older reports page in (v2_reports' cursor); the first page comes with the dashboard refresh.
  const [older, setOlder] = useState<Report[]>([]); const [more, setMore] = useState(true); const [paging, setPaging] = useState(false);
  useEffect(() => { setOlder([]); setMore(reports.length >= REPORT_PAGE); }, [reports]);
  const listed = [...reports, ...older.filter(o => !reports.some(r => r.id === o.id))];
  const loadOlder = async () => {
    const last = listed.at(-1); if (!last) return; setPaging(true); setError('');
    try { const page = await rpc<Report[]>('v2_reports', { p_before_created_at: last.created_at, p_before_id: last.id, p_limit: REPORT_PAGE });
      setOlder(o => [...o, ...page]); setMore(page.length >= REPORT_PAGE); }
    catch (e) { setError((e as Error).message); } finally { setPaging(false); }
  };
  const [reply, setReply] = useState(''); const [build, setBuild] = useState(''); const [error, setError] = useState(''); const [busy, setBusy] = useState(false);
  const selectedRef = useRef(selected);
  selectedRef.current = selected;
  const load = useCallback(async () => { if (selected) { try { const next = await rpc<Thread>('v1_report_thread', { p_report_id: selected }); if (selectedRef.current === selected) setThread(next); } catch (e) { if (selectedRef.current === selected) setError((e as Error).message); } } }, [selected]);
  useEffect(() => { setThread(null); setReply(''); setBuild(''); setError(''); void load(); }, [load]);
  async function status(value: string) {
    if (!selected) return; setBusy(true); setError('');
    try { await mutate(accountID, 'v1_set_report_status', { p_report_id: selected, p_status: value, p_fixed_build: value === 'ready_to_retest' ? build : null }); await load(); await refresh(); }
    catch (e) { setError((e as Error).message); } finally { setBusy(false); }
  }
  return <div className="support-layout"><section className="panel report-list"><h2>Reports</h2>{!listed.length && <Empty text="No reports have been submitted." />}
    {listed.map(report => <button key={report.id} disabled={busy} className={selected === report.id ? 'report selected-report' : 'report'} onClick={() => setSelected(report.id)}><strong>{report.title}</strong><span>{statusName(report.status)} · Build {report.build}</span><small>{date(report.created_at)}</small></button>)}
    {more && listed.length > 0 && <button className="secondary" disabled={paging} onClick={() => void loadOlder()}>{paging ? 'Loading…' : 'Load older reports'}</button>}
    </section><section className="panel report-detail">
      {!thread ? <Empty text="Select a report to review the issue and reply." /> : <><span className="badge">{statusName(thread.report.status)}</span><h2>{thread.report.title}</h2><p className="report-note">{thread.report.note}</p>
        <p className="muted">Version {thread.report.app_version} ({thread.report.build}) · {thread.report.os_version} · {thread.report.screen}</p>
        {thread.report.fixed_build && <p className="fix-build">Fix available in build {thread.report.fixed_build}</p>}
        {thread.attachments.length > 0 && <div className="attachments">{thread.attachments.map(attachment => <PrivateAttachment key={attachment.id} id={attachment.id} />)}</div>}
        <div className="messages">{thread.messages.map(message => <article key={message.id}><strong>{message.is_operator ? 'Support' : 'Reporter'}</strong><time>{date(message.created_at)}</time><p>{message.body}</p></article>)}</div>
        <form onSubmit={async event => { event.preventDefault(); setBusy(true); setError(''); try { await mutate(accountID, 'v1_reply_to_report', { p_report_id: selected, p_body: reply }); setReply(''); await load(); } catch (e) { setError((e as Error).message); } finally { setBusy(false); } }}>
          <label>Reply<textarea required disabled={busy} maxLength={10000} rows={4} value={reply} onChange={e => setReply(e.target.value)} /></label><button disabled={busy || !reply.trim()}>Send reply</button>
        </form>
        <div className="status-controls"><button className="secondary" disabled={busy} onClick={() => void status('investigating')}>Investigating</button><label>Fixed in build<input value={build} maxLength={40} onChange={e => setBuild(e.target.value)} placeholder="e.g. 12" /></label><button className="secondary" disabled={busy || !build.trim()} onClick={() => void status('ready_to_retest')}>Ready to retest</button>
          {thread.report.status === 'verified'
            ? <button className="secondary" disabled={busy} onClick={() => void status('open')}>Reopen</button>
            : <button className="secondary" disabled={busy} onClick={() => void status('verified')} title="Resolved and confirmed; it leaves the open count">Close</button>}</div>
      </>}{error && <p className="error" role="alert">{error}</p>}
    </section></div>;
}

function PrivateAttachment({ id }: { id: string }) {
  const [source, setSource] = useState(''); const [error, setError] = useState(''); const [attempt, setAttempt] = useState(0);
  useEffect(() => {
    const controller = new AbortController(); let objectURL = '';
    setSource(''); setError('');
    void attachmentImage(id, controller.signal).then(blob => {
      if (controller.signal.aborted) return;
      objectURL = URL.createObjectURL(blob); setSource(objectURL);
    }).catch(error => { if (!controller.signal.aborted) setError(error instanceof Error ? error.message : 'Screenshot unavailable.'); });
    return () => { controller.abort(); if (objectURL) URL.revokeObjectURL(objectURL); };
  }, [id, attempt]);
  return <figure>{source ? <a href={source} target="_blank" rel="noreferrer"><img src={source} alt="Screenshot shared by the reporter" /></a> : <p role="status">{error || 'Loading private screenshot…'}</p>}{error && <button className="secondary" onClick={() => setAttempt(n => n + 1)}>Retry image</button>}</figure>;
}

const root = createRoot(document.getElementById('root')!);
// Development-only screenshot fixtures; production builds drop these branches and their modules.
if (import.meta.env.DEV && new URLSearchParams(location.search).get('fixture') === 'spending') {
  void import('./spending-fixture').then(({ SpendingFixture }) => root.render(<React.StrictMode><SpendingFixture /></React.StrictMode>));
} else if (import.meta.env.DEV && ['reliability', 'accounts', 'purchases', 'health', 'costs', 'spend-income'].includes(new URLSearchParams(location.search).get('fixture') ?? '')) {
  void import('./fixtures').then(({ ReliabilityFixture, AccountsFixture, PurchasesFixture, HealthFixture, CostsFixture, SpendIncomeFixture }) => root.render(<React.StrictMode>
    {new URLSearchParams(location.search).get('fixture') === 'health' ? <HealthFixture />
      : new URLSearchParams(location.search).get('fixture') === 'spend-income' ? <SpendIncomeFixture />
      : new URLSearchParams(location.search).get('fixture') === 'costs' ? <CostsFixture />
      : new URLSearchParams(location.search).get('fixture') === 'accounts' ? <AccountsFixture />
      : new URLSearchParams(location.search).get('fixture') === 'purchases' ? <PurchasesFixture /> : <ReliabilityFixture />}</React.StrictMode>));
} else {
  root.render(<React.StrictMode><App /></React.StrictMode>);
}
