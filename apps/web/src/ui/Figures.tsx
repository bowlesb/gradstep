// The paper's figures (legacy FigureViewer): a gallery of the verified images, one figure at a time
// in its own sandboxed frame (as the app renders it, caption included), arrow keys to step through,
// and Show in paper, which jumps there with the citation Back. Escape returns from a figure to the gallery.
import { useEffect, useMemo, useState } from 'react';
import { toBase64 } from '../lib/bytes';
import type { VerifiedBundle } from '../lib/bundle';
import { frameDocument } from '../reader/frame';
import { Dialog } from './common';
import { Icon } from './icons';

export function FigureViewer({ bundle, theme, initial, onClose, onShowInPaper }: {
  bundle: VerifiedBundle; theme: 'light' | 'dark'; initial: string | null; onClose: () => void; onShowInPaper: (id: string) => void;
}) {
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
      if (index === null || (event.target as HTMLElement)?.closest?.('input, textarea')) return;
      if (event.key === 'ArrowRight') { event.preventDefault(); setIndex(i => (i === null ? i : Math.min(figures.length - 1, i + 1))); }
      if (event.key === 'ArrowLeft') { event.preventDefault(); setIndex(i => (i === null ? i : Math.max(0, i - 1))); }
    };
    window.addEventListener('keydown', key);
    return () => window.removeEventListener('keydown', key);
  }, [index, figures.length]);

  return (
    <Dialog open onClose={back} title="Figures" wide>
      <div className="figure-viewer">
        <div className="figure-head">
          {current && fromGallery && <button className="link" onClick={() => setIndex(null)}><Icon name="chevronLeft" size={14} /> All figures</button>}
          <h2>{current ? `Figure ${index! + 1} of ${figures.length}` : `Figures · ${figures.length}`}</h2>
          <div className="figure-actions">
            {current && <>
              <button className="icon-button" onClick={() => setIndex(index! - 1)} disabled={index === 0} aria-label="Previous figure"><Icon name="chevronLeft" /></button>
              <button className="icon-button" onClick={() => setIndex(index! + 1)} disabled={index === figures.length - 1} aria-label="Next figure"><Icon name="chevronRight" /></button>
              <button className="secondary small" onClick={() => onShowInPaper(current.id)} data-testid="show-in-paper">Show in paper</button>
            </>}
            <button className="primary small" onClick={onClose}>Done</button>
          </div>
        </div>
        {current && doc ? (
          <iframe key={current.id} className="figure-frame" title={current.alt || `Figure ${index! + 1}`} sandbox="allow-scripts" srcDoc={doc} />
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
      </div>
    </Dialog>
  );
}
