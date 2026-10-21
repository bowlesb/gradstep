// The figure view (docs/architecture/FIGURE_VIEW.md), on the figure page: the walkthrough AI Explainer asks for from the
// page's top row (owner, build 62), as the equation view. Nothing is asked of the AI unasked; it asks the chat's consent first. The
// walkthrough says what the figure shows, then goes part by part, with a crop at the top of a part only where the model
// drew a box (cut here from the image that was sent, so it costs nothing more). Each part's ⋯ offers Explain more
// simply (streamed under it), Extract the subfigure and more context (owner, TestFlight 62: a loader under the part, then
// its crop and a closer reading), Show in the paper and Ask in chat about this. No credit counts (owner, build 59).
import { STANDARD_PROFILE, modelName, modelOption, type ProfileChoice } from '../lib/chat-profiles';
import { ExplainerModelDialog } from './ChatProfile';
import type { ContextualHost } from './ContextualChat';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { failureText, interruptionNote } from '../lib/chat';
import { cropCoverage, cardTypeLabel, sectionHeading, type FigureAction, type FigureResult, type FigureSection } from '../lib/figure-view';
import { boxFractions } from '../lib/figure-crops';
import { frameParts, type FramedPart } from '../lib/figure-framing';
import { framingShown, type ArxivFigure, type FramingSurface } from '../lib/figure-framing-record';
import { useFramedParts, useSentInk } from './useFigureCrops';
import { ViewportCard, type FigureSource } from './FigureViewport';
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
  /** A kept walkthrough's image, prepared again on this device (B4). */
  image?: (figureID: string) => Promise<FigureResult['image']>;
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
  request?: { id: string; n: number } | null;
  /** The figure's caption (its panel letters cap the parts shown: FIGURE_VIEW.md "Parts as viewports"). */
  caption?: string;
  /** The figure of an arXiv paper (its public identity), for the local framing record; null for anything else. */
  arxiv?: Omit<ArxivFigure, 'figure'> | null;
  /** Save snippet from a part: what its card shows, into the snippet composer. */
  onSnippet?: (image: Blob, label: string) => void };

const partKey = (s: FigureSection, i: number) => `${i}:${s.label}:${s.title}`;
const words = (r: FigureResult | null) => !!r && (!!r.walkthrough || !!r.text.trim());
/** Under words that ended early and that the server said cost nothing (a length limit): CHAT.md's wording. */
const endedEarly = (r: FigureResult | null | undefined) => r?.phase === 'done' && r.charged === false && words(r) ? interruptionNote(false, { charged: false }) : null;
const loading = (): FigureResult => ({ phase: 'loading', walkthrough: null, text: '', issue: null, image: null, credits: null });
const issueText = (code: string) => code === 'figure_unavailable' ? 'This figure’s image couldn’t be prepared in this browser.' : failureText(code);

