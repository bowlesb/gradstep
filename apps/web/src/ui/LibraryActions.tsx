import {paperShareLinks,sharePublicURL} from '../lib/public-paper-link';
import {entryCatalogKey} from '../lib/library-catalogs';
import type { LibraryPaper, ClientEntry } from '../lib/device-pdf';
import { isLibraryPaper } from '../lib/reader-paper';
import { type ReaderPaper, isReaderPaper, isSourcePaper, paperIdentity } from '../lib/reader-paper';
// One action surface per library view. Rows contain only a button; menus/dialogs are portaled
// outside the scrolling table and identify their owning row for optional library windowing.
import { type KeyboardEvent, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { vocabularyName } from '../../../../supabase/functions/_shared/tag-vocabulary.ts';
import { BackendError } from '../lib/backend';
import { CommandRefreshError, type CommandResponse, type Item } from '../lib/library';
import { effectiveTags, allowedKeyword } from '../lib/paper';
import { containsTag, editedTags, MAX_OWN_TAGS, normalizeTag, ownTagsInLibrary, tagSuggestions } from '../lib/paper-tags';
import type { useLibrary } from './useLibrary';
import './library-actions.css';

type Library = ReturnType<typeof useLibrary>;
type Action = 'menu' | 'tags' | 'archive' | 'remove' | 'catalog';
interface Selection { item: LibraryPaper; trigger: HTMLElement; region: Element | null; action: Action; last: boolean }
type OpenMenu = (item: LibraryPaper, trigger: HTMLButtonElement, last?: boolean) => void;
const title = (item: LibraryPaper) => item.metadata?.title ?? (item.source_id ? `arXiv ${item.source_id}` : 'Untitled paper');

/** A reader-only item at the top of the paper's menu (the reader's ⋯ › Reader version details). */
export interface ExtraAction { label: string; testID: string; applies: (item: LibraryPaper) => boolean; run: (item: LibraryPaper) => void }
/** Whether the library manages this paper (tags, archive, remove): every visible paper but a legacy item outside the shared catalog. */
const managed = (item: LibraryPaper) => !(item.kind === 'item' && item.scope !== 'shared_catalog');

export function useLibraryActions(library: Library, beforeSequentialNavigation?: () => void, extra?: ExtraAction, onSimilar?: (paper:LibraryPaper)=>void) {
  const [selection, setSelection] = useState<Selection | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const current = useRef(selection), latest = useRef(library), returnTo = useRef<Selection | null>(null), latestExtra = useRef(extra);
  current.current = selection; latest.current = library; latestExtra.current = extra;
  const open: OpenMenu = useCallback((item, trigger, last) => {
    if (!item.visible || !managed(item) && !latestExtra.current?.applies(item) || latest.current.pending.has(item.id)) return;
    if (last === undefined && current.current?.action === 'menu' && current.current.trigger === trigger) {
      setSelection(null); return;
    }
    setNotice(null);
    setSelection({ item, trigger, region: trigger.closest('.library, .compact-library'), action: 'menu', last: last ?? false });
  }, []);
  const close = useCallback((owner: Selection, message?: string, restore = true) => {
    if (current.current !== owner) return;
    returnTo.current = restore ? owner : null;
    setSelection(null);
    if (message) setNotice(message);
  }, []);
  const choose = useCallback((owner: Selection, action: Action) => {
    if (current.current === owner) setSelection({ ...owner, action });
  }, []);
  useLayoutEffect(() => {
    if (selection || !returnTo.current) return;
    const owner = returnTo.current;
    returnTo.current = null;
    if (owner.trigger.isConnected && !(owner.trigger instanceof HTMLButtonElement && owner.trigger.disabled)) owner.trigger.focus();
    else if (owner.region?.isConnected) owner.region.querySelector<HTMLElement>('.table-wrap, .paper-menu-button, a.compact-link')?.focus();
  }, [selection]);
  const editTags = (item: LibraryPaper) => {
    if (!item.visible || !managed(item) || latest.current.pending.has(item.id)) return;
    const trigger = document.activeElement instanceof HTMLElement ? document.activeElement : document.body;
    setSelection({ item, trigger, region: null, action: 'tags', last: false });
  };
  return { library, selection, notice, open, close, choose, editTags, beforeSequentialNavigation, extra, onSimilar, menuItemID: selection?.action === 'menu' ? selection.item.id : null };
}
type Actions = ReturnType<typeof useLibraryActions>;

/** Lightweight title-cell control. Never nest it inside the paper link. */
export function PaperMenuButton({ item, busy, expanded, onOpen, extra = false }: { item: LibraryPaper; busy: boolean; expanded: boolean; onOpen: OpenMenu;
  /** The menu has a reader-only item, so it opens for a paper the library doesn't manage too. */ extra?: boolean }) {
  if (!item.visible || !managed(item) && !extra) return null;
  return <button type="button" className="paper-menu-button" aria-label={`Actions for ${title(item)}`} title="Paper actions" disabled={busy}
    aria-haspopup="menu" aria-expanded={expanded} onClick={event => { event.stopPropagation(); onOpen(item, event.currentTarget); }}
    onContextMenu={event => { event.preventDefault(); event.stopPropagation(); onOpen(item, event.currentTarget); }}
    onKeyDown={event => { if (event.key === 'ArrowDown' || event.key === 'ArrowUp') { event.preventDefault(); event.stopPropagation(); onOpen(item, event.currentTarget, event.key === 'ArrowUp'); } }}>
    <svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><circle cx="5" cy="12" r="2" /><circle cx="12" cy="12" r="2" /><circle cx="19" cy="12" r="2" /></svg>
  </button>;
}

export function LibraryActionSurface({ actions }: { actions: Actions }) {
  const selected = actions.selection;
  return <>
    {actions.notice && <p className="library-action-notice fine" role="status">{actions.notice}</p>}
    {selected && createPortal(selected.action === 'menu'
      ? <PaperMenu selection={selected} actions={actions} />
      : <PaperActionDialog key={`${selected.item.id}:${selected.action}`} selection={selected} actions={actions} />, document.body)}
  </>;
}

function PaperMenu({ selection, actions }: { selection: Selection; actions: Actions }) {
  const ref = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const menu = ref.current!;
    const place = () => {
      const rect = selection.trigger.getBoundingClientRect();
      menu.style.left = `${Math.max(8, Math.min(window.innerWidth - menu.offsetWidth - 8, rect.right - menu.offsetWidth))}px`;
      menu.style.top = `${Math.max(8, Math.min(window.innerHeight - menu.offsetHeight - 8, rect.bottom + 4))}px`;
    };
    place();
    const buttons = menu.querySelectorAll<HTMLElement>('[role=menuitem]');
    buttons[selection.last ? buttons.length - 1 : 0]?.focus();
    const outside = (event: PointerEvent) => { if (!menu.contains(event.target as Node) && !selection.trigger.contains(event.target as Node)) actions.close(selection, undefined, false); };
    const focus = (event: FocusEvent) => { if (!menu.contains(event.target as Node) && event.target !== selection.trigger) actions.close(selection, undefined, false); };
    document.addEventListener('pointerdown', outside);
    document.addEventListener('focusin', focus);
    window.addEventListener('resize', place);
    window.addEventListener('scroll', place, true);
    return () => {
      document.removeEventListener('pointerdown', outside); document.removeEventListener('focusin', focus);
      window.removeEventListener('resize', place); window.removeEventListener('scroll', place, true);
    };
  }, [selection, actions.close]);
  const move = (event: KeyboardEvent<HTMLDivElement>) => {
    const buttons = [...event.currentTarget.querySelectorAll<HTMLElement>('[role=menuitem]')];
    const index = buttons.indexOf(document.activeElement as HTMLElement);
    if (['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) {
      event.preventDefault(); event.stopPropagation();
      buttons[event.key === 'Home' ? 0 : event.key === 'End' ? buttons.length - 1 : (index + (event.key === 'ArrowDown' ? 1 : -1) + buttons.length) % buttons.length]?.focus();
    } else if (event.key === 'Escape') {
      event.preventDefault(); event.stopPropagation(); actions.close(selection);
    } else if (event.key === 'Tab') {
      // Resume the native tab sequence at the row's button, rather than tabbing through this
      // detached menu or consuming the key. Windowing expands rows before native traversal.
      event.stopPropagation();
      actions.beforeSequentialNavigation?.();
      if (selection.trigger.isConnected) { selection.trigger.focus({ preventScroll: true }); actions.close(selection, undefined, false); }
      else { event.preventDefault(); actions.close(selection); }
    }
  };
  const extra = actions.extra;
  const links=paperShareLinks(selection.item);
  const share=async(url:string)=>{try{await sharePublicURL(url);actions.close(selection,typeof navigator.share==='function'?undefined:'Link copied');}catch(e){if((e as Error).name!=='AbortError')actions.close(selection,'Couldn’t share the link. Try again.');}};
  return <div ref={ref} role="menu" aria-label="Paper actions" className="paper-action-menu" data-library-row-owner={`${selection.item.kind}:${selection.item.id}`} onKeyDown={move}>
    {actions.onSimilar && <button type="button" role="menuitem" onClick={()=>{actions.close(selection,undefined,false);actions.onSimilar?.(selection.item);}}>Find similar papers</button>}
    {links.source && <button type="button" role="menuitem" onClick={()=>void share(links.source!)}>Share Source URL</button>}
    {links.gradstep && <button type="button" role="menuitem" onClick={()=>void share(links.gradstep!)}>Share Gradstep link</button>}
    {extra?.applies(selection.item) && <button type="button" role="menuitem" data-testid={extra.testID} onClick={() => { actions.close(selection, undefined, false); extra.run(selection.item); }}>{extra.label}</button>}
    {selection.item.kind === 'import' && <button type="button" role="menuitem" onClick={() => {
      window.open(`https://arxiv.org/pdf/${selection.item.source_id}v${selection.item.source_revision}`, '_blank', 'noopener,noreferrer');
      actions.close(selection);
    }}>Open PDF on this device</button>}
    {managed(selection.item) && <>
      <button type="button" role="menuitem" onClick={() => actions.choose(selection, 'tags')}>Edit tags…</button>
      {actions.library.catalogs && actions.library.catalogs.state.catalogs.length > 1 && <button type="button" role="menuitem" onClick={() => actions.choose(selection, 'catalog')}>Move to catalog…</button>}
      <button type="button" role="menuitem" onClick={() => actions.choose(selection, 'archive')}>{selection.item.archived ? 'Unarchive…' : 'Archive…'}</button>
      <button type="button" role="menuitem" className="remove-action" onClick={() => actions.choose(selection, 'remove')}>Remove from library…</button>
    </>}
  </div>;
}

