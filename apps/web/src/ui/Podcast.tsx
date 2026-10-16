// Paper podcasts in the browser (docs/architecture/PAPER_PODCASTS.md): the Feed's Listen filter and a player docked
// under the workspace. The dock takes its own row of the app's column, so the workspace (reader, chat composer and
// selection actions) shrinks above it instead of being covered. Audio is fetched once per play through a single-use
// grant, verified (length and SHA-256) and played from an in-memory Blob URL; nothing is kept after Stop or sign-out.
import { type ReactNode, useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react';
import { authorLine } from '../lib/authors';
import { auth, BackendError } from '../lib/backend';
import { type Capabilities, type Chapter, type Episode, type EpisodeDetail, type Evidence, downloadEpisodeAudio, podcastCatalog, podcastEpisode, podcastStates, revocationPollDelay, podcastPaper, podcastQuote, podcastStart, podcastStatus, podcastCancel, jobTerminal, statusPollDelay, type Job, type Quote, type PaperPodcast, type RequestResult, podcastUploadSource, type DeviceSourceText, type DeviceSourceDescriptor, DEFAULT_LENGTH, aboutMinutes,
  type Mine, type MineRequest, mineCheckDelay, MINE_CHECK_LIMIT_MS, expectedWait, plainProviders } from '../lib/podcast';
import { SKIP_MS, SPEEDS, chapterAt, clock, durationLabel, loadPosition, positionText, resumeAt, savePosition, segmentAt, clearPositions, removePosition } from '../lib/podcast-playback';
import { Icon } from './PodcastIcons';
import { Dialog } from './common';
import { asOf } from '../lib/retry';
import './Podcast.css';
import { useMedia } from './prefs';
import { PodcastRequests, PodcastTrackingError } from '../lib/podcast-requests';

// Auth refresh preserves generation; sign-out, account change and same-account re-login retire every operation.
function useAccountOwner(account: string) {
  const snapshot = useSyncExternalStore(auth.subscribe, auth.snapshot);
  return useMemo(() => snapshot, [account, snapshot.generation]);
}

// Older deployments may not have the podcast function yet. Keep this distinct from a failed
// download or an uncertain paid request; only read-only catalog/paper discovery uses it.
const featureUnavailable = (error: unknown) => error instanceof BackendError
  && (error.status === 404 || error.status === 405 || error.code === 'podcast_unavailable');

// ---------- Catalog ----------

export function usePodcasts(account: string) {
  const owner = useAccountOwner(account);
  const [episodes, setEpisodes] = useState<Episode[]>([]);
  const [capabilities, setCapabilities] = useState<Capabilities | null>(null);
  const [state, setState] = useState<'idle' | 'loading' | 'loaded' | 'failed' | 'unavailable'>('idle');
  const [next, setNext] = useState<string | null>(null);
  // When the list shown was last loaded: a failed check keeps it, said as of then (RESILIENCE.md fix 10).
  const [loadedAt, setLoadedAt] = useState<number | null>(null);
  // Listen's own section (migration 076): your ready episodes and the ones you asked for.
  const [mine, setMine] = useState<Mine | null>(null);
  const request = useRef<AbortController | null>(null);
  const mineRequest = useRef<AbortController | null>(null);
  const load = useCallback((more = false) => {
    if (owner.signal.aborted || owner.session?.user.id !== account) return;
    request.current?.abort();
    const controller = new AbortController();
    request.current = controller;
    setState('loading');
    podcastCatalog(account, more ? next : null, controller.signal).then(catalog => {
      if (controller.signal.aborted || owner.signal.aborted) return;
      setCapabilities(catalog.capabilities);
      setEpisodes(previous => {
        if (!more) return catalog.episodes;
        const known = new Set(previous.map(e => e.releaseID));
        return [...previous, ...catalog.episodes.filter(e => !known.has(e.releaseID))].slice(0, 500);
      });
      if (!more) setMine(catalog.mine);
      setNext(catalog.next); setState('loaded'); setLoadedAt(Date.now());
    }, error => { if (!controller.signal.aborted && !owner.signal.aborted) setState(featureUnavailable(error) ? 'unavailable' : 'failed'); });
  }, [account, next, owner]);
  /** Your episodes again (returning to Listen or to the tab, after asking, and while one is being made): the first
   * page's own section only, leaving the shared list as it is. A failed check keeps what is shown. */
  const refreshMine = useCallback(() => {
    if (owner.signal.aborted || owner.session?.user.id !== account) return;
    mineRequest.current?.abort();
    const controller = new AbortController();
    mineRequest.current = controller;
    podcastCatalog(account, null, controller.signal).then(catalog => {
      if (controller.signal.aborted || owner.signal.aborted) return;
      setCapabilities(catalog.capabilities); setMine(catalog.mine);
    }, error => {
      // Keep what is shown on a failed check (the next one tries again); a server without podcasts says so.
      if (!controller.signal.aborted && !owner.signal.aborted && featureUnavailable(error)) { setState('unavailable'); setMine(null); }
    });
  }, [account, owner]);
  const latestRefresh = useRef(refreshMine); latestRefresh.current = refreshMine;
  // While one is being made: check after 15 s, 30 s, then every minute, only while the tab is visible, for at most 45
  // minutes; coming back to the tab checks at once. Asking again (or opening Listen) starts over.
  const making = !!mine?.requests.some(r => r.status === 'making');
  const [watchRevision, setWatchRevision] = useState(0);
  useEffect(() => {
    if (!making || owner.signal.aborted) return;
    const started = Date.now();
    let checks = 0, timer: ReturnType<typeof setTimeout> | undefined;
    const schedule = () => {
      if (Date.now() - started >= MINE_CHECK_LIMIT_MS) return;
      timer = setTimeout(() => { if (!document.hidden && navigator.onLine) latestRefresh.current(); checks += 1; schedule(); }, mineCheckDelay(checks));
    };
    schedule();
    return () => clearTimeout(timer);
  }, [making, owner, watchRevision]);
  useEffect(() => {
    let last = 0;
    const wake = () => {
      if (document.hidden || !navigator.onLine || (state !== 'loaded' && !making) || Date.now() - last < 5_000) return;
      last = Date.now(); latestRefresh.current(); setWatchRevision(v => v + 1);
    };
    document.addEventListener('visibilitychange', wake); window.addEventListener('online', wake);
    return () => { document.removeEventListener('visibilitychange', wake); window.removeEventListener('online', wake); };
  }, [state, making]);
  const asked = useCallback(() => { latestRefresh.current(); setWatchRevision(v => v + 1); }, []);
  /** Your own episode not yet played in this browser. */
  const isNew = useCallback((episode: Episode) => episode.scope === 'private' && loadPosition(account, episode.releaseID, owner.session?.lifetime ?? 'signed-out') === null,
    [account, owner]);
  useEffect(() => {
    const retire = () => { request.current?.abort(); mineRequest.current?.abort(); setEpisodes([]); setCapabilities(null); setNext(null); setState('idle'); setLoadedAt(null); setMine(null); };
    owner.signal.addEventListener('abort', retire, { once: true });
    if (owner.signal.aborted) retire();
    return () => { owner.signal.removeEventListener('abort', retire); retire(); };
  }, [owner]);
  return { episodes, capabilities, state, next, load, loadedAt, mine, refreshMine, asked, isNew };
}
export type PodcastsModel = ReturnType<typeof usePodcasts>;

/** Additive Feed filter: root keeps its For you/topic/category selection intact behind this view. */
export interface ListenFilter { selected: boolean; select: (selected: boolean) => void; view: ReactNode }
export function ListenFilterButton({ selected, onSelect, rail = false }: { selected: boolean; onSelect: () => void; rail?: boolean }) {
  return <button className={`${rail ? 'rail-item' : 'chip listen-chip'}${selected ? ' selected' : ''}`} aria-pressed={selected}
    onClick={onSelect} data-testid="podcast-listen"><Icon name="headphones" size={14} /><span>Listen</span></button>;
}

function Badges({ episode, fresh = false }: { episode: Episode; fresh?: boolean }) {
  return (
    <span className="podcast-badges">
      {fresh && <span className="badge new" data-testid="podcast-new">New</span>}
      <span className="badge ai" title="Generated speech, from the paper’s own text">AI audio</span>
      {episode.scope === 'private' && <span className="badge private" title="Only your account can play it">Private</span>}
      {episode.fixture && <span className="badge fixture" title="Labeled synthetic test audio, not a real episode">Synthetic fixture</span>}
    </span>
  );
}

/** One episode card (shared or your own): title, authors, badges, year, duration, topic and Play. */
function EpisodeCard({ episode: e, player, fresh = false }: { episode: Episode; player: PlayerModel; fresh?: boolean }) {
  const current = player.episode?.releaseID === e.releaseID;
  const label = current && player.playing ? 'Pause' : current && player.status === 'loading' ? 'Loading…' : current ? 'Resume' : 'Play';
  return (
    <li className={`feed-card podcast-card${current ? ' current' : ''}`} data-testid="podcast-card" data-scope={e.scope}>
      <span className="feed-title" id={`episode-${e.releaseID}`}>{e.title}</span>
      {e.authors.length > 0 && <div className="feed-authors">{authorLine(e.authors)}</div>}
      <Badges episode={e} fresh={fresh && !current} />
      <div className="feed-meta">
        <span>{e.year ?? ''}</span><span aria-label={`Duration ${durationLabel(e.durationMs)}`}>{durationLabel(e.durationMs)}</span>
        {e.topic && <span className="tag static">{e.topic}</span>}
        <button className="pill accent podcast-play" aria-describedby={`episode-${e.releaseID}`} disabled={current && player.status === 'loading'}
          onClick={() => (current ? player.toggle() : player.open(e))} data-testid="podcast-play">
          <Icon name={current && player.playing ? 'pause' : 'play'} size={12} /> {label}</button>
      </div>
    </li>
  );
}

/** An episode you asked for: being made (you can leave; it appears here), or couldn't be made, with Try again. */
function RequestCard({ request: r, onTryAgain }: { request: MineRequest; onTryAgain?: (request: MineRequest) => boolean }) {
  const [elsewhere, setElsewhere] = useState(false);
  const wait = expectedWait(r.targetSeconds);
  return (
    <li className={`feed-card podcast-card podcast-request ${r.status}`} data-testid="podcast-request" data-status={r.status}>
      <span className="feed-title">{r.title ?? 'Your episode'}</span>
      {r.status === 'making' ? <>
        <p className="podcast-request-state" role="status"><span className="podcast-wave" aria-hidden="true"><i /><i /><i /><i /></span> Making your episode</p>
        <p className="fine">{[r.label, wait.charAt(0).toLowerCase() + wait.slice(1)].filter(Boolean).join(' · ')}</p>
      </> : <>
        <p className="podcast-request-state">Couldn’t make this episode.</p>
        {onTryAgain && <button className="secondary small" onClick={() => setElsewhere(!onTryAgain(r))} data-testid="podcast-request-retry">Try again</button>}
        {elsewhere && <p className="fine">Open the paper in your library, then choose Listen to try again.</p>}
      </>}
    </li>
  );
}

/** The Feed's Listen filter: your episodes (being made, ready), then ready shared episodes. Playing never adds a paper
 * or starts a paid generation. */
export function ListenView({ podcasts, player, onTryAgain }: { podcasts: PodcastsModel; player: PlayerModel; onTryAgain?: (request: MineRequest) => boolean }) {
  const { episodes, capabilities, state, next, load, loadedAt, mine, refreshMine, isNew } = podcasts;
  useEffect(() => { if (state === 'idle') load(); }, [state, load]);
  // Coming back to Listen checks your own episodes again (one being made may be ready now).
  const opened = useRef(false);
  useEffect(() => { if (!opened.current && state === 'loaded') { opened.current = true; refreshMine(); } }, [state, refreshMine]);
  const own = (mine?.requests.length ?? 0) + (mine?.episodes.length ?? 0) > 0;
  if (state === 'loading' && !episodes.length && !own) return <div className="empty"><div className="spinner" aria-label="Loading episodes" /></div>;
  if (state === 'failed' && !episodes.length && !own) return (
    <div className="empty"><p>Episodes aren’t available right now. Try again in a moment.</p><button className="secondary" onClick={() => load()}>Try again</button></div>);
  if (state === 'unavailable' || (capabilities && (!capabilities.catalog || !capabilities.delivery) && !own)) return (
    <div className="empty" data-testid="podcast-unavailable"><p><strong>Listening isn’t available yet.</strong></p>
      <p className="muted">Shared paper episodes appear here once they’re published. Reading and chat are unaffected.</p></div>);
  if (state === 'loaded' && !episodes.length && !own) return (
    <div className="empty"><p><strong>No episodes yet.</strong></p><p className="muted">Pick a topic to discover papers. New episodes appear here when they’re ready.</p></div>);
  return (
    <>
      <div className="feed-status"><span>{episodes.length} shared {episodes.length === 1 ? 'episode' : 'episodes'} · AI-generated from each paper’s text</span>
        <button className="link small-link" onClick={() => { load(); refreshMine(); }} disabled={state === 'loading'}><Icon name="refresh" size={12} /> {state === 'loading' ? 'Checking…' : 'Check for new episodes'}</button></div>
      {state === 'failed' && <p className="feed-note issue" role="status" data-testid="podcast-stale">Couldn’t check for new episodes. These are the episodes from {loadedAt ? asOf(loadedAt) : 'earlier'}.</p>}
      {own && mine && <section className="podcast-own" aria-labelledby="podcast-own-title" data-testid="podcast-own">
        <h3 id="podcast-own-title" className="podcast-section">Your episodes</h3>
        <ul className="feed-grid">
          {mine.requests.map(r => <RequestCard key={r.requestID} request={r} onTryAgain={onTryAgain} />)}
          {mine.episodes.map(e => <EpisodeCard key={e.releaseID} episode={e} player={player} fresh={isNew(e)} />)}
        </ul>
      </section>}
      {own && episodes.length > 0 && <h3 className="podcast-section">Shared episodes</h3>}
      <ul className="feed-grid" data-testid="podcast-grid">
        {episodes.map(e => <EpisodeCard key={e.releaseID} episode={e} player={player} />)}
      </ul>
      {next && <div className="podcast-more"><button className="secondary small" onClick={() => load(true)} disabled={state === 'loading'}>More episodes</button></div>}
    </>
  );
}

// ---------- Player ----------

const message = (error: unknown) => {
  const code = error instanceof BackendError ? error.code : '';
  if (code === 'podcast_transfer_limit') return 'You’ve reached this month’s listening download allowance. Already open episodes keep playing.';
  if (code === 'podcast_integrity_failed') return 'This episode didn’t match its verified checksum, so it wasn’t played. Try again.';
  if (code === 'connection' || code === 'request_failed') return 'Couldn’t download this episode. Check your connection and try again.';
  if (code === 'podcast_unavailable' || code === 'podcast_release_unavailable' || code === 'podcast_withdrawn') return 'This episode is no longer available.';
  return 'Couldn’t play this episode right now.';
};
const savingInterval = 15_000;

/** One account lifetime owns the media element, downloads, polling and local positions. */
export function usePodcastPlayer(account: string) {
  const owner = useAccountOwner(account);
  const lifetime = owner.session?.lifetime ?? 'signed-out';
  const [episode, setEpisode] = useState<Episode | null>(null);
  const [detail, setDetail] = useState<EpisodeDetail | null>(null);
  const [status, setStatus] = useState<'idle' | 'loading' | 'ready' | 'failed' | 'revoked'>('idle');
  const [issue, setIssue] = useState<string | null>(null);
  const [replacementID, setReplacement] = useState<string | null>(null);
  const [playing, setPlaying] = useState(false);
  const [positionMs, setPosition] = useState(0);
  const [rate, setRateState] = useState(1);
  const audio = useRef<HTMLAudioElement | null>(null);
  const [element, setElement] = useState<HTMLAudioElement | null>(null);
  const objectURL = useRef<string | null>(null);
  const loading = useRef<AbortController | null>(null);
  const session = useRef<{ id: string; startedAt: number; sequence: number; lastSaved: number } | null>(null);
  const current = useRef<{ episode: Episode | null; detail: EpisodeDetail | null; status: typeof status }>({ episode: null, detail: null, status: 'idle' });
  const active = useRef(false);
  const currentRate = useRef(rate); currentRate.current = rate;
  const valid = useCallback(() => active.current && !owner.signal.aborted && auth.snapshot().generation === owner.generation
    && owner.session?.user.id === account, [account, owner]);
  const save = useCallback((completed = false) => {
    const e = current.current.episode, element = audio.current, s = session.current;
    if (!valid() || !e || !element || !s || !objectURL.current) return;
    const durationMs = Math.round((Number.isFinite(element.duration) ? element.duration : e.durationMs / 1000) * 1000);
    s.sequence += 1; s.lastSaved = Date.now();
    savePosition(account, e.releaseID, { positionMs: Math.min(durationMs, Math.max(0, Math.round(element.currentTime * 1000))), durationMs,
      completed: completed || element.ended, session: s.id, sessionStartedAt: s.startedAt, sequence: s.sequence, savedAt: s.lastSaved }, lifetime);
  }, [account, lifetime, valid]);
  const release = useCallback(() => {
    loading.current?.abort(); loading.current = null;
    const url = objectURL.current; objectURL.current = null; session.current = null;
    // Clear save authority before pause dispatches its event.
    const element = audio.current;
    if (element) { element.pause(); element.removeAttribute('src'); element.load(); }
    if (url) URL.revokeObjectURL(url);
    if ('mediaSession' in navigator) { navigator.mediaSession.metadata = null; navigator.mediaSession.playbackState = 'none'; }
  }, []);
  const reset = useCallback(() => {
    current.current = { episode: null, detail: null, status: 'idle' };
    setEpisode(null); setDetail(null); setStatus('idle'); setIssue(null); setPlaying(false); setPosition(0); setReplacement(null);
  }, []);
  const stop = useCallback(() => { if (!valid()) return; save(); release(); reset(); }, [valid, release, reset, save]);
  useEffect(() => {
    active.current = true; reset();
    const retire = () => { active.current = false; release(); clearPositions(account, lifetime); reset(); };
    owner.signal.addEventListener('abort', retire, { once: true });
    if (owner.signal.aborted) retire();
    return () => { owner.signal.removeEventListener('abort', retire); save(); active.current = false; release(); reset(); };
  }, [owner, account, lifetime, release, reset, save]);

  const revoke = useCallback((id: string, replacement: string | null) => {
    if (!valid() || current.current.episode?.releaseID !== id) return;
    release(); removePosition(account, id, lifetime);
    current.current.status = 'revoked'; current.current.detail = null;
    setDetail(null); setStatus('revoked'); setPlaying(false); setPosition(0); setReplacement(replacement);
    setIssue('This episode is no longer available. Its audio and saved position were removed.');
  }, [valid, release, account, lifetime]);
  const open = useCallback(async (next: Episode) => {
    if (!valid()) return;
    save(); release();
    const controller = new AbortController(); loading.current = controller;
    const aborted = () => controller.abort(); owner.signal.addEventListener('abort', aborted, { once: true });
    const live = () => valid() && !controller.signal.aborted && loading.current === controller;
    current.current = { episode: next, detail: null, status: 'loading' };
    setEpisode(next); setDetail(null); setStatus('loading'); setIssue(null); setPlaying(false); setPosition(0); setReplacement(null);
    try {
      const states = await podcastStates(account, [next.releaseID], controller.signal);
      if (!live()) return;
      const state = states.get(next.releaseID)!;
      if (state.state !== 'ready') { revoke(next.releaseID, state.replacementID); return; }
      const loaded = await podcastEpisode(account, next.releaseID, controller.signal);
      if (!live()) return;
      if (loaded.state !== 'ready') { revoke(next.releaseID, loaded.replacementID); return; }
      if (loaded.audio.sha256 !== next.audio.sha256 || loaded.audio.bytes !== next.audio.bytes || loaded.audio.mediaType !== next.audio.mediaType
        || loaded.documentID !== next.documentID) throw new BackendError('podcast_integrity_failed');
      // Private releases intentionally have no server title; use the title already supplied by the library.
      if (loaded.scope === 'private') loaded.title = next.title;
      current.current.detail = loaded; setDetail(loaded);
      const blob = await downloadEpisodeAudio(account, loaded, controller.signal);
      if (!live()) return;
      const element = audio.current;
      if (!element) throw new BackendError('cancelled');
      const url = URL.createObjectURL(blob); objectURL.current = url;
      const start = resumeAt(loadPosition(account, loaded.releaseID, lifetime), loaded.durationMs);
      await new Promise<void>((resolve, reject) => {
        const clean = () => { clearTimeout(timeout); element.removeEventListener('loadedmetadata', done); element.removeEventListener('error', fail); controller.signal.removeEventListener('abort', cancel); };
        const done = () => { clean(); resolve(); };
        const fail = () => { clean(); reject(new BackendError('podcast_unplayable')); };
        const cancel = () => { clean(); reject(new BackendError('cancelled')); };
        const timeout = setTimeout(fail, 15_000);
        element.addEventListener('loadedmetadata', done); element.addEventListener('error', fail); controller.signal.addEventListener('abort', cancel, { once: true });
        element.src = url; element.load();
      });
      if (!live()) return;
      session.current = { id: crypto.randomUUID(), startedAt: Date.now(), sequence: 0, lastSaved: Date.now() };
      element.currentTime = start / 1000; element.playbackRate = currentRate.current; setPosition(start);
      current.current.status = 'ready'; setStatus('ready');
      try { await element.play(); } catch { if (live()) setIssue('Press play to start.'); }
    } catch (error) {
      if (!live()) return;
      release(); current.current.status = 'failed'; setStatus('failed');
      setIssue(error instanceof BackendError && error.code === 'podcast_unplayable' ? 'This browser can’t play this episode’s audio.' : message(error));
    } finally { owner.signal.removeEventListener('abort', aborted); }
  }, [account, lifetime, owner, valid, revoke, release, save]);
  const play = useCallback(() => {
    const element = audio.current;
    if (!valid() || !element) return;
    if (current.current.status === 'failed' && current.current.episode) { void open(current.current.episode); return; }
    if (current.current.status !== 'ready' || !element.paused) return;
    const expected = objectURL.current;
    void element.play().then(() => { if (valid() && objectURL.current === expected) setIssue(null); }, () => {
      if (valid() && objectURL.current === expected) setIssue('Press play to start.');
    });
  }, [valid, open]);
  const pause = useCallback(() => { if (valid() && audio.current && !audio.current.paused) audio.current.pause(); }, [valid]);
  const toggle = useCallback(() => { if (audio.current?.paused) play(); else pause(); }, [play, pause]);
  const seek = useCallback((ms: number) => {
    const element = audio.current;
    if (!valid() || !element || current.current.status !== 'ready' || !Number.isFinite(ms)) return;
    const end = Number.isFinite(element.duration) ? element.duration * 1000 : current.current.episode?.durationMs ?? 0;
    element.currentTime = Math.max(0, Math.min(ms, end)) / 1000; setPosition(Math.round(element.currentTime * 1000)); save();
  }, [valid, save]);
  const skip = useCallback((delta: number) => { if (audio.current) seek(audio.current.currentTime * 1000 + delta); }, [seek]);
  const setRate = useCallback((value: number) => { if (!valid() || !SPEEDS.some(s => s === value)) return; setRateState(value); if (audio.current) audio.current.playbackRate = value; }, [valid]);
  const bind = useCallback((node: HTMLAudioElement | null) => { if (node) audio.current = node; setElement(node); }, []);
  useEffect(() => {
    if (!element) return;
    let lastChapter: string | null = null;
    const time = () => {
      if (!valid() || !objectURL.current) return;
      const ms = Math.round(element.currentTime * 1000); setPosition(ms);
      const chapter = current.current.detail ? chapterAt(current.current.detail.chapters, ms)?.id ?? null : null;
      if (chapter !== lastChapter) { const changed = lastChapter !== null; lastChapter = chapter; if (changed) save(); }
      if (!element.paused && session.current && Date.now() - session.current.lastSaved >= savingInterval) save();
      if ('mediaSession' in navigator && Number.isFinite(element.duration) && element.duration > 0) {
        try { navigator.mediaSession.setPositionState({ duration: element.duration, playbackRate: element.playbackRate, position: Math.min(element.currentTime, element.duration) }); } catch { /* optional API */ }
      }
    };
    const ownsAudio = () => valid() && !!objectURL.current && current.current.status === 'ready';
    const playing = () => { if (ownsAudio()) { setPlaying(true); if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'playing'; } };
    const paused = () => { if (ownsAudio()) { setPlaying(false); save(); if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'paused'; } };
    const ended = () => { if (ownsAudio()) { setPlaying(false); save(true); if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'paused'; } };
    const hide = () => { if (document.visibilityState === 'hidden') save(); };
    const leave = () => save();
    element.addEventListener('timeupdate', time); element.addEventListener('play', playing); element.addEventListener('pause', paused); element.addEventListener('ended', ended);
    document.addEventListener('visibilitychange', hide); window.addEventListener('pagehide', leave);
    return () => {
      element.removeEventListener('timeupdate', time); element.removeEventListener('play', playing); element.removeEventListener('pause', paused); element.removeEventListener('ended', ended);
      document.removeEventListener('visibilitychange', hide); window.removeEventListener('pagehide', leave);
    };
  }, [element, valid, save]);
  useEffect(() => {
    if (!('mediaSession' in navigator) || !episode || !valid()) return;
    const media = navigator.mediaSession;
    media.metadata = new MediaMetadata({ title: episode.title, artist: episode.fixture ? 'Gradstep · Synthetic fixture' : 'Gradstep · AI audio', album: episode.topic ?? 'Paper podcast' });
    const handlers: [MediaSessionAction, MediaSessionActionHandler][] = [
      ['play', play], ['pause', pause], ['stop', stop], ['seekbackward', () => skip(-SKIP_MS)], ['seekforward', () => skip(SKIP_MS)],
      ['seekto', value => { if (typeof value.seekTime === 'number') seek(value.seekTime * 1000); }],
    ];
    for (const [action, handler] of handlers) { try { media.setActionHandler(action, handler); } catch { /* optional action */ } }
    return () => { for (const [action] of handlers) { try { media.setActionHandler(action, null); } catch { /* optional action */ } } };
  }, [episode, valid, play, pause, stop, skip, seek]);

  // One read/minute while visible, one/5 minutes hidden. Reconnect checks immediately, visibility wakes are throttled.
  useEffect(() => {
    if (!episode || status !== 'ready') return;
    const controller = new AbortController(); let timer: ReturnType<typeof setTimeout> | undefined, inFlight = false, last = 0;
    const schedule = () => { clearTimeout(timer); timer = setTimeout(() => void check(), revocationPollDelay(document.hidden)); };
    const check = async () => {
      if (controller.signal.aborted || !valid() || inFlight) return;
      if (!navigator.onLine) { schedule(); return; }
      inFlight = true; last = Date.now();
      try {
        const states = await podcastStates(account, [episode.releaseID], controller.signal);
        if (!controller.signal.aborted && valid()) { const s = states.get(episode.releaseID)!; if (s.state !== 'ready') revoke(episode.releaseID, s.replacementID); }
      } catch { /* Keep verified audio on transient failure; only an authoritative state revokes it. */ }
      finally { inFlight = false; if (!controller.signal.aborted && valid()) schedule(); }
    };
    const wake = () => { if (Date.now() - last >= 10_000) { clearTimeout(timer); void check(); } };
    schedule(); window.addEventListener('online', wake); document.addEventListener('visibilitychange', wake);
    return () => { controller.abort(); clearTimeout(timer); window.removeEventListener('online', wake); document.removeEventListener('visibilitychange', wake); };
  }, [episode, status, valid, account, revoke]);
  const openReplacement = useCallback(async () => {
    if (!replacementID || !valid()) return;
    const controller = new AbortController(); loading.current?.abort(); loading.current = controller;
    try { const replacement = await podcastEpisode(account, replacementID, controller.signal); if (valid() && !controller.signal.aborted) await open(replacement); }
    catch (e) { if (valid() && !controller.signal.aborted) setIssue(message(e)); }
  }, [account, replacementID, valid, open]);
  return { episode, detail, status, issue, playing, positionMs, rate, open, play, pause, toggle, seek, skip, setRate, stop, bind, setIssue, replacementID, openReplacement };
}
export type PlayerModel = ReturnType<typeof usePodcastPlayer>;

/** Evidence: true opens the passage, false offers Add, null means the navigation was superseded. */
export function PodcastDock({ player, onEvidence, onAdd }: { player: PlayerModel; onEvidence: (episode: Episode, evidence: Evidence) => boolean | null | Promise<boolean | null>; onAdd?: (episode: Episode) => Promise<void> }) {
  const { episode, detail, status, issue, playing, positionMs, rate } = player;
  const [expanded, setExpanded] = useState(false);
  const [notice, setNotice] = useState<Episode | null>(null);
  const [adding, setAdding] = useState(false);
  const [addNotice, setAddNotice] = useState<string | null>(null);
  const evidenceOwner = useRef(episode?.releaseID); evidenceOwner.current = episode?.releaseID;
  const [follow, setFollow] = useState(true);
  const reduced = useMedia('(prefers-reduced-motion: reduce)');
  const transcript = useRef<HTMLOListElement>(null);
  const durationMs = detail?.durationMs ?? episode?.durationMs ?? 0;
  const segment = detail ? segmentAt(detail.transcript.segments, positionMs) : null;
  const chapter = detail ? chapterAt(detail.chapters, positionMs) : null;
  const chapterIndex = useMemo(() => new Map(detail?.chapters.map(c => [c.id, c]) ?? []), [detail]);
  useEffect(() => { setNotice(null); setFollow(true); setAdding(false); setAddNotice(null); }, [episode?.releaseID]);
  useEffect(() => {
    if (!expanded || !follow || !segment) return;
    transcript.current?.querySelector<HTMLElement>(`[data-segment="${segment.id}"]`)?.scrollIntoView({ block: 'nearest', behavior: reduced ? 'auto' : 'smooth' });
  }, [segment?.id, expanded, follow, reduced]);
  // One persistent element: the hook binds its events once, and Stop clears its source.
  const audioElement = <audio ref={player.bind} preload="auto" hidden data-testid="podcast-audio" />;
  // Always a fragment with the element first, so it is never remounted when the dock appears or closes.
  if (!episode) return <>{audioElement}</>;
  const ready = status === 'ready';
  const go = (c: Chapter) => player.seek(c.startMs);
  return (
    <>{audioElement}
    <section className={`podcast-dock${expanded ? ' expanded' : ''}`} aria-label="Podcast player" data-testid="podcast-dock">
      <div className="dock-bar">
        <div className="dock-controls" role="group" aria-label="Playback">
          <button className="icon-button" onClick={() => player.skip(-SKIP_MS)} disabled={!ready} aria-label="Back 15 seconds" title="Back 15 seconds"><Icon name="back15" /></button>
          <button className="icon-button dock-play" onClick={player.toggle} disabled={status === 'loading' || status === 'idle' || status === 'revoked'} aria-label={playing ? 'Pause' : 'Play'}
            title={playing ? 'Pause' : 'Play'} data-testid="podcast-toggle">
            {status === 'loading' ? <span className="spinner small" aria-hidden="true" /> : <Icon name={playing ? 'pause' : 'play'} size={18} />}</button>
          <button className="icon-button" onClick={() => player.skip(SKIP_MS)} disabled={!ready} aria-label="Forward 15 seconds" title="Forward 15 seconds"><Icon name="forward15" /></button>
        </div>
        <div className="dock-title">
          <strong title={episode.title}>{episode.title}</strong>
          <span className="dock-sub">
            <span className="badge ai">AI audio</span>{episode.fixture && <span className="badge fixture">Synthetic fixture</span>}
            <span aria-live="polite" className="dock-status">{status === 'loading' ? 'Downloading and verifying…' : chapter ? chapter.title : ''}</span>
          </span>
        </div>
        <div className="dock-progress">
          <span className="dock-time mono" aria-hidden="true">{clock(positionMs)}</span>
          <input type="range" min={0} max={Math.max(1, durationMs)} step={1000} value={Math.min(positionMs, durationMs)} disabled={!ready}
            aria-label="Playback position" aria-valuetext={positionText(positionMs, durationMs)} data-testid="podcast-position"
            onChange={event => player.seek(Number(event.target.value))} />
          <span className="dock-time mono" aria-hidden="true">{clock(durationMs)}</span>
        </div>
        <label className="dock-speed"><span className="visually-hidden">Playback speed</span>
          <select value={rate} onChange={event => player.setRate(Number(event.target.value))} aria-label="Playback speed" data-testid="podcast-speed">
            {SPEEDS.map(s => <option key={s} value={s}>{s}×</option>)}</select></label>
        <div className="dock-actions">
          <button className={`icon-button${expanded ? ' on' : ''}`} onClick={() => setExpanded(e => !e)} aria-expanded={expanded} aria-controls="podcast-details"
            aria-label={expanded ? 'Hide transcript and chapters' : 'Show transcript and chapters'} title="Transcript and chapters" data-testid="podcast-expand"><Icon name="transcript" /></button>
          <button className="icon-button" onClick={player.stop} aria-label="Stop and close the player" title="Stop" data-testid="podcast-stop"><Icon name="close" /></button>
        </div>
      </div>
      {issue && <p className="issue dock-issue" role="alert">{issue}{player.replacementID && <button className="link" onClick={() => void player.openReplacement()}>Open replacement</button>}</p>}
      {expanded && (
        <div className="dock-details" id="podcast-details">
          {!detail ? <p className="fine dock-wait">The transcript appears when the episode opens.</p> : <>
            <nav className="dock-chapters" aria-label="Chapters">
              <div className="rail-heading">Chapters</div>
              <ol>{detail.chapters.map(c => (
                <li key={c.id}><button className={`dock-chapter${chapter?.id === c.id ? ' on' : ''}`} aria-current={chapter?.id === c.id ? 'true' : undefined}
                  onClick={() => go(c)} disabled={!ready} data-testid="podcast-chapter">
                  <span className="mono faint">{clock(c.startMs)}</span> <span>{c.title}</span></button></li>))}</ol>
            </nav>
            <div className="dock-transcript">
              <div className="rail-heading">Transcript <span className="dock-timing">Timing approximate</span>
                {!follow && <button className="rail-clear" onClick={() => setFollow(true)}>Follow playback</button>}</div>
              {notice && (
                <p className="dock-notice" role="status">This paper isn’t in your library.{' '}
                  {notice.source.url ? <a href={notice.source.url} target="_blank" rel="noopener noreferrer">Open source</a> : null}{onAdd && notice.source.arxivID && <button className="link" disabled={adding} onClick={() => {
                    const id = episode.releaseID; setAdding(true); setAddNotice(null);
                    void onAdd(notice).then(() => { if (evidenceOwner.current === id) setAddNotice('Added. The paper will appear in your library when it is ready.'); },
                      () => { if (evidenceOwner.current === id) setAddNotice('The paper could not be added. Try again from Add paper.'); })
                      .finally(() => { if (evidenceOwner.current === id) setAdding(false); });
                  }}>{adding ? 'Adding…' : 'Add to library'}</button>}{addNotice && <span>{addNotice}</span>}
                  <button className="link" onClick={() => setNotice(null)}>Dismiss</button></p>)}
              <ol ref={transcript} onWheel={() => setFollow(false)} onTouchMove={() => setFollow(false)} data-testid="podcast-transcript">
                {detail.transcript.segments.map((s, index) => {
                  const heading = s.chapter && (index === 0 || detail.transcript.segments[index - 1].chapter !== s.chapter) ? chapterIndex.get(s.chapter) : undefined;
                  return (
                    <li key={s.id} data-segment={s.id} className={`dock-segment ${s.speaker}${segment?.id === s.id ? ' on' : ''}`}>
                      {heading && <div className="dock-segment-chapter">{heading.title}</div>}
                      <button className="dock-segment-text" onClick={() => player.seek(s.startMs)} disabled={!ready} aria-current={segment?.id === s.id ? 'true' : undefined}
                        aria-label={`${detail.transcript.speakers[s.speaker]}, ${clock(s.startMs)}: ${s.text}`} data-testid="podcast-segment">
                        <span className="dock-speaker">{detail.transcript.speakers[s.speaker]}</span> <span className="mono faint">{clock(s.startMs)}</span>
                        <span className="dock-line">{s.text}</span></button>
                      {s.evidence.length > 0 && (
                        <div className="dock-evidence">{s.evidence.map(ev => (
                          <button key={ev.id} className="tag evidence" onClick={async () => {
                              const owner = auth.snapshot(), releaseID = episode.releaseID;
                              try {
                                const opened = await onEvidence(episode, ev);
                                if (owner.signal.aborted || auth.snapshot().generation !== owner.generation || evidenceOwner.current !== releaseID) return;
                                // Only the winning navigation folds the dock. Superseded navigation is neither a jump nor a missing paper.
                                if (opened === true) setExpanded(false); else if (opened === false) setNotice(episode);
                              } catch { /* The host owns navigation/save errors; preserve the transcript. */ }
                            }}
                            title={`From the paper: “${ev.quote}”`} aria-label={`Open the cited passage${ev.section ? ` in section ${ev.section}` : ''}: ${ev.quote}`} data-testid="podcast-evidence">
                            “{ev.quote.length > 72 ? ev.quote.slice(0, 70) + '…' : ev.quote}”{ev.section ? ` · §${ev.section}` : ''}</button>))}</div>)}
                    </li>
                  );
                })}
              </ol>
              <p className="fine dock-disclosure">{detail.transcript.disclosure} Downloads aren’t kept in this browser; playing again downloads the episode again.</p>
            </div>
          </>}
        </div>
      )}
    </section></>
  );
}

// ---------- Paper Listen / explicit private generation ----------

// Simplified at the owner's request (2026-10-16: "our podcast UX feels too complex right now ... the important thing
// is you ask for, it doesnt matter if you leave the page or app, its there for you"): one action, the length and the
// writer preselected, the price said once; then one calm state, no stages; the episode waits in Listen.
function generationMessage(error: unknown) {
  if (error instanceof PodcastTrackingError) return error.code === 'full'
    ? 'This tab is keeping track of too many episode requests. Check Listen before asking for another.'
    : 'This tab couldn’t keep track of the request, so nothing was sent. Check that browser storage is available, then try again.';
  const code = error instanceof BackendError ? error.code : '';
  if (code === 'insufficient_credits') return 'You don’t have enough credits for this length. Add credits in Gradstep on iPhone, iPad or Mac, or choose a shorter one.';
  if (code === 'quote_expired' || code === 'quote_unavailable') return 'That took too long to confirm. Try again.';
  if (code === 'podcast_unavailable' || code === 'podcast_paused') return 'Episodes can’t be made right now. You can keep reading.';
  if (code === 'source_unavailable') return 'Open this paper first so it’s ready on this device, then try again.';
  if (code === 'active_generation_limit') return 'Another episode is being made for you. Try again when it’s ready.';
  if (code === 'podcast_outcome_pending') return 'Your previous episode’s charge is still being confirmed. You can make another once it’s settled.';
  if (['request_rate_limit', 'podcast_daily_limit', 'podcast_busy', 'too_many_active_operations'].includes(code)) return 'Episodes are busy right now. Nothing was charged; try again later.';
  if (code === 'platform_budget_exhausted' || code === 'storage_full') return 'Episodes are paused for now. Nothing was charged, and you can keep reading.';
  return 'We couldn’t confirm that. Try again.';
}

/** Mount beside a synced paper's existing toolbar actions. No quote or paid start happens on mount; opening Listen
 * prices the chosen length (a quote holds nothing) and only Make an episode starts anything. */
/** The paper's own text on this device, built on demand (a verified bundle's numbered context) for a private episode. */
export type DeviceSourceProvider = (signal: AbortSignal) => Promise<{ text: DeviceSourceText; identity: Omit<DeviceSourceDescriptor, 'text_sha256'> } | null>;
export function PaperListen({ account, itemID, title, player, onBrowseShared, deviceSource, onAsked, openWith, onOpened }: { account: string; itemID: string; title: string; player: PlayerModel; onBrowseShared?: () => void; deviceSource?: DeviceSourceProvider;
  /** A request started (Listen shows it being made). */ onAsked?: () => void;
  /** Open at once (Try again from Listen), at this length. */ openWith?: { profile: string | null } | null; onOpened?: () => void }) {
  const owner = useAccountOwner(account);
  const tracking = useMemo(() => new PodcastRequests(account, owner), [account, owner]);
  const [shown, setShown] = useState(false);
  const [paper, setPaper] = useState<PaperPodcast | null>(null);
  const [quote, setQuote] = useState<Quote | null>(null);
  // The chosen writer (2026-10-14); null follows the server's default (the first it lists).
  const [writer, setWriter] = useState<string | null>(null);
  // The length (PodcastGenerateSheet's chips): each is its own episode; 5 min until the reader chooses.
  const [length, setLength] = useState<string | null>(null);
  const [job, setJob] = useState<Job | null>(null);
  const [busy, setBusy] = useState<'paper' | 'quote' | 'start' | 'status' | 'cancel' | null>(null);
  const [issue, setIssue] = useState<string | null>(null);
  const [uncertainStart, setUncertainStart] = useState(false);
  const [trackingBlocked, setTrackingBlocked] = useState(false);
  const [unavailable, setUnavailable] = useState(false);
  const [pollPaused, setPollPaused] = useState(false);
  const [sourceTooLarge, setSourceTooLarge] = useState(false);
  const [wakeRevision, setWakeRevision] = useState(0);
  // Price the chosen length once the paper is known, and again when the length or writer changes.
  const [wantQuote, setWantQuote] = useState(false);
  const requestID = useRef<string | null>(null);
  const pending = useRef<AbortController | null>(null);
  const visible = useRef(shown); visible.current = shown;
  const startedPolling = useRef(0);
  // The paper's text is sent once per request and named by digest; the server deletes it once the episode is made
  // (migration 076), so a finished request forgets it and the next one sends it again.
  const uploadedDevice = useRef<DeviceSourceDescriptor | null>(null);
  const reset = useCallback(() => { pending.current?.abort(); pending.current = null; requestID.current = null; uploadedDevice.current = null;
    setShown(false); setPaper(null); setQuote(null); setJob(null); setBusy(null); setIssue(null); setUncertainStart(false); setPollPaused(false); setUnavailable(false); setTrackingBlocked(false); setSourceTooLarge(false); setWantQuote(false); }, []);
  useEffect(() => {
    reset(); owner.signal.addEventListener('abort', reset, { once: true });
    return () => { owner.signal.removeEventListener('abort', reset); reset(); };
  }, [owner, itemID, reset]);
  const begin = (kind: NonNullable<typeof busy>) => {
    if (owner.signal.aborted || owner.session?.user.id !== account || auth.snapshot().generation !== owner.generation) return null;
    // React state updates are not an operation lock. Two handlers in one task must not dispatch two Starts.
    if (kind !== 'paper' && pending.current && !pending.current.signal.aborted) return null;
    pending.current?.abort(); const controller = new AbortController(); pending.current = controller; setBusy(kind); setIssue(null);
    return controller;
  };
  const live = (c: AbortController) => !c.signal.aborted && !owner.signal.aborted && pending.current === c && auth.snapshot().generation === owner.generation;
  const isSourceTooLarge = (error: unknown) => error instanceof BackendError && error.code === 'source_too_large';
  const confirmed = (id: string) => {
    // Failure to remove a confirmed hint is safe: the next open reconciles the same ID again.
    try { tracking.resolve(itemID, id); } catch { /* never replace an unresolved stored identity */ }
  };
  const acceptJob = (next: Job) => {
    confirmed(next.requestID);
    requestID.current = next.requestID; setJob(next); setQuote(null); setUncertainStart(false);
    if (jobTerminal(next)) uploadedDevice.current = null;
    setSourceTooLarge(next.failure === 'source_too_large');
    if (next.failure === 'source_too_large') setIssue(null);
    if (!startedPolling.current) startedPolling.current = Date.now();
  };
  const acceptResult = async (next: RequestResult, id: string, c: AbortController, discovery = paper) => {
    if (!live(c)) return;
    if (next.kind === 'job') { acceptJob(next.job); return; }
    // A successful start/status reuse is authoritative, but fetch and validate its actual release
    // before offering Play. A failed lookup retains the exact request so status remains recoverable.
    const episode = await podcastEpisode(account, next.releaseID, c.signal);
    if (!live(c)) return;
    if (episode.state !== 'ready') throw new BackendError('podcast_release_unavailable');
    confirmed(id);
    const capabilities = discovery?.capabilities ?? { catalog: false, generation: false, delivery: false, maxCredits: 150, targetSeconds: 300, transfer: null, writers: [] };
    setPaper({ capabilities, job: null, episode: { ...episode, title: episode.scope === 'private' ? title : episode.title } });
    setJob(null); setQuote(null); setUncertainStart(false);
  };
  const load = async (profile: string | null = null) => {
    const c = begin('paper'); if (!c) return;
    visible.current = true; setShown(true); setUnavailable(false); setPaper(null); setTrackingBlocked(false); setSourceTooLarge(false);
    if (profile) setLength(profile);
    let retained = null;
    try { retained = tracking.get(itemID); }
    catch (e) { setTrackingBlocked(true); setIssue(generationMessage(e)); }
    if (retained) { requestID.current = retained.requestID; setQuote(retained.quote); setJob(null); setUncertainStart(true); }
    try {
      const result = await podcastPaper(account, itemID, c.signal); if (!live(c)) return;
      setPaper(retained ? { ...result, episode: null, job: null } : result);
      setPollPaused(false); startedPolling.current = Date.now();
      if (retained) {
        // A discovery miss (or a different active request) is not a negative receipt. Only this
        // request's result can reconcile a Start whose transport may already have reached the server.
        const outcome = await podcastStatus(account, retained.requestID, c.signal);
        await acceptResult(outcome, retained.requestID, c, result);
      } else {
        setQuote(null); setJob(result.job); setUncertainStart(false);
        if (result.job?.failure === 'source_too_large') { setSourceTooLarge(true); setIssue(null); }
        requestID.current = result.job?.requestID ?? crypto.randomUUID();
        // Nothing playing or being made: price the chosen length at once (a quote holds nothing).
        if (!result.episode && result.job?.failure !== 'source_too_large' && (!result.job || jobTerminal(result.job))) {
          if (result.job) { setJob(null); requestID.current = crypto.randomUUID(); }
          setWantQuote(true);
        }
      }
    } catch (e) { if (live(c)) { if (!retained && featureUnavailable(e)) setUnavailable(true); else if (isSourceTooLarge(e)) { setSourceTooLarge(true); setIssue(null); } else setIssue(generationMessage(e)); } }
    finally { if (live(c)) { pending.current = null; setBusy(null); } }
  };
  const resolveDevice = async (c: AbortController, fresh = false): Promise<DeviceSourceDescriptor | undefined> => {
    if (!deviceSource) return undefined;
    if (uploadedDevice.current && !fresh) return uploadedDevice.current;
    const built = await deviceSource(c.signal);
    if (!built) return undefined;
    const stored = await podcastUploadSource(account, built.text, c.signal);
    uploadedDevice.current = { ...built.identity, text_sha256: stored.textSHA256 };
    return uploadedDevice.current;
  };
  const estimate = async () => {
    if (!paper?.capabilities.generation || busy || trackingBlocked || uncertainStart) return;
    const c = begin('quote'); if (!c) return;
    requestID.current ??= crypto.randomUUID();
    // A choice changed while this was in flight: its answer is dropped, and the new choice is priced next.
    const asked = `${chosenLength?.profile}|${chosenWriter}`, current = () => asked === chosenKey.current;
    try {
      const cached = !!uploadedDevice.current;
      let device = await resolveDevice(c); if (!live(c)) return;
      let result;
      try { result = await podcastQuote(account, itemID, requestID.current, c.signal, chosenWriter ?? undefined, device, chosenLength?.profile); }
      catch (e) {
        // Text the server no longer has (an episode made from it finished): sent again, once.
        if (!(cached && e instanceof BackendError && e.code === 'source_unavailable')) throw e;
        device = await resolveDevice(c, true); if (!live(c)) return;
        result = await podcastQuote(account, itemID, requestID.current, c.signal, chosenWriter ?? undefined, device, chosenLength?.profile);
      }
      if (!live(c) || !current()) return;
      if (result.kind === 'quote') { setQuote(result.quote); setJob(null); }
      else if (result.kind === 'join') {
        requestID.current = result.requestID;
        await acceptResult(await podcastStatus(account, result.requestID, c.signal), result.requestID, c);
      } else {
        const e = await podcastEpisode(account, result.releaseID, c.signal);
        if (live(c)) {
          if (e.state !== 'ready') throw new BackendError('podcast_release_unavailable');
          setPaper({ ...paper, episode: { ...e, title: e.scope === 'private' ? title : e.title } }); setQuote(null);
        }
      }
    } catch (e) { if (live(c)) { if (isSourceTooLarge(e)) { setSourceTooLarge(true); setIssue(null); } else setIssue(generationMessage(e)); } }
    finally { if (live(c)) { pending.current = null; setBusy(null); } }
  };
  const latestEstimate = useRef(estimate); latestEstimate.current = estimate;
  useEffect(() => {
    if (!wantQuote || !shown || busy || !paper) return;
    setWantQuote(false); void latestEstimate.current();
  }, [wantQuote, shown, busy, paper]);
  const start = async () => {
    if (!paper?.capabilities.generation || !quote || !requestID.current || busy || trackingBlocked || (pending.current && !pending.current.signal.aborted)) return;
    const id = requestID.current, capturedQuote = quote, wasUncertain = uncertainStart;
    if (!wasUncertain && Date.now() >= quote.expiresAt) { setQuote(null); requestID.current = crypto.randomUUID(); setWantQuote(true); return; }
    const c = begin('start'); if (!c) return;
    try {
      // Synchronous write + read-back precedes every transport, including an exact retry. No storage
      // success means no paid POST. Reload recovers the same finite consent/quote identity.
      tracking.remember(itemID, id, capturedQuote);
      setUncertainStart(true);
      await acceptResult(await podcastStart(account, capturedQuote, id, c.signal), id, c);
      onAsked?.();
    } catch (e) {
      if (live(c)) {
        if (isSourceTooLarge(e)) { setSourceTooLarge(true); setIssue(null); }
        else setIssue(wasUncertain && e instanceof BackendError && ['quote_expired', 'quote_unavailable'].includes(e.code)
          ? 'The earlier request may have started. Check again before asking for another.' : generationMessage(e));
        if (e instanceof PodcastTrackingError) setTrackingBlocked(true);
        else if (!wasUncertain && e instanceof BackendError && ['quote_expired', 'quote_unavailable'].includes(e.code)) {
          // This first, uninterrupted call was explicitly refused before admission. Once a prior
          // attempt was ambiguous, preserve its identity even if a later retry sees an expired quote.
          confirmed(id); setQuote(null); setUncertainStart(false); requestID.current = crypto.randomUUID();
        }
      }
    } finally { if (live(c)) { pending.current = null; setBusy(null); } }
  };
  const updateJob = async (cancel = false) => {
    if (!visible.current || !requestID.current || busy) return;
    const id = requestID.current, c = begin(cancel ? 'cancel' : 'status'); if (!c) return;
    try {
      if (cancel) { const next = await podcastCancel(account, id, c.signal); if (live(c)) acceptJob(next); }
      else await acceptResult(await podcastStatus(account, id, c.signal), id, c);
    } catch (e) { if (live(c)) { if (isSourceTooLarge(e)) { setSourceTooLarge(true); setIssue(null); } else setIssue(generationMessage(e)); setPollPaused(true); } }
    finally { if (live(c)) { pending.current = null; setBusy(null); } }
  };
  const latestUpdate = useRef(updateJob); latestUpdate.current = updateJob;
  // One in-flight status read, 5s during the first minute then 15s, visible sheet only, finite 30-minute window
  // (Listen keeps checking after that, and after the sheet is closed).
  useEffect(() => {
    if (!shown || !job || jobTerminal(job) || busy || pollPaused || document.hidden || !navigator.onLine) return;
    const elapsed = Date.now() - startedPolling.current;
    if (elapsed >= 30 * 60_000) { setPollPaused(true); return; }
    const timer = setTimeout(() => { if (!document.hidden && navigator.onLine) void latestUpdate.current(); }, statusPollDelay(elapsed));
    return () => clearTimeout(timer);
  }, [shown, job, busy, pollPaused, wakeRevision, owner]);
  useEffect(() => {
    const wake = () => { if (visible.current && !document.hidden && navigator.onLine) { startedPolling.current = Date.now(); setPollPaused(false); setWakeRevision(v => v + 1); } };
    document.addEventListener('visibilitychange', wake); window.addEventListener('online', wake);
    return () => { document.removeEventListener('visibilitychange', wake); window.removeEventListener('online', wake); };
  }, []);
  // Try again from Listen: open at once, at the length that couldn't be made.
  useEffect(() => { if (openWith && !shown) { onOpened?.(); void load(openWith.profile); } }, [openWith]); // eslint-disable-line react-hooks/exhaustive-deps
  const close = () => { visible.current = false; pending.current?.abort(); pending.current = null; setShown(false); setBusy(null); };
  const play = async () => {
    const c = begin('paper'); if (!c) return;
    try {
      const e = paper?.episode ?? (job?.releaseID ? await podcastEpisode(account, job.releaseID, c.signal) : null);
      if (live(c) && e && paper?.capabilities.delivery) { close(); await player.open({ ...e, title: e.scope === 'private' ? title : e.title }); }
    } catch (e) { if (live(c)) setIssue(message(e)); }
    finally { if (live(c)) { pending.current = null; setBusy(null); } }
  };
  // Try again after a failure: the same length and writer, asked afresh (its text is sent again).
  const askAgain = () => { setJob(null); setQuote(null); setIssue(null); uploadedDevice.current = null; requestID.current = crypto.randomUUID(); setWantQuote(true); };
  const choose = (next: { length?: string; writer?: string }) => {
    if (next.length) setLength(next.length); if (next.writer) setWriter(next.writer);
    setQuote(null); setIssue(null); requestID.current = crypto.randomUUID(); setWantQuote(true);
  };
  const ready = paper?.episode?.state === 'ready' || job?.state === 'ready';
  const lengths = paper?.capabilities.lengths ?? [];
  const chosenLength = lengths.find(l => l.profile === length) ?? lengths.find(l => l.profile === DEFAULT_LENGTH) ?? lengths[0];
  // The chosen length's writers (the default length's list from servers that list no lengths).
  const writers = chosenLength?.writers.length ? chosenLength.writers : paper?.capabilities.writers ?? [];
  const chosenWriter = writers.find(w => w.writer === writer)?.writer ?? writers[0]?.writer ?? null;
  const chosenKey = useRef(''); chosenKey.current = `${chosenLength?.profile}|${chosenWriter}`;
  const maximum = quote?.maxCredits ?? writers.find(w => w.writer === chosenWriter)?.maxCredits ?? chosenLength?.maxCredits ?? paper?.capabilities.maxCredits ?? 150;
  const providers = quote?.providers ?? [chosenWriter === 'deepseek' ? 'DeepSeek' : 'Anthropic', 'Google'];
  const making = !!job && !jobTerminal(job);
  const failed = !!job && jobTerminal(job) && job.state !== 'ready' && !sourceTooLarge;
  const asking = !!paper && paper.capabilities.generation && !ready && !job && !sourceTooLarge;
  return <>
    <button className="secondary small podcast-paper-listen" onClick={() => void load()} data-testid="podcast-paper-listen"><Icon name="headphones" size={14} /> Listen</button>
    <Dialog open={shown} onClose={close} title="Listen to this paper">
      <div className="podcast-generation">
        <div className="dialog-head"><h2>Listen</h2><button className="icon-button" aria-label="Close Listen" onClick={close}><Icon name="close" /></button></div>
        <strong>{title}</strong>
        {busy === 'paper' && !paper && <p role="status"><span className="spinner small" /> Opening…</p>}
        {issue && !sourceTooLarge && <p className="issue" role="alert">{issue}</p>}
        {trackingBlocked && <button className="secondary" disabled={!!busy} onClick={() => void load()}>Try again</button>}
        {unavailable && <p data-testid="podcast-generation-unavailable">Episodes aren’t available for this paper yet. You can keep reading.</p>}
        {sourceTooLarge && <div className="podcast-too-large" role="alert" data-testid="podcast-source-too-large">
          <strong>This paper is too long for an episode.</strong>
          <p>Nothing was charged.</p>
          <div className="podcast-too-large-actions">
            {onBrowseShared && <button className="secondary" disabled={!!busy} data-testid="podcast-browse-shared" onClick={() => { close(); onBrowseShared(); }}>Browse episodes</button>}
            <button className="link" disabled={!!busy} onClick={close}>Back to paper</button>
          </div>
        </div>}
        {paper && ready && !sourceTooLarge && <div className="podcast-done" data-testid="podcast-ready"><p><strong>Your episode is ready.</strong></p>
          {job?.chargedCredits ? <p className="fine" data-testid="podcast-charges">Charged {job.chargedCredits} credits.</p> : null}
          <button className="primary" disabled={!paper.capabilities.delivery || !!busy} onClick={() => void play()}>Play episode</button>
          {!paper.capabilities.delivery && <p>Listening is temporarily unavailable.</p>}</div>}
        {making && job && <div className="podcast-making" data-testid="podcast-making" role="status">
          <span className="podcast-wave large" aria-hidden="true"><i /><i /><i /><i /><i /></span>
          <strong>Making your episode</strong>
          <p data-testid="podcast-leave">You can leave this page. It’ll be in Listen when it’s ready.</p>
          <p className="fine" data-testid="podcast-wait">{expectedWait(lengths.find(l => l.profile === (job.profile ?? chosenLength?.profile))?.targetSeconds ?? quote?.targetSeconds ?? 300)}</p>
          <button className="primary" onClick={close} data-testid="podcast-done">Done</button>
          {job.cancelRequested ? <p className="fine">Canceling.</p>
            : <button className="link danger" disabled={!!busy} onClick={() => void updateJob(true)} data-testid="podcast-cancel">Cancel this episode</button>}
        </div>}
        {failed && job && <div className="podcast-done" data-testid="podcast-failed">
          <p><strong>{job.state === 'canceled' ? 'Canceled.' : job.state === 'unknown_provider' ? 'We couldn’t finish this episode.' : job.state === 'quarantined' ? 'This episode is held back for review.' : 'We couldn’t make this episode.'}</strong></p>
          <p className="fine" data-testid="podcast-charges">{job.state === 'unknown_provider' ? 'You won’t be charged more than its maximum.' : job.chargedCredits ? `Charged ${job.chargedCredits} credits.` : 'Nothing was charged.'}</p>
          {(job.state === 'failed' || job.state === 'canceled') && paper?.capabilities.generation && <button className="primary" disabled={!!busy} onClick={askAgain} data-testid="podcast-retry">Try again</button>}
        </div>}
        {paper && !paper.capabilities.generation && !ready && !job && !sourceTooLarge && <p data-testid="podcast-generation-unavailable">Episodes aren’t available for this paper yet. You can keep reading.</p>}
        {asking && <>
          <p className="fine">Two AI hosts, an explainer and a skeptical reader, talk through the paper. The transcript links to its passages.</p>
          {lengths.length > 1 && <fieldset className="podcast-choice" data-testid="podcast-lengths"><legend>Length</legend>
            <div className="podcast-chips">{lengths.map(l => <label key={l.profile} className="podcast-chip">
              <input type="radio" name="podcast-length" value={l.profile} checked={chosenLength?.profile === l.profile} disabled={busy === 'start' || uncertainStart}
                onChange={() => choose({ length: l.profile })} aria-describedby="podcast-length-line" /><span>{l.label}</span></label>)}</div>
            <span className="fine" id="podcast-length-line" data-testid="podcast-length-line">{aboutMinutes(chosenLength?.targetSeconds ?? 300)}</span>
          </fieldset>}
          {writers.length > 1 && <fieldset className="podcast-choice" data-testid="podcast-writers"><legend>Written by</legend>
            <div className="podcast-chips segmented">{writers.map(w => <label key={w.writer} className="podcast-chip">
              <input type="radio" name="podcast-writer" value={w.writer} checked={chosenWriter === w.writer} disabled={busy === 'start' || uncertainStart}
                onChange={() => choose({ writer: w.writer })} /><span>{w.label}</span></label>)}</div>
          </fieldset>}
          <p data-testid="podcast-price">Up to {maximum} credits. You’re charged only for what’s used, and nothing if it can’t be made.</p>
          <p className="fine" data-testid="podcast-privacy">To make it, the paper’s text is sent to {plainProviders(providers)} and deleted once the episode is made. The episode is private to your account (not end-to-end encrypted). AI-generated: check important claims against the paper.</p>
          <button className="primary" disabled={!quote || !!busy || trackingBlocked} onClick={() => void start()} data-testid="podcast-confirm">
            {busy === 'quote' || busy === 'start' ? <span className="spinner small" aria-hidden="true" /> : null} {uncertainStart ? 'Try again' : 'Make an episode'}</button>
          {uncertainStart && <button className="link" disabled={!!busy} onClick={() => void updateJob()}>Check again</button>}
          {issue && !quote && !busy && <button className="link" onClick={() => { setIssue(null); setWantQuote(true); }}>Try again</button>}
        </>}
      </div>
    </Dialog>
  </>;
}
