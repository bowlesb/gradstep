// The paper's figures (legacy FigureViewer): a gallery of the verified images, one figure at a time
// in its own sandboxed frame (as the app renders it, caption included), arrow keys to step through,
// and Show in paper, which jumps there with the citation Back. Escape returns from a figure to the gallery.
// One top row (owner, build 62; docs/DESIGN.md "Sheet top row"): Explain in Chat (an unsent draft about the figure) and
// AI Explainer (its walkthrough, FIGURE_VIEW.md) on the left, the close X on the right; the caption names the figure.
// The walkthrough's heading is a small menu of the paper's figures to switch to; one switched to waits for AI Explainer.
import { ContextualChat, useContextualChat } from './ContextualChat';
import { citedMarker } from '../lib/passage';
import { lazy, Suspense, useEffect, useMemo, useState } from 'react';
import { toBase64 } from '../lib/bytes';
import type { VerifiedBundle } from '../lib/bundle';
import { figureName } from '../lib/figure-view';
import { frameDocument } from '../reader/frame';
import { Dialog, MenuButton, SheetTop } from './common';
import type { FigureHost } from './FigureView';
import { Icon } from './icons';
// Loaded with its first figure page: it brings the Markdown and math typesetter of the walkthrough with it.
const FigureExplain = lazy(() => import('./FigureView').then(m => ({ default: m.FigureExplain })));

