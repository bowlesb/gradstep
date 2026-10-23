// Paper search beside the library search: native parity (RootView's Library / ML paper search switch, DiscoveryList
// and DiscoveryRow; owner, 2026-10-15: "If no downside shoot for parity"; the name, owner 2026-10-16: "Call it ML
// Paper search"). It searches arXiv's papers from this browser
// (DataCite, docs/architecture/ARXIV_DEVICE_ONLY.md §5.6) while the server's `device_search` capability is on, and
// through the server's `discover?q=` otherwise, as the native app does. Results are the Feed's paper rows: Add, In
// library (opens the paper) and the Downloading…/Preparing… percent after Add; Newest or Relevance order.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { browserSearch, DISCOVERY_ORDER_KEY, type DiscoveryOrder, orderDiscovery, searchPapers } from '../lib/device-search';
import type { DiscoveryResult } from '../lib/feed';
import { Add, FeedCards } from './FeedResults';
import { firstAuthorLine } from '../lib/authors';
import { Icon } from './icons';
import type { Library } from './Library';
import { useStored } from './prefs';

export type DiscoveryState = { kind: 'idle' } | { kind: 'searching' } | { kind: 'failed'; message: string } | { kind: 'results'; results: DiscoveryResult[] };
const UNAVAILABLE = 'ML paper search isn’t available right now. Try again in a moment.';
/** The state shown once the query changes: an empty query is always idle; otherwise what the last search left. */
export function nextDiscoveryState(previous: DiscoveryState, query: string): DiscoveryState {
  return query.trim() ? previous : previous.kind === 'idle' ? previous : { kind: 'idle' };
}

/** The search's query, state and order. The latest search owns the results; a failure is shown as one, never as an
 * empty list (native runDiscovery). */
export function usePaperSearch(account: string) {
  const engine = useMemo(() => browserSearch(account), [account]);
  const [query, setQueryState] = useState('');
  const [state, setState] = useState<DiscoveryState>({ kind: 'idle' });
  const [order, setOrder] = useStored<DiscoveryOrder>(DISCOVERY_ORDER_KEY, 'newest', v => v === 'newest' || v === 'relevance');
  const latest = useRef(query); latest.current = query;
  const request = useRef<AbortController | null>(null);
  // An author tap sets the query and runs it in the same event, before React renders. An emptied field is idle again
  // (native discoveryState): an earlier failure or result never shows under an empty field (UX audit S3).
  const setQuery = useCallback((text: string) => {
    latest.current = text; setQueryState(text);
    if (!text.trim()) { request.current?.abort(); request.current = null; setState(previous => nextDiscoveryState(previous, text)); }
  }, []);
  const run = useCallback(() => {
    const text = latest.current.trim();
    request.current?.abort();
    if (!text) { request.current = null; setState({ kind: 'idle' }); return; }
    const controller = new AbortController(); request.current = controller;
    setState({ kind: 'searching' });
    searchPapers(account, engine, text, controller.signal).then(
      results => { if (!controller.signal.aborted) setState({ kind: 'results', results }); },
      () => { if (!controller.signal.aborted) setState({ kind: 'failed', message: UNAVAILABLE }); });
  }, [account, engine]);
  useEffect(() => () => request.current?.abort(), []);
  /** Cancel: no words, no request, the idle hint (audit S3: an earlier failure never waits behind an empty field). */
  const clear = useCallback(() => { request.current?.abort(); request.current = null; latest.current = ''; setQueryState(''); setState({ kind: 'idle' }); }, []);
  return { query, setQuery, state, run, clear, order, setOrder };
}
export type PaperSearch = ReturnType<typeof usePaperSearch>;

