// This browser becomes a device: new keys for an account without any; otherwise approval from another device (QR,
// the primary path) or the recovery code.
import { type FormEvent, useCallback, useEffect, useRef, useState } from 'react';
import { BackendError } from '../lib/backend';
import { StorageError } from '../lib/idb';
import { type Preparation, bootstrap, prepare, recoverWithCode } from '../lib/keys';
import { WireError, generateBundle, generateRecoveryCode, recoveryCodeBytes } from '../lib/wire';
import { ApproveFromPhone } from './Approve';
import { Brand } from './common';
import { storageGuidance, useStorageLifecycle } from './StorageNotice';

type Ready = Extract<Preparation, { kind: 'ready' }>;
type View = { kind: 'preparing' } | { kind: 'needs_new_keys' } | { kind: 'recovery_required' } | { kind: 'failed'; message: string; title?: string; reload?: boolean };

function message(error: unknown): string {
  // Another tab changed or closed storage: say what to do, rather than blaming the browser's capabilities.
  const guidance = storageGuidance(error);
  if (guidance) return guidance.text;
  if (error instanceof WireError) {
    if (error.code === 'unsupported_browser') return 'This browser can’t save the keys needed for your private library. Try another browser, or use Gradstep on iPhone, iPad or Mac.';
    if (error.code === 'invalid_recovery_code') return 'That recovery code doesn’t match this account. Check it and try again.';
    if (error.code === 'stale_epoch') return 'Your keys changed on another device. Try again.';
    return 'This browser’s keys couldn’t be checked. Try again.';
  }
  if (error instanceof BackendError) {
    if (error.code === 'connection') return 'Couldn’t reach Gradstep. Check your connection and try again.';
    if (error.code === 'too_many_enrollment_requests') return 'Too many devices are waiting to be added. Try again in 15 minutes.';
    if (error.code === 'sign_in_required') return 'Your session ended. Sign in again.';
  }
  if (error instanceof Error && error.message === 'storage_unavailable') return 'This browser isn’t allowing Gradstep to store its keys (private browsing, or site data blocked).';
  return 'Something went wrong preparing this browser. Try again.';
}

export function KeySetup({ account, email, onReady, onSignOut }: { account: string; email: string | null; onReady: (ready: Ready) => void; onSignOut: () => void }) {
  const [view, setView] = useState<View>({ kind: 'preparing' });
  const [busy, setBusy] = useState(false);
  const [issue, setIssue] = useState<string | null>(null);
  const lifetime = useRef<AbortController | null>(null);
  const [attempt, setAttempt] = useState(0);
  const [method, setMethod] = useState<'phone' | 'code'>('phone');
  const [phoneAttempt, setPhoneAttempt] = useState(0);
  const { issue: storageIssue } = useStorageLifecycle();

  const route = useCallback((result: Preparation, signal: AbortSignal) => {
    if (signal.aborted) return;
    if (result.kind === 'ready') onReady(result); else setView({ kind: result.kind });
  }, [onReady]);

  const approved = useCallback((result: Preparation) => route(result, lifetime.current!.signal), [route]);
  const approvalIssue = useCallback((error: unknown) => { if (!lifetime.current?.signal.aborted) setIssue(message(error)); }, []);

  useEffect(() => {
    const controller = new AbortController();
    lifetime.current = controller;
    setView({ kind: 'preparing' }); setIssue(null);
    prepare(account, controller.signal).then(result => route(result, controller.signal), error => {
      const guidance = storageGuidance(error);
      if (!controller.signal.aborted) setView({ kind: 'failed', message: message(error), title: guidance?.title, reload: !!guidance?.reload });
    });
    return () => controller.abort();
  }, [account, attempt, route]);

  return (
    <main className="auth-shell">
      <section className="card auth-card keys-card" aria-live="polite">
        <Brand />
        {view.kind === 'preparing' && <><h1>Preparing this browser…</h1><div className="spinner" aria-label="Preparing" />
          {storageIssue === 'blocked' && <p className="issue" role="status">{storageGuidance(new StorageError('storage_blocked'))!.text}</p>}</>}
        {view.kind === 'failed' && <>
          <h1>{view.title ?? 'Couldn’t prepare this browser'}</h1>
          <p className="issue" role="alert">{view.message}</p>
          {view.reload ? <button className="primary" onClick={() => location.reload()}>Reload this page</button>
            : <button className="primary" onClick={() => setAttempt(a => a + 1)}>Try again</button>}
        </>}
        {view.kind === 'recovery_required' && method === 'phone' && <>
          {issue ? <>
            <h1>Restore your private library</h1>
            <p className="issue" role="alert">{issue}</p>
            <button className="primary" onClick={() => { setIssue(null); setPhoneAttempt(a => a + 1); }}>Try again</button>
            <button type="button" className="secondary" onClick={() => { setIssue(null); setMethod('code'); }}>Use recovery code instead</button>
          </> : <ApproveFromPhone account={account} attempt={phoneAttempt} onResult={approved} onIssue={approvalIssue}
            onUseCode={() => { setIssue(null); setMethod('code'); }} />}
        </>}
        {view.kind === 'recovery_required' && method === 'code' && <Recover onUsePhone={() => { setIssue(null); setMethod('phone'); }} account={account} email={email} busy={busy} issue={issue} onSubmit={async code => {
          const signal = lifetime.current!.signal;
          setBusy(true); setIssue(null);
          try { route(await recoverWithCode(account, code, signal), signal); } catch (error) { if (!signal.aborted) setIssue(message(error)); }
          finally { if (!signal.aborted) setBusy(false); }
        }} />}
        {view.kind === 'needs_new_keys' && <NewKeys account={account} email={email} busy={busy} issue={issue} onConfirm={async (code, bundle) => {
          const signal = lifetime.current!.signal;
          setBusy(true); setIssue(null);
          try { route(await bootstrap(account, bundle, code, signal), signal); } catch (error) { if (!signal.aborted) setIssue(message(error)); }
          finally { if (!signal.aborted) setBusy(false); }
        }} />}
        <button className="link signout" onClick={onSignOut} disabled={busy}>Sign out</button>
      </section>
    </main>
  );
}

