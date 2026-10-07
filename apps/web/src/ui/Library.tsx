// The library as a table (owner decision 2026-10-07): Title with first author, Year, Tags, Added,
// Opened, Progress; sortable headers, search, tag and state filters, live import progress with
// inline Retry/Remove. Chats and tag editing are Phase 2.
import { type FormEvent, memo, useCallback, useEffect, useMemo, useState } from 'react';
import type { Activity } from '../lib/activity';
import { parseArxiv } from '../lib/arxiv';
import { BackendError } from '../lib/backend';
import type { Entry, Import, Item } from '../lib/library';
import { type Row, rows as buildRows } from '../lib/paper';
import { type Mark, importStep, progressView, retryingAutomatically } from '../lib/progress';
import { Dialog, formatDate } from './common';
import type { useLibrary } from './useLibrary';

type Library = ReturnType<typeof useLibrary>;
type SortKey = 'title' | 'year' | 'tags' | 'added' | 'opened' | 'progress';
type Filter = 'all' | 'unread' | 'reading' | 'failed' | 'archived';

const commandError = (error: unknown) => {
  const code = error instanceof BackendError ? error.code : '';
  if (code === 'library_active_import_limit') return 'Several papers are already being added. Try again when one finishes.';
  if (code === 'library_account_import_limit' || code === 'library_account_receipt_limit') return 'Your library has reached its current limit.';
  if (code === 'request_rate_limit') return 'Too many changes in a short time. Try again in a minute.';
  if (code === 'import_not_retryable') return 'This paper can’t be retried. Remove it and add it again.';
  if (code === 'connection') return 'Couldn’t reach Gradstep. Your change may not have been saved; check the list, then try again.';
  return 'Couldn’t update the library. Try again.';
};

