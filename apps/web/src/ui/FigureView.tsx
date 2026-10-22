// The figure view (docs/architecture/FIGURE_VIEW.md), on the figure page: the walkthrough AI Explainer asks for from the
// page's top row (owner, build 62), as the equation view. Nothing is asked of the AI unasked; it asks the chat's consent first. The
// walkthrough says what the figure shows, then goes part by part, with a crop at the top of a part only where the model
// drew a box (cut here from the image that was sent, so it costs nothing more). Each part's ⋯ offers Explain more
// simply (streamed under it: the one AI follow-up), Show in the paper, Save snippet and Ask in chat about this. To look
// closer, a part's card zooms and expands to the whole figure ("Extract the subfigure and more context" was removed on
// 2026-10-21: one AI result, the walkthrough). No credit counts (owner, build 59).
import { STANDARD_PROFILE, modelName, modelOption, type ProfileChoice } from '../lib/chat-profiles';
import { ExplainerModelDialog } from './ChatProfile';
import type { ContextualHost } from './ContextualChat';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { failureText, interruptionNote } from '../lib/chat';
import { cropCoverage, cardTypeLabel, sectionHeading, type FigureAction, type FigureResult, type FigureSection, type FigureStreamProgress } from '../lib/figure-view';
import { boxFractions } from '../lib/figure-crops';
import { matchSections } from '../lib/figure-structure';
import { captionLetters, type FramedPart } from '../lib/figure-framing';
import { expectedParts, figureProgress, type FigureProgressState } from '../lib/figure-progress';
import { framingShown, type ArxivFigure, type FramingSurface } from '../lib/figure-framing-record';
import { useFramedParts, useSentInk } from './useFigureCrops';
import { ViewportCard, type FigureSource } from './FigureViewport';
import { safeLink } from '../lib/markdown';
import Answer from './Answer';
import { sessionBalance, useFreeAIRefusal } from './free-ai';
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
const PREPARING: FigureStreamProgress = { stage: 'preparing', summary: false, parts: 0, characters: 0, charactersAtLast: 0, announced: null };
const reducedMotion = () => typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches;

/** The walkthrough's progress bar (owner, 2026-10-22: "it needs a progress bar"; figure-progress.ts): a thin bar, its
 * value when the number of parts is known, else indeterminate, with the stage under it. It sits where the walkthrough's
 * next words will appear; `fading` is its short exit once the walkthrough is done (hidden from assistive technology). */
function ProgressBar({ state, fading = false }: { state: FigureProgressState; fading?: boolean }) {
  const percent = state.value === null ? null : Math.round(state.value * 100);
  return <div className={`figure-progress${fading ? ' fading' : ''}`} data-testid="figure-progress" aria-hidden={fading || undefined}>
    <div className={`figure-progress-track${percent === null ? ' indeterminate' : ''}`} role="progressbar" aria-label={state.label} aria-valuetext={state.label}
      aria-valuemin={0} aria-valuemax={100} aria-valuenow={percent ?? undefined}>
      <div className="figure-progress-fill" style={percent === null ? undefined : { width: `${percent}%` }} />
    </div>
    <p className="figure-progress-label" aria-hidden="true">{state.label}</p>
  </div>;
}
/** What is on its way, until it arrives: the summary's lines and a part's card (static: the bar is the motion). */
const SummarySkeleton = () => <div className="figure-skeleton" aria-hidden="true" data-testid="figure-skeleton-summary"><span /><span /><span className="short" /></div>;
const PartSkeleton = () => <div className="figure-skeleton figure-skeleton-part" aria-hidden="true" data-testid="figure-skeleton-part">
  <span className="head" /><span className="frame" /><span /><span className="short" /></div>;

