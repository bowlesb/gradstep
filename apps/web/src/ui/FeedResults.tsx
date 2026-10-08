import { type CSSProperties, Fragment, useEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { type DiscoveryResult, type FeedFeedback, type FeedSort, published, resultTopics } from '../lib/feed';
import { defaultFeedColumns, FEED_COLUMNS, FEED_COLUMNS_KEY, type FeedColumn, parseFeedColumns } from '../lib/feed-columns';
import { Dialog } from './common';
import { Icon } from './icons';
import { writeStored } from './prefs';

interface Actions {
  expanded: Set<string>; toggle(source: string): void; adding: string | null; inLibrary: Set<string>; addBlocked: boolean;
  add(paper: DiscoveryResult): Promise<void>; feedback?(source: string, kind: FeedFeedback | null): Promise<void>;
  feedbackBusy: boolean; feedbackState: Map<string, FeedFeedback>;
}
const address = (paper: DiscoveryResult) => `https://arxiv.org/abs/${paper.source_id}`;
const authors = (paper: DiscoveryResult) => paper.authors.slice(0, 6).join(', ') + (paper.authors.length > 6 ? ` +${paper.authors.length - 6}` : '');
function Popularity({ paper }: { paper: DiscoveryResult }) {
  return <span className="feed-popularity" title="Upvotes on Hugging Face Papers" aria-label={paper.upvotes === null ? 'Popularity unknown' : `${paper.upvotes} upvotes on Hugging Face Papers`}>
    {paper.upvotes === null ? '—' : `▲ ${paper.upvotes.toLocaleString()}`}</span>;
}
function Topics({ paper }: { paper: DiscoveryResult }) {
  return <span className="tags">{resultTopics(paper).map(t => <span key={t} className="tag static">{t}</span>)}</span>;
}
function Add({ paper, actions }: { paper: DiscoveryResult; actions: Actions }) {
  const have = actions.inLibrary.has(paper.source_id);
  return <button className={have ? 'pill passive' : 'pill accent'} disabled={have || !!actions.adding || actions.addBlocked} onClick={() => void actions.add(paper)}>
    {have ? 'In library' : actions.adding === paper.source_id ? 'Adding…' : '+ Add to library'}</button>;
}
function Feedback({ paper, actions }: { paper: DiscoveryResult; actions: Actions }) {
  const trigger = useRef<HTMLButtonElement>(null), menu = useRef<HTMLDivElement>(null);
  const [position, setPosition] = useState<{ left: number; top: number } | null>(null);
  const close = () => { setPosition(null); trigger.current?.focus({ preventScroll: true }); };
  useEffect(() => {
    if (!position) return;
    menu.current?.querySelector<HTMLButtonElement>('button:not(:disabled)')?.focus();
    const outside = (e: PointerEvent) => { if (!menu.current?.contains(e.target as Node) && !trigger.current?.contains(e.target as Node)) setPosition(null); };
    const moved = (e: Event) => { if (!menu.current?.contains(e.target as Node)) setPosition(null); };
    document.addEventListener('pointerdown', outside); window.addEventListener('resize', moved); document.addEventListener('scroll', moved, true);
    return () => { document.removeEventListener('pointerdown', outside); window.removeEventListener('resize', moved); document.removeEventListener('scroll', moved, true); };
  }, [position]);
  if (!actions.feedback) return null;
  const liked = actions.feedbackState.get(paper.source_id) === 'more_like_this';
  return <><button ref={trigger} className="icon-button feed-feedback-trigger" aria-label={`Feed choices for ${paper.title}`} title="Tune your feed" aria-haspopup="menu" aria-expanded={!!position}
    onClick={() => {
      if (position) { close(); return; }
      const bounds = trigger.current!.getBoundingClientRect();
      setPosition({ left: Math.max(8, Math.min(window.innerWidth - 188, bounds.right - 180)), top: bounds.top >= 94 ? bounds.top - 90 : bounds.bottom + 4 });
    }}><Icon name="more" size={18} /></button>
    {position && createPortal(<div ref={menu} className="feed-feedback-menu" role="menu" aria-label={`Feed choices for ${paper.title}`} style={position}
      onKeyDown={event => {
        if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); close(); }
        if (event.key === 'Tab') close();
        if (['ArrowUp', 'ArrowDown', 'Home', 'End'].includes(event.key)) {
          event.preventDefault(); const buttons = [...event.currentTarget.querySelectorAll<HTMLButtonElement>('button:not(:disabled)')];
          const index = buttons.indexOf(document.activeElement as HTMLButtonElement);
          buttons[event.key === 'Home' ? 0 : event.key === 'End' ? buttons.length - 1 : (index + (event.key === 'ArrowDown' ? 1 : -1) + buttons.length) % buttons.length]?.focus();
        }
      }}>
      <button role="menuitem" disabled={actions.feedbackBusy} onClick={() => { close(); void actions.feedback!(paper.source_id, liked ? null : 'more_like_this'); }}>{liked ? 'Undo more like this' : 'More like this'}</button>
      <button role="menuitem" disabled={actions.feedbackBusy} onClick={() => { close(); void actions.feedback!(paper.source_id, 'not_interested'); }}>Not interested</button>
    </div>, document.body)}
  </>;
}

