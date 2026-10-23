// Feed mirrors native: For you and precise interests when offered by the server; category fallback;
// Cards/Table, optional columns, clear reasons and explicit feedback. No provider call on the client.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { BackendError, config } from '../lib/backend';
import { type DiscoveryResult, type FeedFeedback, type FeedPage, type FeedSelection, type FeedSort, type FeedTopic,
  feedPage, feedCategories, orderFeed, personalFeed, recordFeedFeedback, selectionName, topicName } from '../lib/feed';
import type { Entry } from '../lib/library';
import { FeedCards, FeedTable, useFeedColumns } from './FeedResults';
import { Icon } from './icons';
import { InfoTip, MenuButton, MenuCheck, SubMenu } from './common';
import { type ListenFilter, ListenFilterButton } from './Podcast';
import { type Library, commandError } from './Library';
import { useStored } from './prefs';
import './feed.css';

type Loaded = FeedPage & { at: number };
const offerKey = (account: string) => `gradstep.${config.environment}.feed-offer.${account}`;
const savedOffer = (account: string): boolean | null => {
  try { const value = localStorage.getItem(offerKey(account)); return value === 'yes' ? true : value === 'no' ? false : null; }
  catch { return null; }
};
const rememberOffer = (account: string, offered: boolean) => { try { localStorage.setItem(offerKey(account), offered ? 'yes' : 'no'); } catch { /* hint only */ } };

export function useFeed(account: string, entries: Entry[]) {
  const categories = useMemo(() => feedCategories(entries), [entries]);
  const [selected, setSelected] = useState<FeedSelection>(() => savedOffer(account) === false ? `category:${categories[0]}` : 'for_you');
  const selectedRef = useRef(selected); selectedRef.current = selected;
  const [offered, setOffered] = useState(() => savedOffer(account) === true);
  const [topics, setTopics] = useState<FeedTopic[]>([]);
  const [loaded, setLoaded] = useState<Map<FeedSelection, Loaded>>(new Map());
  const [state, setState] = useState<'idle' | 'loading' | 'failed'>('idle');
  const [feedback, setFeedback] = useState<Map<string, FeedFeedback>>(new Map());
  const request = useRef<AbortController | null>(null);
  const pendingSelection = useRef<FeedSelection | null>(null);
  const attempted = useRef(new Set<FeedSelection>());
  const chosen = useRef(false);
  const fallback = useRef(categories[0]); fallback.current = categories[0];
  const cancel = useCallback(() => {
    request.current?.abort();
    if (pendingSelection.current) attempted.current.delete(pendingSelection.current);
    request.current = null; pendingSelection.current = null;
    setState('idle'); // a cached page remains usable when its refresh is interrupted by navigation
  }, []);
  const load = useCallback((which: FeedSelection) => {
    cancel();
    const controller = new AbortController(); request.current = controller;
    pendingSelection.current = which;
    attempted.current.add(which); setState('loading');
    feedPage(account, which, controller.signal).then(page => {
      if (controller.signal.aborted) return;
      if (personalFeed(which) && !page.forYou) throw new BackendError('feed_unavailable', 404);
      setLoaded(previous => {
        const next = new Map(previous); next.delete(which); next.set(which, { ...page, at: Date.now() });
        while (next.size > 16) { const oldest = next.keys().next().value!; next.delete(oldest); attempted.current.delete(oldest); }
        return next;
      });
      setOffered(page.forYou); rememberOffer(account, page.forYou);
      if (page.topics) setTopics(page.topics);
      if (!page.forYou) setTopics([]);
      if (page.forYou && !chosen.current && !attempted.current.has('for_you')) setSelected('for_you');
      setState('idle');
    }).catch(error => {
      if (controller.signal.aborted) return;
      if (personalFeed(which)) {
        const code = error instanceof BackendError ? error.code : '';
        if (code === 'feed_unavailable' || code === 'invalid_feed') {
          setOffered(false); setTopics([]); rememberOffer(account, false);
        }
        // Expired interests return to For you; other personal-feed failures keep category browsing working.
        if (which.startsWith('topic:') && code === 'invalid_feed_topic') {
          setTopics(previous => previous.filter(t => `topic:${t.name}` !== which));
          attempted.current.delete('for_you'); setLoaded(previous => { const next = new Map(previous); next.delete('for_you'); return next; });
          setSelected('for_you');
        } else {
          attempted.current.delete(`category:${fallback.current}`);
          setSelected(`category:${fallback.current}`);
        }
        setState('idle');
      } else setState('failed');
    }).finally(() => { if (request.current === controller) { request.current = null; pendingSelection.current = null; } });
  }, [account, cancel]);
  const select = useCallback((next: FeedSelection) => {
    cancel(); chosen.current = true; setState('idle'); setSelected(next);
    if (!loaded.has(next)) load(next);
  }, [cancel, loaded, load]);
  const updateFeedback = useCallback((source: string, kind: FeedFeedback | null) => {
    const visible = selectedRef.current;
    setFeedback(previous => { const next = new Map(previous); if (kind) next.set(source, kind); else next.delete(source); return next; });
    // A choice changes all feeds. Keep the visible page stable, but never return stale cached rankings later.
    setLoaded(previous => new Map([...previous].filter(([key]) => key === visible)));
    attempted.current = new Set([visible]);
    if (kind === null) load(visible); // Undo after a refresh must ask the server for the previously omitted paper.
  }, [load]);
  return { account, categories, selected, select, offered, topics, loaded, state, load, cancel, attempted, feedback, updateFeedback };
}
export type FeedModel = ReturnType<typeof useFeed>;

