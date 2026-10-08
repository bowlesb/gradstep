// Research Feed (legacy ResearchFeed): the newest arXiv papers in the library's main topics, as a
// card grid with topic chips (or the topic list in the left rail), and Add to library in place.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { type DiscoveryResult, feed, feedCategories, topicName } from '../lib/feed';
import type { Entry } from '../lib/library';
import { Icon } from './icons';
import { type Library, commandError } from './Library';

type Loaded = { results: DiscoveryResult[]; at: number };

export function useFeed(account: string, entries: Entry[]) {
  const categories = useMemo(() => feedCategories(entries), [entries]);
  const [category, setCategory] = useState<string | null>(null);
  const [loaded, setLoaded] = useState<Map<string, Loaded>>(new Map());
  const [state, setState] = useState<'idle' | 'loading' | 'failed'>('idle');
  const request = useRef<AbortController | null>(null);
  const selected = category && categories.includes(category) ? category : categories[0];
  const load = useCallback((which: string) => {
    request.current?.abort();
    const controller = new AbortController();
    request.current = controller;
    setState('loading');
    feed(account, which, controller.signal).then(results => {
      if (controller.signal.aborted) return;
      setLoaded(previous => new Map(previous).set(which, { results, at: Date.now() }));
      setState('idle');
    }, () => { if (!controller.signal.aborted) setState('failed'); });
  }, [account]);
  return { categories, selected, setCategory, loaded, state, load, request };
}
export type FeedModel = ReturnType<typeof useFeed>;

/** Loads the selected topic the first time it is shown; later visits keep this session's results. */
export function useFeedLoading(model: FeedModel) {
  const { selected, loaded, load, request } = model;
  useEffect(() => { if (selected && !loaded.has(selected)) load(selected); }, [selected, loaded, load]);
  useEffect(() => () => request.current?.abort(), [request]);
}

export function FeedRail({ model }: { model: FeedModel }) {
  return (
    <nav className="rail-nav" aria-label="Feed topics">
      <div className="rail-section">
        <div className="rail-heading">Topics</div>
        {model.categories.map(c => (
          <button key={c} className={`rail-item${model.selected === c ? ' selected' : ''}`} aria-pressed={model.selected === c} onClick={() => model.setCategory(c)}>
            <span className="rail-label">{topicName(c)}</span><span className="rail-count mono">{c}</span>
          </button>
        ))}
      </div>
      <p className="fine rail-note">Topics come from your library’s arXiv categories.</p>
    </nav>
  );
}

const ago = (at: number) => { const m = Math.round((Date.now() - at) / 60_000); return m < 1 ? 'just now' : m < 60 ? `${m} min ago` : `${Math.round(m / 60)} h ago`; };

export function FeedView({ model, library, showChips }: { model: FeedModel; library: Library; showChips: boolean }) {
  useFeedLoading(model);
  const [adding, setAdding] = useState<string | null>(null);
  const [issue, setIssue] = useState<string | null>(null);
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const inLibrary = useMemo(() => new Set(library.entries.filter(e => e.visible).map(e => e.source_id).filter(Boolean)), [library.entries]);
  const current = model.selected ? model.loaded.get(model.selected) : undefined;
  const add = async (result: DiscoveryResult) => {
    setAdding(result.source_id); setIssue(null);
    try { await library.addArxiv(result.source_id, null); } catch (error) { setIssue(commandError(error)); } finally { setAdding(null); }
  };
  return (
    <section className="feed" aria-labelledby="feed-title">
      <div className="view-head">
        <h1 id="feed-title">Research Feed</h1>
        <span className="view-sub">{model.selected ? `Newest in ${topicName(model.selected)}` : ''}</span>
      </div>
      {showChips && (
        <div className="chips" role="toolbar" aria-label="Feed topics">
          {model.categories.map(c => <button key={c} className={model.selected === c ? 'chip selected' : 'chip'} aria-pressed={model.selected === c} onClick={() => model.setCategory(c)}>{topicName(c)}</button>)}
        </div>
      )}
      <div className="feed-status">
        <span>{current ? `${current.results.length} papers · Updated ${ago(current.at)}` : model.state === 'loading' ? 'Loading…' : ''}</span>
        <button className="link small-link" onClick={() => model.selected && model.load(model.selected)} disabled={model.state === 'loading'}>
          <Icon name="refresh" size={12} /> {model.state === 'loading' ? 'Refreshing…' : 'Refresh'}</button>
      </div>
      {issue && <p className="issue banner" role="alert">{issue}</p>}
      {model.state === 'failed' && !current && <div className="empty"><p>New papers aren’t available right now. Try again in a moment.</p>
        <button className="secondary" onClick={() => model.selected && model.load(model.selected)}>Try again</button></div>}
      {model.state === 'loading' && !current && <div className="empty"><div className="spinner" aria-label="Loading the feed" /></div>}
      {current && current.results.length === 0 && <div className="empty"><p>No new papers in this topic right now.</p></div>}
      {current && current.results.length > 0 && (
        <ul className="feed-grid" data-testid="feed-grid">
          {current.results.map(r => {
            const have = inLibrary.has(r.source_id);
            return (
              <li key={r.source_id} className={`feed-card${expanded.has(r.source_id) ? ' expanded' : ''}`}>
                <a className="feed-title" href={`https://arxiv.org/abs/${r.source_id}`} target="_blank" rel="noopener noreferrer">{r.title}</a>
                {r.authors.length > 0 && <div className="feed-authors">{r.authors.slice(0, 6).join(', ')}{r.authors.length > 6 ? ` +${r.authors.length - 6}` : ''}</div>}
                {r.abstract && <>
                  <p className="feed-abstract" id={`abstract-${r.source_id}`}>{r.abstract}</p>
                  <button className="link small-link" aria-expanded={expanded.has(r.source_id)} aria-controls={`abstract-${r.source_id}`}
                    onClick={() => setExpanded(previous => { const next = new Set(previous); next.has(r.source_id) ? next.delete(r.source_id) : next.add(r.source_id); return next; })}>
                    {expanded.has(r.source_id) ? 'Less' : 'Full abstract'}</button>
                  {expanded.has(r.source_id) && r.abstractTruncated && <a className="link small-link" href={`https://arxiv.org/abs/${r.source_id}`} target="_blank" rel="noopener noreferrer">Read the full abstract on arXiv</a>}
                </>}
                <div className="feed-meta">
                  <span>{r.year ?? ''}</span><span className="tag static">{topicName(r.categories[0] ?? model.selected ?? '')}</span><span className="mono faint">{r.source_id}</span>
                  <button className={have ? 'pill passive' : 'pill accent'} disabled={have || !!adding || library.state !== 'ready'} onClick={() => void add(r)}>
                    {have ? 'In library' : adding === r.source_id ? 'Adding…' : '+ Add to library'}</button>
                </div>
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );
}