function Abstract({ paper, expanded = false }: { paper: DiscoveryResult; expanded?: boolean }) {
  return <>
    <p className={`feed-abstract${expanded ? ' expanded' : ''}`} id={`abstract-${paper.source_id}`}>{paper.abstract ?? 'No abstract available.'}</p>
    {expanded && paper.abstractTruncated && <a className="link small-link" href={address(paper)} target="_blank" rel="noopener noreferrer">Read the full abstract on arXiv</a>}
  </>;
}

export function FeedCards({ results, actions }: { results: DiscoveryResult[]; actions: Actions }) {
  return <ul className="feed-grid" data-testid="feed-grid">{results.map(paper => <li key={paper.source_id} className={`feed-card${actions.expanded.has(paper.source_id) ? ' expanded' : ''}`}>
    <a className="feed-title" href={address(paper)} target="_blank" rel="noopener noreferrer">{paper.title}</a>
    {paper.reason && <p className="feed-reason">{paper.reason}</p>}
    {paper.authors.length > 0 && <div className="feed-authors" title={authors(paper)}>{authors(paper)}</div>}
    {paper.abstract && <>
      <Abstract paper={paper} expanded={actions.expanded.has(paper.source_id)} />
      <button className="link small-link" aria-expanded={actions.expanded.has(paper.source_id)} aria-controls={`abstract-${paper.source_id}`} onClick={() => actions.toggle(paper.source_id)}>
        {actions.expanded.has(paper.source_id) ? 'Less' : 'Full abstract'}</button>
    </>}
    <Topics paper={paper} />
    <div className="feed-meta"><span>{published(paper)}</span><Popularity paper={paper} /><span className="mono faint">{paper.source_id}</span><Add paper={paper} actions={actions} /><Feedback paper={paper} actions={actions} /></div>
  </li>)}</ul>;
}

const compact = () => typeof matchMedia === 'function' && matchMedia('(max-width: 759px)').matches;
export function useFeedColumns() {
  const [columns, update] = useState<FeedColumn[]>(() => {
    try { return parseFeedColumns(localStorage.getItem(FEED_COLUMNS_KEY)) ?? defaultFeedColumns(compact()); }
    catch { return defaultFeedColumns(compact()); }
  });
  const [choosing, setChoosing] = useState(false);
  const setColumns = (next: FeedColumn[]) => { update(next); writeStored(FEED_COLUMNS_KEY, { version: 1, columns: next }); };
  return { columns, setColumns, choosing, setChoosing, reset: () => setColumns(defaultFeedColumns(compact())) };
}
const SORT: Partial<Record<FeedColumn, FeedSort>> = { popularity: 'popularity', topic: 'topic', published: 'newest', authors: 'authors' };

