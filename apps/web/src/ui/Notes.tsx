// Notes and snippets in the browser (docs/architecture/NOTES_AND_SNIPPETS.md; prototype docs/prototypes/notes-snippets.html):
// the Notes list (search, new, rename, delete), a note's stream of crops, quotes and the reader's own writing, the
// composer used by Add to note and Add text, and the full-size crop view. Everything here is the account's encrypted
// notes (lib/notes-store.ts); nothing is sent except encrypted events and opaque image blobs.
import { type ReactNode, useEffect, useId, useMemo, useRef, useState, useSyncExternalStore } from 'react';
import type { ChatSession } from '../lib/chat-session';
import type { PreparedSnippetImage } from '../lib/note-images';
import { NOTES_LIMITS, type EntryAnchor, type EntryKind, type EntrySource, type EntryView, type MediaDescriptor, type NoteView, cleanNoteTitle } from '../lib/notes';
import { type NotesStore, UPLOAD_ISSUE_TEXT, entryOperation, imageIssue, noteWriteFailure } from '../lib/notes-store';
import { COMPACT_TITLE_LIMIT, collapsedEntries, collapsedLine, rememberCollapsed } from '../lib/note-collapse';
import { Dialog, MenuButton, SheetTop } from './common';
import { Icon } from './icons';
import './notes.css';

const noop = () => () => {};
/** The account's notes, re-rendering when they change (history, uploads, issues). */
export function useNotes(chat: ChatSession | null): NotesStore | null {
  const store = chat?.noteStore ?? null;
  useSyncExternalStore(store?.subscribe ?? noop, store?.getVersion ?? (() => 0));
  return store;
}

/** What a capture hands the composer: the image already prepared (previewed exactly as it will be saved), or a quote. */
export interface ComposerDraft {
  kind: EntryKind; image?: PreparedSnippetImage; quote?: string; source: EntrySource | null; anchor: EntryAnchor | null; capturedAt: number;
  /** Add text from inside a note: that note, fixed. */ destination?: string;
}

const bytes = (s: string) => new TextEncoder().encode(s).length;
const dayLabel = (ms: number) => new Date(ms).toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' });
const timeLabel = (ms: number) => new Date(ms).toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
const kindLabel = (kind: EntryKind) => kind === 'text' ? 'Your writing' : kind === 'quote' ? 'Text snippet' : 'Region snippet';
const entriesLabel = (n: number) => `${n} ${n === 1 ? 'snippet' : 'snippets'}`;
export const noteTitle = (note: NoteView) => note.title ?? (note.future ? 'Update Gradstep to see this note' : 'Note still arriving');
/** The quiet source line: paper · location · version. */
export function sourceLine(source: EntrySource | null): string {
  if (!source) return '';
  const where = [source.label, source.section].filter(Boolean).join(' · ');
  const version = source.kind === 'arxiv' && source.sourceID ? `arXiv ${source.sourceID}${source.revision ? `v${source.revision}` : ''}` : source.page ? `Page ${source.page}` : '';
  return [source.title || 'Untitled paper', where, version].filter(Boolean).join(' · ');
}
function preview(note: NoteView): string {
  const last = note.entries.at(-1);
  if (!last) return note.future ? 'Made with a newer Gradstep' : 'No snippets yet';
  return last.record.comment || last.record.quote || (last.record.source ? `Snippet from ${last.record.source.title || 'a paper'}` : 'Your writing');
}

// ---------- Images ----------

/** A snippet image from the store: decrypted and checked on demand (thumbnail in the stream); a placeholder with Retry
 * while it isn't available, never another image. */
