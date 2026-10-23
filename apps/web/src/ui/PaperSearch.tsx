// Paper search beside the library search: native parity (RootView's Library / ML paper search switch, DiscoveryList
// and DiscoveryRow; owner, 2026-10-15: "If no downside shoot for parity"; the name, owner 2026-10-16: "Call it ML
// Paper search"). It searches arXiv's papers from this browser
// (DataCite, docs/architecture/ARXIV_DEVICE_ONLY.md §5.6) while the server's `device_search` capability is on, and
// through the server's `discover?q=` otherwise, as the native app does. Results are the Feed's paper rows: Add, In
// library (opens the paper) and the Downloading…/Preparing… percent after Add; Newest or Relevance order.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { browserSearch, DISCOVERY_ORDER_KEY, type DiscoveryOrder, orderDiscovery, searchPapers } from '../lib/device-search';
import type { DiscoveryResult } from '../lib/feed';
import { FeedCards } from './FeedResults';
import { Icon } from './icons';
import type { Library } from './Library';
import { useStored } from './prefs';

export type DiscoveryState = { kind: 'idle' } | { kind: 'searching' } | { kind: 'failed'; message: string } | { kind: 'results'; results: DiscoveryResult[] };
const UNAVAILABLE = 'ML paper search isn’t available right now. Try again in a moment.';

/** The search's query, state and order. The latest search owns the results; a failure is shown as one, never as an
 * empty list (native runDiscovery). */
export function usePaperSearch(account: string) {
  const engine = useMemo(() => browserSearch(account), [account]);
  const [query, setQueryState] = useState('');
  const [state, setState] = useState<DiscoveryState>({ kind: 'idle' });
  const [order, setOrder] = useStored<DiscoveryOrder>(DISCOVERY_ORDER_KEY, 'newest', v => v === 'newest' || v === 'relevance');
  const latest = useRef(query); latest.current = query;
  // An author tap sets the query and runs it in the same event, before React renders.
  const setQuery = useCallback((text: string) => { latest.current = text; setQueryState(text); }, []);
  const request = useRef<AbortController | null>(null);
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
  return { query, setQuery, state, run, order, setOrder };
}
export type PaperSearch = ReturnType<typeof usePaperSearch>;

export function PaperSearchView({ search, library, preparing, onAdded, onOpen, onLibrary }: { search: PaperSearch; library: Library;
  preparing?: Map<string, number | null>; onAdded?: (sourceID: string) => void; onOpen?: (sourceID: string) => void; onLibrary?: () => void }) {
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
  switch (search.state.kind) {
    case 'idle':
      body = <div className="empty" data-testid="discover-idle"><Icon name="search" size={28} />
        <p className="muted">Search ML papers by title, author, topic or arXiv ID, then add a paper to your library.</p></div>;
      break;
    case 'searching':
      body = <div className="empty" role="status" data-testid="discover-searching"><div className="spinner" aria-hidden="true" /><p>Searching ML papers…</p></div>;
      break;
    case 'failed':
      body = <div className="empty" role="alert" data-testid="discover-failed"><p><strong>Couldn’t search</strong></p><p className="muted">{search.state.message}</p>
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
          <FeedCards results={shown} actions={actions} unknownPopularity={false} />
        </>;
  }
  return <section className="feed paper-search" aria-labelledby="paper-search-title" data-testid="paper-search">
    <h1 id="paper-search-title" className="visually-hidden">ML paper search</h1>
    <details className="advanced-search"><summary>Search by fields</summary>
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
