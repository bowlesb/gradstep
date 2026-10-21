import type { DevicePDFs } from './useDevicePDFs';
import { CatalogsDialog } from './Catalogs';
import { entryCatalogKey, arxivCatalogKey } from '../lib/library-catalogs';
import { compactAuthors, firstAuthorLine } from '../lib/authors';
import type { LibraryPaper, ClientEntry } from '../lib/device-pdf';
import { isLibraryPaper } from '../lib/reader-paper';
import { type ReaderPaper, isNewPaper, isReaderPaper, isSourcePaper, paperIdentity, readingSource } from '../lib/reader-paper';
// The library on a large screen (legacy LibraryView/PaperTable density, today's data): a dense,
// full-width table — Title, Authors, Year, Tags, Added, Opened, Progress — with sortable headers,
// the filters in the left rail (or as chips when the rail is hidden), live import progress with
// inline Retry/Remove/credits states, and a compact list beside an open paper.
import { type CSSProperties, type FocusEvent, type FormEvent, type KeyboardEvent, type RefObject, memo, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { flushSync } from 'react-dom';
import type { Activity } from '../lib/activity';
import { addFailure, addOutcome, type AddOutcome, addPaper } from '../lib/add';
import { parseArxiv } from '../lib/arxiv';
import { BackendError } from '../lib/backend';
import { type Preparation } from '../lib/keys';
import { CommandRefreshError, type Entry, type Import, type Item } from '../lib/library';
import { LIBRARY_COLUMNS, type LibraryColumn } from '../lib/library-columns';
import { type Row, rows as buildRows } from '../lib/paper';
import { type Mark, importStep, progressView, retryingAutomatically } from '../lib/progress';
import { Dialog, dateLines, formatDate, formatDateTime } from './common';
import { Icon } from './icons';
import { LibraryActionSurface, PaperMenuButton, useLibraryActions } from './LibraryActions';
import { useLibraryColumns } from './prefs';
import type { useLibrary } from './useLibrary';
import { LibraryRows, type LibraryRowsCommands, type LibraryViewport, WINDOW_THRESHOLD } from './LibraryRows';

export type Library = ReturnType<typeof useLibrary>;
type SortKey = 'title' | 'authors' | 'year' | 'tags' | 'added' | 'opened' | 'progress';
export type Filter = 'all' | 'unread' | 'reading' | 'failed' | 'archived';
export interface LibraryQuery { query: string; filter: Filter; tag: string; sort: { key: SortKey; descending: boolean } }
export const INITIAL_QUERY: LibraryQuery = { query: '', filter: 'all', tag: '', sort: { key: 'added', descending: true } };
type SetQuery = (update: (q: LibraryQuery) => LibraryQuery) => void;

export const commandError = (error: unknown) => {
  const code = error instanceof BackendError ? error.code : '';
  if (code === 'library_active_import_limit') return 'Several papers are already being added. Try again when one finishes.';
  if (code === 'library_account_import_limit' || code === 'library_account_receipt_limit') return 'Your library has reached its current limit.';
  if (code === 'request_rate_limit') return 'Too many changes in a short time. Try again in a minute.';
  if (code === 'import_not_retryable') return 'This paper can’t be retried. Remove it and add it again.';
  if (code === 'library_refresh_pending') return 'Your request reached Gradstep, but the library couldn’t refresh. Refresh the page to check its status.';
  if (code === 'library_command_pending') return 'This change is still updating. Wait for your library to refresh.';
  if (code === 'library_revision_conflict') return 'This paper changed since you last saw it. Check its status and try again.';
  if (code === 'library_not_ready') return 'Wait for your library to load, then add the paper.';
  if (code === 'connection') return 'Couldn’t reach Gradstep. Your change may not have been saved; check the list, then try again.';
  return 'Couldn’t update the library. Try again.';
};

const isReading = (a: Activity | undefined) => !!a && a.progress < 0.995;
const authorList = (entry: ClientEntry) => entry.metadata?.authors ?? [];
/** What this device holds of a paper, as the apps say it (PaperDeviceCopy): a check when it opens at once (prepared in
 * this tab, or a PDF here), a cloud when it still has to download. A browser keeps prepared papers for this tab only. */
type DeviceCopy = { kind: 'device' | 'cloud' | 'unavailable'; glyph: string; label: string };
export function deviceCopy(entry: ClientEntry, prepared: boolean): DeviceCopy | null {
  if (entry.kind === 'local_pdf') return entry.available ? { kind: 'device', glyph: '✓', label: 'PDF on this device' }
    : { kind: 'cloud', glyph: '☁︎', label: 'Not on this device yet; choose the PDF again to read it' };
  if (!isReaderPaper(entry)) return null;
  if (prepared) return { kind: 'device', glyph: '✓', label: 'On this device (prepared in this tab)' };
  if (isSourcePaper(entry) || readingSource(entry) || (entry.readiness === 'converted_ready' && entry.render_availability !== 'quarantined'))
    return { kind: 'cloud', glyph: '☁︎', label: 'Not on this device yet; downloads when you open it' };
  return { kind: 'unavailable', glyph: '!', label: 'No readable copy on this device' };
}
/** The row's device copy before its first author. */
function RowMarks({ copy }: { copy: DeviceCopy | null }) {
  return copy && <span className={`device ${copy.kind}`} title={copy.label} aria-label={copy.label} role="img" data-testid="device-badge">{copy.glyph}</span>;
}
/** A paper added in the last three days and never opened on this device (owner, build 42: an indicator for recently
 * added unread papers) as plain secondary words where "—" (never opened) would be. Build 75 (AK1U): the accent dot
 * beside the device check was "confusing". */
function NewLabel() {
  return <span className="new-label" title="Added recently, not opened yet" data-testid="new-label">New<span className="visually-hidden">, not opened yet</span></span>;
}
/** Where a row's New goes: the Opened column, else Progress, else beside the device mark (the first of them shown). */
const newSlot = (columns: readonly LibraryColumn[]): 'opened' | 'progress' | 'device' | null =>
  columns.includes('opened') ? 'opened' : columns.includes('progress') ? 'progress' : columns.includes('device') ? 'device' : null;

/** Rows, counts, tags and the filtered, sorted list for one library view. Shared by the table, rail and compact list. */
export function useLibraryModel(library: Library, current: Map<string, Activity>, view: LibraryQuery, visible = true) {
  const viewport = useRef<LibraryViewport | null>(null);
  const [windowed, setWindowed] = useState(false); // explicit opt-in, retained only for this account session
  // While no library view is showing (reading a paper), reading-place reports must not re-sort the library.
  const seen = useRef(current);
  if (visible) seen.current = current;
  const activity = seen.current;
  const [rowCache] = useState(() => new WeakMap<ClientEntry, Row>());
  const all = useMemo(() => buildRows(library.entries.filter(e => !library.catalogs || library.catalogs.state.catalogFor(entryCatalogKey(e)) === library.catalogs.currentID), rowCache), [library.entries, rowCache, library.catalogs?.state, library.catalogs?.currentID]);
  const counts = useMemo(() => {
    const live = all.filter(r => !r.archived);
    return {
      unread: live.filter(r => r.readable && !activity.has(r.entry.id)).length,
      reading: live.filter(r => r.readable && isReading(activity.get(r.entry.id))).length,
      failed: live.filter(r => r.failed).length, archived: all.filter(r => r.archived).length, total: live.length,
    };
  }, [all, activity]);
  const tags = useMemo(() => {
    const n = new Map<string, number>();
    for (const r of all) if (!r.archived) for (const t of r.tags) n.set(t, (n.get(t) ?? 0) + 1);
    return [...n].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
  }, [all]);
  const shown = useMemo(() => {
    const needle = view.query.trim().toLowerCase();
    const { filter, tag, sort } = view;
    const list = all.filter(r => {
      if (filter === 'archived' ? !r.archived : r.archived) return false;
      if (filter === 'unread' && !(r.readable && !activity.has(r.entry.id))) return false;
      if (filter === 'reading' && !(r.readable && isReading(activity.get(r.entry.id)))) return false;
      if (filter === 'failed' && !r.failed) return false;
      if (tag && !r.tags.includes(tag)) return false;
      if (!needle) return true;
      const m = r.entry.metadata;
      return [r.title, ...(m?.authors ?? []), ...r.tags, r.source, m?.venue ?? ''].some(s => s.toLowerCase().includes(needle));
    });
    const value = (r: Row): string | number => {
      const a = isReaderPaper(r.entry) ? activity.get(r.entry.id) : undefined;
      switch (sort.key) {
        case 'title': return r.title.toLowerCase();
        case 'authors': return (r.firstAuthor ?? '￿').toLowerCase();
        case 'year': return r.year ?? -1;
        case 'tags': return (r.tags[0] ?? '￿').toLowerCase();
        case 'added': return r.added ?? Number.MAX_SAFE_INTEGER; // imports in progress first when newest-first
        case 'opened': return a?.opened ?? -1;
        case 'progress': return a ? a.progress : -1;
      }
    };
    return list.sort((a, b) => {
      const x = value(a), y = value(b);
      const c = typeof x === 'number' && typeof y === 'number' ? x - y : String(x).localeCompare(String(y));
      return (sort.descending ? -c : c) || a.title.localeCompare(b.title);
    });
  }, [all, view, activity]);
  return { all, counts, tags, shown, viewport, windowed, setWindowed, library };
}
export type LibraryModel = ReturnType<typeof useLibraryModel>;

const FILTERS: { value: Filter; label: string }[] = [
  { value: 'all', label: 'All papers' }, { value: 'unread', label: 'Unread' }, { value: 'reading', label: 'Reading' },
  { value: 'failed', label: 'Failed' }, { value: 'archived', label: 'Archived' },
];
const filterCount = (model: LibraryModel, f: Filter) => f === 'all' ? model.counts.total : model.counts[f];
/** Only filters that would change the list appear (DESIGN.md › Filters). */
const offered = (model: LibraryModel, f: Filter) => f === 'all' || (f === 'unread' ? model.counts.unread > 0 && model.counts.unread < model.counts.total : filterCount(model, f) > 0);

/** The library route's left rail: the views and the tags, with counts. */
export function LibraryRail({ model, view, setView }: { model: LibraryModel; view: LibraryQuery; setView: SetQuery }) {
  return (
    <nav className="rail-nav" aria-label="Library filters">
      <div className="rail-section">
        {FILTERS.filter(f => offered(model, f.value)).map(f => (
          <button key={f.value} className={`rail-item${view.filter === f.value ? ' selected' : ''}${f.value === 'failed' ? ' problem' : ''}`} aria-pressed={view.filter === f.value}
            onClick={() => setView(q => ({ ...q, filter: f.value }))}>
            <span className="rail-label">{f.value === 'all' ? 'All papers' : f.label}</span><span className="rail-count">{filterCount(model, f.value) || ''}</span>
          </button>
        ))}
      </div>
      {model.tags.length > 0 && (
        <div className="rail-section">
          <div className="rail-heading">Tags{view.tag && <button className="rail-clear" onClick={() => setView(q => ({ ...q, tag: '' }))}>Clear</button>}</div>
          {model.tags.map(([t, n]) => (
            <button key={t} className={`rail-item tag-item${view.tag === t ? ' selected' : ''}`} aria-pressed={view.tag === t} onClick={() => setView(q => ({ ...q, tag: q.tag === t ? '' : t }))}>
              <span className="rail-label">{t}</span><span className="rail-count">{n}</span>
            </button>
          ))}
        </div>
      )}
    </nav>
  );
}

/** The same filters as chips, when the rail isn't showing. */
function FilterChips({ model, view, setView }: { model: LibraryModel; view: LibraryQuery; setView: SetQuery }) {
  const chip = (value: Filter, label: string) => (
    <button key={value} className={view.filter === value ? 'chip selected' : 'chip'} aria-pressed={view.filter === value} onClick={() => setView(q => ({ ...q, filter: value }))}>
      {label}{value === 'failed' && model.counts.failed > 0 ? <span className="chip-count"> {model.counts.failed}</span> : null}
    </button>
  );
  return (
    <div className="chips" role="toolbar" aria-label="Filter library">
      {model.tags.length > 0 && (
        <label className="tag-select"><span className="visually-hidden">Tag</span>
          <select value={view.tag} onChange={e => setView(q => ({ ...q, tag: e.target.value }))} aria-label="Filter by tag">
            <option value="">Tags</option>
            {model.tags.map(([t, n]) => <option key={t} value={t}>{t} ({n})</option>)}
          </select>
        </label>
      )}
      {FILTERS.filter(f => offered(model, f.value)).map(f => chip(f.value, f.value === 'all' ? 'All' : f.label))}
    </div>
  );
}

function useCommandRunner() {
  const [notice, setNotice] = useState<{ text: string; pendingKey?: string; onObserved?: string } | null>(null);
  const run = useCallback(async (key: string, promise: Promise<unknown>) => {
    setNotice(null);
    try { await promise; } catch (error) {
      setNotice({ text: commandError(error), pendingKey: error instanceof CommandRefreshError ? key : undefined,
        onObserved: error instanceof CommandRefreshError && error.response.result.status === 'revision_conflict'
          ? commandError(new BackendError('library_revision_conflict')) : undefined });
    }
  }, []);
  return { notice, setNotice, run };
}

/** Arrow keys move between the rows' links (the table's managed focus). */
function moveRowFocus(event: KeyboardEvent<HTMLElement>, selector: string) {
  if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return;
  const links = [...event.currentTarget.querySelectorAll<HTMLElement>(selector)];
  const index = links.indexOf(document.activeElement as HTMLElement);
  if (index < 0) return;
  event.preventDefault();
  links[Math.max(0, Math.min(links.length - 1, index + (event.key === 'ArrowDown' ? 1 : -1)))]?.focus();
}

/** The scroll region and row/header links keep horizontal movement available without moving the page. */
function scrollColumns(event: KeyboardEvent<HTMLDivElement>) {
  if (event.altKey || event.ctrlKey || event.metaKey || event.shiftKey || !['ArrowLeft', 'ArrowRight'].includes(event.key)) return;
  const target = event.target as HTMLElement;
  if (target !== event.currentTarget && !target.closest('a.title, button.sort')) return;
  event.preventDefault();
  event.currentTarget.scrollLeft += event.key === 'ArrowRight' ? 160 : -160;
}

/** Native focus scrolling doesn't account for an overlapping sticky cell. Keep focused controls uncovered. */
function revealColumnFocus(event: FocusEvent<HTMLDivElement>) {
  const target = event.target as HTMLElement, cell = target.closest('td, th');
  if (!cell || cell.classList.contains('col-title')) return;
  const scroller = event.currentTarget, pinned = scroller.querySelector('th.col-title');
  if (!pinned) return;
  const bounds = target.getBoundingClientRect(), left = pinned.getBoundingClientRect().right, right = scroller.getBoundingClientRect().right;
  if (bounds.left < left) scroller.scrollLeft -= left - bounds.left;
  else if (bounds.right > right) scroller.scrollLeft += bounds.right - right;
}

/** Overlay scrollbars can be invisible. Keep an explicit affordance without rerendering rows on scroll. */
function ColumnScrollControls({ scroller, available }: { scroller: RefObject<HTMLDivElement | null>; available: boolean }) {
  const [edge, setEdge] = useState({ left: false, right: false });
  useEffect(() => {
    const element = scroller.current;
    if (!element || !available) { setEdge({ left: false, right: false }); return; }
    const measure = () => {
      const left = element.scrollLeft > 1, right = element.scrollLeft + element.clientWidth < element.scrollWidth - 1;
      setEdge(previous => previous.left === left && previous.right === right ? previous : { left, right });
    };
    const observer = new ResizeObserver(measure);
    observer.observe(element);
    const table = element.querySelector('table');
    if (table) observer.observe(table);
    element.addEventListener('scroll', measure, { passive: true });
    measure();
    return () => { observer.disconnect(); element.removeEventListener('scroll', measure); };
  }, [scroller, available]);
  if (!edge.left && !edge.right) return null;
  const scroll = (direction: number) => {
    const element = scroller.current;
    if (!element) return;
    // One useful visible detail area at a time, keeping a small overlap for orientation.
    const titleWidth = element.querySelector('th.col-title')?.getBoundingClientRect().width ?? 200;
    element.scrollLeft += direction * Math.max(120, element.clientWidth - titleWidth - 24);
  };
  return <div className="column-scroll-controls" role="group" aria-label="Scroll library columns">
    <button className="icon-button" disabled={!edge.left} onClick={() => scroll(-1)} aria-label="Scroll columns left" title="Scroll columns left"><Icon name="chevronLeft" size={16} /></button>
    <button className="icon-button" disabled={!edge.right} onClick={() => scroll(1)} aria-label="Scroll columns right" title="Scroll columns right"><Icon name="chevronRight" size={16} /></button>
  </div>;
}

export function LibraryView({ library, model, activity, view, setView, showChips, currentID, onOpen, onAdd, prepared, onSimilar }: {
  library: Library; model: LibraryModel; activity: Map<string, Activity>; view: LibraryQuery; setView: SetQuery; showChips: boolean;
  /** Whether this tab has the paper prepared (the row's check); without it every paper shows as still to download. */
  prepared?: (entry: ClientEntry) => boolean;
  currentID: string | null; onOpen: (item: LibraryPaper) => void; onAdd: () => void; onSimilar?:(item:LibraryPaper)=>void;
}) {
  const { notice, setNotice, run } = useCommandRunner();
  const { columns, setColumns, reset } = useLibraryColumns();
  const [choosingColumns, setChoosingColumns] = useState(false);
  const [showCatalogs, setShowCatalogs] = useState(false);
  const selectedCatalog = library.catalogs?.currentID;
  const lastCatalog = useRef(selectedCatalog);
  useEffect(() => { if (lastCatalog.current !== selectedCatalog) { lastCatalog.current = selectedCatalog; setView(q => ({ ...q, query: '', tag: '' })); } }, [selectedCatalog, setView]);
  const showAll = useCallback(() => model.setWindowed(false), [model.setWindowed]);
  const rowCommands = useRef<LibraryRowsCommands | null>(null);
  const prepareMenuTab = useCallback(() => rowCommands.current?.beforeSequentialNavigation(), []);
  const actions = useLibraryActions(library, prepareMenuTab, undefined, onSimilar);
  const [printing, setPrinting] = useState(false);
  const scroller = useRef<HTMLDivElement>(null);
  const tableHeader = useRef<HTMLTableSectionElement>(null);
  const selection = document.getSelection();
  const selectedText = !!selection && !selection.isCollapsed && !!scroller.current
    && (scroller.current.contains(selection.anchorNode) || scroller.current.contains(selection.focusNode));
  // Native Find searches the whole current result set. Keep full mode until the reader chooses
  // windowing again; native Find's close/menu commands have no observable browser API.
  useEffect(() => {
    const find = (event: globalThis.KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && !event.altKey && event.key.toLowerCase() === 'f' && !document.querySelector('dialog[open]')) {
        flushSync(showAll); // allow the browser's normal Find command afterwards
      }
    };
    const beforePrint = () => { rowCommands.current?.beforePrint(); flushSync(() => setPrinting(true)); };
    const afterPrint = () => setPrinting(false);
    addEventListener('keydown', find, true); addEventListener('beforeprint', beforePrint); addEventListener('afterprint', afterPrint);
    return () => { removeEventListener('keydown', find, true); removeEventListener('beforeprint', beforePrint); removeEventListener('afterprint', afterPrint); };
  }, [showAll]);
  useEffect(() => {
    if (notice?.pendingKey && !library.pending.has(notice.pendingKey)) setNotice(notice.onObserved ? { text: notice.onObserved } : null);
  }, [notice, library.pending, setNotice]);
  const { all, counts, shown } = model;
  const visibleColumns = LIBRARY_COLUMNS.filter(c => columns.includes(c.key));
  const sortedHidden = view.sort.key !== 'title' && !columns.includes(view.sort.key);
  const header = (key: SortKey, label: string, className: string) => (
    <th key={key} className={className} aria-sort={view.sort.key === key ? (view.sort.descending ? 'descending' : 'ascending') : 'none'} scope="col">
      <button className="sort" onClick={() => setView(q => ({ ...q, sort: { key, descending: q.sort.key === key ? !q.sort.descending : !['title', 'authors', 'tags'].includes(key) } }))}>
        {label}{view.sort.key === key && <span className="sort-mark" aria-hidden="true">{view.sort.descending ? ' ↓' : ' ↑'}</span>}
      </button>
    </th>
  );
  const describe = [view.filter !== 'all' ? FILTERS.find(f => f.value === view.filter)!.label : null, view.tag || null, view.query.trim() ? `“${view.query.trim()}”` : null].filter(Boolean);

  return (
    <section className="library" aria-labelledby="library-title">
      <div className="view-head library-head">
        <h1 id="library-title">Library</h1>
        <span className="view-sub" aria-live="polite">
          {library.state === 'ready' || all.length ? `${shown.length.toLocaleString()} ${shown.length === 1 ? 'paper' : 'papers'}${describe.length ? ` · ${describe.join(' · ')}` : ''}` : ''}
        </span>
        {(describe.length > 0) && <button className="link small-link" onClick={() => setView(q => ({ ...q, filter: 'all', tag: '', query: '' }))}>Clear filters</button>}
        <div className="library-table-tools">
          <button className="secondary small" onClick={() => setShowCatalogs(true)} aria-haspopup="dialog">Catalogs</button>
          <ColumnScrollControls scroller={scroller} available={all.length > 0} />
          <button className="secondary small columns-button" aria-haspopup="dialog" aria-expanded={choosingColumns} onClick={() => setChoosingColumns(true)}>Columns</button>
        </div>
        {sortedHidden && <span className="fine library-sort-note">Sorted by {LIBRARY_COLUMNS.find(c => c.key === view.sort.key)?.label} {view.sort.descending ? '↓' : '↑'}</span>}
      </div>
      <CatalogsDialog open={showCatalogs} onClose={() => setShowCatalogs(false)} library={library} />
      {library.catalogs && (library.catalogs.state.catalogs.length > 1 || library.catalogs.state.catalogs[0].name !== 'Default') && <label className="catalog-switch">Catalog <select aria-label="Current catalog" value={library.catalogs.currentID} onChange={e => library.catalogs?.select(e.target.value)}>
        {library.catalogs.state.catalogs.map(c => <option key={c.id} value={c.id}>{c.name}</option>)}</select></label>}
      <Dialog open={choosingColumns} onClose={() => setChoosingColumns(false)} title="Library columns">
        <h2>Library columns</h2>
        <p className="fine">Title stays pinned as you scroll.</p>
        <div className="column-choices">
          <label className="check"><input type="checkbox" checked disabled />Title <span className="fine">Always shown</span></label>
          {LIBRARY_COLUMNS.map(column => <label className="check" key={column.key}>
            <input type="checkbox" checked={columns.includes(column.key)} onChange={event => setColumns(event.target.checked
              ? LIBRARY_COLUMNS.filter(c => c.key === column.key || columns.includes(c.key)).map(c => c.key)
              : columns.filter(c => c !== column.key))} />{column.label}
          </label>)}
          {model.shown.length >= WINDOW_THRESHOLD && <div className="library-window-choice">
            <label className="check"><input type="checkbox" checked={model.windowed} disabled={selectedText && !model.windowed} onChange={event => model.setWindowed(event.target.checked)} />Show rows as you scroll</label>
            <p className="fine">Keep off for browser-menu Find and full screen-reader browsing. Keyboard Find, Tab and selecting text load every row.</p>
            {selectedText && <p className="fine">Clear the text selection to show rows as you scroll.</p>}
          </div>}
        </div>
        <div className="row-actions column-actions"><button className="secondary" onClick={reset}>Reset</button><button className="primary" onClick={() => setChoosingColumns(false)}>Done</button></div>
      </Dialog>
      {showChips && (counts.total > 0 || counts.archived > 0) && <FilterChips model={model} view={view} setView={setView} />}
      {notice && <p className="issue banner" role="alert">{notice.text}</p>}
      <LibraryActionSurface actions={actions} />
      {library.state === 'loading' && all.length === 0 && <div className="empty"><div className="spinner" aria-label="Loading library" /></div>}
      {library.state === 'error' && all.length === 0 && (
        <div className="empty"><p>Couldn’t load your library.</p><button className="secondary" onClick={() => library.refresh().catch(() => {})}>Try again</button></div>
      )}
      {library.state === 'ready' && all.length === 0 && (
        <div className="empty"><p><strong>Your library is empty.</strong></p><p className="muted">Add a paper by its arXiv ID, DOI or a link.</p>
          <button className="primary" onClick={onAdd}>Add paper</button></div>
      )}
      {all.length > 0 && (
        <div className="table-wrap" ref={scroller} tabIndex={0} role="region" aria-label="Library table" aria-describedby="library-scroll-help"
          onKeyDown={scrollColumns} onFocus={revealColumnFocus}
          style={{ '--library-detail-width': `${visibleColumns.reduce((sum, c) => sum + c.width, 0)}px` } as CSSProperties}>
          <span id="library-scroll-help" className="visually-hidden">Left and right arrows scroll columns. Up and down arrows move between paper titles.</span>
          <table className="papers" data-testid="library-table" aria-label="Papers" aria-rowcount={shown.length + 1}>
            <colgroup><col className="col-title" />{visibleColumns.map(c => <col key={c.key} style={{ width: c.width }} />)}</colgroup>
            <thead ref={tableHeader}><tr aria-rowindex={1}>
              {header('title', 'Title', 'col-title')}{visibleColumns.map(c => c.key === 'device' ? <th key={c.key} className="col-device" scope="col">{c.label}</th> : header(c.key, c.label, `col-${c.key}`))}
            </tr></thead>
            <LibraryRows rows={shown} scroller={scroller} header={tableHeader} viewport={model.viewport}
              query={JSON.stringify(view)} columns={columns} full={!model.windowed || printing} printing={printing} commands={rowCommands} showAll={showAll} render={(row, index, measure) => {
                const a = isReaderPaper(row.entry) ? activity.get(row.entry.id) : undefined;
                return <PaperRow key={row.key} row={row} opened={a?.opened ?? null} progress={a ? a.progress : null} mark={library.marks.get(row.entry.id)}
                  onDevice={!!prepared?.(row.entry)} isNew={isReaderPaper(row.entry) && isNewPaper(row.entry, !!a)} activeTag={view.tag}
                  busy={library.pending.has(row.entry.id)} current={row.entry.id === currentID} onOpen={onOpen} retry={library.retry} remove={library.remove} run={run}
                  onTag={setView} columns={columns} index={index} measure={measure} menuOpen={actions.menuItemID === row.entry.id} onMenu={actions.open} />;
              }} />
          </table>
        </div>
      )}
    </section>
  );
}