export function FigureExplain({ manifest, figureID, host, onActive, onCite, onShowFigure, onAsk, busy, request, profile: shownProfile, onExplanation, label = 'Figure', caption = '', arxiv = null, onSnippet }: Props) {
  // AI Explainer asks which model first (B7, AIChoiceView): Default or Choose model; that choice answers here.
  const [chosen, setChosen] = useState<ProfileChoice | null>(null), [choosing, setChoosing] = useState(false), [pending, setPending] = useState(false);
  const profile = chosen ?? shownProfile, table = host?.context?.chat.profileTable ?? null;
  const [consented, setConsented] = useState(() => !!host?.consented());
  const [asking, setAsking] = useState(false);
  const [walk, setWalk] = useState<FigureResult | null>(() => host?.saved(manifest, figureID, 'figure', '', profile) ?? null);
  const [simpler, setSimpler] = useState<Map<string, FigureResult>>(() => new Map());
  // Free AI (migration 0150): why free credits couldn't pay for the walkthrough or a part, from a fresh balance read.
  const freeBalance = useMemo(() => sessionBalance(host?.context?.chat), [host?.context?.chat]);
  const creditIssue = walk?.issue === 'insufficient_credits' || [...simpler.values()].some(m => m.issue === 'insufficient_credits') ? 'insufficient_credits' : null;
  const freeRefusal = useFreeAIRefusal(creditIssue, freeBalance, profile?.model);
  const refusalText = (code: string) => (code === 'insufficient_credits' && freeRefusal) || issueText(code);
  const requests = useRef(new Map<string, AbortController>());
  /** The progress bar's value last shown (it never goes back), for the walkthrough on its way. */
  const lastShown = useRef<number | null>(null);
  useEffect(() => () => { for (const c of requests.current.values()) c.abort(); }, []);
  useEffect(() => { onActive(asking || !!walk); }, [asking, walk, onActive]);

  useEffect(() => {
    for (const c of requests.current.values()) c.abort();
    setWalk(host?.saved(manifest, figureID, 'figure', '', profile) ?? null); setSimpler(new Map());
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
  }, [host, manifest, figureID, walk?.walkthrough]);

  const run = useCallback((action: FigureAction, part?: FigureSection, index = 0) => {
    if (!host) return;
    const key = part ? partKey(part, index) : '';
    requests.current.get(`${action}|${key}`)?.abort();
    const controller = new AbortController(); requests.current.set(`${action}|${key}`, controller);
    const set = (result: FigureResult) => {
      if (controller.signal.aborted) return;
      if (action === 'figure') setWalk(result);
      else setSimpler(m => new Map(m).set(key, result));
    };
    if (action === 'figure') lastShown.current = null;
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
  // The walkthrough streams (FIGURE_VIEW.md "Streamed walkthrough"): the summary and each part appear as they arrive,
  // each below the last, so nothing shown moves; the progress bar sits where the next words will appear, a skeleton of
  // them under it. The expected number of parts: as the model announced it, else the figure's own sub-figures, else the
  // panels its caption letters.
  const streaming = result?.phase === 'loading';
  const live = streaming ? result!.progress ?? PREPARING : null;
  const progress = live ? figureProgress({ ...live, previous: lastShown.current,
    expected: live.announced ?? expectedParts(image?.structure?.parts.length ?? null, captionLetters(caption).length) }) : null;
  if (progress?.value != null) lastShown.current = progress.value;
  const pendingAt = !streaming ? null : !result!.walkthrough && !result!.text ? 'start' : 'end';
  // Once done, the bar fades out where it was (at once with Reduce Motion), and "Done" is said to assistive technology.
  const [fading, setFading] = useState(false), streamed = useRef(false);
  useEffect(() => {
    if (streaming) { streamed.current = true; setFading(false); return; }
    if (!streamed.current || walk?.phase !== 'done' || reducedMotion()) return;
    setFading(true);
    const t = setTimeout(() => setFading(false), 300);
    return () => clearTimeout(t);
  }, [streaming, walk?.phase]);
  const announced = progress?.label ?? (streamed.current && walk?.phase === 'done' ? 'Done' : '');
  // Every part a viewport into the whole figure (FIGURE_VIEW.md "Parts as viewports"): completed on the image the request
  // carried, then framed by confidence (tight, loose and outlined, or the whole figure outlined); a caption naming its
  // panels caps the parts shown. The note below says when the parts leave some of the figure's ink out.
  // Structure first (FIGURE_VIEW.md "Structure first"): a figure of several images has exact parts, its own sub-figures;
  // a section that shows one (by letter, a box on its band, or in order) is shown as it, tight; the others as the AI boxed
  // them. When the parts number neither the caption's panels nor the sub-figures, the AI's own show the whole figure.
  const ink = useSentInk(image?.data);
  const structure = image?.structure ?? null;
  const matched = useMemo(() => matchSections(sections.map(s => ({ label: s.label, title: s.title, kind: s.kind, box: s.box ? boxFractions(s.box) : null })), structure),
    [sections, structure]);
  const boxed = sections.flatMap((s, i) => (!s.kind || s.kind === 'panel') && (s.box || matched[i] !== null) ? [i] : []);
  const exactOf = (i: number) => matched[i] !== null && structure ? structure.parts[matched[i]!].rect : null;
  // While parts stream, the count check (it needs the final number of parts) is off, and a card keeps the framing it was
  // first shown with, so a later part never resizes one above it. The final walkthrough is framed afresh, with the count
  // check (a card whose framing is unchanged stays as it is).
  const framed = useFramedParts(ink, image, { boxes: boxed.map(i => exactOf(i) ?? boxFractions(sections[i].box!)), exact: boxed.map(exactOf),
    structureParts: structure?.parts.length ?? 0, countCheck: !streaming, caption, labels: boxed.map(i => sections[i].label || sections[i].title) });
  const held = useRef(new Map<string, FramedPart>());
  if (!streaming) held.current.clear();
  const shownFor = new Map(boxed.map((i, k) => {
    const fresh = framed?.parts[k], key = partKey(sections[i], i);
    if (!streaming || !fresh) return [i, fresh] as const;
    if (!held.current.has(key)) held.current.set(key, fresh);
    return [i, held.current.get(key)] as const;
  }));
  const coverage = streaming || !framed || !image ? null : framed.coverage ?? (ink === null ? cropCoverage(sections, image) : null);
  const source = useMemo((): FigureSource | null => image ? { src: `data:image/jpeg;base64,${image.data}`, width: image.width, height: image.height } : null, [image]);
  // What each card shows, for Save snippet, by part and card.
  const captures = useRef(new Map<string, () => Promise<Blob | null>>());
  const registerCapture = (key: string) => (capture: (() => Promise<Blob | null>) | null) => { if (capture) captures.current.set(key, capture); else captures.current.delete(key); };
  const recordKey = (surface: FramingSurface, i: number) => `${manifest}|${figureID}|${surface}|${i}`;
  // The local framing record (figure-framing-record.ts): arXiv figures only, in memory, never sent.
  useEffect(() => {
    if (!arxiv || !image || streaming) return;
    const show = (surface: FramingSurface, i: number, part: FramedPart | undefined, box: { x: number; y: number; w: number; h: number } | undefined, parts: number, index: number) => {
      if (part && box) framingShown(recordKey(surface, i), { figure: { ...arxiv, figure: label }, surface, part: index, parts, level: part.level, box: boxFractions(box), region: part.region, frame: part.frame });
    };
    boxed.forEach((i, k) => { const e = exactOf(i); show('walkthrough', i, framed?.parts[k], sections[i].box ?? (e ? { x: e[0], y: e[1], w: e[2] - e[0], h: e[3] - e[1] } : undefined), boxed.length, k); });
  }); // eslint-disable-line react-hooks/exhaustive-deps
  const snippet = async (key: string, heading: string) => {
    const capture = captures.current.get(`card:${key}`);
    const blob = capture ? await capture() : null;
    if (blob && onSnippet) onSnippet(blob, `${label} · ${heading}`);
  };

  return <div className="figure-explain" ref={panel}>
    {host && <p className="visually-hidden" aria-live="polite" data-testid="figure-progress-status">{announced}</p>}
    {!host ? null : asking && !consented ? <section className="equation-consent" data-testid="figure-consent">
      <p>Explaining the figure uses cloud AI: the figure’s image and the paper’s text go through OpenRouter to Google Vertex or DeepInfra according to your choice, as with chat. They may retain requests under their API terms. Answers use credits.</p>
      <div className="dialog-actions"><button className="secondary" onClick={() => setAsking(false)}>Not now</button><button className="primary" onClick={allow}>Allow and explain</button></div>
    </section> : !result ? null : <div className="figure-walkthrough" data-testid="figure-walkthrough" onClick={answerClick} onKeyDown={citeKey}>
      <section className="equation-section" aria-labelledby="figure-what">
        <h3 id="figure-what">What it shows</h3>
        {result.walkthrough?.summary ? <div data-testid="figure-summary"><Answer text={result.walkthrough.summary} /></div>
          : !result.walkthrough && result.text ? <div data-testid="figure-words"><Answer text={result.text} streaming={result.phase === 'loading'} /></div>
          : pendingAt === 'start' && progress ? <div className="figure-pending"><ProgressBar state={progress} /><SummarySkeleton /></div> : null}
      </section>
      {pendingAt === 'start' && <PartSkeleton />}
      {sections.length > 0 && <section className="equation-section" aria-labelledby="figure-parts">
        <h3 id="figure-parts">Part by part</h3>
        <ol className="figure-sections">{sections.map((s, i) => {
          const key = partKey(s, i), heading = sectionHeading(s), more = simpler.get(key), shown = shownFor.get(i);
          const aspect = (p: FramedPart, im: { width: number; height: number }) => ((p.frame[2] - p.frame[0]) * im.width) / ((p.frame[3] - p.frame[1]) * im.height);
          return <li key={key} className="figure-section" data-testid={`figure-section-${i}`}>
            <div className="figure-section-head">
              <h4><span className="figure-section-label">{[cardTypeLabel(s), s.label].filter(Boolean).join(' · ')}</span><span>{s.title}</span></h4>
              {/* A part's actions once the walkthrough is in (a streamed part is final only then). */}
              <MenuButton icon="more" label={`${heading}: options`} testID={`figure-section-menu-${i}`} disabled={streaming}>{close => <>
                <button type="button" role="menuitem" className="menu-item" data-testid="figure-simpler-item" disabled={!!more && more.phase !== 'failed'}
                  onClick={() => { close(false); run('figure_simpler', s, i); }}><Icon name="lightbulb" size={14} /> Explain more simply</button>
                <button type="button" role="menuitem" className="menu-item" data-testid="figure-show-item"
                  onClick={() => { close(false); if (s.paragraphs[0]) onCite(s.paragraphs[0]); else onShowFigure(); }}><Icon name="book" size={14} /> Show in the paper</button>
                {onSnippet && shown && <button type="button" role="menuitem" className="menu-item" data-testid="figure-snippet-item"
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
              {more.phase === 'failed' && !more.text ? <div className="equation-issue" role="alert"><p>{refusalText(more.issue ?? 'provider_unavailable')}</p>
                {more.issue !== 'invalid_request' && <button className="secondary small" onClick={() => run('figure_simpler', s, i)}>Try again</button>}</div>
                : more.text ? <Answer text={more.text} streaming={more.phase === 'loading'} /> : <p className="fine" role="status">Writing…</p>}
              {endedEarly(more) && <p className="fine">{endedEarly(more)}</p>}
            </div>}
          </li>;
        })}</ol>
      </section>}
      {pendingAt === 'end' && progress && <div className="figure-pending"><ProgressBar state={progress} />{result.walkthrough && <PartSkeleton />}</div>}
      {fading && !streaming && <ProgressBar state={{ label: 'Done', value: 1 }} fading />}
      {/* Under the parts, once they are all in (it says what they leave out; above them it would move them). */}
      {coverage !== null && coverage < 1 && <p className="fine" data-testid="figure-coverage-fallback">The detail cards do not cover the entire image. The whole figure above keeps every panel, axis and legend available.</p>}
      {result.phase === 'failed' && <div className="equation-issue" role="alert" data-testid="figure-issue"><p>{refusalText(result.issue ?? 'provider_unavailable')}</p>
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
