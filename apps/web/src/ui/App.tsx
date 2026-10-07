import { useCallback, useEffect, useRef, useState, useSyncExternalStore } from 'react';
import { type Activity, loadActivity, saveActivity } from '../lib/activity';
import { type Session, auth, config } from '../lib/backend';
import { type DeviceRecord, type Preparation, forgetDevice, readDevice } from '../lib/keys';
import type { Item } from '../lib/library';
import { supportsX25519 } from '../lib/wire';
import { Brand, Dialog, NOT_YET } from './common';
import { KeySetup } from './Keys';
import { LibraryView } from './Library';
import { type ReaderCache, Reader } from './Reader';
import { SignIn } from './SignIn';
import { useLibrary } from './useLibrary';

type Ready = Extract<Preparation, { kind: 'ready' }>;

function usePath(): [string, (path: string) => void] {
  const [path, setPath] = useState(location.pathname);
  useEffect(() => { const pop = () => setPath(location.pathname); addEventListener('popstate', pop); return () => removeEventListener('popstate', pop); }, []);
  const navigate = useCallback((next: string) => { if (next !== location.pathname) history.pushState(null, '', next); setPath(next); }, []);
  return [path, navigate];
}

export function App() {
  const [supported, setSupported] = useState<boolean | null>(null);
  const { session, generation } = useSyncExternalStore(auth.subscribe, auth.snapshot);

  useEffect(() => {
    (async () => setSupported(!!config.url && typeof indexedDB !== 'undefined' && !!crypto?.subtle && await supportsX25519()))();
  }, []);

  if (supported === null) return null;
  if (!supported) return <Unsupported />;
  if (!session) return <SignIn />;
  return <AccountSession key={generation} session={session} />;
}

/** Refreshing tokens preserves this tree; signing out or starting another login always retires it. */
function AccountSession({ session }: { session: Session }) {
  const [ready, setReady] = useState<Ready | null>(null);
  if (!ready) return <KeySetup account={session.user.id} email={session.user.email} onReady={setReady} onSignOut={() => void auth.signOut()} />;
  return <Signed session={session} ready={ready} />;
}

function Unsupported() {
  return (
    <main className="auth-shell"><section className="card auth-card"><Brand />
      <h1>This browser isn’t supported</h1>
      <p className="muted">Gradstep needs encryption and local key storage, with site data allowed. Try another current browser, or use Gradstep on iPhone, iPad or Mac. Private windows may not work.</p>
    </section></main>
  );
}

function Signed({ session, ready }: { session: Session; ready: Ready }) {
  const account = session.user.id;
  const library = useLibrary(account);
  const [path, navigate] = usePath();
  const [device, setDevice] = useState<DeviceRecord | null>(null);
  const [activity, setActivity] = useState<Map<string, Activity>>(new Map());
  const [activityLoaded, setActivityLoaded] = useState(false);
  const [menu, setMenu] = useState(false);
  const [signingOut, setSigningOut] = useState(false);
  const [forget, setForget] = useState(false);
  const [chats, setChats] = useState(false);
  const [leaving, setLeaving] = useState(false);
  const [signOutError, setSignOutError] = useState<string | null>(null);
  const [readerCache] = useState<ReaderCache>(() => new Map());
  const saveTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    let live = true;
    setActivityLoaded(false);
    readDevice(account).then(async record => {
      if (!record || record.deviceID !== ready.deviceID) return;
      const saved = await loadActivity(record);
      if (!live) return;
      setDevice(record); setActivity(saved);
    }).catch(() => {}).finally(() => { if (live) setActivityLoaded(true); });
    return () => { live = false; if (saveTimer.current) clearTimeout(saveTimer.current); readerCache.clear(); };
  }, [account, ready.deviceID]);

  const record = useCallback((itemID: string, value: Activity) => {
    if (!activityLoaded || leaving) return;
    setActivity(previous => {
      const next = new Map(previous); next.set(itemID, value);
      return next;
    });
  }, [activityLoaded, leaving]);

  useEffect(() => {
    if (!device || leaving) return;
    const timer = setTimeout(() => { saveActivity(device, activity).catch(() => {}); }, 500);
    saveTimer.current = timer;
    return () => clearTimeout(timer);
  }, [device, activity, leaving]);

  const match = /^\/paper\/([0-9a-f-]{36})$/.exec(path);
  const item = match ? library.entries.find((e): e is Item => e.kind === 'item' && e.id === match[1] && e.visible) : undefined;
  useEffect(() => { if (path !== '/' && !match) navigate('/'); }, [path, match, navigate]);

  async function signOut() {
    if (leaving) return;
    const owner = auth.snapshot();
    setLeaving(true); setSignOutError(null);
    if (saveTimer.current) clearTimeout(saveTimer.current);
    try {
      // Finish local removal before another login can prepare this device. Failure stays visible and retryable.
      if (forget) await forgetDevice(account);
      else if (device) await saveActivity(device, activity).catch(() => {});
      if (owner.signal.aborted || owner.generation !== auth.snapshot().generation) return;
      navigate('/');
      await auth.signOut(owner.generation);
    } catch {
      if (!owner.signal.aborted) { setSignOutError('Couldn’t remove this browser’s keys. Try again.'); setLeaving(false); }
    }
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
        // A direct paper URL can finish loading the library before local decryption. Mounting the
        // reader then would record the top of the paper before its saved place could be restored.
        item && !activityLoaded ? <div className="empty" role="status" aria-label="Opening paper"><div className="spinner" /><p>Opening the paper…</p></div>
          : item ? <Reader cache={readerCache} account={account} item={item} saved={activity.get(item.id)} onActivity={record} onBack={() => navigate('/')} />
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
      <Dialog open={signingOut} onClose={() => { if (!leaving) setSigningOut(false); }} title="Sign out">
        <h2>Sign out?</h2>
        <p className="muted">This browser stays approved, so signing in again won’t need your recovery code.</p>
        <label className="check"><input type="checkbox" checked={forget} disabled={leaving} onChange={e => setForget(e.target.checked)} data-testid="forget-device" />
          Also remove this browser’s keys and reading places (use on a shared computer)</label>
        {signOutError && <p className="issue" role="alert">{signOutError}</p>}
        <div className="dialog-actions">
          <button className="secondary" disabled={leaving} onClick={() => setSigningOut(false)}>Cancel</button>
          <button className="primary" disabled={leaving} onClick={() => void signOut()} data-testid="confirm-sign-out">{leaving ? 'Signing out…' : 'Sign out'}</button>
        </div>
      </Dialog>
    </div>
  );
}