export function SnippetImage({ store, media, label, onOpen }: { store: NotesStore; media: MediaDescriptor; label: string; onOpen?: () => void }) {
  const [state, setState] = useState<{ url?: string; failed?: string }>({});
  const [attempt, setAttempt] = useState(0);
  useEffect(() => {
    let live = true; setState({});
    store.image(media).then(url => { if (live) setState({ url }); }, error => { if (live) setState({ failed: imageIssue(error) }); });
    return () => { live = false; };
  }, [store, media, attempt]);
  const ratio = { aspectRatio: `${media.width} / ${media.height}` };
  if (state.failed) return <div className="snippet-missing" role="status" style={ratio} data-testid="snippet-missing">
    <Icon name="image" size={20} /><span>{state.failed}</span><button className="secondary small" onClick={() => setAttempt(a => a + 1)}>Retry</button></div>;
  if (!state.url) return <div className="snippet-loading" style={ratio} role="status" aria-label="Loading image" />;
  const image = <img src={state.url} alt={label} width={media.width} height={media.height} />;
  return onOpen ? <button type="button" className="snippet-image" onClick={onOpen} aria-label={`Enlarge ${label}`} data-testid="snippet-image">{image}</button>
    : <div className="snippet-image">{image}</div>;
}
/** A prepared (not yet saved) image, shown from its own bytes. */
function PreparedImage({ image, label }: { image: PreparedSnippetImage['full']; label: string }) {
  const [url, setURL] = useState<string | null>(null);
  useEffect(() => {
    const value = URL.createObjectURL(new Blob([image.bytes], { type: image.type }));
    setURL(value);
    return () => URL.revokeObjectURL(value);
  }, [image]);
  return <div className="snippet-image composer-image">{url && <img src={url} alt={label} width={image.width} height={image.height} data-testid="composer-image" />}</div>;
}

/** The full-size crop with zoom (a slider and the keyboard), scrollable when enlarged. */
export function ZoomView({ store, media, label, detail, onClose, onChat }: { store: NotesStore; media: MediaDescriptor; label: string; detail: string; onClose: () => void;
  /** Chat about this snippet (owner, 2026-10-21), as a figure's Chat about Figure: nothing is sent. */ onChat?: () => void }) {
  const [url, setURL] = useState<string | null>(null), [failed, setFailed] = useState(false), [zoom, setZoom] = useState(1);
  useEffect(() => { let live = true; store.image(media).then(u => { if (live) setURL(u); }, () => { if (live) setFailed(true); }); return () => { live = false; }; }, [store, media]);
  return <Dialog open onClose={onClose} title="Snippet" wide className="snippet-zoom">
    <SheetTop onClose={onClose} testID="zoom-close" trailing={onChat && <button type="button" className="sheet-action zoom-chat" onClick={() => { onClose(); onChat(); }} data-testid="zoom-chat"><Icon name="chat" size={14} /> Chat</button>}>
      <h2>Snippet</h2></SheetTop>
    <div className="zoom-stage" tabIndex={0} aria-label={label} data-testid="zoom-stage">
      {failed ? <p className="issue" role="alert">This image couldn’t be shown. It may not have downloaded yet.</p>
        : url ? <img src={url} alt={label} style={{ width: `${zoom * 100}%`, maxWidth: zoom === 1 ? '100%' : 'none' }} /> : <div className="snippet-loading" role="status" aria-label="Loading image" />}
    </div>
    <label className="zoom-control">Zoom<input type="range" min={1} max={4} step={0.25} value={zoom} onChange={e => setZoom(Number(e.target.value))} aria-valuetext={`${Math.round(zoom * 100)}%`} data-testid="zoom" /></label>
    <p className="fine">{detail} · {media.width} × {media.height}</p>
  </Dialog>;
}

// ---------- Notes list ----------

