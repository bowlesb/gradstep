// Paper podcasts in the browser (docs/architecture/PAPER_PODCASTS.md): the Feed's Listen filter and a player docked
// under the workspace. The dock takes its own row of the app's column, so the workspace (reader, chat composer and
// selection actions) shrinks above it instead of being covered. Audio is fetched once per play through a single-use
// grant, verified (length and SHA-256) and played from an in-memory Blob URL; nothing is kept after Stop or sign-out.
import { type ReactNode, useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react';
import { auth, BackendError } from '../lib/backend';
import { type Capabilities, type Chapter, type Episode, type EpisodeDetail, type Evidence, downloadEpisodeAudio, podcastCatalog, podcastEpisode, podcastStates, revocationPollDelay, podcastPaper, podcastQuote, podcastStart, podcastStatus, podcastCancel, jobTerminal, statusPollDelay, type Job, type Quote, type PaperPodcast, type RequestResult } from '../lib/podcast';
import { SKIP_MS, SPEEDS, chapterAt, clock, durationLabel, loadPosition, positionText, resumeAt, savePosition, segmentAt, clearPositions, removePosition } from '../lib/podcast-playback';
import { Icon } from './PodcastIcons';
import { Dialog } from './common';
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
  const request = useRef<AbortController | null>(null);
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
      setNext(catalog.next); setState('loaded');
    }, error => { if (!controller.signal.aborted && !owner.signal.aborted) setState(featureUnavailable(error) ? 'unavailable' : 'failed'); });
  }, [account, next, owner]);
  useEffect(() => {
    const retire = () => { request.current?.abort(); setEpisodes([]); setCapabilities(null); setNext(null); setState('idle'); };
    owner.signal.addEventListener('abort', retire, { once: true });
    if (owner.signal.aborted) retire();
    return () => { owner.signal.removeEventListener('abort', retire); retire(); };
  }, [owner]);
  return { episodes, capabilities, state, next, load };
}
export type PodcastsModel = ReturnType<typeof usePodcasts>;

/** Additive Feed filter: root keeps its For you/topic/category selection intact behind this view. */
export interface ListenFilter { selected: boolean; select: (selected: boolean) => void; view: ReactNode }
export function ListenFilterButton({ selected, onSelect, rail = false }: { selected: boolean; onSelect: () => void; rail?: boolean }) {
  return <button className={`${rail ? 'rail-item' : 'chip listen-chip'}${selected ? ' selected' : ''}`} aria-pressed={selected}
    onClick={onSelect} data-testid="podcast-listen"><Icon name="headphones" size={14} /><span>Listen</span></button>;
}

function Badges({ episode }: { episode: Episode }) {
  return (
    <span className="podcast-badges">
      <span className="badge ai" title="Generated speech, from the paper’s own text">AI audio</span>
      {episode.fixture && <span className="badge fixture" title="Labeled synthetic test audio, not a real episode">Synthetic fixture</span>}
    </span>
  );
}

