import { type FormEvent, useEffect, useRef, useState, useSyncExternalStore } from 'react';
import { AuthError, auth } from '../lib/backend';
import { OAuthError, oauthProviders, type OAuthAttempt } from '../lib/oauth';
import type { OAuthProvider } from '../lib/auth-state';
import { Brand } from './common';

export const authIssueText: Record<string, string> = {
  invalid_email: 'Enter a valid email address.',
  no_account: 'There’s no Gradstep account for this address. Gradstep is invite-only during the beta.',
  rate_limited: 'Too many attempts. Wait a minute, then try again.',
  invalid_code: 'That code didn’t work. Check it, or send a new one.',
  connection: 'Couldn’t reach Gradstep. Check your connection and try again.',
  configuration: 'This sign-in method is unavailable right now.',
  auth_storage: 'Couldn’t save or remove your sign-in on this browser. Allow site data, then try again. If you were signing out, the saved session may still be present.',
  oauth_cancelled: 'Sign-in was cancelled. You can choose a sign-in method again.',
  oauth_expired: 'That sign-in attempt expired. Start again.',
  oauth_rejected: 'That sign-in return is no longer valid. Start again.',
  oauth_unavailable: 'This browser sign-in method isn’t available. Use your email code.',
  rejected: 'Couldn’t sign in. Try again.',
};