export function NotesList({ store, current, onOpen, onNew, rail = false }: { store: NotesStore; current: string | null; onOpen: (noteID: string) => void; onNew: () => void; rail?: boolean }) {
  const [query, setQuery] = useState('');
  const view = store.view();
  const found = useMemo(() => {
    const q = query.trim().toLocaleLowerCase();
    if (!q) return view.notes;
    return view.notes.filter(n => [n.title ?? '', ...n.entries.flatMap(e => [e.record.comment, e.record.quote ?? '', e.record.source?.title ?? ''])].join('\n').toLocaleLowerCase().includes(q));
  }, [view, query]);
  const pending = store.pendingCount;
  return <div className={`notes-list${rail ? ' rail' : ''}`} data-testid={rail ? 'notes-rail' : 'notes-list'}>
    {!rail && <div className="view-head notes-head"><h1>Snippets</h1><span className="view-sub">{view.notes.length} {view.notes.length === 1 ? 'collection' : 'collections'}{pending ? ` · ${pending} waiting to sync` : ''}</span>
      <button className="icon-button notes-new" onClick={onNew} aria-label="New collection" title="New collection" disabled={!store.writable} data-testid="new-note"><Icon name="plus" /></button></div>}
    {store.issue && !rail && <SyncIssue store={store} />}
    <label className="notes-search"><Icon name="search" size={14} /><input type="search" placeholder="Search snippets" aria-label="Search snippets" value={query} onChange={e => setQuery(e.target.value)} data-testid="notes-search" /></label>
    {found.length ? <ul className="notes-rows" aria-label="Snippet collections">
      {found.map(n => <li key={n.id}><button className={`note-row${n.id === current ? ' on' : ''}`} onClick={() => onOpen(n.id)} aria-current={n.id === current ? 'true' : undefined} data-testid="note-row">
        <span className="note-mark" aria-hidden="true"><Icon name="notes" size={18} /></span>
        <span className="note-row-text"><span className="note-row-title">{noteTitle(n)}</span>
          <span className="note-row-preview">{preview(n)}</span>
          <span className="note-row-meta">{entriesLabel(n.entries.length)} · {n.lastEdited ? dayLabel(n.lastEdited) : '—'}{store.pendingIn(n) ? ' · Waiting to sync' : ''}{n.versions.length > 1 ? ' · 2 titles' : ''}</span></span>
      </button></li>)}
    </ul> : <div className="notes-empty">
      {view.notes.length ? <p className="muted">Nothing matches “{query.trim()}”.</p> : <>
        <h2>A place for your next idea</h2><p className="muted">Collect snippets while reading: Paper ⋯ › Draw snippet, or select text and choose Save snippet.</p>
        <button className="primary" onClick={onNew} disabled={!store.writable}>New collection</button></>}
    </div>}
    {view.malformed > 0 && <p className="fine notes-skipped" role="status">{view.malformed} snippet {view.malformed === 1 ? 'record' : 'records'} couldn’t be read and {view.malformed === 1 ? 'was' : 'were'} skipped.</p>}
    {rail && <div className="notes-rail-actions"><button className="secondary small" onClick={onNew} disabled={!store.writable} data-testid="new-note"><Icon name="plus" size={14} /> New collection</button></div>}
  </div>;
}

function SyncIssue({ store }: { store: NotesStore }) {
  const [busy, setBusy] = useState(false);
  if (!store.issue) return null;
  return <div className="notes-issue" role="status" data-testid="notes-issue"><Icon name="info" size={14} /><span>{UPLOAD_ISSUE_TEXT[store.issue]}</span>
    {store.issue !== 'missing' && <button className="secondary small" disabled={busy} onClick={() => { setBusy(true); void store.retry().catch(() => {}).finally(() => setBusy(false)); }}>Retry</button>}</div>;
}

// ---------- A note ----------

type Editing = { kind: 'rename' } | { kind: 'delete-note' } | { kind: 'comment'; entry: EntryView } | { kind: 'delete-entry'; entry: EntryView }
  | { kind: 'entry-versions'; entry: EntryView } | { kind: 'title-versions' } | { kind: 'zoom'; entry: EntryView };