/** The Feed's Listen filter: ready shared episodes. Playing never adds a paper or starts a paid generation. */
export function ListenView({ podcasts, player }: { podcasts: PodcastsModel; player: PlayerModel }) {
  const { episodes, capabilities, state, next, load } = podcasts;
  useEffect(() => { if (state === 'idle') load(); }, [state, load]);
  if (state === 'loading' && !episodes.length) return <div className="empty"><div className="spinner" aria-label="Loading episodes" /></div>;
  if (state === 'failed' && !episodes.length) return (
    <div className="empty"><p>Episodes aren’t available right now. Try again in a moment.</p><button className="secondary" onClick={() => load()}>Try again</button></div>);
  if (state === 'unavailable' || (capabilities && (!capabilities.catalog || !capabilities.delivery))) return (
    <div className="empty" data-testid="podcast-unavailable"><p><strong>Listening isn’t available yet.</strong></p>
      <p className="muted">Shared paper episodes appear here once they’re published. Reading and chat are unaffected.</p></div>);
  if (state === 'loaded' && !episodes.length) return (
    <div className="empty"><p><strong>No episodes yet.</strong></p><p className="muted">Pick a topic to discover papers. New episodes appear here when they’re ready.</p></div>);
  return (
    <>
      <div className="feed-status"><span>{episodes.length} {episodes.length === 1 ? 'episode' : 'episodes'} · AI-generated from each paper’s text</span>
        <button className="link small-link" onClick={() => load()} disabled={state === 'loading'}><Icon name="refresh" size={12} /> {state === 'loading' ? 'Refreshing…' : 'Refresh'}</button></div>
      <ul className="feed-grid" data-testid="podcast-grid">
        {episodes.map(e => {
          const current = player.episode?.releaseID === e.releaseID;
          const label = current && player.playing ? 'Pause' : current && player.status === 'loading' ? 'Loading…' : current ? 'Resume' : 'Play';
          return (
            <li key={e.releaseID} className={`feed-card podcast-card${current ? ' current' : ''}`} data-testid="podcast-card">
              <span className="feed-title" id={`episode-${e.releaseID}`}>{e.title}</span>
              {e.authors.length > 0 && <div className="feed-authors">{e.authors.slice(0, 6).join(', ')}{e.authors.length > 6 ? ` +${e.authors.length - 6}` : ''}</div>}
              <Badges episode={e} />
              <div className="feed-meta">
                <span>{e.year ?? ''}</span><span aria-label={`Duration ${durationLabel(e.durationMs)}`}>{durationLabel(e.durationMs)}</span>
                {e.topic && <span className="tag static">{e.topic}</span>}
                <button className="pill accent podcast-play" aria-describedby={`episode-${e.releaseID}`} disabled={current && player.status === 'loading'}
                  onClick={() => (current ? player.toggle() : player.open(e))} data-testid="podcast-play">
                  <Icon name={current && player.playing ? 'pause' : 'play'} size={12} /> {label}</button>
              </div>
            </li>
          );
        })}
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

const jobLabels: Record<Job['state'], string> = {
  queued: 'Waiting to start', scripting: 'Writing the script from the paper', checking: 'Checking it against the paper',
  synthesizing: 'Recording the two voices', verifying: 'Checking the audio', publishing: 'Finishing up',
  ready: 'Your private episode is ready', canceled: 'Generation canceled', failed: 'The episode could not be made',
  capacity_wait: 'Waiting for capacity', unknown_provider: 'Generation stopped; provider outcome needs review', quarantined: 'Episode held for review',
};
function generationMessage(error: unknown) {
  if (error instanceof PodcastTrackingError) return error.code === 'full'
    ? 'This tab has too many unresolved episode requests. Check their status before starting another.'
    : 'This tab couldn’t retain the request for a safe retry. No new episode request was sent. Check that browser storage is available, then check availability again.';
  const code = error instanceof BackendError ? error.code : '';
  if (code === 'insufficient_credits') return 'There aren’t enough available credits. Add credits in Gradstep on iPhone, iPad or Mac, then retry this estimate.';
  if (code === 'quote_expired' || code === 'quote_unavailable') return 'This estimate expired. Get a new estimate before confirming.';
  if (code === 'podcast_unavailable' || code === 'podcast_paused') return 'Private episodes aren’t available right now. You can keep reading.';
  if (code === 'source_unavailable' || code === 'source_too_large') return 'This paper can’t be used for a private episode yet.';
  if (['request_rate_limit', 'podcast_daily_limit', 'active_generation_limit', 'podcast_busy', 'too_many_active_operations'].includes(code)) return 'Episode requests are busy or at their limit. Wait before checking again.';
  if (code === 'platform_budget_exhausted' || code === 'storage_full') return 'New episodes are paused for capacity. You can keep reading.';
  return 'The request could not be confirmed. Check the status or retry the same request.';
}

/** Mount beside a synced paper's existing toolbar actions. No quote or paid start happens on mount/open. */
export function PaperListen({ account, itemID, title, player }: { account: string; itemID: string; title: string; player: PlayerModel }) {
  const owner = useAccountOwner(account);
  const tracking = useMemo(() => new PodcastRequests(account, owner), [account, owner]);
  const [shown, setShown] = useState(false);
  const [paper, setPaper] = useState<PaperPodcast | null>(null);
  const [quote, setQuote] = useState<Quote | null>(null);
  const [job, setJob] = useState<Job | null>(null);
  const [busy, setBusy] = useState<'paper' | 'quote' | 'start' | 'status' | 'cancel' | null>(null);
  const [issue, setIssue] = useState<string | null>(null);
  const [uncertainStart, setUncertainStart] = useState(false);
  const [trackingBlocked, setTrackingBlocked] = useState(false);
  const [unavailable, setUnavailable] = useState(false);
  const [pollPaused, setPollPaused] = useState(false);
  const [wakeRevision, setWakeRevision] = useState(0);
  const requestID = useRef<string | null>(null);
  const pending = useRef<AbortController | null>(null);
  const visible = useRef(shown); visible.current = shown;
  const startedPolling = useRef(0);
  const reset = useCallback(() => { pending.current?.abort(); pending.current = null; requestID.current = null;
    setShown(false); setPaper(null); setQuote(null); setJob(null); setBusy(null); setIssue(null); setUncertainStart(false); setPollPaused(false); setUnavailable(false); setTrackingBlocked(false); }, []);
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
  const confirmed = (id: string) => {
    // Failure to remove a confirmed hint is safe: the next open reconciles the same ID again.
    try { tracking.resolve(itemID, id); } catch { /* never replace an unresolved stored identity */ }
  };
  const acceptJob = (next: Job) => {
    confirmed(next.requestID);
    requestID.current = next.requestID; setJob(next); setQuote(null); setUncertainStart(false);
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
    const capabilities = discovery?.capabilities ?? { catalog: false, generation: false, delivery: false, maxCredits: 150, targetSeconds: 300, transfer: null };
    setPaper({ capabilities, job: null, episode: { ...episode, title: episode.scope === 'private' ? title : episode.title } });
    setJob(null); setQuote(null); setUncertainStart(false);
  };
  const load = async () => {
    const c = begin('paper'); if (!c) return;
    visible.current = true; setShown(true); setUnavailable(false); setPaper(null); setTrackingBlocked(false);
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
        requestID.current = result.job?.requestID ?? crypto.randomUUID();
      }
    } catch (e) { if (live(c)) { if (!retained && featureUnavailable(e)) setUnavailable(true); else setIssue(generationMessage(e)); } }
    finally { if (live(c)) { pending.current = null; setBusy(null); } }
  };
  const estimate = async () => {
    if (!paper?.capabilities.generation || busy || trackingBlocked || uncertainStart) return;
    const c = begin('quote'); if (!c) return;
    requestID.current ??= crypto.randomUUID();
    try {
      const result = await podcastQuote(account, itemID, requestID.current, c.signal); if (!live(c)) return;
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
    } catch (e) { if (live(c)) setIssue(generationMessage(e)); }
    finally { if (live(c)) { pending.current = null; setBusy(null); } }
  };
  const start = async () => {
    if (!paper?.capabilities.generation || !quote || !requestID.current || busy || trackingBlocked || (pending.current && !pending.current.signal.aborted)) return;
    const id = requestID.current, capturedQuote = quote, wasUncertain = uncertainStart;
    if (!wasUncertain && Date.now() >= quote.expiresAt) { setIssue('This estimate expired. Get a new estimate before confirming.'); setQuote(null); requestID.current = crypto.randomUUID(); return; }
    const c = begin('start'); if (!c) return;
    try {
      // Synchronous write + read-back precedes every transport, including an exact retry. No storage
      // success means no paid POST. Reload recovers the same finite consent/quote identity.
      tracking.remember(itemID, id, capturedQuote);
      setUncertainStart(true);
      await acceptResult(await podcastStart(account, capturedQuote, id, c.signal), id, c);
    } catch (e) {
      if (live(c)) {
        setIssue(wasUncertain && e instanceof BackendError && ['quote_expired', 'quote_unavailable'].includes(e.code)
          ? 'This estimate expired, but the earlier request may have started. Check its status before starting another.' : generationMessage(e));
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
    } catch (e) { if (live(c)) { setIssue(generationMessage(e)); setPollPaused(true); } }
    finally { if (live(c)) { pending.current = null; setBusy(null); } }
  };
  const latestUpdate = useRef(updateJob); latestUpdate.current = updateJob;
  // One in-flight status read, 5s during the first minute then 15s, visible sheet only, finite 30-minute window.
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
  const close = () => { visible.current = false; pending.current?.abort(); pending.current = null; setShown(false); setBusy(null); };
  const play = async () => {
    const c = begin('paper'); if (!c) return;
    try {
      const e = paper?.episode ?? (job?.releaseID ? await podcastEpisode(account, job.releaseID, c.signal) : null);
      if (live(c) && e && paper?.capabilities.delivery) { close(); await player.open({ ...e, title: e.scope === 'private' ? title : e.title }); }
    } catch (e) { if (live(c)) setIssue(message(e)); }
    finally { if (live(c)) { pending.current = null; setBusy(null); } }
  };
  const ready = paper?.episode?.state === 'ready' || job?.state === 'ready';
  return <>
    <button className="secondary small podcast-paper-listen" onClick={() => void load()} data-testid="podcast-paper-listen"><Icon name="headphones" size={14} /> Listen</button>
    <Dialog open={shown} onClose={close} title="Listen to this paper">
      <div className="podcast-generation">
        <div className="dialog-head"><h2>Listen</h2><button className="icon-button" aria-label="Close Listen" onClick={close}><Icon name="close" /></button></div>
        <strong>{title}</strong>
        {busy && <p role="status"><span className="spinner small" /> {busy === 'quote' ? 'Getting an estimate…' : busy === 'start' ? 'Starting…' : busy === 'cancel' ? 'Canceling…' : 'Checking availability…'}</p>}
        {issue && <p className="issue" role="alert">{issue}</p>}
        {trackingBlocked && <button className="secondary" disabled={!!busy} onClick={() => void load()}>Check availability</button>}
        {unavailable && <p data-testid="podcast-generation-unavailable">Episodes aren’t available for this paper yet. You can keep reading.</p>}
        {!paper && !busy && !unavailable && !trackingBlocked && <button className="secondary" onClick={() => void load()}>Check availability</button>}
        {paper && ready && <><p>Your episode is ready. AI audio and a source-linked transcript.</p><button className="primary" disabled={!paper.capabilities.delivery || !!busy} onClick={() => void play()}>Play episode</button>
          {!paper.capabilities.delivery && <p>Listening is temporarily unavailable.</p>}</>}
        {job && <>
          <p role="status" data-testid="podcast-job-state">{jobLabels[job.state]}</p>
          <p data-testid="podcast-charges">{job.chargedCredits === null ? `Holding up to ${job.heldCredits} credits until the final charge is recorded.` : `${job.chargedCredits} credits charged${job.releasedCredits === null ? '' : ` · ${job.releasedCredits} released`}.`}</p>
          {!jobTerminal(job) && <><p className="fine">Closing this sheet keeps generation running. Cancel stops future work; usage already completed may be charged.</p>
            <button className="secondary" disabled={!!busy} onClick={() => void updateJob(true)}>Cancel generation</button></>}
          {(pollPaused || jobTerminal(job)) && <p className="fine">{pollPaused ? 'Automatic status checks are paused.' : 'Nothing is retried automatically.'}</p>}
          <button className="link" disabled={!!busy} onClick={() => { startedPolling.current = Date.now(); setPollPaused(false); void updateJob(); }}>Refresh status</button>
        </>}
        {paper && !ready && !job && !quote && <>
          {paper.capabilities.generation ? <><p>Make a private, five-minute episode with two AI hosts and a transcript linked to the paper.</p>
            <p className="fine">You’ll see the credit estimate before anything is held.</p><button className="primary" disabled={!!busy || trackingBlocked} onClick={() => void estimate()}>Get an estimate</button></>
            : <p data-testid="podcast-generation-unavailable">Episodes aren’t available for this paper yet. You can keep reading.</p>}
        </>}
        {quote && !ready && !job && <>
          <div className="podcast-estimate"><strong data-testid="podcast-estimate">{quote.estimate}</strong><p>Starting holds up to {quote.maxCredits} credits. You’re charged for work actually done, and the rest is released. Quality failures charge no credits.</p></div>
          <p>The paper’s converted text is sent to {quote.providers.join(' and ')}. Chats, notes and highlights are never used.</p>
          <p>The audio and transcript are stored privately for your account. They aren’t end-to-end encrypted.</p>
          <p className="fine">AI-generated · beta: check important claims against the paper.</p>
          <button className="primary" disabled={!!busy || trackingBlocked || !paper?.capabilities.generation} onClick={() => void start()} data-testid="podcast-confirm">
            {uncertainStart ? 'Retry same request' : `Create episode · up to ${quote.maxCredits} credits`}</button>
          {uncertainStart && <button className="link" disabled={!!busy} onClick={() => void updateJob()}>Check request status</button>}
        </>}
      </div>
    </Dialog>
  </>;
}
