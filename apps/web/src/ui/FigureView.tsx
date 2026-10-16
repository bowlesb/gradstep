// The figure view (docs/architecture/FIGURE_VIEW.md), on the figure page: Explain and Ask in chat side by side under
// the figure, as the equation view. Nothing is asked of the AI on opening; Explain asks the chat's consent first. The
// walkthrough says what the figure shows, then goes part by part, with a crop at the top of a part only where the model
// drew a box (cut here from the image that was sent, so it costs nothing more). Each part's ⋯ offers Explain more
// simply (streamed under it), Show in the paper and Ask in chat about this. No credit counts (owner, build 59).
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { failureText, interruptionNote } from '../lib/chat';
import { cropStyle, sectionHeading, type FigureAction, type FigureResult, type FigureSection } from '../lib/figure-view';
import { safeLink } from '../lib/markdown';
import Answer from './Answer';
import { MenuButton } from './common';
import { Icon } from './icons';

/** What the reader's host offers the view: the chat's consent and its requests (ChatSession.figure). */
export interface FigureHost {
  consented: () => boolean; accept: () => boolean;
  saved: (manifest: string, figureID: string, action: FigureAction, part?: string) => FigureResult | null;
  run: (input: { figureID: string; part?: { key: string; label: string; title: string; text: string } }, action: FigureAction,
    update: (result: FigureResult) => void, signal: AbortSignal) => Promise<FigureResult>;
}
type Props = { manifest: string; figureID: string; host?: FigureHost;
  /** The page's figure gets smaller while a walkthrough is asked for or shown, so the words are in view. */
  onActive: (active: boolean) => void;
  /** A `[¶N]` or a part's Show in the paper: the page closes and the paper lands there with Back. */
  onCite: (paragraph: number) => void; onShowFigure: () => void;
  /** Ask in chat (the caption) or Ask in chat about this (a part's text): an unsent draft; true once it was made. */
  onAsk?: (text: string) => Promise<boolean>; busy: boolean };

const partKey = (s: FigureSection, i: number) => `${i}:${s.label}:${s.title}`;
const words = (r: FigureResult | null) => !!r && (!!r.walkthrough || !!r.text.trim());
/** Under words that ended early and that the server said cost nothing (a length limit): CHAT.md's wording. */
const endedEarly = (r: FigureResult | null | undefined) => r?.phase === 'done' && r.charged === false && words(r) ? interruptionNote(false, { charged: false }) : null;
const loading = (): FigureResult => ({ phase: 'loading', walkthrough: null, text: '', issue: null, image: null, credits: null });
const issueText = (code: string) => code === 'figure_unavailable' ? 'This figure’s image couldn’t be prepared in this browser.' : failureText(code);