/** Only an active import row ticks. Ready papers and the table's query/sort state stay idle. */
function useImportProgress(entry: ClientEntry, mark?: Mark) {
  const active = entry.kind === 'import' && !!(importStep(entry) || retryingAutomatically(entry));
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    if (!active) return;
    const tick = () => { if (document.visibilityState === 'visible') setNow(Date.now()); };
    tick();
    const clock = setInterval(tick, 1000);
    document.addEventListener('visibilitychange', tick);
    return () => { clearInterval(clock); document.removeEventListener('visibilitychange', tick); };
  }, [active]);
  return entry.kind === 'import' ? progressView(entry, mark, now) : null;
}

function RowAction({ row, busy, retry, remove, run }: { row: Row; busy: boolean; retry: Library['retry']; remove: Library['remove']; run: (key: string, p: Promise<unknown>) => void }) {
  const entry = row.entry;
  if (entry.kind !== 'import' || !row.action || busy) return null;
  if (row.action === 'retry') return <button className="pill" onClick={e => { e.stopPropagation(); run(entry.id, retry(entry as Import)); }}>Retry</button>;
  if (row.action === 'remove') return <button className="pill" onClick={e => { e.stopPropagation(); run(entry.id, remove(entry as Import)); }}>Remove</button>;
  return <span className="pill passive" title="Credits can be added in Gradstep on iPhone, iPad or Mac">Get credits in the app</span>;
}