export function FigureExplain({ manifest, figureID, host, onActive, onCite, onShowFigure, onAsk, busy, request, profile: shownProfile, onExplanation, label = 'Figure', caption = '', arxiv = null, onSnippet }: Props) {
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

  // A kept walkthrough (B4) comes back without its image: it is prepared again from the paper on this device.
  useEffect(() => {
    if (walk?.phase !== 'done' || walk.image || !host?.image) return;
    let live = true;
    void host.image(figureID).then(image => { if (live && image) setWalk(w => w && !w.image ? { ...w, image } : w); });
    return () => { live = false; };
  }, [walk, host, figureID]);
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
  // Every part a viewport into the whole figure (FIGURE_VIEW.md "Parts as viewports"): completed on the image the request
  // carried, then framed by confidence (tight, loose and outlined, or the whole figure outlined); a caption naming its
  // panels caps the parts shown. The note below says when the parts leave some of the figure's ink out.
  const ink = useSentInk(image?.data);
  const boxed = sections.flatMap((s, i) => (!s.kind || s.kind === 'panel') && s.box ? [i] : []);
  const framed = useFramedParts(ink, image, { boxes: boxed.map(i => boxFractions(sections[i].box!)), caption, labels: boxed.map(i => sections[i].label || sections[i].title) });
  const shownFor = new Map(boxed.map((i, k) => [i, framed?.parts[k]] as const));
  const coverage = !framed || !image ? null : framed.coverage ?? (ink === null ? cropCoverage(sections, image) : null);
  // An extracted part is framed alone, by the same rules (it is one of the walkthrough's parts, never a new one).
  const closerFor = useMemo(() => ink === undefined ? new Map<string, FramedPart>() : new Map([...details].flatMap(([k, r]) => {
    const sent = r.image ?? image;
    return r.detail && sent ? [[k, frameParts(ink, sent, { boxes: [boxFractions(r.detail.box)], labels: [r.detail.label || r.detail.title] }).parts[0]] as const] : [];
  })), [ink, details, image]);
  const source = useMemo((): FigureSource | null => image ? { src: `data:image/jpeg;base64,${image.data}`, width: image.width, height: image.height } : null, [image]);
  // What each card shows, for Save snippet, by part and card.
  const captures = useRef(new Map<string, () => Promise<Blob | null>>());
  const registerCapture = (key: string) => (capture: (() => Promise<Blob | null>) | null) => { if (capture) captures.current.set(key, capture); else captures.current.delete(key); };
  const recordKey = (surface: FramingSurface, i: number) => `${manifest}|${figureID}|${surface}|${i}`;
  // The local framing record (figure-framing-record.ts): arXiv figures only, in memory, never sent.
  useEffect(() => {
    if (!arxiv || !image) return;
    const show = (surface: FramingSurface, i: number, part: FramedPart | undefined, box: { x: number; y: number; w: number; h: number } | undefined, parts: number, index: number) => {
      if (part && box) framingShown(recordKey(surface, i), { figure: { ...arxiv, figure: label }, surface, part: index, parts, level: part.level, box: boxFractions(box), region: part.region, frame: part.frame });
    };
    boxed.forEach((i, k) => show('walkthrough', i, framed?.parts[k], sections[i].box, boxed.length, k));
    sections.forEach((s, i) => { const r = details.get(partKey(s, i)); show('detail', i, closerFor.get(partKey(s, i)), r?.detail?.box, 1, 0); });
  }); // eslint-disable-line react-hooks/exhaustive-deps
  const snippet = async (key: string, heading: string) => {
    const capture = captures.current.get(`card:${key}`) ?? captures.current.get(`detail:${key}`);
    const blob = capture ? await capture() : null;
    if (blob && onSnippet) onSnippet(blob, `${label} · ${heading}`);
  };

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
          const key = partKey(s, i), heading = sectionHeading(s), more = simpler.get(key), shown = shownFor.get(i);
          const closer = details.get(key), closerImage = closer?.image ?? image, closerShown = closer?.detail ? closerFor.get(key) : undefined;
          const closerSource = closerImage && closerImage !== image ? { src: `data:image/jpeg;base64,${closerImage.data}`, width: closerImage.width, height: closerImage.height } : source;
          const aspect = (p: FramedPart, im: { width: number; height: number }) => ((p.frame[2] - p.frame[0]) * im.width) / ((p.frame[3] - p.frame[1]) * im.height);
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
                {onSnippet && (shown || closerShown) && <button type="button" role="menuitem" className="menu-item" data-testid="figure-snippet-item"
                  onClick={() => { close(false); void snippet(key, heading); }}><Icon name="image" size={14} /> Save snippet</button>}
                {onAsk && <button type="button" role="menuitem" className="menu-item" data-testid="figure-ask-item" disabled={busy}
                  onClick={() => { close(false); void onAsk(s.text); }}><Icon name="chat" size={14} /> Ask in chat about this</button>}
              </>}</MenuButton>
            </div>
            {shown && source && <ViewportCard key={shown.frame.join()} image={source} part={shown} label={`${heading}, the part of the figure it describes`} testID="figure-crop"
              width={`min(100%, ${Math.round(Math.min(560, 320 * aspect(shown, source)))}px)`} recordKey={arxiv ? recordKey('walkthrough', i) : undefined} register={registerCapture(`card:${key}`)} />}
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
                  {closerShown && closerSource && <ViewportCard key={closerShown.frame.join()} image={closerSource} part={closerShown} label={`${heading}, up close`} testID="figure-detail-crop"
                    width={`min(100%, ${Math.round(Math.min(560, 360 * aspect(closerShown, closerSource)))}px)`} recordKey={arxiv ? recordKey('detail', i) : undefined} register={registerCapture(`detail:${key}`)} />}
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