export function FigureExplain({ manifest, figureID, host, onActive, onCite, onShowFigure, onAsk, busy }: Props) {
  const [consented, setConsented] = useState(() => !!host?.consented());
  const [asking, setAsking] = useState(false);
  const [walk, setWalk] = useState<FigureResult | null>(() => host?.saved(manifest, figureID, 'figure') ?? null);
  const [simpler, setSimpler] = useState<Map<string, FigureResult>>(() => new Map());
  const requests = useRef(new Map<string, AbortController>());
  useEffect(() => () => { for (const c of requests.current.values()) c.abort(); }, []);
  useEffect(() => { onActive(asking || !!walk); }, [asking, walk, onActive]);

  // A reopened walkthrough brings its parts' simpler explanations with it (this session only).
  useEffect(() => {
    if (!host || !walk?.walkthrough) return;
    setSimpler(previous => {
      const next = new Map(previous);
      walk.walkthrough!.sections.forEach((s, i) => { const k = partKey(s, i), saved = host.saved(manifest, figureID, 'figure_simpler', k); if (saved && !next.has(k)) next.set(k, saved); });
      return next;
    });
  }, [host, manifest, figureID, walk?.walkthrough]);

  const run = useCallback((action: FigureAction, part?: FigureSection, index = 0) => {
    if (!host) return;
    const key = part ? partKey(part, index) : '';
    requests.current.get(`${action}|${key}`)?.abort();
    const controller = new AbortController(); requests.current.set(`${action}|${key}`, controller);
    const set = (result: FigureResult) => {
      if (controller.signal.aborted) return;
      if (action === 'figure') setWalk(result); else setSimpler(m => new Map(m).set(key, result));
    };
    set(loading());
    void host.run({ figureID, ...(part ? { part: { key, label: part.label, title: part.title, text: part.text } } : {}) }, action, set, controller.signal).catch(() => {});
  }, [host, figureID]);

  const panel = useRef<HTMLDivElement>(null);
  const explain = () => {
    if (!host || walk) return;
    if (!consented && !host.consented()) { setAsking(true); return; }
    setConsented(true); setAsking(false); run('figure');
    requestAnimationFrame(() => panel.current?.scrollIntoView({ block: 'start', behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' }));
  };
  const allow = () => { if (host?.accept()) { setConsented(true); setAsking(false); run('figure'); } };

  const [link, setLink] = useState<string | null>(null);
  const answerClick = (e: React.MouseEvent | React.KeyboardEvent) => {
    const target = e.target as Element, control = target.closest('.cite'), marker = Number(control?.getAttribute('data-cite'));
    if (control && Number.isInteger(marker) && marker >= 1) { e.preventDefault(); onCite(marker); return; }
    const a = target.closest('a[href]'); if (!a) return;
    e.preventDefault(); const href = safeLink(a.getAttribute('href') ?? ''); if (href) setLink(href);
  };
  const citeKey = (e: React.KeyboardEvent) => { if ((e.key === 'Enter' || e.key === ' ') && (e.target as Element).closest('.cite')) answerClick(e); };

  const result = walk, sections = result?.walkthrough?.sections ?? [];
  const note = endedEarly(result);
  const image = result?.image ?? null;
  const background = useMemo(() => image ? `url("data:image/jpeg;base64,${image.data}")` : null, [image]);

  return <div className="figure-explain" ref={panel}>
    {(onAsk || (host && !walk && !asking)) && <div className="equation-actions">
      {host && !walk && !asking && <button className="primary" onClick={explain} disabled={busy} data-testid="figure-explain"
        title="Walks through the figure part by part. Uses credits."><Icon name="sparkles" />Explain</button>}
      {onAsk && <button className="secondary" onClick={() => void onAsk('')} disabled={busy} data-testid="figure-ask"
        title="Opens the paper’s chat with this figure selected"><Icon name="chat" />Ask in chat</button>}
    </div>}
    {!host ? null : asking && !consented ? <section className="equation-consent" data-testid="figure-consent">
      <p>Explaining the figure uses cloud AI: the figure’s image and the paper’s text go to Anthropic, or DeepSeek when you choose it, as with chat. They may retain requests under their API terms. Answers use credits.</p>
      <div className="dialog-actions"><button className="secondary" onClick={() => setAsking(false)}>Not now</button><button className="primary" onClick={allow}>Allow and explain</button></div>
    </section> : !result ? null : <div className="figure-walkthrough" data-testid="figure-walkthrough" onClick={answerClick} onKeyDown={citeKey}>
      <section className="equation-section" aria-labelledby="figure-what">
        <h3 id="figure-what">What it shows</h3>
        {result.walkthrough?.summary ? <div data-testid="figure-summary"><Answer text={result.walkthrough.summary} /></div>
          : !result.walkthrough && result.text ? <div data-testid="figure-words"><Answer text={result.text} streaming={result.phase === 'loading'} /></div>
          : result.phase === 'loading' ? <p className="fine" role="status">Looking at the figure…</p> : null}
      </section>
      {sections.length > 0 && <section className="equation-section" aria-labelledby="figure-parts">
        <h3 id="figure-parts">Part by part</h3>
        <ol className="figure-sections">{sections.map((s, i) => {
          const key = partKey(s, i), heading = sectionHeading(s), more = simpler.get(key), style = s.box && image ? cropStyle(s.box, image) : null;
          return <li key={key} className="figure-section" data-testid={`figure-section-${i}`}>
            <div className="figure-section-head">
              <h4>{s.label && <span className="figure-section-label">{s.label}</span>}<span>{s.title}</span></h4>
              <MenuButton icon="more" label={`${heading}: options`} testID={`figure-section-menu-${i}`}>{close => <>
                <button type="button" role="menuitem" className="menu-item" data-testid="figure-simpler-item" disabled={!!more && more.phase !== 'failed'}
                  onClick={() => { close(false); run('figure_simpler', s, i); }}><Icon name="lightbulb" size={14} /> Explain more simply</button>
                <button type="button" role="menuitem" className="menu-item" data-testid="figure-show-item"
                  onClick={() => { close(false); if (s.paragraphs[0]) onCite(s.paragraphs[0]); else onShowFigure(); }}><Icon name="book" size={14} /> Show in the paper</button>
                {onAsk && <button type="button" role="menuitem" className="menu-item" data-testid="figure-ask-item" disabled={busy}
                  onClick={() => { close(false); void onAsk(s.text); }}><Icon name="chat" size={14} /> Ask in chat about this</button>}
              </>}</MenuButton>
            </div>
            {style && background && <div className="figure-crop" role="img" aria-label={`${heading}, the part of the figure it describes`} data-testid="figure-crop"
              style={{ aspectRatio: String(style.aspect), width: `min(100%, ${Math.round(Math.min(560, 320 * style.aspect))}px)`, backgroundImage: background,
                backgroundSize: style.size, backgroundPosition: style.position }} />}
            <Answer text={s.text} />
            {more && <div className="figure-simpler" data-testid="figure-simpler">
              <p className="figure-simpler-head">More simply</p>
              {more.phase === 'failed' && !more.text ? <div className="equation-issue" role="alert"><p>{issueText(more.issue ?? 'provider_unavailable')}</p>
                {more.issue !== 'invalid_request' && <button className="secondary small" onClick={() => run('figure_simpler', s, i)}>Try again</button>}</div>
                : more.text ? <Answer text={more.text} streaming={more.phase === 'loading'} /> : <p className="fine" role="status">Writing…</p>}
              {endedEarly(more) && <p className="fine">{endedEarly(more)}</p>}
            </div>}
          </li>;
        })}</ol>
      </section>}
      {result.phase === 'failed' && <div className="equation-issue" role="alert" data-testid="figure-issue"><p>{issueText(result.issue ?? 'provider_unavailable')}</p>
        {result.issue !== 'invalid_request' && result.issue !== 'storage_retired' && <button className="secondary small" onClick={() => run('figure')} data-testid="figure-retry">Try again</button>}</div>}
      {note && <p className="fine" data-testid="figure-note">{note}</p>}
    </div>}
    {link && <div className="equation-link" role="group" aria-label="Open source"><p className="source-address">{link}</p>
      <button className="secondary small" onClick={() => setLink(null)}>Cancel</button>
      <a className="primary small" href={link} target="_blank" rel="noopener noreferrer" onClick={() => setLink(null)}>Open link</a></div>}
  </div>;
}
