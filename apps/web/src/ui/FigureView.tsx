// The figure view (docs/architecture/FIGURE_VIEW.md), on the figure page: the walkthrough AI Explainer asks for from the
// page's top row (owner, build 62), as the equation view. Nothing is asked of the AI unasked; it asks the chat's consent first. The
// walkthrough says what the figure shows, then goes part by part, with a crop at the top of a part only where the model
// drew a box (cut here from the image that was sent, so it costs nothing more). Each part's ⋯ offers Explain more
// simply (streamed under it), Extract the subfigure and more context (owner, TestFlight 62: a loader under the part, then
// its crop and a closer reading), Show in the paper and Ask in chat about this. No credit counts (owner, build 59).
import { STANDARD_PROFILE, modelName, modelOption, type ProfileChoice } from '../lib/chat-profiles';
import { ExplainerModelDialog } from './ChatProfile';
import type { ContextualHost } from './ContextualChat';
import { useCallback, useEffect, useMemo, useRef, useState, type CSSProperties } from 'react';
import { failureText, interruptionNote } from '../lib/chat';
import { displayBox, cropStyle, cropCoverage, cardTypeLabel, sectionHeading, type FigureAction, type FigureResult, type FigureSection } from '../lib/figure-view';
import { safeLink } from '../lib/markdown';
import Answer from './Answer';
import { Dialog, SheetTop, MenuButton } from './common';
import { Icon } from './icons';

/** What the reader's host offers the view: the chat's consent and its requests (ChatSession.figure). */
export interface FigureHost {
  context?: ContextualHost;
  consented: () => boolean; accept: () => boolean;
  saved: (manifest: string, figureID: string, action: FigureAction, part?: string, choice?: ProfileChoice) => FigureResult | null;
  run: (input: { figureID: string; part?: { key: string; label: string; title: string; text: string } }, action: FigureAction,
    update: (result: FigureResult) => void, signal: AbortSignal, choice?: ProfileChoice) => Promise<FigureResult>;
}
type Props = { label?:string; profile?: ProfileChoice; onExplanation?: (text: string) => void; manifest: string; figureID: string; host?: FigureHost;
  /** The page's figure gets smaller while a walkthrough is asked for or shown, so the words are in view. */
  onActive: (active: boolean) => void;
  /** A `[¶N]` or a part's Show in the paper: the page closes and the paper lands there with Back. */
  onCite: (paragraph: number) => void; onShowFigure: () => void;
  /** Ask in chat about this (a part's text): an unsent draft; true once it was made. */
  onAsk?: (text: string) => Promise<boolean>; busy: boolean;
  /** AI Explainer, pressed in the page's top row (or chosen to open the page): asks for this figure's walkthrough when
   * `id` is this figure and `n` is new. A figure switched to waits for its own press. */
  request?: { id: string; n: number } | null };

const partKey = (s: FigureSection, i: number) => `${i}:${s.label}:${s.title}`;
const words = (r: FigureResult | null) => !!r && (!!r.walkthrough || !!r.text.trim());
/** Under words that ended early and that the server said cost nothing (a length limit): CHAT.md's wording. */
const endedEarly = (r: FigureResult | null | undefined) => r?.phase === 'done' && r.charged === false && words(r) ? interruptionNote(false, { charged: false }) : null;
const loading = (): FigureResult => ({ phase: 'loading', walkthrough: null, text: '', issue: null, image: null, credits: null });
const issueText = (code: string) => code === 'figure_unavailable' ? 'This figure’s image couldn’t be prepared in this browser.' : failureText(code);