const PaperRow = memo(function PaperRow({ row, opened, progress: readingProgress, mark, busy, current, onOpen, retry, remove, run, onTag, columns, index, measure, menuOpen, onMenu, onDevice, isNew, activeTag }: {
  row: Row; opened: number | null; progress: number | null; mark?: Mark; busy: boolean; current: boolean; onDevice: boolean; isNew: boolean; activeTag: string;
  onOpen: (item: LibraryPaper) => void; retry: Library['retry']; remove: Library['remove']; run: (key: string, p: Promise<unknown>) => void; onTag: SetQuery; columns: readonly LibraryColumn[];
  index: number; measure?: (element: HTMLTableRowElement | null) => void;
  menuOpen: boolean; onMenu: ReturnType<typeof useLibraryActions>['open'];
}) {
  const entry = row.entry;
  const progress = useImportProgress(entry, mark);
  const open = () => { if (row.readable && isLibraryPaper(entry)) onOpen(entry); };
  const authors = authorList(entry);
  // A paper still being added (no title or authors yet) keeps the height it will have: two title lines and, when the
  // authors show under the title (no Authors column), their line (owner, build 58), so the row never grows when its
  // details arrive.
  const adding = entry.kind === 'import' && !entry.metadata && ['accepted', 'resolving', 'acquiring'].includes(entry.phase);
  const fresh = isNew ? newSlot(columns) : null;
  return (
    <tr ref={measure} data-index={index} data-row-key={row.key} aria-rowindex={index + 2}
      className={`${row.readable ? 'readable' : 'pending'}${adding ? ' adding' : ''}${current ? ' current' : ''}`} onClick={open} data-testid="paper-row">
      <td className="col-title">
        {isLibraryPaper(entry) && <PaperMenuButton item={entry} busy={busy} expanded={menuOpen} onOpen={onMenu} />}
        {row.readable ? <a href={`/paper/${entry.id}`} onClick={e => { e.preventDefault(); e.stopPropagation(); open(); }} className="title" title={row.title}>{row.title}</a>
          : <span className="title" title={row.title}>{row.title}</span>}

        {row.status && !progress && <span className={`status ${row.status.kind}`}>{row.status.kind === 'problem' ? '⚠︎ ' : ''}{row.status.text}</span>}
        {progress && <span className="status active" aria-label={progress.label}>{progress.title}{progress.detail ? ` (${progress.detail})` : ''}</span>}
        {busy && <span className="status active">Updating…</span>}
        <span className="inline-action"><RowAction row={row} busy={busy} retry={retry} remove={remove} run={run} /></span>
      </td>
      {columns.includes('device') && <td className="col-device"><RowMarks copy={deviceCopy(entry, onDevice)} />{fresh === 'device' && <> <NewLabel /></>}</td>}
      {columns.includes('authors') && <td className="col-authors" title={authors.join(', ')}>{compactAuthors(authors) || <span className="faint">—</span>}</td>}
      {columns.includes('year') && <td className="col-year">{row.year ?? '—'}</td>}
      {columns.includes('tags') && <td className="col-tags">{row.tags.length ? <span className="tags">{row.tags.slice(0, 4).map(t => (
        // Tapping the active tag again clears the filter; the active one is drawn in the accent (PaperTable's chips).
        <button className={t === activeTag ? 'tag on' : 'tag'} key={t} aria-pressed={t === activeTag} onClick={e => { e.stopPropagation(); onTag(q => ({ ...q, tag: q.tag === t ? '' : t })); }}
          title={t === activeTag ? `Show all papers` : `Show papers tagged “${t}”`}>{t}</button>))}</span>
        : <span className="faint">—</span>}</td>}
      {columns.includes('added') && <td className="col-added"><TableDate ms={row.added} /></td>}
      {columns.includes('opened') && <td className="col-opened">{fresh === 'opened' ? <NewLabel /> : <TableDate ms={opened} />}</td>}
      {columns.includes('progress') && <td className="col-progress">
        {progress ? (
          <span className="import-progress" data-testid="import-progress">
            {progress.percent !== null ? <progress max={100} value={progress.percent} aria-label={progress.label} /> : <span className="spinner small" aria-label={progress.label} />}
            <span className="fine">{[progress.percent !== null ? `${progress.percent}%` : null, progress.compactTime].filter(Boolean).join(' · ')}</span>
          </span>
        ) : row.readable ? (
          readingProgress !== null ? <span className="reading-progress"><progress className="accent" max={1} value={readingProgress} aria-label={`${Math.round(readingProgress * 100)}% read`} />
            <span className="fine">{Math.round(readingProgress * 100)}%</span></span> : fresh === 'progress' ? <NewLabel /> : <span className="faint">—</span>
        ) : <span className="faint">—</span>}
      </td>}
    </tr>
  );
});