/** A failed request waits for an explicit retry. Merely re-rendering must not create a request loop. */
export function useFeedLoading(model: FeedModel, active = true) {
  const { selected, loaded, load, cancel, attempted } = model;
  useEffect(() => { if (active && !loaded.has(selected) && !attempted.current.has(selected)) load(selected); }, [active, selected, loaded, load, attempted]);
  useEffect(() => { if (!active) cancel(); return cancel; }, [active, cancel]);
}

function FeedChoices({ model, rail = false, listen, listenButton = true }: { model: FeedModel; rail?: boolean; listen?: ListenFilter; listenButton?: boolean }) {
  const select = (value: FeedSelection) => { listen?.select(false); model.select(value); };
  const button = (value: FeedSelection, title: string, count?: number) => <button key={value}
    className={`${rail ? 'rail-item' : 'chip'}${model.selected === value && !listen?.selected ? ' selected' : ''}`} aria-pressed={model.selected === value && !listen?.selected}
    onClick={() => select(value)}><span className="rail-label">{title}</span>{rail && count !== undefined && <span className="rail-count">{count}</span>}</button>;
  const extraCategories = useMemo(() => {
    const names = new Set<string>();
    return [...new Set([...model.categories, 'cs.LG', 'cs.CL', 'cs.AI', 'cs.CV', 'stat.ML', 'cs.RO', 'cs.IR', 'cs.NE'])].filter(c => {
      const name = topicName(c); if (names.has(name)) return false; names.add(name); return true;
    });
  }, [model.categories]);
  return <>
    {listen && listenButton && <ListenFilterButton selected={listen.selected} onSelect={() => listen.select(true)} rail={rail} />}
    {model.offered ? <>
      {button('for_you', 'For you')}
      {model.topics.map(t => button(`topic:${t.name}`, t.name, t.papers))}
      {model.selected.startsWith('category:') && button(model.selected, selectionName(model.selected))}
      <label className={`feed-more-topics${rail ? ' rail-item' : ''}`}><span className="visually-hidden">More topics</span>
        <select aria-label="More topics" value="" onChange={e => { if (e.target.value) select(`category:${e.target.value}`); }}>
          <option value="">More topics…</option>{extraCategories.map(c => <option key={c} value={c}>{topicName(c)}</option>)}
        </select>
      </label>
    </> : model.categories.map(c => button(`category:${c}`, topicName(c)))}
  </>;
}

/** The Feed's rail (owner-approved 2026-10-22, audit S16): Listen above a hairline (it isn't a topic), then Topics, whose
 * explanation is behind an ⓘ. */
export function FeedRail({ model, listen }: { model: FeedModel; listen?: ListenFilter }) {
  return <nav className="rail-nav" aria-label="Feed topics">
    {listen && <div className="rail-section feed-rail-listen"><ListenFilterButton selected={listen.selected} onSelect={() => listen.select(true)} rail /></div>}
    <div className="rail-section"><div className="rail-heading feed-topics-heading">Topics{!model.offered && <InfoTip text="Topics come from your library’s arXiv categories." testID="feed-topics-info" />}</div>
      <FeedChoices model={model} rail listen={listen} listenButton={false} />
    </div></nav>;
}

