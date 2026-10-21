import { useState } from 'react';
import { type Library, commandError } from './Library';
import { BackendError } from '../lib/backend';
import { Dialog } from './common';
import type { Catalog } from '../lib/library-catalogs';

const paperCount = (count: number) => `${count} ${count === 1 ? 'paper' : 'papers'}`;

export function CatalogsDialog({ open, onClose, library }: { open: boolean; onClose: () => void; library: Library }) {
  const catalogs = library.catalogs;
  const [editing, setEditing] = useState<Catalog | 'new' | null>(null), [name, setName] = useState('');
  const [deleting, setDeleting] = useState<Catalog | null>(null), [mode, setMode] = useState('existing'), [target, setTarget] = useState('');
  const [confirm, setConfirm] = useState(false), [busy, setBusy] = useState(false), [issue, setIssue] = useState<string | null>(null), [progress, setProgress] = useState('');
  const reset = () => { setEditing(null); setDeleting(null); setIssue(null); setConfirm(false); setProgress(''); };
  const run = async (action: () => Promise<unknown>) => {
    if (busy || !catalogs?.ready) return;
    const signal = catalogs.signal; setIssue(null); setBusy(true);
    try { await action(); if (!signal?.aborted) reset(); }
    // A library command's failure says what happened (D11: it showed codes such as library_revision_conflict).
    catch (error) { if (!signal?.aborted) setIssue(error instanceof BackendError ? commandError(error) : error instanceof Error ? error.message : 'Couldn’t save this change. Try again.'); }
    finally { if (!signal?.aborted) setBusy(false); }
  };
  const remove = () => void run(async () => {
    if (!deleting || !catalogs) return;
    if (mode === 'delete') await library.deleteCatalogPapers(deleting.id, (done, total) => setProgress(`Deleting paper ${done} of ${total}…`));
    else await catalogs.retire(deleting.id, mode === 'existing' ? target : undefined, mode === 'new' ? name : undefined);
  });
  const others = catalogs?.state.catalogs.filter(c => c.id !== deleting?.id) ?? [];
  return <Dialog open={open} onClose={() => { if (!busy) { reset(); onClose(); } }} title="Catalogs">
    <h2>{deleting ? 'Delete catalog' : editing === 'new' ? 'New catalog' : editing ? 'Rename catalog' : 'Catalogs'}</h2>
    {!catalogs?.ready && <p>Unlock your library to manage catalogs.</p>}
    {issue && <p role="alert" className="issue">{issue}</p>}
    <fieldset disabled={busy || !catalogs?.ready} className="catalog-fields">
      {editing ? <form onSubmit={e => { e.preventDefault(); void run(() => editing === 'new' ? catalogs!.create(name) : catalogs!.rename(editing.id, name)); }}>
        <label>Catalog name<input autoFocus value={name} maxLength={160} onChange={e => setName(e.target.value)} /></label>
        <div className="row-actions"><button type="button" className="secondary" onClick={reset}>Cancel</button><button className="primary">Save</button></div>
      </form> : deleting ? <>
        <p>{deleting.name} contains {paperCount(library.catalogEntries(deleting.id).length)}.</p>
        {!confirm ? <>
          <label>What happens to its papers?<select value={mode} onChange={e => setMode(e.target.value)}>
            {others.length > 0 && <option value="existing">Move to another catalog</option>}
            <option value="new">Move to a new catalog</option><option value="delete">Delete its papers</option>
          </select></label>
          {mode === 'existing' && <label>Move papers to<select value={target} onChange={e => setTarget(e.target.value)}>{others.map(c => <option key={c.id} value={c.id}>{c.name}</option>)}</select></label>}
          {mode === 'new' && <label>New catalog name<input value={name} onChange={e => setName(e.target.value)} /></label>}
          <div className="row-actions"><button className="secondary" onClick={reset}>Cancel</button><button className="primary" onClick={() => mode === 'delete' ? setConfirm(true) : remove()}>{mode === 'delete' ? 'Continue' : 'Move papers and delete catalog'}</button></div>
        </> : <>
          <p>Remove these papers from your library and delete {deleting.name}? The catalog stays visible if a removal cannot finish.</p>
          <div className="row-actions"><button className="secondary" onClick={() => setConfirm(false)}>Back</button><button className="danger" onClick={remove}>Delete catalog and papers</button></div>
        </>}
      </> : <>
        <ul className="catalog-list">{catalogs?.state.catalogs.map(c => <li key={c.id}>
          <button className="catalog-select" aria-pressed={c.id === catalogs.currentID} onClick={() => catalogs.select(c.id)}>
            <strong>{c.name}{c.id === catalogs.currentID ? ' ✓' : ''}</strong><span className="fine">{paperCount(library.catalogEntries(c.id).length)}{c.id === catalogs.state.defaultID ? ' · Default' : ''}</span>
          </button>
          <div className="row-actions">
            <button className="link" aria-label={`Rename ${c.name}`} onClick={() => { setEditing(c); setName(c.name); }}>Rename</button>
            {c.id !== catalogs.state.defaultID && <button className="link" aria-label={`Make ${c.name} default`} onClick={() => void run(() => catalogs.makeDefault(c.id))}>Make default</button>}
            <button className="link" aria-label={`Delete ${c.name}`} onClick={() => { const other = catalogs.state.catalogs.find(x => x.id !== c.id); setDeleting(c); setMode(other ? 'existing' : 'new'); setTarget(other?.id ?? ''); setName(''); }}>Delete…</button>
          </div>
        </li>)}</ul>
        <p className="fine">Your default opens when you start the app. New papers go into the catalog you’re viewing.</p>
        <div className="row-actions"><button className="secondary" onClick={() => { reset(); onClose(); }}>Close</button><button className="primary" onClick={() => { setEditing('new'); setName(''); }}>New catalog</button></div>
      </>}
    </fieldset>
    {busy && <p role="status">{progress || 'Saving…'}</p>}
  </Dialog>;
}
