// Standalone fixture composition: exercises the owned components without changing root-owned App/Feed.
import { StrictMode, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { auth } from '../src/lib/backend';
import { loadPosition, positionsKey } from '../src/lib/podcast-playback';
import { ListenView, PaperListen, PodcastDock, usePodcasts, usePodcastPlayer } from '../src/ui/Podcast';
import '../src/tokens.css';
import '../src/style.css';
const account = '11111111-2222-4333-8444-555555555555', itemID = 'd0000000-0000-4000-8000-000000000001';
function PlayerFixture() {
  const player = usePodcastPlayer(account), podcasts = usePodcasts(account);
  const [passage, setPassage] = useState(''), [added, setAdded] = useState(false);
  const [inLibrary, setInLibrary] = useState(true), [again, setAgain] = useState(false);
  const evidence = useRef<{ held: boolean; pending: ((value: boolean | null) => void)[] }>({ held: false, pending: [] });
  Object.assign(window, { podcastFixture: { player, auth, loadPosition: (id: string) => loadPosition(account, id), positionsKey: () => positionsKey(account),
    holdEvidence: () => { evidence.current.held = true; }, finishEvidence: (value: boolean | null) => { evidence.current.pending.shift()?.(value); } } });
  return <main className="app" style={{ height: '100dvh', display: 'flex', flexDirection: 'column' }}>
    <header style={{ display: 'flex', alignItems: 'center', flexWrap: 'wrap', gap: 12, padding: 12 }}><strong>Gradstep · Podcast fixture</strong>
      <PaperListen account={account} itemID={itemID} title="My library paper title" player={player} onAsked={podcasts.asked}
        openWith={again ? { profile: null } : null} onOpened={() => setAgain(false)} />
      <label><input type="checkbox" checked={inLibrary} onChange={e => setInLibrary(e.target.checked)} /> Paper in library</label></header>
    <section style={{ flex: 1, minHeight: 0, display: 'flex', flexDirection: 'column' }}><div style={{ flex: 1, minHeight: 0, overflow: 'auto', padding: 18 }}>
      <h1>Research Feed · Listen</h1><ListenView podcasts={podcasts} player={player} onTryAgain={() => { setAgain(true); return true; }} />
      <p data-testid="fixture-passage">{passage}</p><p data-testid="fixture-added">{added ? 'Added by explicit action' : ''}</p>
      </div><textarea aria-label="Paper chat composer" placeholder="Ask about the paper" style={{ width: '100%', height: 80, minHeight: 60, flex: 'none', margin: 0 }} />
    </section>
    <PodcastDock player={player} onEvidence={async (_episode, cited) => {
      const opened = evidence.current.held ? await new Promise<boolean | null>(resolve => evidence.current.pending.push(resolve)) : inLibrary;
      if (opened === true) setPassage(cited.quote); return opened;
    }} onAdd={async () => { setAdded(true); }} />
  </main>;
}
function Harness() { const [mounted, setMounted] = useState(true); return <><button style={{ position: 'absolute', right: 10, top: 50, zIndex: 100 }} data-testid="fixture-unmount" onClick={() => setMounted(v => !v)}>{mounted ? 'Unmount fixture' : 'Mount fixture'}</button>{mounted && <PlayerFixture />}</>; }
createRoot(document.getElementById('root')!).render(<StrictMode><Harness /></StrictMode>);