export function FigureViewer({ bundle, theme, initial, explain = false, onClose, onShowInPaper, onDiscuss, figureView, onCite }: {
  bundle: VerifiedBundle; theme: 'light' | 'dark'; initial: string | null; onClose: () => void; onShowInPaper: (id: string) => void; onDiscuss?: (text: string, blockID?: string) => Promise<boolean>;
  /** AI Explainer was chosen to open this page (a figure in the paper, a kept explanation): the walkthrough is asked for at once. */
  explain?: boolean;
  /** The figure view's requests (the chat's consent and cache); without it the page offers Explain in Chat only. */
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
  // AI Explainer's presses: for the figure it was pressed on (the first when the page opened to explain).
  const [request, setRequest] = useState<{ id: string; n: number } | null>(() => explain && index !== null ? { id: figures[index].id, n: 1 } : null);
  const images = useMemo(() => {
    const members = new Map(bundle.manifest.members.map(m => [m.path, m]));
    return figures.map(f => {
      const member = members.get(f.asset_paths[0] ?? '');
      const bytes = member && bundle.contents.get(member.path);
      return member && bytes ? `data:${member.media_type};base64,${toBase64(bytes)}` : null;
    });
  }, [bundle, figures]);
  const names = useMemo(() => figures.map(f => figureName(bundle, f.id)), [bundle, figures]);
  const [explanation, setExplanation] = useState('');
  const current = index !== null ? figures[index] : null;
  const context = useContextualChat(figureView?.context, bundle.manifestSHA256, current?.id ?? null, index === null ? 'Figure' : names[index], current?.caption || current?.alt || 'Figure');
  const doc = useMemo(() => current ? frameDocument(bundle, { parentOrigin: location.origin, figureID: current.id, theme }) : null, [bundle, current, theme]);
  const back = () => { if (index !== null && fromGallery) setIndex(null); else onClose(); };
  const show = (i: number) => { setExplaining(false); setIndex(i); };

  useEffect(() => {
    const key = (event: KeyboardEvent) => {
      if (discussing || index === null || (event.target as HTMLElement)?.closest?.('input, textarea, [role=menu]')) return;
      if (event.key === 'ArrowRight' && index < figures.length - 1) { event.preventDefault(); show(index + 1); }
      if (event.key === 'ArrowLeft' && index > 0) { event.preventDefault(); show(index - 1); }
    };
    window.addEventListener('keydown', key);
    return () => window.removeEventListener('keydown', key);
  }, [index, figures.length, discussing]);

  // Explain in Chat: an unsent draft about the figure (its caption), or about one part of its walkthrough (that part's text).
  const discuss = async (text = ''): Promise<boolean> => {
    if (context) {
      if (text) context.host.chat.edit(context.composer, `About this part: ${text} `);
      requestAnimationFrame(() => document.querySelector<HTMLTextAreaElement>('.contextual-chat textarea')?.focus());
      return true;
    }
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
        <SheetTop onClose={onClose} closeDisabled={discussing} testID="figure-close">
          {current ? <>
            {fromGallery && <button className="icon-button sheet-back" disabled={discussing} onClick={() => setIndex(null)} aria-label="All figures" title="All figures"
              data-testid="figure-gallery-back"><Icon name="chevronLeft" /></button>}
            {onDiscuss && <button className="sheet-action" onClick={() => void discuss()} disabled={discussing} data-testid="figure-ask"
              title="Ask about this figure below; nothing is sent"><Icon name="chat" size={15} />Chat about Figure</button>}
            {figureView && !explaining && <button className="sheet-action prominent" disabled={discussing} data-testid="figure-explain"
              onClick={() => setRequest(r => ({ id: current.id, n: (r?.n ?? 0) + 1 }))}
              title="Walks through the figure part by part. Uses credits."><Icon name="sparkles" size={15} />AI Explainer</button>}
          </> : <h2>Figures · {figures.length}</h2>}
        </SheetTop>
        {current && doc ? <>
          <iframe key={current.id} className={`figure-frame${explaining ? ' compact' : ''}`} title={current.alt || names[index!]} sandbox="allow-scripts" srcDoc={doc} />
          <div className="figure-nav">
            <button className="icon-button" onClick={() => show(index! - 1)} disabled={discussing || index === 0} aria-label="Previous figure"><Icon name="chevronLeft" /></button>
            <span className="fine figure-count" aria-live="polite" data-testid="figure-count">{index! + 1} of {figures.length}</span>
            <button className="secondary small" disabled={discussing} onClick={() => onShowInPaper(current.id)} data-testid="show-in-paper">Show in paper</button>
            <button className="icon-button" onClick={() => show(index! + 1)} disabled={discussing || index === figures.length - 1} aria-label="Next figure"><Icon name="chevronRight" /></button>
          </div>
        </> : (
          <ul className="figure-grid" aria-label="Figures">
            {figures.map((f, i) => (
              <li key={f.id}>
                <button className="figure-card" onClick={() => { setFromGallery(true); show(i); }} aria-label={f.alt || names[i]}>
                  <span className="figure-thumb">{images[i] ? <img src={images[i]!} alt="" /> : <Icon name="image" size={28} />}</span>
                  <span className="figure-caption">{f.caption || f.alt}</span>
                </button>
              </li>
            ))}
          </ul>
        )}
        {issue && <p className="issue" role="alert">{issue}</p>}
        {/* The explainer's heading: the paper's figures to switch to (owner, build 62). */}
        {current && explaining && figureView && <h2 className="explainer-heading">{figures.length > 1
          ? <MenuButton icon="chevronDown" text={names[index!]} label={names[index!]} align="start" testID="figure-heading" disabled={discussing}>{close => figures.map((f, i) =>
            <button key={f.id} type="button" role="menuitemradio" aria-checked={i === index} className="menu-item"
              onClick={() => { close(false); if (i !== index) show(i); }}>{names[i]}</button>)}</MenuButton>
          : names[index!]}</h2>}
        {current && figureView && <Suspense fallback={null}><FigureExplain key={current.id} manifest={bundle.manifestSHA256} figureID={current.id} host={figureView} profile={context?.profile} onExplanation={setExplanation} busy={discussing}
          request={request} onActive={setExplaining} onAsk={onDiscuss ? discuss : undefined} onShowFigure={() => onShowInPaper(current.id)}
          onCite={marker => { if (onCite) onCite(marker); else onShowInPaper(current.id); }} /></Suspense>}
        {current && <ContextualChat context={context} explanation={explanation} onCite={anchor => { const n = citedMarker(anchor); if (n && onCite) onCite(n); }} />}
      </div>
    </Dialog>
  );
}