export function NoteDetail({ store, noteID, onBack, onAddText, onOpenSource, back, onChat }: {
  store: NotesStore; noteID: string; onBack: () => void; onAddText: (noteID: string) => void;
  /** A snippet's or quotation's Chat (owner, 2026-10-21): a chat about it, nothing sent. */ onChat?: (entry: EntryView) => void;
  /** Open in paper: false when the paper isn't available here (the message explains why). */ onOpenSource: (entry: EntryView) => string | null;
  /** The list isn't beside the note (narrow windows): a Back to Notes control. */ back: boolean;
}) {
  const note = store.note(noteID);
  const [editing, setEditing] = useState<Editing | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  useEffect(() => { if (!notice) return; const t = setTimeout(() => setNotice(null), 6000); return () => clearTimeout(t); }, [notice]);
  // Collapsed cards (owner, 2026-10-22), remembered in this browser only (lib/note-collapse.ts).
  const [collapsed, setCollapsedState] = useState<Set<string>>(() => collapsedEntries(noteID));
  useEffect(() => { setCollapsedState(collapsedEntries(noteID)); }, [noteID]);
  const saveCollapsed = (next: Set<string>) => { setCollapsedState(next); rememberCollapsed(noteID, next, note?.entries.map(e => e.id)); };
  const toggle = (entryID: string) => { const next = new Set(collapsed); if (!next.delete(entryID)) next.add(entryID); saveCollapsed(next); };
  if (!note) return <div className="empty notes-gone"><p>This collection isn’t available. It may have been deleted on another device.</p><button className="secondary" onClick={onBack}>Back to Snippets</button></div>;
  const title = noteTitle(note);
  const shownCollapsed = note.entries.filter(e => collapsed.has(e.id)).length;
  let day = '';
  return <div className="note-detail" data-testid="note-detail">
    <header className="note-head">
      {back && <button className="icon-button" onClick={onBack} aria-label="Back to Snippets" title="Back to Snippets" data-testid="notes-back"><Icon name="chevronLeft" /></button>}
      <div className="note-head-text"><h1 data-testid="note-title">{title}</h1>
        <span className="view-sub">{entriesLabel(note.entries.length)}{store.pendingIn(note) ? ' · Saved on this device · Waiting to sync' : ''}
          {note.versions.length > 1 && <> · <button className="link small-link" onClick={() => setEditing({ kind: 'title-versions' })} data-testid="title-versions">2 titles · Review</button></>}</span></div>
      <MenuButton icon="more" label={`${title} options`} testID="note-menu">{close => <>
        {/* View choices first (DESIGN.md "Screen options"), only when they would change something. */}
        {shownCollapsed < note.entries.length && <button type="button" role="menuitem" className="menu-item" onClick={() => { close(); saveCollapsed(new Set(note.entries.map(e => e.id))); }} data-testid="collapse-all"><Icon name="chevronUp" size={14} /> Collapse all</button>}
        {shownCollapsed > 0 && <button type="button" role="menuitem" className="menu-item" onClick={() => { close(); saveCollapsed(new Set()); }} data-testid="expand-all"><Icon name="chevronDown" size={14} /> Expand all</button>}
        <button type="button" role="menuitem" className="menu-item" disabled={!store.writable || !note.record} onClick={() => { close(false); setEditing({ kind: 'rename' }); }}><Icon name="pencil" size={14} /> Rename collection…</button>
        <button type="button" role="menuitem" className="menu-item danger" disabled={!store.writable} onClick={() => { close(false); setEditing({ kind: 'delete-note' }); }}><Icon name="trash" size={14} /> Delete collection…</button>
      </>}</MenuButton>
    </header>
    {store.issue && <SyncIssue store={store} />}
    {note.future > 0 && <p className="notes-banner" role="status">Part of this collection was made with a newer version of Gradstep. Reload to update and see everything in it.</p>}
    {note.incomplete && !note.future && <p className="notes-banner" role="status">This collection is still arriving from your other devices.</p>}
    <div className="note-stream">
      {note.entries.length ? note.entries.map((entry, index) => {
        const d = dayLabel(entry.record.capturedAt), divider = d !== day ? <div className="note-day" key={`day-${entry.id}`}>{d}</div> : null;
        day = d;
        return [divider, <Entry key={entry.id} store={store} entry={entry} index={index} collapsed={collapsed.has(entry.id)} onToggle={() => toggle(entry.id)} onEdit={setEditing} onOpenSource={() => { const issue = onOpenSource(entry); if (issue) setNotice(issue); }}
          onChat={onChat ? () => onChat(entry) : undefined} />];
      }) : <div className="notes-empty"><h2>A place for your next idea</h2><p className="muted">Collect a snippet while reading: Paper ⋯ › Draw snippet, or select text and choose Save snippet.</p></div>}
    </div>
    {notice && <div className="notes-toast" role="status">{notice}</div>}
    {editing?.kind === 'rename' && note.record && <NameDialog title="Rename note" action="Rename" initial={note.title ?? ''} onClose={() => setEditing(null)}
      onSubmit={name => store.renameNote(note.id, name)} />}
    {editing?.kind === 'delete-note' && <ConfirmDialog title={`Delete “${title}”?`} action="Delete collection" onClose={() => setEditing(null)}
      onConfirm={async () => { await store.deleteNote(note.id); onBack(); }}>
      This removes the collection and its {entriesLabel(note.entries.length)} from your devices when they sync. Copies already synced stay encrypted until your account is deleted.
    </ConfirmDialog>}
    {editing?.kind === 'comment' && <CommentDialog entry={editing.entry} store={store} onClose={() => setEditing(null)} />}
    {editing?.kind === 'delete-entry' && <ConfirmDialog title="Delete this snippet?" action="Delete snippet" onClose={() => setEditing(null)}
      onConfirm={() => store.deleteEntry(editing.entry.id)}>This removes the {editing.entry.record.kind === 'text' ? 'writing' : 'snippet and its comment'} from your devices when they sync.</ConfirmDialog>}
    {editing?.kind === 'entry-versions' && <VersionsDialog title="Two versions of this comment" versions={editing.entry.versions.map(v => ({ id: v.eventID, text: v.record.comment || '(no comment)', at: v.createdAt }))}
      onClose={() => setEditing(null)} onChoose={id => store.chooseComment(editing.entry.id, id)} />}
    {editing?.kind === 'title-versions' && <VersionsDialog title="Two versions of this title" versions={note.versions.map(v => ({ id: v.eventID, text: v.record.title, at: v.createdAt }))}
      onClose={() => setEditing(null)} onChoose={id => store.chooseTitle(note.id, id)} />}
    {editing?.kind === 'zoom' && editing.entry.record.media && <ZoomView store={store} media={editing.entry.record.media.full} label={`Snippet ${note.entries.indexOf(editing.entry) + 1}`}
      detail={sourceLine(editing.entry.record.source) || 'Snippet'} onClose={() => setEditing(null)} onChat={onChat ? () => onChat(editing.entry) : undefined} />}
  </div>;
}

