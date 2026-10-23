// Search beside the reading view (owner, 2026-10-22: "the search bar should probably be on the left … in the same area as
// the list of articles would be", like Mail): a mode of the left panel off the Library route. Its own field with ✕, the
// Library | ML papers switch inside the panel, and a list of papers; a result opens in the middle and the list stays,
// the open paper highlighted. Logic: lib/search-rail.ts.
import type { KeyboardEvent, Ref } from 'react';
import { firstAuthorLine } from '../lib/authors';
import type { Row } from '../lib/paper';
import { Icon } from './icons';
import type { Library } from './Library';
import { type PaperSearch, PaperSearchView } from './PaperSearch';
import './search-rail.css';

/** Up and Down move between the list's rows; Up from the first returns to the field. */
function moveRows(event: KeyboardEvent<HTMLElement>, field: () => void) {
  if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return;
  const rows = [...event.currentTarget.querySelectorAll<HTMLElement>('button.search-rail-open')];
  const index = rows.indexOf(document.activeElement as HTMLElement);
  if (index < 0) return;
  event.preventDefault();
  if (event.key === 'ArrowUp' && index === 0) { field(); return; }
  rows[Math.max(0, Math.min(rows.length - 1, index + (event.key === 'ArrowDown' ? 1 : -1)))]?.focus();
}

/** The Library route's Library | ML papers switch, in its title row while searching (never a row of its own that pushes
 * the page down, audit S2), with Cancel. */
export function ScopeSwitch({ ml, onLibrary, onML, onCancel }: { ml: boolean; onLibrary: () => void; onML: () => void; onCancel: () => void }) {
  return <span className="scope-switch" data-testid="search-scope">
    <span className="segmented" role="group" aria-label="Search in">
      <button type="button" className={`segment${ml ? '' : ' on'}`} aria-pressed={!ml} onMouseDown={e => e.preventDefault()} onClick={onLibrary} data-testid="search-scope-library">Library</button>
      <button type="button" className={`segment${ml ? ' on' : ''}`} aria-pressed={ml} onMouseDown={e => e.preventDefault()} onClick={onML} data-testid="search-scope-arxiv">ML papers</button>
    </span>
    <button type="button" className="link small-link" onMouseDown={e => e.preventDefault()} onClick={onCancel} data-testid="search-cancel">Cancel</button>
  </span>;
}

export function SearchRail({ fieldRef, text, ml, onText, onKey, onClose, onLibrary, onML, matches, total, currentID, onOpen, search, library, preparing, onAdded, onOpenSource, currentSource }: {
  fieldRef: Ref<HTMLInputElement>; text: string; ml: boolean; onText: (text: string) => void; onKey: (event: KeyboardEvent<HTMLInputElement>) => void;
  onClose: () => void; onLibrary: () => void; onML: () => void;
  /** Library mode: the matches (best first), how many there are, the paper open in the middle and how to open one. */
  matches: Row[]; total: number; currentID: string | null; onOpen: (row: Row) => void;
  /** ML mode: ML paper search's states and rows. */
  search: PaperSearch; library: Library; preparing?: Map<string, number | null>; onAdded?: (sourceID: string) => void; onOpenSource: (sourceID: string) => void; currentSource: string | null;
}) {
  const words = text.trim();
  const focusField = () => (document.querySelector<HTMLInputElement>('[data-testid=rail-search]'))?.focus();
  // Esc from a row returns to the field (where Esc clears, then ends search), never past the list.
  return <div className="search-rail" data-testid="search-rail"
    onKeyDown={e => { if (e.key === 'Escape' && (e.target as HTMLElement).tagName !== 'INPUT') { e.preventDefault(); e.stopPropagation(); focusField(); } }}>
    <div className="search-rail-top">
      <div className="search-rail-field">
        <Icon name="search" size={14} />
        <input ref={fieldRef} type="search" placeholder="Search papers" aria-label="Search papers" value={text} data-testid="rail-search" enterKeyHint="search"
          autoComplete="off" spellCheck={false} onChange={e => onText(e.target.value)} onKeyDown={onKey} />
        <button type="button" className="icon-button search-rail-close" onClick={onClose} aria-label="Close search" title="Close search (Esc)" data-testid="rail-search-close">
          <Icon name="close" size={15} /></button>
      </div>
      <span className="segmented search-rail-switch" role="group" aria-label="Search in" data-testid="search-scope">
        <button type="button" className={`segment${ml ? '' : ' on'}`} aria-pressed={!ml} onClick={onLibrary} data-testid="search-scope-library">Library</button>
        <button type="button" className={`segment${ml ? ' on' : ''}`} aria-pressed={ml} onClick={onML} data-testid="search-scope-arxiv">ML papers</button>
      </span>
    </div>
    <div className="search-rail-body">
      {ml ? <PaperSearchView compact search={search} library={library} preparing={preparing} onAdded={onAdded} onOpen={onOpenSource} current={currentSource} />
        : !words ? <p className="fine search-rail-note" data-testid="rail-search-idle">Search your library by title, author or tag, or switch to ML papers.</p>
        : matches.length === 0 ? <div className="search-rail-note" data-testid="rail-search-empty"><p className="fine">No papers in your library match “{words}”.</p>
          <button type="button" className="link" onClick={onML} data-testid="rail-search-ml">Search ML papers for “{words}”</button></div>
        : <>
          {total > matches.length && <p className="fine search-rail-note">Showing {matches.length.toLocaleString()} of {total.toLocaleString()}</p>}
          <ul className="search-rail-list" aria-label="Library results" onKeyDown={e => moveRows(e, focusField)}>
            {matches.map(row => {
              const meta = [firstAuthorLine(row.entry.metadata?.authors ?? []) || null, row.year].filter(Boolean).join(' · ');
              const current = row.entry.id === currentID;
              return <li key={row.key} className={`search-rail-row${current ? ' current' : ''}`}>
                <button type="button" className="search-rail-open" aria-current={current ? 'page' : undefined} onClick={() => onOpen(row)} data-testid="search-result">
                  <span className="search-rail-title">{row.title}</span>{meta && <span className="search-rail-meta">{meta}</span>}</button>
              </li>;
            })}
          </ul>
        </>}
    </div>
  </div>;
}
