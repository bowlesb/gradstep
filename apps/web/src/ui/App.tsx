import { useCallback, useEffect, useRef, useState } from 'react';
import { type Activity, loadActivity, saveActivity } from '../lib/activity';
import { type Session, auth, config } from '../lib/backend';
import { type DeviceRecord, type Preparation, forgetDevice, loadDevice } from '../lib/keys';
import type { Item } from '../lib/library';
import { supportsX25519 } from '../lib/wire';
import { Brand, Dialog, NOT_YET } from './common';
import { KeySetup } from './Keys';
import { LibraryView } from './Library';
import { Reader } from './Reader';
import { SignIn } from './SignIn';
import { useLibrary } from './useLibrary';

type Ready = Extract<Preparation, { kind: 'ready' }>;

function useSession(): Session | null {
  const [session, setSession] = useState(auth.session);
  useEffect(() => auth.subscribe(setSession), []);
  return session;
}

function usePath(): [string, (path: string) => void] {
  const [path, setPath] = useState(location.pathname);
  useEffect(() => { const pop = () => setPath(location.pathname); addEventListener('popstate', pop); return () => removeEventListener('popstate', pop); }, []);
  const navigate = useCallback((next: string) => { if (next !== location.pathname) history.pushState(null, '', next); setPath(next); }, []);
  return [path, navigate];
}

export function App() {
  const [supported, setSupported] = useState<boolean | null>(null);
  const session = useSession();
  // Keys belong to one account session; another (or no) account never sees them.
  const [prepared, setPrepared] = useState<{ account: string; ready: Ready } | null>(null);
  const account = session?.user.id ?? null;
  const ready = prepared && prepared.account === account ? prepared.ready : null;

  useEffect(() => {
    (async () => setSupported(!!config.url && typeof indexedDB !== 'undefined' && !!crypto?.subtle && await supportsX25519()))();
  }, []);

  if (supported === null) return null;
  if (!supported) return <Unsupported />;
  if (!session) return <SignIn />;
  if (!ready) return <KeySetup key={session.user.id} account={session.user.id} email={session.user.email} onReady={value => setPrepared({ account: session.user.id, ready: value })} onSignOut={() => void auth.signOut()} />;
  return <Signed key={session.user.id} session={session} ready={ready} />;
}

function Unsupported() {
  return (
    <main className="auth-shell"><section className="card auth-card"><Brand />
      <h1>This browser isn’t supported</h1>
      <p className="muted">Gradstep keeps your encryption keys in the browser and needs a current version of Safari (17 or later), Chrome, Edge or Firefox, with site data allowed. Private windows may not work.</p>
    </section></main>
  );
}

function Signed({ session, ready }: { session: Session; ready: Ready }) {
  const account = session.user.id;
  const library = useLibrary(account);
  const [path, navigate] = usePath();
  const [device, setDevice] = useState<DeviceRecord | null>(null);
  const [activity, setActivity] = useState<Map<string, Activity>>(new Map());
  const [menu, setMenu] = useState(false);
  const [signingOut, setSigningOut] = useState(false);
  const [forget, setForget] = useState(false);
  const [chats, setChats] = useState(false);
  const saveTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    let live = true;
    loadDevice(account).then(async record => { if (!live) return; setDevice(record); setActivity(await loadActivity(record)); }).catch(() => {});
    return () => { live = false; };
  }, [account, ready.deviceID]);

  const record = useCallback((itemID: string, value: Activity) => {
    setActivity(previous => {
      const next = new Map(previous); next.set(itemID, value);
      if (device) {
        if (saveTimer.current) clearTimeout(saveTimer.current);
        saveTimer.current = setTimeout(() => { saveActivity(device, next).catch(() => {}); }, 500);
      }
      return next;
    });
  }, [device]);

  const match = /^\/paper\/([0-9a-f-]{36})$/.exec(path);
  const item = match ? library.entries.find((e): e is Item => e.kind === 'item' && e.id === match[1] && e.visible) : undefined;
  useEffect(() => { if (path !== '/' && !match) navigate('/'); }, [path, match, navigate]);

  async function signOut() {
    if (saveTimer.current) clearTimeout(saveTimer.current);
    navigate('/');
    // The session is cleared at once (this view closes); local cleanup follows.
    const loggingOut = auth.signOut();
    if (forget) await forgetDevice(account).catch(() => {});
    else if (device) await saveActivity(device, activity).catch(() => {});
    await loggingOut;
  }

  return (
    <div className="app">
      <header className="topbar">
        <a href="/" className="brand-link" onClick={e => { e.preventDefault(); navigate('/'); }}><Brand small /></a>
        <span className="environment" title="This browser reader uses the staging backend">{config.environment === 'production' ? '' : 'Beta'}</span>
        <nav className="topnav" aria-label="Main">
          <button className="link" aria-current={!match ? 'page' : undefined} onClick={() => navigate('/')}>Library</button>
          <button className="link" onClick={() => setChats(true)}>Chats</button>
        </nav>
        <div className="account">
          <button className="secondary small" aria-haspopup="menu" aria-expanded={menu} onClick={() => setMenu(m => !m)} data-testid="account-menu">
            {session.user.email ?? 'Account'}
          </button>
          {menu && (
            <div className="menu" role="menu">
              <p className="fine">This browser is an approved device.</p>
              <button role="menuitem" className="link" onClick={() => { setMenu(false); setSigningOut(true); }} data-testid="sign-out">Sign out…</button>
            </div>
          )}
        </div>
      </header>
      {match ? (
        item ? <Reader account={account} item={item} saved={activity.get(item.id)} onActivity={record} onBack={() => navigate('/')} />
          : library.state === 'loading' ? <div className="empty"><div className="spinner" aria-label="Loading" /></div>
            : <div className="empty"><p>This paper isn’t in your library.</p><button className="secondary" onClick={() => navigate('/')}>Back to library</button></div>
      ) : (
        <LibraryView library={library} activity={activity} onOpen={paper => navigate(`/paper/${paper.id}`)} />
      )}
      <Dialog open={chats} onClose={() => setChats(false)} title="Chats">
        <h2>Chats</h2>
        <p>Chat is {NOT_YET.charAt(0).toLowerCase() + NOT_YET.slice(1)}</p>
        <div className="dialog-actions"><button className="primary" onClick={() => setChats(false)}>OK</button></div>
      </Dialog>
      <Dialog open={signingOut} onClose={() => setSigningOut(false)} title="Sign out">
        <h2>Sign out?</h2>
        <p className="muted">This browser stays approved, so signing in again won’t need your recovery code.</p>
        <label className="check"><input type="checkbox" checked={forget} onChange={e => setForget(e.target.checked)} data-testid="forget-device" />
          Also remove this browser’s keys and reading places (use on a shared computer)</label>
        <div className="dialog-actions">
          <button className="secondary" onClick={() => setSigningOut(false)}>Cancel</button>
          <button className="primary" onClick={() => void signOut()} data-testid="confirm-sign-out">Sign out</button>
        </div>
      </Dialog>
    </div>
  );
}