export function PaperSearchView({ search, library, preparing, onAdded, onOpen, onLibrary, compact = false, current }: { search: PaperSearch; library: Library;
  preparing?: Map<string, number | null>; onAdded?: (sourceID: string) => void; onOpen?: (sourceID: string) => void; onLibrary?: () => void;
  /** The left panel's list (search beside the reading view, 2026-10-22): one row per paper, title with authors and year
   * under it, Add or In library at its end; a row in the library opens its paper. */
  compact?: boolean;
  /** The source of the paper open beside the list, highlighted. */
  current?: string | null }) {
  const [criteria,setCriteria]=useState([{field:'title',value:''}]);
  const [adding, setAdding] = useState<string | null>(null);
  const [issue, setIssue] = useState<string | null>(null);
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const inLibrary = useMemo(() => new Set(library.entries.filter(e => e.visible).map(e => e.source_id).filter((id): id is string => !!id)), [library.entries]);
  const results = search.state.kind === 'results' ? search.state.results : null;
  const shown = useMemo(() => results ? orderDiscovery(results, search.order) : [], [results, search.order]);
  useEffect(() => { setIssue(null); setExpanded(new Set()); }, [results]);
  const add = async (result: DiscoveryResult) => {
    if (adding || library.pending.has('add')) return;
    setAdding(result.source_id); setIssue(null);
    try { await library.addArxiv(result.source_id, null); onAdded?.(result.source_id); }
    catch { setIssue(`Couldn’t add “${result.title}”. Try again.`); }
    finally { setAdding(null); }
  };
  const toggle = (source: string) => setExpanded(previous => { const next = new Set(previous); next.has(source) ? next.delete(source) : next.add(source); return next; });
  const actions = { expanded, toggle, adding, inLibrary, add, addBlocked: library.state !== 'ready' || library.pending.has('add'),
    feedbackBusy: false, feedbackState: new Map(), preparing, open: onOpen, library: onLibrary };
  let body;
  // An emptied field shows the idle hint, never the last search's results or failure (audit S3).
  switch (search.query.trim() ? search.state.kind : 'idle') {
    case 'idle':
      body = <div className="empty" data-testid="discover-idle"><Icon name="search" size={28} />
        <p className="muted">Search ML papers by title, author, topic or arXiv ID, then add a paper to your library.</p></div>;
      break;
    case 'searching':
      body = <div className="empty" role="status" data-testid="discover-searching"><div className="spinner" aria-hidden="true" /><p>Searching ML papers…</p></div>;
      break;
    case 'failed':
      body = <div className="empty" role="alert" data-testid="discover-failed"><p><strong>Couldn’t search</strong></p><p className="muted">{search.state.kind === 'failed' ? search.state.message : ''}</p>
        <button className="secondary" onClick={search.run}>Try again</button></div>;
      break;
    case 'results':
      body = shown.length === 0
        ? <div className="empty" data-testid="discover-empty"><p><strong>No papers found</strong></p><p className="muted">Try fewer or different words, an author, or an arXiv ID.</p></div>
        : <>
          <div className="chips" role="toolbar" aria-label="Order">
            {(['newest', 'relevance'] as const).map(order => <button key={order} className={`chip${search.order === order ? ' selected' : ''}`} aria-pressed={search.order === order}
              onClick={() => search.setOrder(order)} data-testid={`discover-order-${order}`}>{order === 'newest' ? 'Newest' : 'Relevance'}</button>)}
          </div>
          {issue && <p className="issue banner" role="alert">{issue}</p>}
          {compact ? <ul className="search-rail-list" aria-label="ML papers">
            {shown.map(paper => {
              const meta = [firstAuthorLine(paper.authors) || null, paper.year].filter(Boolean).join(' · ');
              const text = <><span className="search-rail-title">{paper.title}</span>{meta && <span className="search-rail-meta">{meta}</span>}</>;
              return <li key={paper.source_id} className={`search-rail-row${paper.source_id === current ? ' current' : ''}`} data-testid="search-ml-result">
                {inLibrary.has(paper.source_id) && onOpen
                  ? <button type="button" className="search-rail-open" aria-current={paper.source_id === current ? 'page' : undefined} onClick={() => onOpen(paper.source_id)}>{text}</button>
                  : <div className="search-rail-open static">{text}</div>}
                <Add paper={paper} actions={actions} short />
              </li>;
            })}
          </ul> : <FeedCards results={shown} actions={actions} unknownPopularity={false} />}
        </>;
  }
  return <section className={`feed paper-search${compact ? ' compact' : ''}`} aria-labelledby="paper-search-title" data-testid="paper-search">
    <h1 id="paper-search-title" className="visually-hidden">ML paper search</h1>
    <details className="advanced-search"><summary><span>Search by fields</span><Icon name="chevronDown" size={14} /></summary>
      {criteria.map((c,i)=><div className="search-criterion" key={i}><select aria-label="Field" value={c.field} onChange={e=>setCriteria(rows=>rows.map((r,j)=>j===i?{...r,field:e.target.value}:r))}>{['title','author','abstract','year'].map(f=><option key={f} value={f}>{f[0].toUpperCase()+f.slice(1)}</option>)}</select>
        <input aria-label={`${c.field} criterion`} value={c.value} maxLength={60} placeholder={c.field==='year'?'2024 or 2020-2026':'Contains…'} onChange={e=>setCriteria(rows=>rows.map((r,j)=>j===i?{...r,value:e.target.value.replaceAll('"','')}:r))}/>
        {criteria.length>1 && <button type="button" className="icon-button" aria-label="Remove criterion" onClick={()=>setCriteria(rows=>rows.filter((_,j)=>i!==j))}>−</button>}</div>)}
      <button type="button" className="secondary small" disabled={criteria.length>=4} onClick={()=>setCriteria(rows=>[...rows,{field:'title',value:''}])}>Add criterion</button>
      <button type="button" className="primary small" disabled={criteria.every(c=>!c.value.trim())} onClick={()=>{search.setQuery(criteria.filter(c=>c.value.trim()).map(c=>`${c.field}:"${c.value}"`).join(' '));search.run();}}>Search</button>
      <p className="fine">Results must match all criteria.</p>
    </details>
    {body}
  </section>;
}
