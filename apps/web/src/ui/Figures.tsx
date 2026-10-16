// The paper's figures (legacy FigureViewer): a gallery of the verified images, one figure at a time
// in its own sandboxed frame (as the app renders it, caption included), arrow keys to step through,
// and Show in paper, which jumps there with the citation Back. Escape returns from a figure to the gallery.
// Under a figure: Explain (its walkthrough, FIGURE_VIEW.md) and Ask in chat, as under an equation.
import { lazy, Suspense, useEffect, useMemo, useState } from 'react';
import { toBase64 } from '../lib/bytes';
import type { VerifiedBundle } from '../lib/bundle';
import { frameDocument } from '../reader/frame';
import { Dialog } from './common';
import type { FigureHost } from './FigureView';
import { Icon } from './icons';
// Loaded with its first figure page: it brings the Markdown and math typesetter of the walkthrough with it.
const FigureExplain = lazy(() => import('./FigureView').then(m => ({ default: m.FigureExplain })));

export function FigureViewer({ bundle, theme, initial, onClose, onShowInPaper, onDiscuss, figureView, onCite }: {
  bundle: VerifiedBundle; theme: 'light' | 'dark'; initial: string | null; onClose: () => void; onShowInPaper: (id: string) => void; onDiscuss?: (text: string, blockID?: string) => Promise<boolean>;
  /** The figure view's requests (the chat's consent and cache); without it the page offers Ask in chat only. */
  figureView?: FigureHost;
  /** A paragraph a walkthrough cites: the page closes and the paper lands there with Back. */
  onCite?: (paragraph: number) => void;
}) {
  const [discussing, setDiscussing] = useState(false), [issue, setIssue] = useState<string | null>(null);
  // While a walkthrough is asked for or shown, the figure gets smaller so its words are in view.
  const [explaining, setExplaining] = useState(false);
  const figures = bundle.index.figures;
  const [index, setIndex] = useState<number | null>(() => { const i = figures.findIndex(f => f.id === initial); return i >= 0 ? i : null; });
  const [fromGallery, setFromGallery] = useState(index === null);
  const images = useMemo(() => {
    const members = new Map(bundle.manifest.members.map(m => [m.path, m]));
    return figures.map(f => {
      const member = members.get(f.asset_paths[0] ?? '');
      const bytes = member && bundle.contents.get(member.path);
      return member && bytes ? `data:${member.media_type};base64,${toBase64(bytes)}` : null;
    });
  }, [bundle, figures]);
  const current = index !== null ? figures[index] : null;
  const doc = useMemo(() => current ? frameDocument(bundle, { parentOrigin: location.origin, figureID: current.id, theme }) : null, [bundle, current, theme]);
  const back = () => { if (index !== null && fromGallery) setIndex(null); else onClose(); };

  useEffect(() => {
    const key = (event: KeyboardEvent) => {
      if (discussing || index === null || (event.target as HTMLElement)?.closest?.('input, textarea')) return;
      if (event.key === 'ArrowRight') { event.preventDefault(); setIndex(i => (i === null ? i : Math.min(figures.length - 1, i + 1))); }
      if (event.key === 'ArrowLeft') { event.preventDefault(); setIndex(i => (i === null ? i : Math.max(0, i - 1))); }
    };
    window.addEventListener('keydown', key);
    return () => window.removeEventListener('keydown', key);
  }, [index, figures.length, discussing]);

  // Ask in chat: an unsent draft about the figure (its caption), or about one part of its walkthrough (that part's text).
  const discuss = async (text = ''): Promise<boolean> => {
    if (!current || !onDiscuss || discussing) return false;
    setDiscussing(true); setIssue(null);
    try { if (await onDiscuss(text || current.caption || current.alt, current.block_id)) { onClose(); return true; } setIssue('Couldn’t save the chat draft. Try again.'); }
    catch { setIssue('Couldn’t save the chat draft. Try again.'); }
    finally { setDiscussing(false); }
    return false;
  };

  return (
    <Dialog open onClose={() => { if (!discussing) back(); }} title="Figures" wide className="figure-dialog">
      <div className="figure-viewer">
        <div className="figure-head">
          {current && fromGallery && <button className="link" disabled={discussing} onClick={() => setIndex(null)}><Icon name="chevronLeft" size={14} /> All figures</button>}
          <h2>{current ? `Figure ${index! + 1} of ${figures.length}` : `Figures · ${figures.length}`}</h2>
          <div className="figure-actions">
            {current && <>
              <button className="icon-button" onClick={() => setIndex(index! - 1)} disabled={discussing || index === 0} aria-label="Previous figure"><Icon name="chevronLeft" /></button>
              <button className="icon-button" onClick={() => setIndex(index! + 1)} disabled={discussing || index === figures.length - 1} aria-label="Next figure"><Icon name="chevronRight" /></button>
              <button className="secondary small" disabled={discussing} onClick={() => onShowInPaper(current.id)} data-testid="show-in-paper">Show in paper</button>
            </>}
            <button className="primary small" disabled={discussing} onClick={onClose}>Done</button>
          </div>
        </div>
        {current && doc ? (
          <iframe key={current.id} className={`figure-frame${explaining ? ' compact' : ''}`} title={current.alt || `Figure ${index! + 1}`} sandbox="allow-scripts" srcDoc={doc} />
        ) : (
          <ul className="figure-grid" aria-label="Figures">
            {figures.map((f, i) => (
              <li key={f.id}>
                <button className="figure-card" onClick={() => { setFromGallery(true); setIndex(i); }} aria-label={f.alt || `Figure ${i + 1}`}>
                  <span className="figure-thumb">{images[i] ? <img src={images[i]!} alt="" /> : <Icon name="image" size={28} />}</span>
                  <span className="figure-caption">{f.caption || f.alt}</span>
                </button>
              </li>
            ))}
          </ul>
        )}
        {issue && <p className="issue" role="alert">{issue}</p>}
        {current && (onDiscuss || figureView) && <Suspense fallback={null}><FigureExplain key={current.id} manifest={bundle.manifestSHA256} figureID={current.id} host={figureView} busy={discussing}
          onActive={setExplaining} onAsk={onDiscuss ? discuss : undefined} onShowFigure={() => onShowInPaper(current.id)}
          onCite={marker => { if (onCite) onCite(marker); else onShowInPaper(current.id); }} /></Suspense>}
      </div>
    </Dialog>
  );
}