/** A date cell: one line when the column is wide, the day over the time when narrow (PaperTableDate). */
function TableDate({ ms }: { ms: number | null }) {
  if (!ms) return <span className="faint">—</span>;
  const lines = dateLines(ms);
  return <span className="table-date" title={new Date(ms).toLocaleString()}><span className="one-line">{formatDateTime(ms)}</span>
    <span className="two-lines"><span>{lines.day}</span>{lines.time && <span className="time">{lines.time}</span>}</span></span>;
}

/** Beside an open paper (the legacy Browse view): the same library, compact. */
export function CompactLibrary({ model, activity, currentID, onOpen, query, prepared, onSimilar }: {
  model: LibraryModel; activity: Map<string, Activity>; currentID: string | null; onOpen: (item: LibraryPaper) => void; query: string; prepared?: (entry: ClientEntry) => boolean; onSimilar?:(item:LibraryPaper)=>void;
}) {
  const list = useRef<HTMLUListElement>(null);
  const actions = useLibraryActions(model.library,undefined,undefined,onSimilar);
  useEffect(() => { list.current?.querySelector('.current')?.scrollIntoView({ block: 'nearest' }); }, []);
  return (
    <div className="compact-library">
      <LibraryActionSurface actions={actions} />
      {query.trim() && <p className="fine compact-note">{model.shown.length} {model.shown.length === 1 ? 'match' : 'matches'} for “{query.trim()}”</p>}
      <ul ref={list} className="compact-list" aria-label="Library" onKeyDown={e => moveRowFocus(e, 'a.compact-link')}>
        {model.shown.map(row => {
          const entry = row.entry, a = isReaderPaper(entry) ? activity.get(entry.id) : undefined;
          const meta = [firstAuthorLine(entry.metadata?.authors ?? []) || null, row.year].filter(Boolean).join(' · ');
          return (
            <li key={row.key} className={entry.id === currentID ? 'current' : undefined}>
              {isLibraryPaper(entry) && <PaperMenuButton item={entry} busy={model.library.pending.has(entry.id)} expanded={actions.menuItemID === entry.id} onOpen={actions.open} />}
              {row.readable && isLibraryPaper(entry)
                ? <a className="compact-link" href={`/paper/${entry.id}`} aria-current={entry.id === currentID ? 'page' : undefined}
                    onClick={e => { e.preventDefault(); onOpen(entry); }}><span className="compact-title">{row.title}</span>
                    <span className="compact-meta"><RowMarks copy={deviceCopy(entry, !!prepared?.(entry))} />
                      {isReaderPaper(entry) && isNewPaper(entry, !!a) && <><NewLabel />{meta ? ' · ' : ''}</>}{meta}</span>
                    {a && <progress className="accent mini" max={1} value={a.progress} aria-label={`${Math.round(a.progress * 100)}% read`} />}</a>
                : <span className="compact-link disabled"><span className="compact-title">{row.title}</span><span className="compact-meta">{row.status?.text ?? meta}</span></span>}
            </li>
          );
        })}
        {model.shown.length === 0 && <li className="fine compact-note">No papers match.</li>}
      </ul>
    </div>
  );
}