export function LibraryView({ library, activity, onOpen }: { library: Library; activity: Map<string, Activity>; onOpen: (item: Item) => void }) {
  const [query, setQuery] = useState('');
  const [filter, setFilter] = useState<Filter>('all');
  const [tag, setTag] = useState('');
  const [sort, setSort] = useState<{ key: SortKey; descending: boolean }>({ key: 'added', descending: true });
  const [adding, setAdding] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);

  const [rowCache] = useState(() => new WeakMap<Entry, Row>());
  const all = useMemo(() => buildRows(library.entries, rowCache), [library.entries, rowCache]);
  const facts = (row: Row) => {
    const a = row.entry.kind === 'item' ? activity.get(row.entry.id) : undefined;
    return { opened: a?.opened ?? null, progress: a ? a.progress : null };
  };
  const counts = useMemo(() => {
    const live = all.filter(r => !r.archived);
    return {
      unread: live.filter(r => r.readable && !activity.has(r.entry.id)).length,
      reading: live.filter(r => { const a = activity.get(r.entry.id); return r.readable && a && a.progress < 0.995; }).length,
      failed: live.filter(r => r.failed).length, archived: all.filter(r => r.archived).length, total: live.length,
    };
  }, [all, activity]);
  const tags = useMemo(() => {
    const n = new Map<string, number>();
    for (const r of all) if (!r.archived) for (const t of r.tags) n.set(t, (n.get(t) ?? 0) + 1);
    return [...n].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
  }, [all]);

  const shown = useMemo(() => {
    const needle = query.trim().toLowerCase();
    const list = all.filter(r => {
      if (filter === 'archived' ? !r.archived : r.archived) return false;
      if (filter === 'unread' && !(r.readable && !activity.has(r.entry.id))) return false;
      if (filter === 'reading') { const a = activity.get(r.entry.id); if (!(r.readable && a && a.progress < 0.995)) return false; }
      if (filter === 'failed' && !r.failed) return false;
      if (tag && !r.tags.includes(tag)) return false;
      if (!needle) return true;
      const m = r.entry.metadata;
      return [r.title, ...(m?.authors ?? []), ...r.tags, r.source, m?.venue ?? ''].some(s => s.toLowerCase().includes(needle));
    });
    const value = (r: Row): string | number => {
      const f = facts(r);
      switch (sort.key) {
        case 'title': return r.title.toLowerCase();
        case 'year': return r.year ?? -1;
        case 'tags': return (r.tags[0] ?? '￿').toLowerCase();
        case 'added': return r.added ?? Number.MAX_SAFE_INTEGER; // imports in progress first when newest-first
        case 'opened': return f.opened ?? -1;
        case 'progress': return f.progress ?? -1;
      }
    };
    return list.sort((a, b) => {
      const x = value(a), y = value(b);
      const c = typeof x === 'number' && typeof y === 'number' ? x - y : String(x).localeCompare(String(y));
      return (sort.descending ? -c : c) || a.title.localeCompare(b.title);
    });
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [all, query, filter, tag, sort, activity]);

  const header = (key: SortKey, label: string, className: string) => (
    <th className={className} aria-sort={sort.key === key ? (sort.descending ? 'descending' : 'ascending') : 'none'} scope="col">
      <button className="sort" onClick={() => setSort(s => ({ key, descending: s.key === key ? !s.descending : key !== 'title' && key !== 'tags' }))}>
        {label}{sort.key === key && <span aria-hidden="true">{sort.descending ? ' ↓' : ' ↑'}</span>}
      </button>
    </th>
  );

  const chip = (value: Filter, label: string, count?: number) => (
    <button className={filter === value ? 'chip selected' : 'chip'} aria-pressed={filter === value} onClick={() => setFilter(value)}>
      {label}{count !== undefined && count > 0 ? <span className="chip-count"> {count}</span> : null}
    </button>
  );

  const run = useCallback(async (promise: Promise<unknown>) => {
    setNotice(null);
    try { await promise; } catch (error) { setNotice(commandError(error)); }
  }, []);

  return (
    <main className="library" aria-labelledby="library-title">
      <div className="library-head">
        <h1 id="library-title">Library</h1>
        <div className="head-actions">
          <button className="primary" onClick={() => setAdding(true)} data-testid="add-paper">Add paper</button>
        </div>
      </div>
      <div className="toolbar">
        <input type="search" placeholder="Search titles, authors and tags" aria-label="Search library" value={query} onChange={e => setQuery(e.target.value)} data-testid="search" />
      </div>
      {(counts.total > 0 || counts.archived > 0) && (
        <div className="chips" role="toolbar" aria-label="Filter library">
          {tags.length > 0 && (
            <label className="tag-select"><span className="visually-hidden">Tag</span>
              <select value={tag} onChange={e => setTag(e.target.value)} aria-label="Filter by tag">
                <option value="">Tags</option>
                {tags.map(([t, n]) => <option key={t} value={t}>{t} ({n})</option>)}
              </select>
            </label>
          )}
          {chip('all', 'All')}
          {counts.unread > 0 && counts.unread < counts.total && chip('unread', 'Unread')}
          {counts.reading > 0 && chip('reading', 'Reading')}
          {counts.failed > 0 && chip('failed', 'Failed', counts.failed)}
          {counts.archived > 0 && chip('archived', 'Archived')}
        </div>
      )}
      {notice && <p className="issue" role="alert">{notice}</p>}
      {library.state === 'loading' && library.entries.length === 0 && <div className="empty"><div className="spinner" aria-label="Loading library" /></div>}
      {library.state === 'error' && library.entries.length === 0 && (
        <div className="empty"><p>Couldn’t load your library.</p><button className="secondary" onClick={() => library.refresh().catch(() => {})}>Try again</button></div>
      )}
      {library.state === 'ready' && all.length === 0 && (
        <div className="empty"><p><strong>Your library is empty.</strong></p><p className="muted">Add a paper from arXiv to start reading.</p></div>
      )}
      {all.length > 0 && (
        <table className="papers" data-testid="library-table">
          <thead><tr>
            {header('title', 'Title', 'col-title')}{header('year', 'Year', 'col-year')}{header('tags', 'Tags', 'col-tags')}
            {header('added', 'Added', 'col-added')}{header('opened', 'Opened', 'col-opened')}{header('progress', 'Progress', 'col-progress')}
          </tr></thead>
          <tbody>
            {shown.map(row => <PaperRow key={row.key} row={row} {...facts(row)} mark={library.marks.get(row.entry.id)} busy={library.pending.has(row.entry.id)}
              onOpen={onOpen} retry={library.retry} remove={library.remove} run={run} />)}
            {shown.length === 0 && <tr><td colSpan={6} className="no-match">No papers match.</td></tr>}
          </tbody>
        </table>
      )}
      <AddPaper open={adding} onClose={() => setAdding(false)} library={library} />
    </main>
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

const PaperRow = memo(function PaperRow({ row, opened, progress: readingProgress, mark, busy, onOpen, retry, remove, run }: {
  row: Row; opened: number | null; progress: number | null; mark?: Mark; busy: boolean;
  onOpen: (item: Item) => void; retry: Library['retry']; remove: Library['remove']; run: (p: Promise<unknown>) => void;
}) {
  const entry = row.entry;
  const progress = useImportProgress(entry, mark);
  const open = () => { if (row.readable && entry.kind === 'item') onOpen(entry); };
  const action = entry.kind === 'import' && row.action && !busy ? (
    row.action === 'retry' ? <button className="secondary small" onClick={e => { e.stopPropagation(); run(retry(entry as Import)); }}>Retry</button>
      : row.action === 'remove' ? <button className="secondary small" onClick={e => { e.stopPropagation(); run(remove(entry as Import)); }}>Remove</button>
        : <span className="fine" title="Credits can be added in the iPhone or iPad app">Needs credits</span>
  ) : null;
  return (
    <tr className={row.readable ? 'readable' : undefined} onClick={open} data-testid="paper-row">
      <td className="col-title">
        {row.readable ? <a href={`/paper/${entry.id}`} onClick={e => { e.preventDefault(); e.stopPropagation(); open(); }} className="title">{row.title}</a>
          : <span className="title">{row.title}</span>}
        {row.firstAuthor && <span className="author">{row.firstAuthor}{(entry.metadata?.authors.length ?? 0) > 1 ? ' et al.' : ''}</span>}
        {row.status && !progress && <span className={`status ${row.status.kind}`}>{row.status.kind === 'problem' ? '⚠︎ ' : ''}{row.status.text}</span>}
        {progress && <span className="status active" aria-label={progress.label}>{progress.title}{progress.detail ? ` (${progress.detail})` : ''}</span>}
        {busy && <span className="status active">Updating…</span>}
        {action && <span className="inline-action">{action}</span>}
      </td>
      <td className="col-year">{row.year ?? '—'}</td>
      <td className="col-tags">{row.tags.length ? <span className="tags">{row.tags.slice(0, 4).map(t => <span className="tag" key={t}>{t}</span>)}</span> : <span className="muted">—</span>}</td>
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
            <span className="fine">{Math.round(readingProgress * 100)}%</span></span> : <span className="muted">—</span>
        ) : <span className="muted">—</span>}
      </td>
    </tr>
  );
});

