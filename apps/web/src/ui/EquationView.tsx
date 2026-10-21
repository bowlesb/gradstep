// The equation view (docs/architecture/EQUATION_VIEW.md): one top row — Explain in Chat (an unsent draft) and AI Explainer
// on the left, the close X on the right (owner, build 62; docs/DESIGN.md "Sheet top row") — then the equation's heading,
// a small menu of the paper's other equations to switch to, and the equation large (a size control and an optional
// sideways scroll). Nothing is asked of the AI unasked (owner, build 59): AI Explainer asks for what it says and each
// symbol described with where that comes from, after which More background is offered; chosen from the equation's own
// menu it asks at once (consent first), while an equation switched to from the heading waits for it. No credit counts
// are shown here (owner, build 59). Loaded only when opened (it brings the math typesetter with it).
import { STANDARD_PROFILE, modelName, modelOption, type ProfileChoice } from '../lib/chat-profiles';
import { ExplainerModelDialog } from './ChatProfile';
import { ContextualChat, useContextualChat, promoteContextual, type ContextualHost } from './ContextualChat';
import { citedMarker } from '../lib/passage';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { VerifiedBundle } from '../lib/bundle';
import { failureText } from '../lib/chat';
import { equationLatex, equationNumber, equationNumbers, type EquationAction, type EquationResult } from '../lib/equation';
import { contentsEquations } from '../lib/paper-contents';
import { safeLink } from '../lib/markdown';
import { symbolMath } from '../lib/equation-math';
import { equationDocument } from '../reader/equation-frame';
import Answer from './Answer';
import { Dialog, MenuButton, SheetTop } from './common';
import { Icon } from './icons';
import { readStored, writeStored } from './prefs';

/** What the reader's host offers the view: the chat's consent and its requests (ChatSession.equation). */
export interface EquationHost {
  context?: ContextualHost;
  consented: () => boolean; accept: () => boolean;
  saved: (manifest: string, equationID: string, action: EquationAction, choice?: ProfileChoice) => EquationResult | null;
  run: (input: { equationID: string; latex: string; number: string | null }, action: EquationAction, update: (result: EquationResult) => void, signal: AbortSignal, choice?: ProfileChoice) => Promise<EquationResult>;
}
type Props = { bundle: VerifiedBundle; equationID: string; theme: 'light' | 'dark'; fontSize: number; host?: EquationHost;
  /** AI Explainer was chosen on the equation in the paper: the explanation is asked for at once (after the consent). */
  autoExplain?: boolean;
  /** Another of the paper's equations, chosen from the heading's menu: shown in its place, waiting for AI Explainer. */
  onSwitch?: (equationID: string) => void;
  onClose: () => void; onCite: (paragraph: number) => void; onAsk?: () => void;
  /** Notes: this equation, rendered on this device as an image, into the composer (NOTES_AND_SNIPPETS.md). */
  onAddToNote?: () => void };

const VIEW_KEY = 'gradstep.equation-view.v1';
const SCALES = [100, 120, 140, 160, 200, 240, 280, 320, 360, 400];
const readView = () => readStored<{ scale: number; scroll: boolean }>(VIEW_KEY, { scale: 160, scroll: false },
  v => !!v && typeof v === 'object' && SCALES.includes((v as { scale: unknown }).scale as number) && typeof (v as { scroll: unknown }).scroll === 'boolean');

