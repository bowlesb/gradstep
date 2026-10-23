// AI recommendations (docs/architecture/AI_RECOMMENDATIONS.md): Paper ⋯ › Recommend similar papers › Add 1/3/5 papers,
// and the Library's Recommend for this catalog. The request belongs to the page (closing the dialog never stops it); the
// dialog shows each paper as it is added, with why, and lets the reader remove any of them or undo all.
import { useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react';
import { arxivCatalogKey, entryCatalogKey } from '../lib/library-catalogs';
import { CommandRefreshError } from '../lib/library';
import type { ClientEntry, LibraryPaper } from '../lib/device-pdf';
import {
  catalogSeeds, creditLabel, eligibleSeed, footerText, papersLabel, RECOMMEND_COUNTS, RECOMMEND_CREDITS, RecommendationRun, recommendBody,
  statusText, streamRecommend, type RecommendCount, type RecommendedPaper,
} from '../lib/recommend';
import { Dialog } from './common';
import { accountBalance, useFreeAIRefusal } from './free-ai';
import type { useLibrary } from './useLibrary';
import './recommend.css';

type Library = ReturnType<typeof useLibrary>;

export interface Recommender {
  /** Whether a paper can be the source of a request. */
  eligible(entry: ClientEntry): boolean;
  /** The note under the menu's title: the price, and where the papers go when there is a choice. */
  note: string;
  paper(entry: LibraryPaper, count: RecommendCount): void;
  catalog(count: RecommendCount): void;
  /** The catalog being viewed has a paper to recommend from. */
  catalogAvailable: boolean;
  catalogName: string;
  run: RecommendationRun | null;
  /** The signed-in account (its balance explains a free-AI refusal). */
  account?: string;
  open: boolean;
  setOpen(open: boolean): void;
}

const title = (entry: ClientEntry) => (entry as { metadata?: { title?: string } }).metadata?.title?.trim() || 'this paper';

export function useRecommendations(account: string, library: Library): Recommender {
  const latest = useRef(library); latest.current = library;
  const [run, setRun] = useState<RecommendationRun | null>(null);
  const [open, setOpen] = useState(false);
  const current = useRef<RecommendationRun | null>(null);
  useEffect(() => () => { current.current?.dispose(); }, [account]);
  useEffect(() => { current.current?.dispose(); current.current = null; setRun(null); setOpen(false); }, [account]);
  const catalogs = library.catalogs;
  const catalogName = catalogs?.state.catalogs.find(c => c.id === catalogs.currentID)?.name ?? 'Default';
  const choice = (catalogs?.state.catalogs.length ?? 1) > 1;
  const note = `${RECOMMEND_CREDITS} credit${choice ? ` · added to ${catalogName}` : ''}`;
  const inCatalog = useCallback((entry: ClientEntry) => {
    const c = latest.current.catalogs;
    return !c || c.state.catalogFor(entryCatalogKey(entry, c.state)) === c.currentID;
  }, []);
  const catalogAvailable = useMemo(() => catalogSeeds(library.entries, inCatalog).length > 0, [library.entries, inCatalog, catalogs?.currentID, catalogs?.state]);

  const begin = useCallback((scope: 'paper' | 'catalog', seeds: LibraryPaper[], count: RecommendCount, subject: string) => {
    if (current.current?.running) { setOpen(true); return; }
    const lib = latest.current, destination = lib.catalogs?.currentID ?? null;
    const name = lib.catalogs && lib.catalogs.state.catalogs.length > 1 ? lib.catalogs.state.catalogs.find(c => c.id === destination)?.name ?? null : null;
    const findEntry = async (source: string) => {
      let entry = latest.current.sourceEntry(source);
      if (!entry) { await latest.current.refresh().catch(() => {}); entry = latest.current.sourceEntry(source); }
      return entry;
    };
    const next = new RecommendationRun({
      stream: (body, signal) => streamRecommend(account, body, signal),
      assign: async source => {
        const c = latest.current.catalogs;
        if (!c || !destination) return;
        const key = arxivCatalogKey(source);
        if (key) { await c.assign(key, destination); return; }
        const entry = await findEntry(source);
        if (entry) await c.assign(entryCatalogKey(entry, c.currentState()), destination);
      },
      refresh: () => latest.current.refresh(),
      remove: async (paper: RecommendedPaper) => {
        const entry = await findEntry(paper.source_id);
        if (!entry) throw Error('not_found');
        try {
          if (entry.kind === 'import') await latest.current.remove(entry);
          else await latest.current.removePaper(entry as LibraryPaper);
        } catch (error) {
          // Sent and applied; only the library's refresh after it failed.
          if (!(error instanceof CommandRefreshError)) throw error;
        }
      },
    }, recommendBody(scope, seeds, count), subject, name);
    current.current?.dispose();
    current.current = next; setRun(next); setOpen(true);
    void next.start();
  }, [account]);

  return {
    eligible: eligibleSeed, note, catalogAvailable, catalogName, run, open, setOpen, account,
    paper: (entry, count) => { if (eligibleSeed(entry)) begin('paper', [entry], count, title(entry)); },
    catalog: count => {
      const seeds = catalogSeeds(latest.current.entries, inCatalog);
      if (seeds.length) begin('catalog', seeds, count, catalogName);
    },
  };
}

/** The three choices and the price note: a group inside a menu (the paper's ⋯) or a menu's body (the catalog's). */
export function RecommendChoices({ note, onChoose }: { note: string; onChoose: (count: RecommendCount) => void }) {
  return <>
    <p className="fine recommend-note" data-testid="recommend-note">{note}</p>
    {RECOMMEND_COUNTS.map(n => <button key={n} type="button" role="menuitem" className="menu-item recommend-choice" data-testid={`recommend-add-${n}`}
      onClick={() => onChoose(n)}>Add {papersLabel(n)}</button>)}
  </>;
}


export function RecommendDialog({ recommender }: { recommender: Recommender }) {
  const run = recommender.run;
  const subscribe = useCallback((l: () => void) => run ? run.subscribe(l) : () => {}, [run]);
  const state = useSyncExternalStore(subscribe, () => run?.state ?? null);
  const [undoing, setUndoing] = useState(false);
  useEffect(() => setUndoing(false), [run]);
  // Free AI (migration 0150): why free credits couldn't pay, from a fresh balance read (recommendations use a fast model).
  const freeBalance = useMemo(() => accountBalance(recommender.account), [recommender.account]);
  const freeRefusal = useFreeAIRefusal(state?.error?.code, freeBalance);
  if (!run || !state) return null;
  const close = () => recommender.setOpen(false);
  const running = state.phase === 'searching' || state.phase === 'choosing';
  const footer = footerText(state);
  const canUndo = state.phase === 'done' && !state.undone && state.rows.some(r => r.paper.status === 'added' && r.removal !== 'removed');
  return <Dialog open={recommender.open} onClose={close} title="Recommended papers" className="recommend-dialog">
    <div data-testid="recommend-dialog">
      <h2>Recommended papers</h2>
      <p className="fine recommend-subject">{state.scope === 'paper' ? `Like “${state.subject}”` : `For ${state.subject}`}</p>
      {running && <p className="recommend-status" role="status" aria-live="polite" data-testid="recommend-status"><span className="spinner" aria-hidden="true" />{statusText(state)}</p>}
      {state.rows.length > 0 && <ul className="recommend-rows" aria-label="Recommended papers">
        {state.rows.map(({ paper, removal }) => {
          const removed = removal === 'removed';
          return <li key={paper.source_id} className={`recommend-row${removed ? ' removed' : ''}`} data-testid={`recommend-row-${paper.source_id}`}>
            <div className="recommend-text">
              <span className="recommend-title">{paper.title}</span>
              {(paper.authors.length > 0 || paper.year) && <span className="fine recommend-meta">{[paper.authors.join(', '), paper.year].filter(Boolean).join(' · ')}</span>}
              {paper.reason && <span className="recommend-reason">{paper.reason}</span>}
              {paper.status === 'present' && <span className="fine recommend-state">Already in your library</span>}
              {paper.status === 'failed' && <span className="fine recommend-state">Couldn’t add</span>}
              {removed && <span className="fine recommend-state">Removed</span>}
              {removal === 'failed' && <span className="fine recommend-state issue">Couldn’t remove. Try again.</span>}
            </div>
            {paper.status === 'added' && !removed && <button type="button" className="icon-button recommend-remove" aria-label={`Remove ${paper.title}`} title="Remove from library"
              data-testid={`recommend-remove-${paper.source_id}`} disabled={removal === 'removing' || undoing} onClick={() => void run.remove(paper.source_id)}>
              <span aria-hidden="true">×</span></button>}
          </li>;
        })}
      </ul>}
      {state.error && <div className="recommend-error"><p className="issue" role="alert">{freeRefusal ?? state.error.message}</p>
        {state.error.retryable && <button type="button" className="secondary small" data-testid="recommend-retry" onClick={() => void run.retry()}>Try again</button>}</div>}
      {footer && <p className="recommend-footer" role="status" data-testid="recommend-footer">{footer}</p>}
      {running && <p className="fine recommend-price">{creditLabel(RECOMMEND_CREDITS)}, only if papers are added. You can close this; they’re still added.</p>}
      {state.catalogIssue && <p className="fine">Some papers couldn’t be put in this catalog. Move them from their ⋯ menu.</p>}
      <div className="dialog-actions">
        {canUndo && <button type="button" className="secondary" data-testid="recommend-undo" disabled={undoing}
          onClick={async () => { setUndoing(true); try { await run.undo(); } finally { setUndoing(false); } }}>{undoing ? 'Removing…' : 'Undo'}</button>}
        <button type="button" className="primary" data-testid="recommend-done" onClick={close}>Done</button>
      </div>
    </div>
  </Dialog>;
}