const conflictMessage = 'This paper changed since you opened it. Your draft is still here. Reload the current tags to start again.';
function actionError(error: unknown) {
  if (error instanceof BackendError) {
    if (error.code === 'connection') return 'Couldn’t reach Gradstep. Check the library before trying again; your change may have been saved.';
    if (error.code === 'request_rate_limit') return 'Too many changes in a short time. Try again in a minute.';
    if (error.code === 'library_command_pending') return 'This paper is still updating. Wait for the library to refresh.';
  }
  return 'Couldn’t update this paper. Try again.';
}
const waitingMessage = 'Gradstep received your request, but the library couldn’t refresh. Refresh to check its result.';

function PaperActionDialog({ selection, actions }: { selection: Selection; actions: Actions }) {
  const { library } = actions;
  // The baseline deliberately stays frozen while other devices change the live library.
  const [baseline, setBaseline] = useState(selection.item);
  const [tags, setTags] = useState(() => effectiveTags(selection.item));
  const [draft, setDraft] = useState('');
  const [issue, setIssue] = useState<string | null>(null), [guard, setGuard] = useState(false);
  const [conflict, setConflict] = useState(false), [sending, setSending] = useState(false), [refreshing, setRefreshing] = useState(false);
  const [awaiting, setAwaiting] = useState<CommandResponse | null>(null);
  const ref = useRef<HTMLDialogElement>(null), field = useRef<HTMLInputElement>(null), alive = useRef(false), submitted = useRef(false);
  const moving = selection.action === 'catalog';
  const [destination, setDestination] = useState(() => library.catalogs?.state.catalogFor(entryCatalogKey(selection.item, library.catalogs.state)) ?? '');
  const editing = selection.action === 'tags', archive = selection.action === 'archive', archiveTarget = !selection.item.archived;
  const changed = JSON.stringify(tags) !== JSON.stringify(effectiveTags(baseline));
  const dirty = editing && (changed || draft.trim().length > 0);
  const busy = sending || awaiting !== null || library.pending.has(baseline.id);
  const current = library.entries.find((entry): entry is LibraryPaper => isLibraryPaper(entry) && entry.id === baseline.id);
  const available = current?.visible === true;
  const label = moving ? 'Move to catalog' : editing ? 'Edit tags' : archive ? (archiveTarget ? 'Archive paper' : 'Unarchive paper') : 'Remove paper';
  const verb = moving ? 'Move' : editing ? 'Save' : archive ? (archiveTarget ? 'Archive' : 'Unarchive') : 'Remove';
  const own = useMemo(() => ownTagsInLibrary(library.entries, baseline.id), [library.entries, baseline.id]);
  const suggestions = useMemo(() => tagSuggestions(baseline.tags ?? [], baseline.metadata?.categories ?? [], tags, own, draft).filter(t=>allowedKeyword(t.name)), [baseline, tags, own, draft]);
  const typed = normalizeTag(draft), ownCount = tags.filter(tag => !containsTag(baseline.tags ?? [], tag)).length;
  const invalidDraft = draft.trim().length > 0 && !typed;
  let invalidTags = false;
  try { if (editing) editedTags(baseline.tags ?? [], tags); } catch { invalidTags = true; }

  useLayoutEffect(() => {
    const dialog = ref.current!;
    alive.current = true;
    dialog.showModal();
    if (editing) field.current?.focus();
    return () => { alive.current = false; dialog.close(); };
  }, [editing]);

  const observed = useCallback((response: CommandResponse|null) => {
    if (!alive.current) return;
    setAwaiting(null); setSending(false); submitted.current = false;
    if (response?.result.status === 'revision_conflict') {
      setConflict(true);
      setIssue(editing ? conflictMessage : 'This paper changed since you opened it. Reload the current paper before trying again.');
    } else actions.close(selection, moving ? 'Paper moved.' : editing ? 'Tags saved.' : archive ? (archiveTarget ? 'Paper archived.' : 'Paper unarchived.') : 'Paper removed from your library.');
  }, [actions.close, selection, editing, archive, archiveTarget, moving]);

  useEffect(() => {
    // useLibrary clears this key only after a complete observation covers the saved receipt.
    if (awaiting && !library.pending.has(baseline.id)) observed(awaiting);
  }, [awaiting, library.pending, baseline.id, observed]);

  const close = (explicit: boolean) => {
    if (busy) return;
    if (!explicit && dirty) { setGuard(true); return; }
    actions.close(selection);
  };
  const add = (raw: string) => {
    if (busy || conflict) return;
    const value = normalizeTag(raw);
    if (!value) { setIssue('Use 1–40 characters, up to 120 UTF-8 bytes, for a tag.'); return; }
    if (!allowedKeyword(value)) { setIssue('Choose a specific method, dataset or topic instead of AI or machine learning.'); return; }
    const name = vocabularyName(value) ?? value;
    if (!containsTag(tags, name)) {
      if (!containsTag(baseline.tags ?? [], name) && ownCount >= MAX_OWN_TAGS) { setIssue(`A paper can have up to ${MAX_OWN_TAGS} tags of your own.`); return; }
      setTags(previous => [...previous, name]);
    }
    setDraft(''); setIssue(null); setGuard(false); field.current?.focus();
  };
  const reload = () => {
    if (busy || !current?.visible) return;
    setBaseline(current); setTags(effectiveTags(current)); setDraft(''); setConflict(false); setIssue(null); setGuard(false);
  };
  const save = async () => {
    if (submitted.current || busy || conflict || !available || library.state !== 'ready' || (editing && (!changed || draft.trim() || invalidTags))) return;
    submitted.current = true; setSending(true); setIssue(null); setGuard(false);
    try {
      if (moving) {
        if (!library.catalogs?.ready || !library.catalogs.currentState().catalogs.some(c => c.id === destination)) throw new BackendError('item_unavailable');
        await library.catalogs.assign(entryCatalogKey(baseline, library.catalogs.currentState()), destination); observed(null);
      } else observed(await (editing ? library.setTags(baseline, tags) : archive ? library.archive(baseline, archiveTarget) : library.removePaper(baseline)));
    } catch (error) {
      if (!alive.current) return;
      if (error instanceof CommandRefreshError) { setAwaiting(error.response); setIssue(waitingMessage); }
      else if (error instanceof BackendError && error.code === 'library_revision_conflict') {
        setConflict(true); setIssue(editing ? conflictMessage : 'This paper changed since you opened it. Reload the current paper before trying again.');
      } else setIssue(actionError(error));
    } finally { if (alive.current) { setSending(false); submitted.current = false; } }
  };
  const refresh = async () => {
    setRefreshing(true);
    try { await library.refresh(); } catch { if (alive.current) setIssue(waitingMessage); }
    finally { if (alive.current) setRefreshing(false); }
  };

  return <dialog ref={ref} className="dialog paper-action-dialog" aria-label={label} data-library-row-owner={`item:${baseline.id}`}
    onCancel={event => { event.preventDefault(); event.stopPropagation(); close(false); }}
    onClick={event => { if (event.target === ref.current) close(false); }}>
    <div className="dialog-body">
      <h2>{label}</h2><p className="fine paper-action-title">{title(baseline)}</p>
      {moving ? <label>Catalog<select aria-label="Catalog" value={destination} onChange={e => setDestination(e.target.value)} disabled={busy}>
        {library.catalogs?.state.catalogs.map(c => <option key={c.id} value={c.id}>{c.name}</option>)}
      </select></label> : editing ? <>
        <div className="editable-tags" aria-label="Selected tags">
          {tags.length ? tags.map(tag => <button key={tag} type="button" className="editable-tag" disabled={busy || conflict} aria-label={`Remove tag ${tag}`}
            onClick={() => { setTags(previous => previous.filter(t => t !== tag)); setIssue(null); setGuard(false); }}>{tag}<span aria-hidden="true">×</span></button>) : <span className="muted">No tags</span>}
        </div>
        <form className="tag-add-form" onSubmit={event => { event.preventDefault(); add(draft); }}>
          <label className="visually-hidden" htmlFor={`tag-field-${baseline.id}`}>Add a tag</label>
          <input id={`tag-field-${baseline.id}`} ref={field} value={draft} onChange={event => { setDraft(event.target.value); setGuard(false); }} disabled={busy || conflict}
            placeholder="Add a tag" autoComplete="off" maxLength={512} aria-invalid={invalidDraft} aria-describedby={invalidDraft ? `tag-limit-${baseline.id}` : undefined} />
          <button type="submit" className="secondary" disabled={busy || conflict || !typed}>Add</button>
        </form>
        {invalidDraft && <p className="issue fine" id={`tag-limit-${baseline.id}`}>Use 1–40 characters, up to 120 UTF-8 bytes, for a tag.</p>}
        {!busy && !conflict && <div className="tag-suggestions" aria-label="Suggested tags">
          {typed && !containsTag(tags, typed) && !vocabularyName(typed) && <button type="button" onClick={() => add(typed)} aria-label={`Add ${typed}`}><span>Add “{typed}”</span></button>}
          {suggestions.map(tag => <button key={tag.name} type="button" onClick={() => add(tag.name)} aria-label={`Add ${tag.name}`}><span>{tag.name}</span>{tag.detail && <small>{tag.detail}</small>}</button>)}
        </div>}
        <p className="fine">Suggested tags come from the paper’s title and abstract. Your tags sync through Gradstep’s server; they aren’t end-to-end encrypted.</p>
      </> : <p>{archive ? (archiveTarget ? 'Archive this paper? It will remain in your library under Archived.' : 'Move this paper back to your active library?')
        : 'Remove this paper from your library? Its personal tags will be cleared. You can add the paper again later.'}</p>}
      {!available && !awaiting && <p className="issue" role="alert">This paper is no longer in your library. Cancel to close this {editing ? 'draft' : 'dialog'}.</p>}
      {issue && <p className="issue" role="alert">{issue}</p>}
      {guard && <p className="fine" role="status">Use Cancel to discard your tag changes.</p>}
      {conflict && available && <button type="button" className="secondary" onClick={reload}>{editing ? 'Reload current tags' : 'Reload current paper'}</button>}
      {awaiting && <button type="button" className="secondary" disabled={refreshing} onClick={() => void refresh()}>{refreshing ? 'Refreshing…' : 'Refresh library'}</button>}
      <div className="dialog-actions">
        <button type="button" className="secondary" disabled={busy} onClick={() => close(true)}>Cancel</button>
        <button type="button" className={selection.action === 'remove' ? 'primary remove-action' : 'primary'} disabled={busy || conflict || !available || library.state !== 'ready' || (editing && (!changed || !!draft.trim() || invalidTags))}
          onClick={() => void save()}>{sending ? 'Saving…' : awaiting ? 'Checking…' : verb}</button>
      </div>
    </div>
  </dialog>;
}