type AddKeys = Pick<Extract<Preparation, { kind: 'ready' }>, 'ring' | 'deviceID'>;

/** Why a chosen file could not become a local paper, in the reader's words. */
function pdfFailure(error: unknown): string {
  const code = error instanceof BackendError ? error.code : '';
  if (code === 'invalid_upload') return 'Choose a readable PDF file.';
  if (code === 'upload_too_large') return 'That PDF is larger than the 64 MB limit.';
  if (code === 'connection') return 'The file could not be read. Choose it again and retry.';
  return 'The PDF could not be opened on this device. Choose it again and try again.';
}

/** Add paper: an arXiv ID stays a library command; a DOI or any link goes to add-paper.
 * A selected PDF is checked and kept on this device; only its encrypted membership syncs. */
export function AddPaper({ open, onClose, library, account, keys, localPDFs }: { localPDFs:DevicePDFs; open: boolean; onClose: () => void; library: Library; account: string; keys: AddKeys }) {
  const [text, setText] = useState('');
  const [file, setFile] = useState<File | null>(null);
  const [issue, setIssue] = useState<string | null>(null);
  const [outcome, setOutcome] = useState<AddOutcome | null>(null);
  const [busy, setBusy] = useState(false);
  const [progress, setProgress] = useState<{ phase: 'checking' } | null>(null);
  const [awaitingObservation, setAwaitingObservation] = useState(false);
  const input = useRef<HTMLInputElement | null>(null);
  const request = useRef<AbortController | null>(null);
  useEffect(() => {
    if (awaitingObservation && !library.pending.has('add')) {
      setAwaitingObservation(false); setIssue(null); setText(''); onClose();
    }
  }, [awaitingObservation, library.pending, onClose]);
  useEffect(() => () => request.current?.abort(), []);
  const close = () => { if (busy) return; setIssue(null); setOutcome(null); setProgress(null); setFile(null); if (input.current) input.current.value = ''; onClose(); };
  const choose = (next: File | null) => {
    if (!next) return;
    setFile(next); setText(''); setIssue(null); setOutcome(null); setProgress(null);
  };

  async function submit(event: FormEvent) {
    event.preventDefault();
    if (busy || awaitingObservation || library.pending.has('add')) return;
    if (file) {
      const controller = new AbortController(); request.current = controller; setBusy(true); setIssue(null); setOutcome(null);
      try {
        setProgress({ phase: 'checking' });
        await localPDFs.add(file);
        if (controller.signal.aborted) return;
        setOutcome({ status: 'added', message: 'Added to your library. The PDF stays on this device; choose it again after reopening this tab.', link: null, finished: true });
        setFile(null); setProgress(null); if (input.current) input.current.value = '';
      } catch (error) {
        if (!controller.signal.aborted) setIssue(error instanceof Error && !(error instanceof BackendError) ? error.message : pdfFailure(error));
      }
      finally { if (!controller.signal.aborted) setBusy(false); }
      return;
    }
    const value = text.trim();
    if (!value) return;
    setBusy(true); setIssue(null); setOutcome(null);
    const reference = parseArxiv(value);
    if (reference) {
      try { await library.addArxiv(reference.sourceID, reference.revision); setText(''); onClose(); }
      catch (error) { setIssue(commandError(error)); if (error instanceof CommandRefreshError) setAwaitingObservation(true); }
      finally { setBusy(false); }
      return;
    }
    if (/^\d{4}\.\d{4,5}|^[a-z-]+(\.[A-Z]{2})?\/\d{7}/i.test(value) || /arxiv\.org/i.test(value)) {
      setBusy(false); setIssue('Enter an arXiv identifier or link, like 2305.18290 or https://arxiv.org/abs/2305.18290.'); return;
    }
    const controller = new AbortController();
    request.current = controller;
    const destination = library.catalogs?.currentID;
    try {
      const raw = await addPaper(account, value, controller.signal);
      const key = raw.paper?.source_id && arxivCatalogKey(raw.paper.source_id);
      if (raw.status === 'added' && key && destination) await library.catalogs?.assign(key, destination);
      const result = addOutcome(raw);
      if (controller.signal.aborted) return;
      if (result.finished) { library.refresh().catch(() => {}); setText(''); }
      setOutcome(result);
    } catch (error) { if (!controller.signal.aborted) setIssue(addFailure(error)); }
    finally { if (!controller.signal.aborted) setBusy(false); }
  }
  const adding = busy || awaitingObservation || library.pending.has('add');
  const selectedName = file?.name ?? null;
  const progressText = progress ? 'Checking PDF…' : null;
  return (
    <Dialog open={open} onClose={close} title="Add paper">
      <form onSubmit={submit} noValidate>
        <h2>Add paper</h2>
        <label>arXiv ID, DOI or link
          <input autoFocus value={text} readOnly={adding} onChange={e => { setText(e.target.value); if (file) { setFile(null); if (input.current) input.current.value = ''; } setOutcome(null); setIssue(null); }}
            placeholder="2305.18290, 10.48550/arXiv.2305.18290 or https://…" spellCheck={false} autoCapitalize="none" data-testid="arxiv-input" />
        </label>
        {issue && <p className="issue" role="alert">{issue}</p>}
        {outcome && (
          <div className={`outcome ${outcome.finished ? 'good' : 'problem'}`} role="status" data-testid="add-outcome">
            <p>{outcome.message}</p>
            {outcome.link && !outcome.finished && <a href={outcome.link} target="_blank" rel="noopener noreferrer" className="outcome-link">Open {new URL(outcome.link).hostname.replace(/^www\./, '')} <Icon name="external" size={12} /></a>}
          </div>
        )}
        <div className="pdf-upload-choice" onDragOver={event => event.preventDefault()} onDrop={event => { event.preventDefault(); choose(event.dataTransfer.files[0] ?? null); }}>
          <input ref={input} type="file" accept="application/pdf,.pdf" hidden onChange={event => choose(event.target.files?.[0] ?? null)} />
          <button type="button" className="secondary" onClick={() => input.current?.click()} disabled={adding}>Choose a PDF</button>
          <span className="fine">or drop one here</span>
          {selectedName && <span className="pdf-upload-name" title={selectedName}>{selectedName}</span>}
        </div>
        {progressText && <p className="fine" role="status" aria-live="polite">{progressText}</p>}
        <p className="fine">Add an arXiv ID, DOI or paper link, or choose a PDF from this device. PDFs are opened and processed only here. Your library title and tags sync encrypted; the file stays on this device.</p>
        <div className="dialog-actions">
          <button type="button" className="secondary" onClick={close} disabled={busy}>{outcome?.finished ? 'Done' : 'Cancel'}</button>
          <button type="submit" className="primary" disabled={adding || library.state !== 'ready' || (!text.trim() && !file)} data-testid="arxiv-add">{adding ? (file ? 'Adding PDF…' : 'Adding…') : file ? 'Add PDF' : 'Add'}</button>
        </div>
      </form>
    </Dialog>
  );
}
