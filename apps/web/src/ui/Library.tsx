// The library on a large screen (legacy LibraryView/PaperTable density, today's data): a dense,
// full-width table — Title, Authors, Year, Tags, Added, Opened, Progress — with sortable headers,
// the filters in the left rail (or as chips when the rail is hidden), live import progress with
// inline Retry/Remove/credits states, and a compact list beside an open paper.
import { type FormEvent, type KeyboardEvent, memo, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { Activity } from '../lib/activity';
import { addFailure, addOutcome, type AddOutcome, addPaper } from '../lib/add';
import { parseArxiv } from '../lib/arxiv';
import { BackendError } from '../lib/backend';
import { CommandRefreshError, type Entry, type Import, type Item } from '../lib/library';
import { type Row, rows as buildRows } from '../lib/paper';
import { type Mark, importStep, progressView, retryingAutomatically } from '../lib/progress';
import { Dialog, formatDate } from './common';
import { Icon } from './icons';
import type { useLibrary } from './useLibrary';

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
const authorList = (entry: Entry) => entry.metadata?.authors ?? [];
const shortAuthors = (authors: string[]) => {
  const surname = (name: string) => name.trim().split(/\s+/).pop() ?? name;
  if (authors.length === 0) return '';
  if (authors.length <= 3) return authors.map(surname).join(', ');
  return `${authors.slice(0, 3).map(surname).join(', ')} +${authors.length - 3}`;
};

/** Rows, counts, tags and the filtered, sorted list for one library view. Shared by the table, rail and compact list. */
export function useLibraryModel(library: Library, current: Map<string, Activity>, view: LibraryQuery, visible = true) {
  // While no library view is showing (reading a paper), reading-place reports must not re-sort the library.
  const seen = useRef(current);
  if (visible) seen.current = current;
  const activity = seen.current;
  const [rowCache] = useState(() => new WeakMap<Entry, Row>());
  const all = useMemo(() => buildRows(library.entries, rowCache), [library.entries, rowCache]);
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
      const a = r.entry.kind === 'item' ? activity.get(r.entry.id) : undefined;
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
  return { all, counts, tags, shown };
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

export function LibraryView({ library, model, activity, view, setView, showChips, currentID, onOpen, onAdd }: {
  library: Library; model: LibraryModel; activity: Map<string, Activity>; view: LibraryQuery; setView: SetQuery; showChips: boolean;
  currentID: string | null; onOpen: (item: Item) => void; onAdd: () => void;
}) {
  const { notice, setNotice, run } = useCommandRunner();
  useEffect(() => {
    if (notice?.pendingKey && !library.pending.has(notice.pendingKey)) setNotice(notice.onObserved ? { text: notice.onObserved } : null);
  }, [notice, library.pending, setNotice]);
  const { all, counts, shown } = model;
  const header = (key: SortKey, label: string, className: string) => (
    <th className={className} aria-sort={view.sort.key === key ? (view.sort.descending ? 'descending' : 'ascending') : 'none'} scope="col">
      <button className="sort" onClick={() => setView(q => ({ ...q, sort: { key, descending: q.sort.key === key ? !q.sort.descending : !['title', 'authors', 'tags'].includes(key) } }))}>
        {label}{view.sort.key === key && <span className="sort-mark" aria-hidden="true">{view.sort.descending ? ' ↓' : ' ↑'}</span>}
      </button>
    </th>
  );
  const describe = [view.filter !== 'all' ? FILTERS.find(f => f.value === view.filter)!.label : null, view.tag || null, view.query.trim() ? `“${view.query.trim()}”` : null].filter(Boolean);

  return (
    <section className="library" aria-labelledby="library-title">
      <div className="view-head">
        <h1 id="library-title">Library</h1>
        <span className="view-sub" aria-live="polite">
          {library.state === 'ready' || all.length ? `${shown.length.toLocaleString()} ${shown.length === 1 ? 'paper' : 'papers'}${describe.length ? ` · ${describe.join(' · ')}` : ''}` : ''}
        </span>
        {(describe.length > 0) && <button className="link small-link" onClick={() => setView(q => ({ ...q, filter: 'all', tag: '', query: '' }))}>Clear filters</button>}
      </div>
      {showChips && (counts.total > 0 || counts.archived > 0) && <FilterChips model={model} view={view} setView={setView} />}
      {notice && <p className="issue banner" role="alert">{notice.text}</p>}
      {library.state === 'loading' && all.length === 0 && <div className="empty"><div className="spinner" aria-label="Loading library" /></div>}
      {library.state === 'error' && all.length === 0 && (
        <div className="empty"><p>Couldn’t load your library.</p><button className="secondary" onClick={() => library.refresh().catch(() => {})}>Try again</button></div>
      )}
      {library.state === 'ready' && all.length === 0 && (
        <div className="empty"><p><strong>Your library is empty.</strong></p><p className="muted">Add a paper by its arXiv ID, DOI or a link.</p>
          <button className="primary" onClick={onAdd}>Add paper</button></div>
      )}
      {all.length > 0 && (
        <div className="table-wrap">
          <table className="papers" data-testid="library-table">
            <thead><tr>
              {header('title', 'Title', 'col-title')}{header('authors', 'Authors', 'col-authors')}{header('year', 'Year', 'col-year')}{header('tags', 'Tags', 'col-tags')}
              {header('added', 'Added', 'col-added')}{header('opened', 'Opened', 'col-opened')}{header('progress', 'Progress', 'col-progress')}
            </tr></thead>
            <tbody onKeyDown={e => moveRowFocus(e, 'a.title')}>
              {shown.map(row => {
                const a = row.entry.kind === 'item' ? activity.get(row.entry.id) : undefined;
                return <PaperRow key={row.key} row={row} opened={a?.opened ?? null} progress={a ? a.progress : null} mark={library.marks.get(row.entry.id)}
                  busy={library.pending.has(row.entry.id)} current={row.entry.id === currentID} onOpen={onOpen} retry={library.retry} remove={library.remove} run={run}
                  onTag={setView} />;
              })}
              {shown.length === 0 && <tr><td colSpan={7} className="no-match">No papers match.</td></tr>}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}

/** Only an active import row ticks. Ready papers and the table's query/sort state stay idle. */
function useImportProgress(entry: Entry, mark?: Mark) {
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

const PaperRow = memo(function PaperRow({ row, opened, progress: readingProgress, mark, busy, current, onOpen, retry, remove, run, onTag }: {
  row: Row; opened: number | null; progress: number | null; mark?: Mark; busy: boolean; current: boolean;
  onOpen: (item: Item) => void; retry: Library['retry']; remove: Library['remove']; run: (key: string, p: Promise<unknown>) => void; onTag: SetQuery;
}) {
  const entry = row.entry;
  const progress = useImportProgress(entry, mark);
  const open = () => { if (row.readable && entry.kind === 'item') onOpen(entry); };
  const authors = authorList(entry);
  return (
    <tr className={`${row.readable ? 'readable' : 'pending'}${current ? ' current' : ''}`} onClick={open} data-testid="paper-row">
      <td className="col-title">
        {row.readable ? <a href={`/paper/${entry.id}`} onClick={e => { e.preventDefault(); e.stopPropagation(); open(); }} className="title" title={row.title}>{row.title}</a>
          : <span className="title" title={row.title}>{row.title}</span>}
        {row.firstAuthor && <span className="author">{row.firstAuthor}{authors.length > 1 ? ' et al.' : ''}</span>}
        {row.status && !progress && <span className={`status ${row.status.kind}`}>{row.status.kind === 'problem' ? '⚠︎ ' : ''}{row.status.text}</span>}
        {progress && <span className="status active" aria-label={progress.label}>{progress.title}{progress.detail ? ` (${progress.detail})` : ''}</span>}
        {busy && <span className="status active">Updating…</span>}
        <span className="inline-action"><RowAction row={row} busy={busy} retry={retry} remove={remove} run={run} /></span>
      </td>
      <td className="col-authors" title={authors.join(', ')}>{shortAuthors(authors) || <span className="faint">—</span>}</td>
      <td className="col-year">{row.year ?? '—'}</td>
      <td className="col-tags">{row.tags.length ? <span className="tags">{row.tags.slice(0, 4).map(t => (
        <button className="tag" key={t} onClick={e => { e.stopPropagation(); onTag(q => ({ ...q, tag: t })); }} title={`Show papers tagged “${t}”`}>{t}</button>))}</span>
        : <span className="faint">—</span>}</td>
      <td className="col-added">{formatDate(row.added)}</td>
      <td className="col-opened">{formatDate(opened)}</td>
      <td className="col-progress">
        {progress ? (
          <span className="import-progress" data-testid="import-progress">
            {progress.percent !== null ? <progress max={100} value={progress.percent} aria-label={progress.label} /> : <span className="spinner small" aria-label={progress.label} />}
            <span className="fine">{[progress.percent !== null ? `${progress.percent}%` : null, progress.compactTime].filter(Boolean).join(' · ')}</span>
          </span>
        ) : row.readable ? (
          readingProgress !== null ? <span className="reading-progress"><progress className="accent" max={1} value={readingProgress} aria-label={`${Math.round(readingProgress * 100)}% read`} />
            <span className="fine">{Math.round(readingProgress * 100)}%</span></span> : <span className="faint">—</span>
        ) : <span className="faint">—</span>}
      </td>
    </tr>
  );
});

/** Beside an open paper (the legacy Browse view): the same library, compact. */
export function CompactLibrary({ model, activity, currentID, onOpen, query }: {
  model: LibraryModel; activity: Map<string, Activity>; currentID: string | null; onOpen: (item: Item) => void; query: string;
}) {
  const list = useRef<HTMLUListElement>(null);
  useEffect(() => { list.current?.querySelector('.current')?.scrollIntoView({ block: 'nearest' }); }, []);
  return (
    <div className="compact-library">
      {query.trim() && <p className="fine compact-note">{model.shown.length} {model.shown.length === 1 ? 'match' : 'matches'} for “{query.trim()}”</p>}
      <ul ref={list} className="compact-list" aria-label="Library" onKeyDown={e => moveRowFocus(e, 'a.compact-link')}>
        {model.shown.map(row => {
          const entry = row.entry, a = entry.kind === 'item' ? activity.get(entry.id) : undefined;
          const meta = [row.firstAuthor ? `${row.firstAuthor}${(entry.metadata?.authors.length ?? 0) > 1 ? ' et al.' : ''}` : null, row.year].filter(Boolean).join(' · ');
          return (
            <li key={row.key} className={entry.id === currentID ? 'current' : undefined}>
              {row.readable && entry.kind === 'item'
                ? <a className="compact-link" href={`/paper/${entry.id}`} aria-current={entry.id === currentID ? 'page' : undefined}
                    onClick={e => { e.preventDefault(); onOpen(entry); }}><span className="compact-title">{row.title}</span><span className="compact-meta">{meta}</span>
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

/** Add paper: an arXiv ID stays a library command; a DOI or any link goes to add-paper. No PDF upload in the browser yet. */
export function AddPaper({ open, onClose, library, account }: { open: boolean; onClose: () => void; library: Library; account: string }) {
  const [text, setText] = useState('');
  const [issue, setIssue] = useState<string | null>(null);
  const [outcome, setOutcome] = useState<AddOutcome | null>(null);
  const [busy, setBusy] = useState(false);
  const [awaitingObservation, setAwaitingObservation] = useState(false);
  const request = useRef<AbortController | null>(null);
  useEffect(() => {
    if (awaitingObservation && !library.pending.has('add')) {
      setAwaitingObservation(false); setIssue(null); setText(''); onClose();
    }
  }, [awaitingObservation, library.pending, onClose]);
  useEffect(() => () => request.current?.abort(), []);
  const close = () => { if (busy) return; setIssue(null); setOutcome(null); onClose(); };

  async function submit(event: FormEvent) {
    event.preventDefault();
    if (busy || awaitingObservation || library.pending.has('add')) return;
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
    try {
      const result = addOutcome(await addPaper(account, value, controller.signal));
      if (controller.signal.aborted) return;
      if (result.finished) { library.refresh().catch(() => {}); setText(''); }
      setOutcome(result);
    } catch (error) { if (!controller.signal.aborted) setIssue(addFailure(error)); }
    finally { if (!controller.signal.aborted) setBusy(false); }
  }
  const adding = busy || awaitingObservation || library.pending.has('add');
  return (
    <Dialog open={open} onClose={close} title="Add paper">
      <form onSubmit={submit} noValidate>
        <h2>Add paper</h2>
        <label>arXiv ID, DOI or link
          <input autoFocus value={text} readOnly={adding} onChange={e => { setText(e.target.value); setOutcome(null); setIssue(null); }}
            placeholder="2305.18290, 10.48550/arXiv.2305.18290 or https://…" spellCheck={false} autoCapitalize="none" data-testid="arxiv-input" />
        </label>
        {issue && <p className="issue" role="alert">{issue}</p>}
        {outcome && (
          <div className={`outcome ${outcome.finished ? 'good' : 'problem'}`} role="status" data-testid="add-outcome">
            <p>{outcome.message}</p>
            {outcome.link && !outcome.finished && <a href={outcome.link} target="_blank" rel="noopener noreferrer" className="outcome-link">Open {new URL(outcome.link).hostname.replace(/^www\./, '')} <Icon name="external" size={12} /></a>}
          </div>
        )}
        <p className="fine">arXiv papers, DOIs and links to papers or their pages. Uploading a PDF isn’t available in the browser yet.</p>
        <div className="dialog-actions">
          <button type="button" className="secondary" onClick={close} disabled={busy}>{outcome?.finished ? 'Done' : 'Cancel'}</button>
          <button type="submit" className="primary" disabled={adding || library.state !== 'ready' || !text.trim()} data-testid="arxiv-add">{adding ? 'Adding…' : 'Add'}</button>
        </div>
      </form>
    </Dialog>
  );
}
