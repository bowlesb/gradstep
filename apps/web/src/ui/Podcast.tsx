// Paper podcasts in the browser (docs/architecture/PAPER_PODCASTS.md): the Feed's Listen filter and a player docked
// under the workspace. The dock takes its own row of the app's column, so the workspace (reader, chat composer and
// selection actions) shrinks above it instead of being covered. Audio is fetched once per play through a single-use
// grant, verified (length and SHA-256) and played from an in-memory Blob URL; nothing is kept after Stop or sign-out.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { BackendError } from '../lib/backend';
import { type Capabilities, type Chapter, type Episode, type EpisodeDetail, type Evidence, downloadEpisodeAudio, podcastCatalog, podcastEpisode } from '../lib/podcast';
import { SKIP_MS, SPEEDS, chapterAt, clock, durationLabel, loadPosition, positionText, resumeAt, savePosition, segmentAt } from '../lib/podcast-playback';
import { Icon } from './icons';
import { useMedia } from './prefs';

// ---------- Catalog ----------

export function usePodcasts(account: string) {
  const [episodes, setEpisodes] = useState<Episode[]>([]);
  const [capabilities, setCapabilities] = useState<Capabilities | null>(null);
  const [state, setState] = useState<'idle' | 'loading' | 'loaded' | 'failed'>('idle');
  const [next, setNext] = useState<string | null>(null);
  const request = useRef<AbortController | null>(null);
  const load = useCallback((more = false) => {
    request.current?.abort();
    const controller = new AbortController();
    request.current = controller;
    setState('loading');
    podcastCatalog(account, more ? next : null, controller.signal).then(catalog => {
      if (controller.signal.aborted) return;
      setCapabilities(catalog.capabilities);
      setEpisodes(previous => {
        if (!more) return catalog.episodes;
        const known = new Set(previous.map(e => e.releaseID));
        return [...previous, ...catalog.episodes.filter(e => !known.has(e.releaseID))].slice(0, 500);
      });
      setNext(catalog.next); setState('loaded');
    }, () => { if (!controller.signal.aborted) setState('failed'); });
  }, [account, next]);
  useEffect(() => () => request.current?.abort(), []);
  return { episodes, capabilities, state, next, load };
}
export type PodcastsModel = ReturnType<typeof usePodcasts>;

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
  if (capabilities && (!capabilities.catalog || !capabilities.delivery)) return (
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

/** One episode at a time. The play session/sequence makes saved places merge deterministically (newer.ts rules). */
export function usePodcastPlayer(account: string) {
  const [episode, setEpisode] = useState<Episode | null>(null);
  const [detail, setDetail] = useState<EpisodeDetail | null>(null);
  const [status, setStatus] = useState<'idle' | 'loading' | 'ready' | 'failed'>('idle');
  const [issue, setIssue] = useState<string | null>(null);
  const [playing, setPlaying] = useState(false);
  const [positionMs, setPosition] = useState(0);
  const [rate, setRateState] = useState(1);
  const audio = useRef<HTMLAudioElement | null>(null);
  const [element, setElement] = useState<HTMLAudioElement | null>(null);
  const objectURL = useRef<string | null>(null);
  const loading = useRef<AbortController | null>(null);
  const session = useRef<{ id: string; startedAt: number; sequence: number; lastSaved: number } | null>(null);
  const current = useRef<{ episode: Episode | null; detail: EpisodeDetail | null }>({ episode: null, detail: null });
  current.current = { episode, detail };

  const save = useCallback((completed = false) => {
    const e = current.current.episode, element = audio.current, s = session.current;
    if (!e || !element || !s || !objectURL.current) return;
    const durationMs = Math.round((Number.isFinite(element.duration) ? element.duration : e.durationMs / 1000) * 1000);
    s.sequence += 1; s.lastSaved = Date.now();
    savePosition(account, e.releaseID, { positionMs: Math.round(element.currentTime * 1000), durationMs, completed, session: s.id,
      sessionStartedAt: s.startedAt, sequence: s.sequence, savedAt: s.lastSaved });
  }, [account]);

  const release = useCallback(() => {
    loading.current?.abort(); loading.current = null;
    const element = audio.current;
    if (element) { element.pause(); element.removeAttribute('src'); element.load(); }
    if (objectURL.current) { URL.revokeObjectURL(objectURL.current); objectURL.current = null; }
    session.current = null;
  }, []);

  const stop = useCallback(() => {
    if (audio.current && objectURL.current) save();
    release();
    setEpisode(null); setDetail(null); setStatus('idle'); setIssue(null); setPlaying(false); setPosition(0);
    if ('mediaSession' in navigator) navigator.mediaSession.metadata = null;
  }, [release, save]);

  const open = useCallback(async (next: Episode) => {
    if (audio.current && objectURL.current) save();
    release();
    const controller = new AbortController();
    loading.current = controller;
    setEpisode(next); setDetail(null); setStatus('loading'); setIssue(null); setPlaying(false); setPosition(0);
    try {
      const loaded = await podcastEpisode(account, next.releaseID, controller.signal);
      // Check the release's current state and identity before a new (charged) download.
      if (loaded.state !== 'ready') throw new BackendError('podcast_release_unavailable');
      if (loaded.audio.sha256 !== next.audio.sha256 || loaded.audio.bytes !== next.audio.bytes) throw new BackendError('podcast_integrity_failed');
      if (controller.signal.aborted) return;
      setDetail(loaded);
      const blob = await downloadEpisodeAudio(account, loaded, controller.signal);
      if (controller.signal.aborted) return;
      const url = URL.createObjectURL(blob);
      objectURL.current = url;
      session.current = { id: crypto.randomUUID(), startedAt: Date.now(), sequence: 0, lastSaved: Date.now() };
      const element = audio.current!;
      element.src = url;
      const start = resumeAt(loadPosition(account, loaded.releaseID), loaded.durationMs);
      await new Promise<void>((resolve, reject) => {
        const done = () => { element.removeEventListener('loadedmetadata', done); element.removeEventListener('error', fail); resolve(); };
        const fail = () => { element.removeEventListener('loadedmetadata', done); element.removeEventListener('error', fail); reject(new BackendError('podcast_unplayable')); };
        element.addEventListener('loadedmetadata', done); element.addEventListener('error', fail);
      });
      if (controller.signal.aborted) return;
      element.currentTime = start / 1000; element.playbackRate = rate; setPosition(start);
      setStatus('ready');
      try { await element.play(); } catch { setIssue('Press play to start.'); }
    } catch (error) {
      if (controller.signal.aborted) return;
      release(); setStatus('failed'); setIssue(error instanceof BackendError && error.code === 'podcast_unplayable' ? 'This browser can’t play this episode’s audio.' : message(error));
    }
  }, [account, rate, release, save]);

  const toggle = useCallback(() => {
    const element = audio.current;
    if (!element || status !== 'ready') { if (current.current.episode && status === 'failed') void open(current.current.episode); return; }
    if (element.paused) { void element.play().then(() => setIssue(null), () => setIssue('Press play to start.')); } else element.pause();
  }, [status, open]);
  const seek = useCallback((ms: number) => {
    const element = audio.current;
    if (!element || status !== 'ready') return;
    const end = Number.isFinite(element.duration) ? element.duration * 1000 : current.current.episode?.durationMs ?? 0;
    element.currentTime = Math.max(0, Math.min(ms, end)) / 1000;
    setPosition(Math.round(element.currentTime * 1000));
    save();
  }, [status, save]);
  const skip = useCallback((delta: number) => { if (audio.current) seek(audio.current.currentTime * 1000 + delta); }, [seek]);
  const setRate = useCallback((value: number) => { setRateState(value); if (audio.current) audio.current.playbackRate = value; }, []);

  // Element events → state; periodic, pause, chapter-change and page-hide saves (not every second).
  const lastChapter = useRef<string | null>(null);
  const bind = useCallback((node: HTMLAudioElement | null) => { audio.current = node; setElement(node); }, []);
  useEffect(() => {
    if (!element) return;
    const time = () => {
      const ms = Math.round(element.currentTime * 1000);
      setPosition(ms);
      const chapter = current.current.detail ? chapterAt(current.current.detail.chapters, ms)?.id ?? null : null;
      if (chapter !== lastChapter.current) { const changed = lastChapter.current !== null; lastChapter.current = chapter; if (changed) save(); }
      if (!element.paused && session.current && Date.now() - session.current.lastSaved >= savingInterval) save();
    };
    const play = () => setPlaying(true);
    const pause = () => { setPlaying(false); save(); };
    const ended = () => { setPlaying(false); save(true); };
    element.addEventListener('timeupdate', time); element.addEventListener('play', play); element.addEventListener('pause', pause); element.addEventListener('ended', ended);
    const hide = () => { if (document.visibilityState === 'hidden') save(); };
    const leave = () => save();
    document.addEventListener('visibilitychange', hide); window.addEventListener('pagehide', leave);
    return () => {
      element.removeEventListener('timeupdate', time); element.removeEventListener('play', play); element.removeEventListener('pause', pause); element.removeEventListener('ended', ended);
      document.removeEventListener('visibilitychange', hide); window.removeEventListener('pagehide', leave);
    };
  }, [element, save]);

  // Lock-screen/hardware media keys where the browser supports the Media Session API.
  useEffect(() => {
    if (!('mediaSession' in navigator) || !episode) return;
    const session = navigator.mediaSession;
    try {
      session.metadata = new MediaMetadata({ title: episode.title, artist: episode.fixture ? 'Gradstep · Synthetic fixture' : 'Gradstep · AI audio', album: episode.topic ?? 'Paper podcast' });
      const handlers: [MediaSessionAction, MediaSessionActionHandler][] = [
        ['play', () => toggle()], ['pause', () => toggle()], ['stop', () => stop()],
        ['seekbackward', () => skip(-SKIP_MS)], ['seekforward', () => skip(SKIP_MS)],
        ['seekto', details => { if (typeof details.seekTime === 'number') seek(details.seekTime * 1000); }],
      ];
      for (const [action, handler] of handlers) { try { session.setActionHandler(action, handler); } catch { /* unsupported action */ } }
      return () => { for (const [action] of handlers) { try { session.setActionHandler(action, null); } catch { /* unsupported action */ } } };
    } catch { return undefined; }
  }, [episode, toggle, stop, skip, seek]);

  // Leaving the account (sign-out, another login) aborts any download and frees the decrypted-free, in-memory audio.
  useEffect(() => () => release(), [release]);

  return { episode, detail, status, issue, playing, positionMs, rate, open, toggle, seek, skip, setRate, stop, bind, setIssue };
}
export type PlayerModel = ReturnType<typeof usePodcastPlayer>;

/** The docked player. `onEvidence` opens the cited passage (true) or reports that the paper isn't in the library (false). */
export function PodcastDock({ player, onEvidence }: { player: PlayerModel; onEvidence: (episode: Episode, evidence: Evidence) => boolean }) {
  const { episode, detail, status, issue, playing, positionMs, rate } = player;
  const [expanded, setExpanded] = useState(false);
  const [notice, setNotice] = useState<Episode | null>(null);
  const [follow, setFollow] = useState(true);
  const reduced = useMedia('(prefers-reduced-motion: reduce)');
  const transcript = useRef<HTMLOListElement>(null);
  const durationMs = detail?.durationMs ?? episode?.durationMs ?? 0;
  const segment = detail ? segmentAt(detail.transcript.segments, positionMs) : null;
  const chapter = detail ? chapterAt(detail.chapters, positionMs) : null;
  const chapterIndex = useMemo(() => new Map(detail?.chapters.map(c => [c.id, c]) ?? []), [detail]);
  useEffect(() => { setNotice(null); setFollow(true); }, [episode?.releaseID]);
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
          <button className="icon-button dock-play" onClick={player.toggle} disabled={status === 'loading' || status === 'idle'} aria-label={playing ? 'Pause' : 'Play'}
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
      {issue && <p className="issue dock-issue" role="alert">{issue}</p>}
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
                  {notice.source.url ? <a href={notice.source.url} target="_blank" rel="noopener noreferrer">Open it on arXiv</a> : null}
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
                          <button key={ev.id} className="tag evidence" onClick={() => {
                              // Jumping to the paper folds the dock back to its bar, so the passage gets the room.
                              if (onEvidence(episode, ev)) setExpanded(false); else setNotice(episode);
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