// Owner, 2026-10-22: "having the ability to collapse individual snippets would be helpful (so you can just see the
// date/times), also having a bit cleaner separation still between the cards with the actual snippet itself being a slightly
// more clear 'box' in a card". Each entry is a card; its crop or quotation sits in an inner box; the chevron collapses it to
// one line (time · short paper title · first words of the comment).
function Entry({ store, entry, index, collapsed, onToggle, onEdit, onOpenSource, onChat }: { store: NotesStore; entry: EntryView; index: number; collapsed: boolean; onToggle: () => void;
  onEdit: (e: Editing) => void; onOpenSource: () => void; onChat?: () => void }) {
  const r = entry.record, state = store.entryState(entry), label = `Entry ${index + 1}`, bodyID = `entry-body-${entry.id}`;
  const disclosure = <button type="button" className="icon-button entry-disclosure" onClick={onToggle} aria-expanded={!collapsed} aria-controls={collapsed ? undefined : bodyID}
    aria-label={collapsed ? 'Expand snippet' : 'Collapse snippet'} title={collapsed ? 'Expand' : 'Collapse'} data-testid="entry-disclosure"><Icon name="chevronDown" size={16} /></button>;
  const menu = <MenuButton icon="more" label={`${label} options`} testID="entry-menu">{close => <>
        <button type="button" role="menuitem" className="menu-item" disabled={!store.writable} onClick={() => { close(false); onEdit({ kind: 'comment', entry }); }}><Icon name="pencil" size={14} /> {r.kind === 'text' ? 'Edit writing' : 'Edit comment'}</button>
        {onChat && r.kind !== 'text' && <button type="button" role="menuitem" className="menu-item" onClick={() => { close(false); onChat(); }} data-testid="entry-chat"><Icon name="chat" size={14} /> Chat</button>}
        {r.source && <button type="button" role="menuitem" className="menu-item" onClick={() => { close(false); onOpenSource(); }}><Icon name="book" size={14} /> Open in paper</button>}
        <button type="button" role="menuitem" className="menu-item danger" disabled={!store.writable} onClick={() => { close(false); onEdit({ kind: 'delete-entry', entry }); }}><Icon name="trash" size={14} /> Delete snippet</button>
      </>}</MenuButton>;
  if (collapsed) return <article className={`note-entry kind-${r.kind} collapsed`} aria-label={label} data-testid="note-entry">
    <div className="note-entry-top">{disclosure}
      <button type="button" className="entry-line" onClick={onToggle} data-testid="entry-line">
        {/* Phones get a shorter title so the comment's first words still fit (CSS shows one of the two). */}
        <span className="line-wide">{collapsedLine(timeLabel(r.capturedAt), r.source?.title ?? '', r.comment, r.quote, r.source?.label)}</span>
        <span className="line-compact">{collapsedLine(timeLabel(r.capturedAt), r.source?.title ?? '', r.comment, r.quote, r.source?.label, COMPACT_TITLE_LIMIT)}</span></button>
      {entry.versions.length > 1 && <button className="link small-link versions-link" onClick={() => onEdit({ kind: 'entry-versions', entry })} data-testid="entry-versions">2 versions</button>}
      {menu}</div>
  </article>;
  return <article className={`note-entry kind-${r.kind}`} aria-label={label} data-testid="note-entry">
    <div className="note-entry-top">{disclosure}<span className="fine entry-when">{timeLabel(r.capturedAt)} · {kindLabel(r.kind)}</span>{menu}</div>
    <div className="note-entry-body" id={bodyID}>
    {r.kind === 'region' && r.media && <div className="snippet-frame"><SnippetImage store={store} media={r.media.thumb ?? r.media.full} label={`${label}: ${r.source?.label ?? 'region'} from ${r.source?.title ?? 'a paper'}`} onOpen={() => onEdit({ kind: 'zoom', entry })} /></div>}
    {r.kind === 'quote' && r.quote && <blockquote className="note-quote snippet-frame">{r.quote}</blockquote>}
    {r.comment ? <p className="note-comment">{r.comment}</p>
      : r.kind !== 'text' && <button className="link small-link" onClick={() => onEdit({ kind: 'comment', entry })} disabled={!store.writable}>Add a comment</button>}
    {entry.versions.length > 1 && <button className="link small-link versions-link" onClick={() => onEdit({ kind: 'entry-versions', entry })} data-testid="entry-versions">2 versions · Review</button>}
    {r.source && <button className="note-source" onClick={onOpenSource} title="Open in paper"><strong>{r.source.title || 'Untitled paper'}</strong>
      <span>{[r.source.label, r.source.section].filter(Boolean).join(' · ') || 'Paper'}{r.source.kind === 'arxiv' && r.source.revision ? ` · v${r.source.revision}` : ''} · {dayLabel(r.capturedAt)}</span></button>}
    {(state.pending || state.uploading) && <p className="fine entry-state" data-testid="entry-state">{state.uploading && store.issue ? UPLOAD_ISSUE_TEXT[store.issue] : 'Saved on this device · Waiting to sync'}</p>}
    </div>
  </article>;
}

