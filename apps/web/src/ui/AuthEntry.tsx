import { useEffect, useState } from 'react';
import { auth, AuthError } from '../lib/backend';
import { OAuthError } from '../lib/oauth';
import { Brand } from './common';
import { authIssueText } from './SignIn';

// Capture/scrub once, before normal routing or any async initialization/adoption. StrictMode may
// mount effects twice; this module-owned entry promise never repeats a consumed exchange.
const callback = typeof location !== 'undefined' && location.pathname === '/auth/callback' ? { url: location.href, origin: location.origin } : null;
let scrubbed = true;
if (callback) { try { history.replaceState(null, '', '/'); } catch { scrubbed = false; } }
const controller = new AbortController();
let task: Promise<void> | null = null;

/** App calls this hook before mounting AccountSession, and returns its node while entry is pending. */
export function useAuthEntry() {
  const [state, setState] = useState<{ loading: boolean; issue?: string }>({ loading: true });
  useEffect(() => {
    let active = true;
    task ??= (async () => {
      if (callback) {
        if (!scrubbed) throw new AuthError('oauth_rejected');
        await auth.completeOAuth(callback.url, callback.origin, controller.signal);
      } else {
        await auth.initialize();
        await auth.returnedToApp(location.origin);
      }
    })();
    task.then(() => { if (active) setState({ loading: false }); }, error => {
      if (active) setState({ loading: false, issue: authIssueText[error instanceof AuthError || error instanceof OAuthError ? error.issue : 'oauth_rejected'] });
    });
    const shown = (event: PageTransitionEvent) => { if (event.persisted) void auth.returnedToApp(location.origin).catch(() => {}); };
    addEventListener('pageshow', shown);
    return () => { active = false; removeEventListener('pageshow', shown); };
  }, []);
  if (!state.loading && !state.issue) return null;
  return <main className="auth-shell"><section className="card auth-card"><Brand />
    <h1>{state.loading ? callback ? 'Finishing sign-in…' : 'Opening Gradstep…' : 'Sign-in wasn’t completed'}</h1>
    {state.issue && <p role="alert" className="issue">{state.issue}</p>}
    {state.loading && callback && <button className="secondary" onClick={() => {
      controller.abort(); setState({ loading: false, issue: authIssueText.oauth_cancelled });
    }}>Cancel sign-in</button>}
    {state.issue && <button className="primary" onClick={() => setState({ loading: false })}>Continue</button>}
  </section></main>;
}