function AddPaper({ open, onClose, library }: { open: boolean; onClose: () => void; library: Library }) {
  const [text, setText] = useState('');
  const [issue, setIssue] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  async function submit(event: FormEvent) {
    event.preventDefault();
    const reference = parseArxiv(text);
    if (!reference) { setIssue('Enter an arXiv identifier or link, like 2305.18290 or https://arxiv.org/abs/2305.18290.'); return; }
    setBusy(true); setIssue(null);
    try { await library.addArxiv(reference.sourceID, reference.revision); setText(''); onClose(); }
    catch (error) { setIssue(commandError(error)); }
    finally { setBusy(false); }
  }
  return (
    <Dialog open={open} onClose={() => { if (!busy) { setIssue(null); onClose(); } }} title="Add paper">
      <form onSubmit={submit} noValidate>
        <h2>Add paper</h2>
        <label>arXiv identifier or link
          <input autoFocus value={text} onChange={e => setText(e.target.value)} placeholder="2305.18290" spellCheck={false} autoCapitalize="none" data-testid="arxiv-input" />
        </label>
        {issue && <p className="issue" role="alert">{issue}</p>}
        <p className="fine">Searching arXiv and adding papers from the web aren’t available in the browser yet.</p>
        <div className="dialog-actions">
          <button type="button" className="secondary" onClick={onClose} disabled={busy}>Cancel</button>
          <button type="submit" className="primary" disabled={busy || !text.trim()} data-testid="arxiv-add">{busy ? 'Adding…' : 'Add'}</button>
        </div>
      </form>
    </Dialog>
  );
}