export default function EquationView({ bundle, equationID, theme, fontSize, host, autoExplain = false, onSwitch, onClose, onCite, onAsk, onAddToNote }: Props) {
  const number = useMemo(() => equationNumber(bundle, equationID), [bundle, equationID]);
  // The heading's menu: every display equation as Contents lists it ("Equation (4)", "Equation · 3.2 Method").
  const others = useMemo(() => { const numbers = equationNumbers(bundle); return contentsEquations(bundle.index, id => numbers.get(id) ?? null); }, [bundle]);
  const latex = useMemo(() => equationLatex(bundle, equationID), [bundle, equationID]);
  const title = number ? `Equation ${number}` : 'Equation';
  const context = useContextualChat(host?.context, bundle.manifestSHA256, equationID, title, latex ?? '');
  // AI Explainer asks which model first (B7, AIChoiceView): Default or Choose model; that choice answers here.
  const [chosen, setChosen] = useState<ProfileChoice | null>(null), [choosing, setChoosing] = useState(false), [pending, setPending] = useState(false);
  const profile = chosen ?? context?.profile, profileKey = JSON.stringify(profile);
  const table = host?.context?.chat.profileTable ?? null;
  const [view, setView] = useState(readView);
  const viewRef = useRef(view); viewRef.current = view;
  const [doc, setDoc] = useState<string | null>(null);
  const [missing, setMissing] = useState(false);
  const [height, setHeight] = useState(120);
  const frame = useRef<HTMLIFrameElement>(null);
  const size = (scale: number) => Math.round(fontSize * scale) / 100;

  useEffect(() => {
    let next: string | null = null;
    try { next = equationDocument(bundle, equationID, { parentOrigin: location.origin, theme, size: fontSize, scale: viewRef.current.scale / 100 }); } catch { next = null; }
    setDoc(next); setMissing(!next);
  }, [bundle, equationID, theme]);
  useEffect(() => {
    const receive = (event: MessageEvent) => {
      if (!frame.current || event.source !== frame.current.contentWindow || event.data?.gradstep !== 'equation') return;
      const h = Number(event.data.height);
      if (Number.isFinite(h)) setHeight(Math.min(1600, Math.max(48, h)));
    };
    addEventListener('message', receive);
    return () => removeEventListener('message', receive);
  }, []);
  const change = (next: { scale: number; scroll: boolean }) => {
    setView(next); writeStored(VIEW_KEY, next);
    frame.current?.contentWindow?.postMessage({ gradstep: 'equation-command', size: fontSize, scale: next.scale / 100 }, '*');
  };
  const step = (delta: number) => { const i = SCALES.indexOf(view.scale) + delta; if (i >= 0 && i < SCALES.length) change({ ...view, scale: SCALES[i] }); };

  // The two requests, each only on its button: Explain (what it says and the symbols), then More background.
  const [consented, setConsented] = useState(() => !!host?.consented());
  // Explain was pressed before the chat's consent: the consent shows, and Allow asks.
  const [asking, setAsking] = useState(false);
  const [symbols, setSymbols] = useState<EquationResult | null>(() => host?.saved(bundle.manifestSHA256, equationID, 'equation', profile) ?? null);
  const [background, setBackground] = useState<EquationResult | null>(() => host?.saved(bundle.manifestSHA256, equationID, 'equation_background', profile) ?? null);
  const requests = useRef(new Map<EquationAction, AbortController>());
  useEffect(() => () => { for (const c of requests.current.values()) c.abort(); }, []);
  const run = useCallback((action: EquationAction) => {
    if (!host || !latex) return;
    requests.current.get(action)?.abort();
    const controller = new AbortController(); requests.current.set(action, controller);
    const set = action === 'equation' ? setSymbols : setBackground;
    void host.run({ equationID, latex, number }, action, result => { if (!controller.signal.aborted) set(result); }, controller.signal, profile).catch(() => {});
  }, [host, latex, equationID, number, profileKey]);
  useEffect(() => {
    for (const c of requests.current.values()) c.abort();
    setSymbols(host?.saved(bundle.manifestSHA256, equationID, 'equation', profile) ?? null);
    setBackground(host?.saved(bundle.manifestSHA256, equationID, 'equation_background', profile) ?? null);
  }, [profileKey]);
  const loading: EquationResult = { phase: 'loading', symbols: null, text: '', credits: null, issue: null };
  const explain = () => {
    if (!host || symbols) return;
    if (!chosen) { setChoosing(true); return; }
    if (!consented && !host.consented()) { setAsking(true); return; }
    setConsented(true); setAsking(false); setSymbols(loading); run('equation');
  };
  // After the model is chosen (its profile now in force): its kept answer, else the consent or the request.
  useEffect(() => {
    if (!pending || !host) return;
    setPending(false);
    const saved = host.saved(bundle.manifestSHA256, equationID, 'equation', profile);
    if (saved) { setSymbols(saved); return; }
    if (!consented && !host.consented()) { setAsking(true); return; }
    setConsented(true); setAsking(false); setSymbols(loading); run('equation');
  }, [pending, profileKey]); // eslint-disable-line react-hooks/exhaustive-deps
  const allow = () => { if (host?.accept()) { setConsented(true); setAsking(false); setSymbols(loading); run('equation'); } };
  const autoAsked = useRef(false);
  useEffect(() => { if (autoExplain && !autoAsked.current) { autoAsked.current = true; explain(); } }); // eslint-disable-line react-hooks/exhaustive-deps

  // More background brings its section to the top of the panel as its first words arrive, so the answer reads in view
  // rather than below the fold (landing-page capture, 2026-10-15: only the first paragraph showed).
  const backgroundSection = useRef<HTMLElement>(null), shownBackground = useRef(false);
  useEffect(() => {
    if (!background?.text || shownBackground.current) return;
    shownBackground.current = true;
    backgroundSection.current?.scrollIntoView({ block: 'start', behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' });
  }, [background?.text]);
  const [link, setLink] = useState<string | null>(null);
  const answerClick = (e: React.MouseEvent) => {
    const target = e.target as Element, control = target.closest('.cite'), marker = Number(control?.getAttribute('data-cite'));
    if (control && Number.isInteger(marker) && marker >= 1) { e.preventDefault(); onCite(marker); return; }
    const a = target.closest('a[href]'); if (!a) return;
    e.preventDefault(); const href = safeLink(a.getAttribute('href') ?? ''); if (href) setLink(href);
  };

  return <Dialog open onClose={onClose} title={title} className="equation-dialog">
    <div className="equation-view" data-testid="equation-view">
      {/* Owner, build 62: the actions in the top row with the X; no Done, no action bar under the equation. */}
      <SheetTop onClose={onClose} testID="equation-close" trailing={context && <button type="button" className="icon-button" aria-label="Open in Chat" onClick={()=>{promoteContextual(context,[symbols?.symbols?.summary??symbols?.text,...(symbols?.symbols?.symbols.map(s=>`${s.symbol}: ${s.meaning}`)??[]),background?.text].filter(Boolean).join('\n'));onClose();}}><Icon name="chat"/></button>}>

        {host && !symbols && !asking && <button className="sheet-action" onClick={explain} data-testid="equation-explain"
          title="Describes the equation and each of its symbols. Uses credits."><Icon name="sparkles" size={15} />AI Explainer</button>}
        {onAddToNote && <button className="sheet-action" onClick={onAddToNote} data-testid="equation-add-to-note" title="Save this equation as an image in a note"><Icon name="notes" size={15} />Add to note</button>}
      </SheetTop>
      <h2 className="explainer-heading">{onSwitch && others.length > 1
        ? <MenuButton icon="chevronDown" text={title} label={title} align="start" testID="equation-heading">{close => others.map(e =>
          <button key={e.id} type="button" role="menuitemradio" aria-checked={e.id === equationID} className="menu-item"
            onClick={() => { close(false); if (e.id !== equationID) onSwitch(e.id); }}>
            {e.label === 'Equation' && e.text ? `Equation — ${[...e.text].slice(0, 40).join('')}` : e.label}</button>)}</MenuButton>
        : title}</h2>
      <div className={`equation-stage${view.scroll ? ' scrolling' : ''}`}>
        {doc ? <iframe ref={frame} className="equation-frame" sandbox="allow-scripts" srcDoc={doc} title={title} style={{ height }} data-testid="equation-frame" />
          : <p className="fine" role="status">{missing ? 'This equation can’t be shown larger.' : 'Preparing…'}</p>}
      </div>
      <div className="equation-controls">
        <span className="equation-size" role="group" aria-label="Equation size">
          <button className="icon-button text-size" onClick={() => step(-1)} disabled={view.scale <= SCALES[0]} aria-label="Smaller equation" title="Smaller"><span>−</span></button>
          <button className="icon-button text-size" onClick={() => step(1)} disabled={view.scale >= SCALES.at(-1)!} aria-label="Larger equation" title="Larger"><span>+</span></button>
          <output aria-live="polite" data-testid="equation-scale">{view.scale}%</output>
        </span>
      </div>

      {!host ? <p className="fine">Explanations need a signed-in chat.</p> : asking && !consented ? <section className="equation-consent" data-testid="equation-consent">
        <p>Explaining the equation uses cloud AI: the equation and the paper’s text go through OpenRouter to Google Vertex or DeepInfra according to your choice, as with chat. They may retain requests under their API terms. Answers use credits.</p>
        <div className="dialog-actions"><button className="secondary" onClick={() => setAsking(false)}>Not now</button><button className="primary" onClick={allow}>Allow and explain</button></div>
      </section> : !symbols ? null : <>
        <section className="equation-section" aria-labelledby="equation-what">
          <h3 id="equation-what">What it says</h3>
          {symbols?.symbols?.summary ? <p data-testid="equation-summary">{symbols.symbols.summary}</p>
            : symbols?.phase === 'failed' ? null
            : symbols?.phase === 'done' && symbols.text ? <div onClick={answerClick}><Answer text={symbols.text} /></div>
            : <p className="fine" role="status">Describing the symbols…</p>}
        </section>
        <section className="equation-section" aria-labelledby="equation-symbols">
          <h3 id="equation-symbols">Symbols</h3>
          {symbols?.phase === 'failed' ? <div className="equation-issue" role="alert"><p>{failureText(symbols.issue ?? 'provider_unavailable')}</p>
            {symbols.issue !== 'invalid_request' && <button className="secondary small" onClick={() => run('equation')}>Try again</button>}
            <button className="secondary small" onClick={() => setChoosing(true)} data-testid="explainer-change">Change AI</button></div>
            : symbols?.symbols?.symbols.length ? <ul className="equation-symbols" data-testid="equation-symbols">{symbols.symbols.symbols.map((s, i) => <li key={i}>
                <span className="equation-symbol" aria-label={s.symbol}>{(() => { const math = symbolMath(s); return math ? <span dangerouslySetInnerHTML={{ __html: math }} /> : s.symbol; })()}</span>
                <div><p>{s.meaning}</p>{s.source === 'paper' && s.paragraph
                  ? <button className="link equation-source" onClick={() => onCite(s.paragraph!)} data-testid="equation-source">From the paper ¶{s.paragraph}</button>
                  : <span className="fine">General meaning</span>}</div></li>)}</ul>
            : symbols?.phase === 'done' ? <p className="fine">No symbols were listed for this equation.</p>
            : <ul className="equation-symbols loading" aria-hidden="true">{[0, 1, 2].map(i => <li key={i}><span className="equation-symbol" /><div><p /></div></li>)}</ul>}
        </section>
        {/* Which model explained it (the apps' caption): the one that answered, else the one asked. */}
        {(symbols.model || profile) && <p className="fine answer-by" data-testid="explainer-model-name">{symbols.model ? modelName(symbols.model) : modelOption(table, profile!.model).label}</p>}
        {symbols.phase === 'done' && <section ref={backgroundSection} className="equation-section equation-background-section" aria-labelledby="equation-background">
          <h3 id="equation-background">Background</h3>
          {!background ? <button className="secondary" onClick={() => { shownBackground.current = false; run('equation_background'); }} data-testid="equation-more">More background</button>
            : background.phase === 'failed' && !background.text ? <div className="equation-issue" role="alert"><p>{failureText(background.issue ?? 'provider_unavailable')}</p>
              <button className="secondary small" onClick={() => run('equation_background')}>Try again</button></div>
            : <div className="equation-background" onClick={answerClick} data-testid="equation-background">
                {background.text ? <Answer text={background.text} streaming={background.phase === 'loading'} /> : <p className="fine" role="status">Writing background…</p>}</div>}
        </section>}
      </>}
      {host && <ExplainerModelDialog open={choosing} table={table} defaultChoice={context?.profile ?? STANDARD_PROFILE} onClose={() => setChoosing(false)}
        onRetry={() => host.context?.chat.reloadProfiles() ?? Promise.resolve()}
        onUse={choice => { setChoosing(false); setChosen({ ...choice }); setPending(true); }} />}
      <ContextualChat context={context} explanation={[symbols?.symbols?.summary ?? symbols?.text, background?.text].filter(Boolean).join('\n')} onCite={anchor => { const n = citedMarker(anchor); if (n) onCite(n); }} />
      {link && <div className="equation-link" role="group" aria-label="Open source"><p className="source-address">{link}</p>
        <button className="secondary small" onClick={() => setLink(null)}>Cancel</button>
        <a className="primary small" href={link} target="_blank" rel="noopener noreferrer" onClick={() => setLink(null)}>Open link</a></div>}
    </div>
  </Dialog>;
}