const ago = (at: number) => { const m = Math.max(0, Math.round((Date.now() - at) / 60_000)); return m < 1 ? 'just now' : m < 60 ? `${m} min ago` : `${Math.round(m / 60)} h ago`; };
const sorts: { value: FeedSort; label: string }[] = [ { value: 'suggested', label: 'Suggested' }, { value: 'newest', label: 'Newest' },
  { value: 'popularity', label: 'Popularity' }, { value: 'title', label: 'Title' }, { value: 'authors', label: 'Authors' }, { value: 'topic', label: 'Topics' } ];

export function FeedView({ model, library, showChips, listen, preparing, onAdded, onOpen, onLibrary, onReport }: { model: FeedModel; library: Library; showChips: boolean; listen?: ListenFilter;
  preparing?: Map<string, number | null>; onAdded?: (sourceID: string) => void; onOpen?: (sourceID: string) => void; onLibrary?: () => void; onReport?: () => void }) {
  useFeedLoading(model, !listen?.selected);
  const [adding, setAdding] = useState<string | null>(null);
  const [issue, setIssue] = useState<string | null>(null);
  const [lastFeedback, setLastFeedback] = useState<{ source: string; kind: FeedFeedback } | null>(null);
  const [feedbackBusy, setFeedbackBusy] = useState(false);
  const feedbackRequest = useRef<AbortController | null>(null);
  useEffect(() => () => feedbackRequest.current?.abort(), []);
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const [layout, setLayout] = useStored<'cards' | 'table'>('gradstep.feed.layout.v1', 'cards', v => v === 'cards' || v === 'table');
  const [hideLibrary, setHideLibrary] = useStored<boolean>('gradstep.feed.hide-library.v1', false, v => typeof v === 'boolean');
  const [ordering, setOrdering] = useState<{ selection: FeedSelection; key: FeedSort; ascending: boolean } | null>(null);
  const columnSettings = useFeedColumns();
  const sort = ordering?.selection === model.selected ? ordering : { key: personalFeed(model.selected) ? 'suggested' as const : 'newest' as const, ascending: false };
  const setSort = (key: FeedSort, ascending = ['title', 'authors', 'topic'].includes(key)) => setOrdering({ selection: model.selected, key, ascending });
  const inLibrary = useMemo(() => new Set(library.entries.filter(e => e.visible).map(e => e.source_id).filter((id): id is string => !!id)), [library.entries]);
  const current = model.loaded.get(model.selected);
  const shown = useMemo(() => orderFeed((current?.results ?? []).filter(r => model.feedback.get(r.source_id) !== 'not_interested' && (!hideLibrary || !inLibrary.has(r.source_id))), sort.key, sort.ascending),
    [current, hideLibrary, inLibrary, model.feedback, sort.key, sort.ascending]);
  const add = async (result: DiscoveryResult) => {
    if (adding || library.pending.has('add')) return;
    setAdding(result.source_id); setIssue(null);
    try { await library.addArxiv(result.source_id, null); onAdded?.(result.source_id); } catch (error) { setIssue(commandError(error)); } finally { setAdding(null); }
  };
  const feedback = async (source: string, kind: FeedFeedback | null) => {
    if (feedbackRequest.current && !feedbackRequest.current.signal.aborted) return;
    const controller = new AbortController(); feedbackRequest.current = controller;
    setFeedbackBusy(true); setIssue(null);
    try {
      await recordFeedFeedback(model.account, source, kind, controller.signal);
      if (controller.signal.aborted) return;
      model.updateFeedback(source, kind); setLastFeedback(kind ? { source, kind } : null);
    } catch { if (!controller.signal.aborted) setIssue('Couldn’t save your feed choice. Try again.'); }
    finally { if (!controller.signal.aborted) { setFeedbackBusy(false); feedbackRequest.current = null; } }
  };
  const toggle = (source: string) => setExpanded(previous => { const next = new Set(previous); next.has(source) ? next.delete(source) : next.add(source); return next; });
  const actions = { expanded, toggle, adding, inLibrary, add, addBlocked: library.state !== 'ready' || library.pending.has('add'),
    feedback: model.offered ? feedback : undefined, feedbackBusy, feedbackState: model.feedback, preparing, open: onOpen, library: onLibrary };
  return <section className={`feed${!listen?.selected && layout === 'table' ? ' feed-table-view' : ''}`} aria-labelledby="feed-title">
    <div className="view-head"><h1 id="feed-title">Feed</h1><span className="view-sub">{listen?.selected ? 'Listen to papers' : personalFeed(model.selected) ? selectionName(model.selected) : `Newest in ${selectionName(model.selected)}`}</span>
      {/* One "…" for the screen's options (owner-approved 2026-10-22, audit S16; RootView's Feed options). */}
      {!listen?.selected && <MenuButton icon="more" label="Feed options" testID="feed-options" className="screen-options">
        {close => <>
          <SubMenu label="View as" icon="grid" value={layout === 'cards' ? 'Cards' : 'Table'} testID="feed-view-as">
            {(['cards', 'table'] as const).map(l => <MenuCheck key={l} radio checked={layout === l} onClick={() => { close(); setLayout(l); }}>{l === 'cards' ? 'Cards' : 'Table'}</MenuCheck>)}
          </SubMenu>
          <SubMenu label="Sort by" icon="list" value={sorts.find(s => s.value === sort.key)?.label} testID="feed-sort">
            {sorts.filter(s => s.value !== 'suggested' || personalFeed(model.selected)).map(s => <MenuCheck key={s.value} radio checked={sort.key === s.value}
              onClick={() => { close(); setSort(s.value); }}>{s.label}</MenuCheck>)}
          </SubMenu>
          <MenuCheck checked={hideLibrary} onClick={() => setHideLibrary(!hideLibrary)} testID="feed-hide-library">Hide papers in my library</MenuCheck>
          {layout === 'table' && <button type="button" role="menuitem" className="menu-item" onClick={() => { close(); columnSettings.setChoosing(true); }} data-testid="feed-columns">
            <Icon name="table" size={14} /> Columns…</button>}
          <hr className="menu-divider" />
          <button type="button" role="menuitem" className="menu-item" disabled={model.state === 'loading'} onClick={() => { close(); model.load(model.selected); }} data-testid="feed-refresh">
            <Icon name="refresh" size={14} /> Refresh feed</button>
          {onReport && <button type="button" role="menuitem" className="menu-item" onClick={() => { close(); onReport(); }} data-testid="feed-report"><Icon name="bug" size={14} /> Report this screen</button>}
        </>}
      </MenuButton>}
    </div>
    {showChips && <div className="chips" role="toolbar" aria-label="Feed topics"><FeedChoices model={model} listen={listen} /></div>}
    {listen?.selected ? listen.view : <>
    <div className="feed-status" data-testid="feed-status"><span>{current ? `${shown.length} papers · ${model.state === 'loading' ? 'Refreshing…' : `Updated ${ago(current.refreshedAt ? Date.parse(current.refreshedAt) : current.at)}`}` : model.state === 'loading' ? 'Loading…' : ''}</span></div>
    {current?.coldStart && personalFeed(model.selected) && <p className="fine feed-note">Add papers or use More like this to tune For you.</p>}
    {issue && <p className="issue banner" role="alert">{issue}</p>}
    {lastFeedback && <div className="feed-feedback-notice" role="status"><span>{lastFeedback.kind === 'not_interested' ? 'Paper hidden from your feed.' : 'Your feed will suggest more papers like this.'}</span>
      <button className="link" disabled={feedbackBusy} onClick={() => void feedback(lastFeedback.source, null)}>Undo</button></div>}
    {model.state === 'failed' && <div className={current ? 'feed-note issue' : 'empty'} role="status"><p>{current ? 'Couldn’t refresh. These are the papers from your last update.' : 'New papers aren’t available right now.'}</p>
      <button className="secondary small" onClick={() => model.load(model.selected)}>Try again</button></div>}
    {model.state === 'loading' && !current && <div className="empty"><div className="spinner" aria-label="Loading the feed" /></div>}
    {current && shown.length === 0 && <div className="empty"><p>{current.results.length ? 'No papers match your filters.' : 'No new papers in this topic right now.'}</p>{hideLibrary && current.results.length > 0 && <button className="link" onClick={() => setHideLibrary(false)}>Show papers in your library</button>}</div>}
    {layout === 'table' ? <FeedTable results={shown} columns={columnSettings} sort={sort} setSort={setSort} actions={actions} />
      : shown.length > 0 && <FeedCards results={shown} actions={actions} />}
    </>}
  </section>;
}