// ---------- Dialogs ----------

function NameDialog({ title, action, initial, onSubmit, onClose }: { title: string; action: string; initial: string; onSubmit: (name: string) => Promise<unknown>; onClose: () => void }) {
  const [name, setName] = useState(initial), [error, setError] = useState<string | null>(null), [busy, setBusy] = useState(false);
  const submit = async () => {
    if (busy) return;
    if (!cleanNoteTitle(name)) { setError('Give the collection a name, up to 80 characters.'); return; }
    setBusy(true); setError(null);
    try { await onSubmit(name); onClose(); } catch (e) { setError(noteWriteFailure(e)); } finally { setBusy(false); }
  };
  return <Dialog open onClose={() => { if (!busy) onClose(); }} title={title}>
    <h2>{title}</h2>
    <form onSubmit={e => { e.preventDefault(); void submit(); }}>
      <label>Collection name<input value={name} maxLength={200} autoFocus placeholder="e.g. Alignment ideas" onChange={e => setName(e.target.value)} data-testid="note-name" /></label>
      <p className="fine">A collection can hold snippets from as many papers as you like.</p>
      {error && <p className="issue" role="alert">{error}</p>}
      <div className="dialog-actions"><button type="button" className="secondary" disabled={busy} onClick={onClose}>Cancel</button>
        <button className="primary" disabled={busy} data-testid="note-name-save">{busy ? 'Saving…' : action}</button></div>
    </form>
  </Dialog>;
}
export function NewNoteDialog({ store, onCreated, onClose }: { store: NotesStore; onCreated: (noteID: string) => void; onClose: () => void }) {
  const op = useRef(entryOperation());
  return <NameDialog title="New note" action="Create" initial="" onClose={onClose} onSubmit={async name => { onCreated(await store.createNote(name, op.current)); }} />;
}

function ConfirmDialog({ title, action, children, onConfirm, onClose }: { title: string; action: string; children: ReactNode; onConfirm: () => Promise<unknown>; onClose: () => void }) {
  const [error, setError] = useState<string | null>(null), [busy, setBusy] = useState(false);
  return <Dialog open onClose={() => { if (!busy) onClose(); }} title={title}>
    <h2>{title}</h2><p className="muted">{children}</p>
    {error && <p className="issue" role="alert">{error}</p>}
    <div className="dialog-actions"><button className="secondary" disabled={busy} onClick={onClose}>Cancel</button>
      <button className="primary danger" disabled={busy} data-testid="confirm-delete" onClick={async () => {
        setBusy(true); setError(null);
        try { await onConfirm(); onClose(); } catch (e) { setError(noteWriteFailure(e)); } finally { setBusy(false); }
      }}>{busy ? 'Deleting…' : action}</button></div>
  </Dialog>;
}