export function FigureExplain({ manifest, figureID, host, onActive, onCite, onShowFigure, onAsk, busy, request, profile: shownProfile, onExplanation, label = 'Figure' }: Props) {
  // AI Explainer asks which model first (B7, AIChoiceView): Default or Choose model; that choice answers here.
  const [chosen, setChosen] = useState<ProfileChoice | null>(null), [choosing, setChoosing] = useState(false), [pending, setPending] = useState(false);
  const profile = chosen ?? shownProfile, table = host?.context?.chat.profileTable ?? null;
  const [consented, setConsented] = useState(() => !!host?.consented());
  const [asking, setAsking] = useState(false);
  const [walk, setWalk] = useState<FigureResult | null>(() => host?.saved(manifest, figureID, 'figure', '', profile) ?? null);
  const [simpler, setSimpler] = useState<Map<string, FigureResult>>(() => new Map());
  const [details, setDetails] = useState<Map<string, FigureResult>>(() => new Map());
  const requests = useRef(new Map<string, AbortController>());
  useEffect(() => () => { for (const c of requests.current.values()) c.abort(); }, []);
  useEffect(() => { onActive(asking || !!walk); }, [asking, walk, onActive]);

  useEffect(() => {
    for (const c of requests.current.values()) c.abort();
    setWalk(host?.saved(manifest, figureID, 'figure', '', profile) ?? null); setSimpler(new Map()); setDetails(new Map());
  }, [JSON.stringify(profile)]);
  useEffect(() => { onExplanation?.(walk?.walkthrough ? [walk.walkthrough.summary, ...walk.walkthrough.sections.map(s => s.text)].join('\n') : walk?.text ?? ''); }, [walk, onExplanation]);
  // A reopened walkthrough brings its parts' simpler explanations with it (this session only).
  useEffect(() => {
    if (!host || !walk?.walkthrough) return;
    setSimpler(previous => {
      const next = new Map(previous);
      walk.walkthrough!.sections.forEach((s, i) => { const k = partKey(s, i), saved = host.saved(manifest, figureID, 'figure_simpler', k, profile); if (saved && !next.has(k)) next.set(k, saved); });
      return next;
    });
    setDetails(previous => {
      const next = new Map(previous);
      walk.walkthrough!.sections.forEach((s, i) => { const k = partKey(s, i), saved = host.saved(manifest, figureID, 'figure_detail', k, profile); if (saved && !next.has(k)) next.set(k, saved); });
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
      if (action === 'figure') setWalk(result);
      else if (action === 'figure_detail') setDetails(m => new Map(m).set(key, result));
      else setSimpler(m => new Map(m).set(key, result));
    };
    set(loading());
    void host.run({ figureID, ...(part ? { part: { key, label: part.label, title: part.title, text: part.text } } : {}) }, action, set, controller.signal, profile).catch(() => {});
  }, [host, figureID, JSON.stringify(profile)]);

  const panel = useRef<HTMLDivElement>(null);
  const explain = () => {
    if (!host || walk) return;
    if (!chosen) { setChoosing(true); return; }
    if (!consented && !host.consented()) { setAsking(true); return; }
    setConsented(true); setAsking(false); run('figure');
    requestAnimationFrame(() => panel.current?.scrollIntoView({ block: 'start', behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' }));
  };
  const allow = () => { if (host?.accept()) { setConsented(true); setAsking(false); run('figure'); } };
  // After the model is chosen: its kept walkthrough, else the consent or the request.
  useEffect(() => {
    if (!pending || !host) return;
    setPending(false);
    const saved = host.saved(manifest, figureID, 'figure', '', profile);
    if (saved) { setWalk(saved); return; }
    if (!consented && !host.consented()) { setAsking(true); return; }
    setConsented(true); setAsking(false); run('figure');
    requestAnimationFrame(() => panel.current?.scrollIntoView({ block: 'start', behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' }));
  }, [pending, JSON.stringify(profile)]); // eslint-disable-line react-hooks/exhaustive-deps
  const handled = useRef(0);
  useEffect(() => {
    if (!request || request.id !== figureID || request.n === handled.current) return;
    handled.current = request.n; explain();
  }); // eslint-disable-line react-hooks/exhaustive-deps

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
  const coverage = image ? cropCoverage(sections, image) : null;
  const background = useMemo(() => image ? `url("data:image/jpeg;base64,${image.data}")` : null, [image]);

  return <div className="figure-explain" ref={panel}>
    {!host ? null : asking && !consented ? <section className="equation-consent" data-testid="figure-consent">
      <p>Explaining the figure uses cloud AI: the figure’s image and the paper’s text go through OpenRouter to Google Vertex or DeepInfra according to your choice, as with chat. They may retain requests under their API terms. Answers use credits.</p>
      <div className="dialog-actions"><button className="secondary" onClick={() => setAsking(false)}>Not now</button><button className="primary" onClick={allow}>Allow and explain</button></div>
    </section> : !result ? null : <div className="figure-walkthrough" data-testid="figure-walkthrough" onClick={answerClick} onKeyDown={citeKey}>
      <section className="equation-section" aria-labelledby="figure-what">
        <h3 id="figure-what">What it shows</h3>
        {result.walkthrough?.summary ? <div data-testid="figure-summary"><Answer text={result.walkthrough.summary} /></div>
          : !result.walkthrough && result.text ? <div data-testid="figure-words"><Answer text={result.text} streaming={result.phase === 'loading'} /></div>
          : result.phase === 'loading' ? <p className="fine" role="status">Looking at the {label.startsWith('Table') ? 'table' : 'figure'}…</p> : null}
      </section>
      {coverage !== null && coverage < 1 && <p className="fine" data-testid="figure-coverage-fallback">The detail cards do not cover the entire image. The whole figure above keeps every panel, axis and legend available.</p>}
      {sections.length > 0 && <section className="equation-section" aria-labelledby="figure-parts">
        <h3 id="figure-parts">Part by part</h3>
        <ol className="figure-sections">{sections.map((s, i) => {
          const key = partKey(s, i), heading = sectionHeading(s), more = simpler.get(key), style = (!s.kind || s.kind === 'panel') && s.box && image ? cropStyle(displayBox(s.box), image) : null;
          const closer = details.get(key), closerImage = closer?.image ?? image, closerStyle = closer?.detail && closerImage ? cropStyle(displayBox(closer.detail.box), closerImage) : null;
          return <li key={key} className="figure-section" data-testid={`figure-section-${i}`}>
            <div className="figure-section-head">
              <h4><span className="figure-section-label">{[cardTypeLabel(s), s.label].filter(Boolean).join(' · ')}</span><span>{s.title}</span></h4>
              <MenuButton icon="more" label={`${heading}: options`} testID={`figure-section-menu-${i}`}>{close => <>
                <button type="button" role="menuitem" className="menu-item" data-testid="figure-simpler-item" disabled={!!more && more.phase !== 'failed'}
                  onClick={() => { close(false); run('figure_simpler', s, i); }}><Icon name="lightbulb" size={14} /> Explain more simply</button>
                {(!s.kind || s.kind === 'panel') && <button type="button" role="menuitem" className="menu-item" data-testid="figure-detail-item" disabled={!!closer && closer.phase !== 'failed'}
                  onClick={() => { close(false); run('figure_detail', s, i); }}><Icon name="search" size={14} /> Extract the subfigure and more context</button>}
                <button type="button" role="menuitem" className="menu-item" data-testid="figure-show-item"
                  onClick={() => { close(false); if (s.paragraphs[0]) onCite(s.paragraphs[0]); else onShowFigure(); }}><Icon name="book" size={14} /> Show in the paper</button>
                {onAsk && <button type="button" role="menuitem" className="menu-item" data-testid="figure-ask-item" disabled={busy}
                  onClick={() => { close(false); void onAsk(s.text); }}><Icon name="chat" size={14} /> Ask in chat about this</button>}
              </>}</MenuButton>
            </div>
            {style && background && <ZoomableCrop label={`${heading}, the part of the figure it describes`} testID="figure-crop" whole={image ?? undefined}
              style={{ aspectRatio: String(style.aspect), width: `min(100%, ${Math.round(Math.min(560, 320 * style.aspect))}px)`, backgroundImage: background,
                backgroundSize: style.size, backgroundPosition: style.position }} />}
            {s.kind === 'related_work' && <p className="fine">As described in this paper</p>}
            <Answer text={s.text} />
            {more && <div className="figure-simpler" data-testid="figure-simpler">
              <p className="figure-simpler-head">More simply</p>
              {more.phase === 'failed' && !more.text ? <div className="equation-issue" role="alert"><p>{issueText(more.issue ?? 'provider_unavailable')}</p>
                {more.issue !== 'invalid_request' && <button className="secondary small" onClick={() => run('figure_simpler', s, i)}>Try again</button>}</div>
                : more.text ? <Answer text={more.text} streaming={more.phase === 'loading'} /> : <p className="fine" role="status">Writing…</p>}
              {endedEarly(more) && <p className="fine">{endedEarly(more)}</p>}
            </div>}
            {closer && <div className="figure-simpler figure-detail" data-testid="figure-detail">
              <p className="figure-simpler-head">Up close</p>
              {closer.phase === 'failed' && !closer.text ? <div className="equation-issue" role="alert"><p>{issueText(closer.issue ?? 'provider_unavailable')}</p>
                {closer.issue !== 'invalid_request' && <button className="secondary small" onClick={() => run('figure_detail', s, i)}>Try again</button>}</div>
                : closer.phase === 'loading' ? <p className="fine" role="status">Extracting this part…</p> : <>
                  {closerStyle && closerImage && <ZoomableCrop label={`${heading}, up close`} testID="figure-detail-crop" whole={closerImage ?? undefined}
                    style={{ aspectRatio: String(closerStyle.aspect), width: `min(100%, ${Math.round(Math.min(560, 360 * closerStyle.aspect))}px)`,
                      backgroundImage: `url("data:image/jpeg;base64,${closerImage.data}")`, backgroundSize: closerStyle.size, backgroundPosition: closerStyle.position }} />}
                  <Answer text={closer.detail?.text ?? closer.text} />
                  {!closer.detail && <p className="fine" data-testid="figure-detail-no-crop">Couldn’t crop this part; here is the closer reading.</p>}
                </>}
              {endedEarly(closer) && <p className="fine">{endedEarly(closer)}</p>}
            </div>}
          </li>;
        })}</ol>
      </section>}
      {result.phase === 'failed' && <div className="equation-issue" role="alert" data-testid="figure-issue"><p>{issueText(result.issue ?? 'provider_unavailable')}</p>
        {result.issue !== 'invalid_request' && result.issue !== 'storage_retired' && <button className="secondary small" onClick={() => run('figure')} data-testid="figure-retry">Try again</button>}
        {result.issue !== 'storage_retired' && <button className="secondary small" onClick={() => setChoosing(true)} data-testid="explainer-change">Change AI</button>}</div>}
      {(result.model || profile) && <p className="fine answer-by" data-testid="explainer-model-name">{result.model ? modelName(result.model) : modelOption(table, profile!.model).label}</p>}
      {note && <p className="fine" data-testid="figure-note">{note}</p>}
    </div>}
    {link && <div className="equation-link" role="group" aria-label="Open source"><p className="source-address">{link}</p>
      <button className="secondary small" onClick={() => setLink(null)}>Cancel</button>
      <a className="primary small" href={link} target="_blank" rel="noopener noreferrer" onClick={() => setLink(null)}>Open link</a></div>}
    {host && <ExplainerModelDialog open={choosing} table={table} defaultChoice={shownProfile ?? STANDARD_PROFILE} onClose={() => setChoosing(false)}
      onRetry={() => host.context?.chat.reloadProfiles() ?? Promise.resolve()}
      onUse={choice => { setChoosing(false); setChosen({ ...choice }); setPending(true); }} />}
  </div>;
}

/** Zoom the extracted region, preserving its crop; no larger image or AI request is needed. */
function ZoomableCrop({ label, testID, style, whole, canExpand=true }: { label: string; testID: string; style: CSSProperties; whole?:{data:string;width:number;height:number}; canExpand?:boolean }) {
  const [expanded,setExpanded]=useState(false),[showWhole,setShowWhole]=useState(false);
  const [scale, setScale] = useState(1), [pan, setPan] = useState({x:0,y:0});
  const points = useRef(new Map<number,{x:number;y:number}>()), previous = useRef<{x:number;y:number;distance:number}|null>(null);
  const box = useRef<HTMLDivElement>(null), held = useRef({scale,pan}); held.current={scale,pan};
  const change = (zoom: number, x=held.current.pan.x, y=held.current.pan.y) => {
    const s=Math.min(8,Math.max(1,zoom)), r=box.current?.getBoundingClientRect();
    setScale(s); setPan({x:Math.min((r?.width??0)*(s-1)/2,Math.max(-(r?.width??0)*(s-1)/2,x)),y:Math.min((r?.height??0)*(s-1)/2,Math.max(-(r?.height??0)*(s-1)/2,y))});
  };
  const center = () => { const p=[...points.current.values()]; return p.length ? {x:p.reduce((s,p)=>s+p.x,0)/p.length,y:p.reduce((s,p)=>s+p.y,0)/p.length,distance:p.length===2?Math.hypot(p[0].x-p[1].x,p[0].y-p[1].y):0}:null; };
  return <><div className="zoom-crop" style={{width:style.width,maxWidth:'100%'}}>
    <div ref={box} role="img" aria-label={label} data-testid={testID} data-scale={scale} style={{aspectRatio:style.aspectRatio,overflow:'hidden',touchAction:'none',position:'relative'}}
      onDoubleClick={()=>change(scale>1?1:2,0,0)} onPointerDown={e=>{e.currentTarget.setPointerCapture(e.pointerId);points.current.set(e.pointerId,{x:e.clientX,y:e.clientY});previous.current=center();}}
      onPointerMove={e=>{if(!points.current.has(e.pointerId))return;points.current.set(e.pointerId,{x:e.clientX,y:e.clientY});const c=center(),p=previous.current;if(c&&p)change(c.distance&&p.distance?held.current.scale*c.distance/p.distance:held.current.scale,held.current.pan.x+c.x-p.x,held.current.pan.y+c.y-p.y);previous.current=c;}}
      onPointerUp={e=>{points.current.delete(e.pointerId);previous.current=center();}} onPointerCancel={e=>{points.current.delete(e.pointerId);previous.current=center();}}>
      <div className="figure-crop" style={{...style,width:'100%',height:'100%',transform:`translate(${pan.x}px,${pan.y}px) scale(${scale})`,transformOrigin:'center'}} />
    </div>
    <div className="crop-zoom-controls"><button type="button" className="icon-button" aria-label="Zoom out of crop" disabled={scale<=1} onClick={()=>change(scale-.5)}>−</button>
      <button type="button" className="icon-button" aria-label="Zoom into crop" disabled={scale>=8} onClick={()=>change(scale+.5)}>+</button>
      <output aria-live="polite">{Math.round(scale*100)}%</output>
      {canExpand && <button type="button" className="secondary small" onClick={()=>setExpanded(true)}>Open fullscreen</button>}</div>
  </div>{expanded && <Dialog open onClose={()=>setExpanded(false)} title={label} wide className="fullscreen-figure">
    <SheetTop onClose={()=>setExpanded(false)}><h2>{label}</h2>{whole && <button className="secondary small" onClick={()=>setShowWhole(v=>!v)}>{showWhole?'Show detail':'Whole figure'}</button>}</SheetTop>
    <ZoomableCrop label={label} testID="fullscreen-crop" canExpand={false} style={showWhole && whole ? {width:'100%',aspectRatio:String(whole.width/whole.height),backgroundImage:`url("data:image/jpeg;base64,${whole.data}")`,backgroundSize:'100% 100%',backgroundPosition:'center'} : {...style,width:'100%'}} />
  </Dialog>}</>;
}
