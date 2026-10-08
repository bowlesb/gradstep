import { type FormEvent, useEffect, useRef, useState } from 'react';
import { AuthError, auth, type AuthIssue, type OAuthProvider } from '../lib/backend';
import { Brand } from './common';

const issueText: Record<string, string> = {
  invalid_email: 'Enter a valid email address.',
  no_account: 'There’s no Gradstep account for this address. Gradstep is invite-only during the beta.',
  rate_limited: 'Too many attempts. Wait a minute, then try again.',
  invalid_code: 'That code didn’t work. Check it, or send a new one.',
  connection: 'Couldn’t reach Gradstep. Check your connection and try again.',
  configuration: 'Email sign-in is unavailable right now.',
  rejected: 'Couldn’t sign in. Try again.',
  oauth_cancelled: 'Sign-in was cancelled. Choose a provider to try again.',
  oauth_invalid: 'That sign-in link has expired or was already used. Start again.',
};

export function SignIn({ initialIssue = null }: { initialIssue?: AuthIssue | null } = {}) {
  const [step, setStep] = useState<'email' | 'code'>('email');
  const [email, setEmail] = useState('');
  const [captured, setCaptured] = useState('');
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState(false);
  const [issue, setIssue] = useState<string | null>(initialIssue ? issueText[initialIssue] : null);
  const [note, setNote] = useState<string | null>(null);
  const [resendAt, setResendAt] = useState(0);
  const [now, setNow] = useState(Date.now());
  const codeField = useRef<HTMLInputElement>(null);
  const attempt = useRef(0);
  const request = useRef<AbortController | null>(null);

  useEffect(() => () => { attempt.current++; request.current?.abort(); }, []);

  useEffect(() => { if (step !== 'code') return; const t = setInterval(() => setNow(Date.now()), 1000); return () => clearInterval(t); }, [step]);
  useEffect(() => { if (step === 'code') codeField.current?.focus(); }, [step]);

  async function startOAuth(provider: OAuthProvider) {
    setBusy(true); setIssue(null); setNote(null);
    try { await auth.startOAuth(provider); }
    catch (error) { setBusy(false); setIssue(issueText[error instanceof AuthError ? error.issue : 'rejected']); }
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
      setIssue(issueText[error instanceof AuthError ? error.issue : 'rejected']);
    } finally { if (id === attempt.current) setBusy(false); }
  }

  function submitEmail(event: FormEvent) {
    event.preventDefault();
    const address = auth.normalizeEmail(email);
    if (!address) { setIssue(issueText.invalid_email); return; }
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
    catch (error) { if (id === attempt.current) setIssue(issueText[error instanceof AuthError ? error.issue : 'rejected']); }
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
            <p className="muted">Read your Gradstep library in the browser. Choose a provider or use an email code.</p>
            <div className="oauth-actions" aria-label="Other sign-in methods">
              <button type="button" className="secondary" onClick={() => void startOAuth('google')} disabled={busy} data-testid="oauth-google">Continue with Google</button>
              <button type="button" className="secondary" onClick={() => void startOAuth('apple')} disabled={busy} data-testid="oauth-apple">Continue with Apple</button>
            </div>
            <div className="auth-divider" aria-hidden="true"><span>or</span></div>
            <label>Email
              <input type="email" name="email" autoComplete="email" inputMode="email" autoCapitalize="none" spellCheck={false} required
                value={email} onChange={e => setEmail(e.target.value)} disabled={busy} data-testid="email" />
            </label>
            {issue && <p className="issue" role="alert">{issue}</p>}
            <button type="submit" className="primary" disabled={busy || !email.trim()} data-testid="send-code">{busy ? 'Sending…' : 'Send code'}</button>
            <p className="fine">Use the email address already linked to your Gradstep account. New accounts remain invite-only.</p>
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