function CommentDialog({ store, entry, onClose }: { store: NotesStore; entry: EntryView; onClose: () => void }) {
  const [text, setText] = useState(entry.record.comment), [error, setError] = useState<string | null>(null), [busy, setBusy] = useState(false);
  const writing = entry.record.kind === 'text', over = bytes(text) > NOTES_LIMITS.commentBytes;
  const save = async () => {
    if (busy || over || (writing && !text.trim())) return;
    setBusy(true); setError(null);
    try { if (text !== entry.record.comment) await store.editComment(entry.id, text); onClose(); } catch (e) { setError(noteWriteFailure(e)); } finally { setBusy(false); }
  };
  return <Dialog open onClose={() => { if (!busy) onClose(); }} title={writing ? 'Edit writing' : 'Edit comment'}>
    <h2>{writing ? 'Edit writing' : 'Edit comment'}</h2>
    {entry.record.media && <SnippetImage store={store} media={entry.record.media.thumb ?? entry.record.media.full} label="This snippet" />}
    {entry.record.quote && <blockquote className="note-quote">{entry.record.quote}</blockquote>}
    <label>{writing ? 'Your writing' : 'Your comment'}<textarea rows={6} value={text} autoFocus onChange={e => setText(e.target.value)} data-testid="comment-text" /></label>
    {over && <p className="issue" role="alert">This is longer than a note entry can hold (16 KB). Shorten it to save.</p>}
    {error && <p className="issue" role="alert">{error}</p>}
    <div className="dialog-actions"><button className="secondary" disabled={busy} onClick={onClose}>Cancel</button>
      <button className="primary" disabled={busy || over || (writing && !text.trim())} onClick={() => void save()} data-testid="comment-save">{busy ? 'Saving…' : 'Done'}</button></div>
  </Dialog>;
}

function VersionsDialog({ title, versions, onChoose, onClose }: { title: string; versions: { id: string; text: string; at: number | null }[]; onChoose: (id: string) => Promise<unknown>; onClose: () => void }) {
  const [error, setError] = useState<string | null>(null), [busy, setBusy] = useState(false);
  return <Dialog open onClose={() => { if (!busy) onClose(); }} title={title}>
    <h2>{title}</h2><p className="muted">These were changed on two devices before they synced. Both are kept until you choose one.</p>
    <ul className="note-versions">{versions.map((v, i) => <li key={v.id}><p>{v.text}</p>
      <div className="row-actions"><span className="fine">{v.at ? `Saved ${dayLabel(v.at)} at ${timeLabel(v.at)}` : `Version ${i + 1}`}</span>
        <button className="secondary small" disabled={busy} onClick={async () => { setBusy(true); try { await onChoose(v.id); onClose(); } catch (e) { setError(noteWriteFailure(e)); } finally { setBusy(false); } }}>Keep this version</button></div></li>)}</ul>
    {error && <p className="issue" role="alert">{error}</p>}
    <div className="dialog-actions"><button className="secondary" disabled={busy} onClick={onClose}>Not now</button></div>
  </Dialog>;
}

// ---------- Composer ----------

/** Add to note (a crop or a quote) and Add text: the content first, then the destination, an optional comment and the
 * quiet source line. Save is a durable local commit; the upload follows on its own. Cancel creates nothing. */