export function SignIn() {
  const savedAuth = useSyncExternalStore(auth.subscribe, auth.snapshot);
  const [provider, setProvider] = useState<OAuthProvider | null>(null);
  const [step, setStep] = useState<'email' | 'code'>('email');
  const [email, setEmail] = useState('');
  const [captured, setCaptured] = useState('');
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState(false);
  const [issue, setIssue] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const [resendAt, setResendAt] = useState(0);
  const [now, setNow] = useState(Date.now());
  const codeField = useRef<HTMLInputElement>(null);
  const attempt = useRef(0);
  const request = useRef<AbortController | null>(null);

  useEffect(() => () => { attempt.current++; request.current?.abort(); }, []);

  useEffect(() => { if (step !== 'code') return; const t = setInterval(() => setNow(Date.now()), 1000); return () => clearInterval(t); }, [step]);
  useEffect(() => { if (step === 'code') codeField.current?.focus(); }, [step]);

  async function startProvider(next: OAuthProvider) {
    const id = ++attempt.current;
    request.current?.abort();
    const controller = new AbortController(); request.current = controller;
    setBusy(true); setProvider(next); setIssue(null); setNote(null);
    let owned: OAuthAttempt | undefined;
    try {
      const start = await auth.beginOAuth(next, location.origin, controller.signal); owned = start.attempt;
      if (id !== attempt.current || !auth.canRedirect(start.attempt)) throw new AuthError('oauth_rejected');
      location.assign(start.url);
    } catch (error) {
      if (owned) await auth.abandonOAuth(owned.id).catch(() => {});
      if (id === attempt.current) setIssue(authIssueText[error instanceof AuthError || error instanceof OAuthError ? error.issue : 'oauth_rejected']);
    } finally { if (id === attempt.current) { setBusy(false); setProvider(null); } }
  }

  async function send(address: string) {
    request.current?.abort();
    const controller = new AbortController(); request.current = controller;
    const id = ++attempt.current;
    setBusy(true); setIssue(null); setNote(null);
    try {
      const { delivered } = await auth.sendCode(address, controller.signal);
      if (id !== attempt.current) return;
      setCaptured(address); setCode(''); setStep('code'); setResendAt(Date.now() + 60_000);
      setNote(delivered ? `We sent a 6-digit code to ${address}.` : 'Couldn’t confirm delivery. You can still enter a code.');
    } catch (error) {
      if (id !== attempt.current) return;
      setIssue(authIssueText[error instanceof AuthError ? error.issue : 'rejected']);
    } finally { if (id === attempt.current) setBusy(false); }
  }

  function submitEmail(event: FormEvent) {
    event.preventDefault();
    const address = auth.normalizeEmail(email);
    if (!address) { setIssue(authIssueText.invalid_email); return; }
    void send(address);
  }

  async function verify(event: FormEvent) {
    event.preventDefault();
    const digits = code.replace(/\s/g, '');
    if (!/^[0-9]{6}$/.test(digits)) { setIssue('Enter the 6-digit code from the email.'); return; }
    const id = ++attempt.current;
    request.current?.abort();
    const controller = new AbortController(); request.current = controller;
    setBusy(true); setIssue(null);
    try { await auth.verifyCode(captured, digits, controller.signal); }
    catch (error) { if (id === attempt.current) setIssue(authIssueText[error instanceof AuthError ? error.issue : 'rejected']); }
    finally { if (id === attempt.current) setBusy(false); }
  }

  function anotherEmail() { attempt.current++; request.current?.abort(); setStep('email'); setCode(''); setIssue(null); setNote(null); setBusy(false); }

  const wait = Math.max(0, Math.ceil((resendAt - now) / 1000));
  return (
    <main className="auth-shell">
      <section className="card auth-card" aria-labelledby="sign-in-title">
        <Brand />
        <h1 id="sign-in-title">{step === 'email' ? 'Sign in' : 'Enter your code'}</h1>
        {step === 'email' ? (
          <form onSubmit={submitEmail} noValidate>
            <p className="muted">Read your Gradstep library in the browser.</p>
            <div className="auth-providers">
              <button type="button" className="secondary" disabled={busy || !oauthProviders.apple} onClick={() => void startProvider('apple')} data-testid="oauth-apple">{provider === 'apple' ? 'Opening Apple…' : 'Continue with Apple'}</button>
              <button type="button" className="secondary" disabled={busy || !oauthProviders.google} onClick={() => void startProvider('google')} data-testid="oauth-google">{provider === 'google' ? 'Opening Google…' : 'Continue with Google'}</button>
            </div>
            {(!oauthProviders.apple || !oauthProviders.google) && <p className="fine">{!oauthProviders.apple && !oauthProviders.google ? 'Apple and Google browser sign-in aren’t available yet.' : !oauthProviders.apple ? 'Apple browser sign-in isn’t available yet.' : 'Google browser sign-in isn’t available yet.'} Email sign-in is available below.</p>}
            {savedAuth.issue && <p className="issue" role="alert">{authIssueText[savedAuth.issue]}</p>}
            <p className="muted">Or sign in with an email code.</p>
            <label>Email
              <input type="email" name="email" autoComplete="email" inputMode="email" autoCapitalize="none" spellCheck={false} required
                value={email} onChange={e => setEmail(e.target.value)} disabled={busy} data-testid="email" />
            </label>
            {issue && <p className="issue" role="alert">{issue}</p>}
            <button type="submit" className="primary" disabled={busy || !email.trim()} data-testid="send-code">{busy && !provider ? 'Sending…' : 'Send code'}</button>
            <p className="fine">Use the email address of your Gradstep account.</p>
          </form>
        ) : (
          <form onSubmit={verify} noValidate>
            {note && <p className="muted" role="status">{note}</p>}
            <label>Code
              <input ref={codeField} name="code" autoComplete="one-time-code" inputMode="numeric" pattern="[0-9]*" maxLength={6} spellCheck={false}
                value={code} onChange={e => setCode(e.target.value.replace(/[^0-9]/g, '').slice(0, 6))} disabled={busy} data-testid="code" />
            </label>
            {issue && <p className="issue" role="alert">{issue}</p>}
            <button type="submit" className="primary" disabled={busy || code.length !== 6} data-testid="verify">{busy ? 'Checking…' : 'Continue'}</button>
            <div className="row-actions">
              <button type="button" className="link" onClick={() => void send(captured)} disabled={busy || wait > 0}>{wait > 0 ? `Resend code (${wait} s)` : 'Resend code'}</button>
              <button type="button" className="link" onClick={anotherEmail}>Use another email</button>
            </div>
          </form>
        )}
      </section>
    </main>
  );
}