export function FeedTable({ results, columns: settings, sort, setSort, actions, toolsSlot }: {
  results: DiscoveryResult[]; columns: ReturnType<typeof useFeedColumns>; sort: { key: FeedSort; ascending: boolean };
  setSort(key: FeedSort, ascending?: boolean): void; actions: Actions;
  toolsSlot: HTMLElement | null;
}) {
  const scroller = useRef<HTMLDivElement>(null);
  const [edges, setEdges] = useState({ left: false, right: false });
  const { columns, setColumns } = settings;
  const chosen = FEED_COLUMNS.filter(c => columns.includes(c.key));
  useEffect(() => {
    const element = scroller.current;
    if (!element) return;
    const measure = () => {
      const left = element.scrollLeft > 1, right = element.scrollLeft + element.clientWidth < element.scrollWidth - 1;
      setEdges(old => old.left === left && old.right === right ? old : { left, right });
    };
    const resize = new ResizeObserver(measure); resize.observe(element); if (element.firstElementChild) resize.observe(element.firstElementChild);
    element.addEventListener('scroll', measure, { passive: true }); measure();
    return () => { resize.disconnect(); element.removeEventListener('scroll', measure); };
  }, [results.length > 0, columns]);
  const header = (label: string, key?: FeedSort, className?: string) => <th className={className} scope="col" aria-sort={key === sort.key ? sort.ascending ? 'ascending' : 'descending' : undefined}>
    {key ? <button className="sort" onClick={() => setSort(key, key === sort.key ? !sort.ascending : undefined)}>{label}{sort.key === key ? sort.ascending ? ' ↑' : ' ↓' : ''}</button> : label}</th>;
  return <>
    <Dialog open={settings.choosing} onClose={() => settings.setChoosing(false)} title="Feed columns">
      <h2>Feed columns</h2><p className="fine">Title stays pinned as you scroll. Add always stays available.</p>
      <div className="column-choices"><label className="check"><input type="checkbox" checked disabled />Title<span className="fine">Always shown</span></label>
        {FEED_COLUMNS.map(column => <label className="check feed-column-choice" key={column.key}><input type="checkbox" checked={columns.includes(column.key)}
          onChange={e => setColumns(e.target.checked ? FEED_COLUMNS.filter(c => c.key === column.key || columns.includes(c.key)).map(c => c.key) : columns.filter(c => c !== column.key))} />
          <span>{column.label}<small>{column.detail}</small></span></label>)}
      </div><div className="row-actions column-actions"><button className="secondary" onClick={settings.reset}>Reset</button><button className="primary" onClick={() => settings.setChoosing(false)}>Done</button></div>
    </Dialog>
    {(edges.left || edges.right) && toolsSlot && createPortal(<div className="column-scroll-controls" role="group" aria-label="Scroll feed columns">
      <button className="icon-button" disabled={!edges.left} aria-label="Scroll feed columns left" onClick={() => { if (scroller.current) scroller.current.scrollLeft -= 240; }}><Icon name="chevronLeft" size={16} /></button>
      <button className="icon-button" disabled={!edges.right} aria-label="Scroll feed columns right" onClick={() => { if (scroller.current) scroller.current.scrollLeft += 240; }}><Icon name="chevronRight" size={16} /></button>
    </div>, toolsSlot)}
    {results.length > 0 && <div className="feed-table-wrap" ref={scroller} tabIndex={0} role="region" aria-label="Feed table" aria-describedby="feed-table-help"
      style={{ '--library-detail-width': `${chosen.reduce((n, c) => n + c.width, 0) + 170}px` } as CSSProperties}
      onKeyDown={event => {
        if (event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return;
        const target = event.target as HTMLElement;
        if (['ArrowLeft', 'ArrowRight'].includes(event.key) && (target === event.currentTarget || target.closest('.feed-expand, .sort'))) {
          event.preventDefault(); event.currentTarget.scrollLeft += event.key === 'ArrowLeft' ? -160 : 160;
        }
        if (['ArrowUp', 'ArrowDown'].includes(event.key) && target.matches('.feed-expand')) {
          const titles = [...event.currentTarget.querySelectorAll<HTMLButtonElement>('.feed-expand')], index = titles.indexOf(target as HTMLButtonElement);
          event.preventDefault(); titles[Math.max(0, Math.min(titles.length - 1, index + (event.key === 'ArrowDown' ? 1 : -1)))]?.focus();
        }
      }}
      onFocus={event => {
        const target = event.target as HTMLElement, cell = target.closest('td, th');
        if (!cell || cell.classList.contains('col-title')) return;
        const pinned = event.currentTarget.querySelector('th.col-title')?.getBoundingClientRect().right;
        if (!pinned) return;
        const bounds = target.getBoundingClientRect(), right = event.currentTarget.getBoundingClientRect().right;
        if (bounds.left < pinned) event.currentTarget.scrollLeft -= pinned - bounds.left;
        else if (bounds.right > right) event.currentTarget.scrollLeft += bounds.right - right;
      }}>
      <span id="feed-table-help" className="visually-hidden">Left and right arrows scroll columns. Up and down arrows move between paper titles. Expand a title for the full abstract.</span>
      <table className="papers feed-table" data-testid="feed-table" aria-label="Feed papers"><colgroup><col className="col-title" />{chosen.map(c => <col key={c.key} style={{ width: c.width }} />)}<col style={{ width: 170 }} /></colgroup>
        <thead><tr>{header('Title', 'title', 'col-title')}{chosen.map(c => <Fragment key={c.key}>{header(c.label, SORT[c.key])}</Fragment>)}<th scope="col"><span className="visually-hidden">Actions</span></th></tr></thead>
        <tbody>{results.map(paper => <Fragment key={paper.source_id}>
          <tr data-testid="feed-row"><td className="col-title"><button className="title feed-expand" aria-expanded={actions.expanded.has(paper.source_id)} aria-controls={`feed-details-${paper.source_id}`} onClick={() => actions.toggle(paper.source_id)}>{paper.title}</button>
            {paper.reason && <span className="feed-reason">{paper.reason}</span>}{paper.authors[0] && <span className="author">{paper.authors[0]}{paper.authors.length > 1 ? ' et al.' : ''}</span>}</td>
            {chosen.map(c => <td key={c.key} className={`feed-col-${c.key}`}>{c.key === 'popularity' ? <Popularity paper={paper} /> : c.key === 'topic' ? <Topics paper={paper} />
              : c.key === 'published' ? published(paper) : c.key === 'authors' ? <span title={authors(paper)}>{authors(paper) || '—'}</span>
                : c.key === 'arxiv' ? <a href={address(paper)} target="_blank" rel="noopener noreferrer">{paper.source_id}</a> : <p className="feed-abstract">{paper.abstract ?? '—'}</p>}</td>)}
            <td className="feed-row-actions"><Add paper={paper} actions={actions} /><Feedback paper={paper} actions={actions} /></td>
          </tr>
          {actions.expanded.has(paper.source_id) && <tr className="feed-detail-row" id={`feed-details-${paper.source_id}`}><td colSpan={chosen.length + 2}><div className="feed-details">
            <h3>{paper.title}</h3><p className="feed-authors">{authors(paper)}</p><Abstract paper={paper} expanded />
            <a className="link small-link" href={address(paper)} target="_blank" rel="noopener noreferrer">Open {paper.source_id} on arXiv</a>
          </div></td></tr>}
        </Fragment>)}</tbody>
      </table>
    </div>}
  </>;
}