export function NoteComposer({ store, draft, onClose, onSaved, onAdjust }: {
  store: NotesStore; draft: ComposerDraft; onClose: () => void; onSaved: (noteID: string, title: string) => void;
  /** Back to the paper with the same box, to adjust the crop. */ onAdjust?: () => void;
}) {
  const view = store.view(), choices = view.notes.filter(n => n.record && !n.future);
  const initial = draft.destination ?? (store.lastDestination && choices.some(n => n.id === store.lastDestination) ? store.lastDestination : choices[0]?.id) ?? 'new';
  const [destination, setDestination] = useState<string>(initial);
  const [newTitle, setNewTitle] = useState(choices.length ? '' : 'Quick snippets');
  const [comment, setComment] = useState(''), [error, setError] = useState<string | null>(null), [busy, setBusy] = useState(false), [leaving, setLeaving] = useState(false);
  const op = useRef(entryOperation()), id = useId();
  const writing = draft.kind === 'text', over = bytes(comment) > NOTES_LIMITS.commentBytes;
  const fixed = !!draft.destination;
  const save = async () => {
    if (busy) return;
    if (writing && !comment.trim()) { setError('Write something before saving.'); return; }
    if (destination === 'new' && !cleanNoteTitle(newTitle)) { setError('Give the new collection a name, up to 80 characters.'); return; }
    if (over) { setError('This is longer than a note entry can hold (16 KB). Shorten it to save.'); return; }
    setBusy(true); setError(null);
    try {
      const saved = await store.saveEntry({ destination: destination === 'new' ? { newTitle } : { noteID: destination }, kind: draft.kind, comment, capturedAt: draft.capturedAt,
        source: draft.source, anchor: draft.anchor, quote: draft.kind === 'quote' ? draft.quote ?? null : null, image: draft.image }, op.current);
      onSaved(saved.noteID, destination === 'new' ? cleanNoteTitle(newTitle)! : noteTitle(store.note(saved.noteID)!));
    } catch (e) { setError(noteWriteFailure(e)); }
    finally { setBusy(false); }
  };
  const cancel = () => { if (busy) return; if (comment.trim() && !leaving) setLeaving(true); else onClose(); };
  const heading = writing ? 'Add text' : 'Save snippet';
  return <Dialog open onClose={cancel} title={heading} className="note-composer">
    <h2>{heading}</h2>
    {draft.image && <div><PreparedImage image={draft.image.full} label="The snippet you drew" />
      <p className="fine">{draft.image.full.width} × {draft.image.full.height} · {draft.image.full.type === 'image/png' ? 'PNG' : 'JPEG'} · saved exactly as shown{onAdjust ? ' · ' : ''}
        {onAdjust && <button className="link small-link" onClick={onAdjust} disabled={busy} data-testid="adjust-crop">Adjust crop</button>}</p></div>}
    {draft.kind === 'quote' && draft.quote && <blockquote className="note-quote composer-quote" data-testid="composer-quote">{draft.quote}</blockquote>}
    {!fixed && <label htmlFor={`${id}-note`}>Collection
      <select id={`${id}-note`} value={destination} onChange={e => setDestination(e.target.value)} disabled={busy} data-testid="composer-note">
        {choices.map(n => <option key={n.id} value={n.id}>{n.title}</option>)}
        <option value="new">New collection…</option>
      </select></label>}
    {!fixed && destination === 'new' && <label>New collection name<input value={newTitle} maxLength={200} placeholder="Name your collection" onChange={e => setNewTitle(e.target.value)} disabled={busy} data-testid="composer-new-name" /></label>}
    {fixed && <p className="fine">Adding to {store.note(draft.destination!)?.title ?? 'this collection'}</p>}
    <label>{writing ? 'Your writing' : 'Your comment (optional)'}
      <textarea rows={writing ? 6 : 4} value={comment} onChange={e => setComment(e.target.value)} disabled={busy} autoFocus={writing}
        placeholder={writing ? 'What are you thinking about?' : 'What caught your attention?'} data-testid="composer-comment" /></label>
    {draft.source && <p className="fine composer-source" data-testid="composer-source">{sourceLine(draft.source)}<br />Captured {dayLabel(draft.capturedAt)} at {timeLabel(draft.capturedAt)}</p>}
    <p className="fine">{store.history.status === 'ready' ? 'Saved here first, then synced with your approved devices.' : 'Saved here first. Sync resumes when you’re back online.'}</p>
    {error && <p className="issue" role="alert" data-testid="composer-error">{error}</p>}
    {leaving ? <div className="dialog-actions" role="group" aria-label="Discard this snippet?"><span className="fine">Discard what you wrote?</span>
      <button className="secondary" onClick={() => setLeaving(false)}>Keep editing</button><button className="primary danger" onClick={onClose} data-testid="composer-discard">Discard</button></div>
      : <div className="dialog-actions"><button className="secondary" disabled={busy} onClick={cancel}>Cancel</button>
        <button className="primary" disabled={busy} onClick={() => void save()} data-testid="composer-save">{busy ? 'Saving…' : writing ? 'Save text' : 'Save snippet'}</button></div>}
  </Dialog>;
}