function Recover({ email, busy, issue, onSubmit, onUsePhone }: { account: string; email: string | null; busy: boolean; issue: string | null;
  onSubmit: (code: string) => void; onUsePhone: () => void }) {
  const [code, setCode] = useState('');
  const [shown, setShown] = useState(false);
  const [local, setLocal] = useState<string | null>(null);
  function submit(event: FormEvent) {
    event.preventDefault();
    try { recoveryCodeBytes(code); } catch { setLocal('A recovery code is 64 letters and numbers (0–9, a–f), often written in groups of eight.'); return; }
    setLocal(null); onSubmit(code);
  }
  return (
    <>
      <h1>Restore your private library</h1>
      <p className="muted">Your private conversations and notes are encrypted with keys held on your devices. Enter your recovery code to add this browser.
        If you lose all approved devices and this code, we cannot recover that content.</p>
      {/* Username + current-password lets Passwords offer a code saved for gradstep.ai under this account email. */}
      <form onSubmit={submit} noValidate>
        <input type="text" name="username" autoComplete="username" value={email ?? ''} readOnly hidden />
        <label>Recovery code
          <span className="field-with-action">
            <input type={shown ? 'text' : 'password'} name="recovery-code" autoComplete="current-password" spellCheck={false} autoCapitalize="none"
              className="mono" value={code} onChange={e => setCode(e.target.value)} disabled={busy} data-testid="recovery-code" />
            <button type="button" className="secondary small" onClick={() => setShown(s => !s)} aria-pressed={shown}>{shown ? 'Hide' : 'Show'}</button>
          </span>
        </label>
        <p className="fine">If you saved it in Passwords on your iPhone, choose it from the suggestions for gradstep.ai, or paste it.</p>
        {(local || issue) && <p className="issue" role="alert">{local ?? issue}</p>}
        <button type="submit" className="primary" disabled={busy || !code.trim()} data-testid="recover">{busy ? 'Restoring…' : 'Restore this browser'}</button>
      </form>
      <button type="button" className="link" onClick={onUsePhone} disabled={busy} data-testid="use-phone">Approve from your phone instead</button>
    </>
  );
}

function NewKeys({ account, email, busy, issue, onConfirm }: { account: string; email: string | null; busy: boolean; issue: string | null; onConfirm: (code: string, bundle: ReturnType<typeof generateBundle>) => void }) {
  // Generated in memory only; nothing is uploaded until the code is confirmed as saved.
  const [code] = useState(generateRecoveryCode);
  const [bundle] = useState(() => generateBundle(account));
  const [saved, setSaved] = useState(false);
  const [copied, setCopied] = useState(false);
  return (
    <>
      <h1>Save your recovery code</h1>
      <p className="muted">Your private conversations and notes are encrypted with keys held on your devices. If you lose all approved devices and this code, we cannot recover that content.</p>
      <form onSubmit={e => { e.preventDefault(); if (saved) onConfirm(code, bundle); }}>
        <input type="text" name="username" autoComplete="username" value={email ?? ''} readOnly hidden />
        <output className="recovery-code mono" data-testid="new-recovery-code">{code}</output>
        <input type="password" name="new-recovery-code" autoComplete="new-password" value={code} readOnly className="visually-hidden" tabIndex={-1} aria-hidden="true" />
        <div className="row-actions">
          <button type="button" className="secondary" onClick={async () => { try { await navigator.clipboard.writeText(code); setCopied(true); } catch { setCopied(false); } }}>
            {copied ? 'Copied' : 'Copy code'}</button>
        </div>
        <p className="fine">Keep it in a password manager (your browser may offer to save it for this account) or somewhere safe offline.</p>
        <label className="check"><input type="checkbox" checked={saved} onChange={e => setSaved(e.target.checked)} data-testid="saved-code" /> I saved this code somewhere safe</label>
        {issue && <p className="issue" role="alert">{issue}</p>}
        <button type="submit" className="primary" disabled={!saved || busy} data-testid="confirm-code">{busy ? 'Setting up…' : 'Continue'}</button>
      </form>
    </>
  );
}
