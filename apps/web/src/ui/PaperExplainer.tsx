// The paper's AI Explainer (2026-10-22; docs/proposals/LEARNING_GUIDE.md "Paper AI Explainer"), from the paper's ⋯: what
// the paper assumes and how its ideas fit together, in the figure explainer's look. Asked for only here (the model is
// chosen first, as the figure explainer; the chat's consent), streamed with the figure explainer's progress rules, kept
// in this browser per paper revision and model. The top row's Open in Chat continues this page's conversation in the
// paper's chat, as the figure explainer's does; its own conversation sits under it.
import { useEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react';
import { failureText, interruptionNote } from '../lib/chat';
import { STANDARD_PROFILE, modelName, modelOption, type ProfileChoice } from '../lib/chat-profiles';
import type { TextAnchor } from '../lib/events';
import { citedMarker } from '../lib/passage';
import { paperExplainerMermaid, paperExplainerProgress, paperExplainerText, type PaperExplainer, type PaperExplainerItem, type PaperExplainerResult,
  type PaperProgressState, type PaperStreamProgress } from '../lib/paper-explainer';
import Answer from './Answer';
import { ExplainerModelDialog } from './ChatProfile';
import { Dialog, SheetTop } from './common';
import { ContextualChat, promoteContextual, type ContextualHost } from './ContextualChat';
import { Diagram } from './Diagram';
import { sessionBalance, useFreeAIRefusal } from './free-ai';
import { Icon } from './icons';

/** What the reader's host offers the explainer: the chat's consent and its requests (ChatSession.paperExplainer). */
export interface PaperExplainerHost {
  context?: ContextualHost;
  consented: () => boolean; accept: () => boolean;
  saved: (manifest: string, choice?: ProfileChoice) => PaperExplainerResult | null;
  run: (update: (result: PaperExplainerResult) => void, signal: AbortSignal, choice?: ProfileChoice) => Promise<PaperExplainerResult>;
}

/** The explainer's own conversation: a contextual composer about the whole paper, following the paper chat's default. */
const LABEL = 'This paper', QUOTE = 'AI Explainer: the whole paper';
const subscribe = () => () => {}, version = () => 0;
function usePaperChat(host: ContextualHost | undefined, manifest: string) {
  useSyncExternalStore(host?.chat.subscribe ?? subscribe, host?.chat.getVersion ?? version);
  const anchor = useMemo<TextAnchor>(() => ({ manifestSHA256: manifest, elementID: 'paper-explainer', quote: QUOTE, prefix: '', suffix: '' }), [manifest]);
  const composer = useMemo(() => host ? host.chat.contextualComposer(host.documentID, anchor, 'paper') : null, [host?.chat, host?.documentID, anchor]);
  useEffect(() => {
    if (host && composer) host.chat.retainContextual(composer, 'paper');
    return () => { if (host && composer && !host.chat.promotedContexts.has(composer.id)) { host.chat.stop(composer); host.chat.releaseContextual(composer); } };
  }, [host?.chat, composer]); // eslint-disable-line react-hooks/exhaustive-deps
  return host && composer ? { host, composer, anchor, label: LABEL, quote: QUOTE, profile: host.chat.profileTable ? host.chat.profileFor(composer) : undefined } : null;
}

const PREPARING: PaperStreamProgress = { stage: 'preparing', summary: false, items: 0, ideas: 0, characters: 0, charactersAtLast: 0, announced: null };
const loading = (): PaperExplainerResult => ({ phase: 'loading', explainer: null, text: '', issue: null, credits: null, progress: PREPARING });
const reducedMotion = () => typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches;

/** The figure explainer's progress bar (same classes, same rules): its value when the count is known, else indeterminate. */
function ProgressBar({ state, fading = false }: { state: PaperProgressState; fading?: boolean }) {
  const percent = state.value === null ? null : Math.round(state.value * 100);
  return <div className={`figure-progress${fading ? ' fading' : ''}`} data-testid="paper-progress" aria-hidden={fading || undefined}>
    <div className={`figure-progress-track${percent === null ? ' indeterminate' : ''}`} role="progressbar" aria-label={state.label} aria-valuetext={state.label}
      aria-valuemin={0} aria-valuemax={100} aria-valuenow={percent ?? undefined}>
      <div className="figure-progress-fill" style={percent === null ? undefined : { width: `${percent}%` }} />
    </div>
    <p className="figure-progress-label" aria-hidden="true">{state.label}</p>
  </div>;
}
const SummarySkeleton = () => <div className="figure-skeleton" aria-hidden="true" data-testid="paper-skeleton-summary"><span /><span /><span className="short" /></div>;
const ItemSkeleton = () => <div className="figure-skeleton" aria-hidden="true" data-testid="paper-skeleton-item"><span className="short" /><span /></div>;

/** Key concepts (build 82: "Key ideas and concepts seems like two versions of the same thing"): one list, the background
 * first, each entry marked quietly with the diagram's colour for its kind. */
function ConceptList({ explainer, onCite }: { explainer: Pick<PaperExplainer, 'background' | 'ideas'>; onCite: (paragraph: number) => void }) {
  const row = (item: PaperExplainerItem, kind: 'background' | 'ideas') => <li key={item.id} data-testid={`paper-${kind}-item`} data-kind={kind}>
    <span className={`concept-kind ${kind}`}>{kind === 'background' ? 'Background' : 'This paper'}</span>
    <strong>{item.name}</strong>{item.line ? ` — ${item.line}` : ''}
    {item.paragraphs.map(n => <button key={n} type="button" className="cite" data-cite={n} onClick={() => onCite(n)} aria-label={`Go to paragraph ${n}`}>¶{n}</button>)}
  </li>;
  return <ul className="paper-background" data-testid="paper-concepts">
    {explainer.background.map(i => row(i, 'background'))}{explainer.ideas.map(i => row(i, 'ideas'))}
  </ul>;
}

/** The explainer's cards after "In short": Key concepts, then (once whole) How it fits together. Its own page and the chat
 * it is opened in show the same cards (build 82: "I expected all above content to follow me"). */
function ConceptCards({ explainer, streaming = false, onCite }: { explainer: PaperExplainer; streaming?: boolean; onCite: (paragraph: number) => void }) {
  const mermaid = useMemo(() => !streaming && explainer.links.length ? paperExplainerMermaid(explainer) : '', [explainer, streaming]);
  return <>
    {!!(explainer.background.length || explainer.ideas.length) && <section className="equation-section" aria-labelledby="paper-concepts">
      <h3 id="paper-concepts">Key concepts</h3>
      <ConceptList explainer={explainer} onCite={onCite} />
    </section>}
    {mermaid && <section className="equation-section paper-diagram" aria-labelledby="paper-diagram" data-testid="paper-diagram">
      <h3 id="paper-diagram">How it fits together</h3>
      <Diagram title="How it fits together" source={mermaid} />
    </section>}
  </>;
}

/** The paper's AI Explainer in its chat after Open in Chat: the same cards as its page, ¶ links going to the paper. */
export function PaperExplainerCards({ explainer, onCite }: { explainer: PaperExplainer; onCite: (paragraph: number) => void }) {
  return <div className="figure-walkthrough paper-explainer-cards" data-testid="promoted-paper-explainer">
    {explainer.summary && <section className="equation-section" aria-labelledby="promoted-paper-short">
      <h3 id="promoted-paper-short">In short</h3><div data-testid="paper-summary"><Answer text={explainer.summary} /></div>
    </section>}
    <ConceptCards explainer={explainer} onCite={onCite} />
  </div>;
}

export function PaperExplainerDialog({ manifest, title, host, onClose, onCite }: {
  manifest: string; title: string; host: PaperExplainerHost; onClose: () => void;
  /** A `¶N`: the page closes and the paper lands there with Back. */
  onCite: (paragraph: number) => void;
}) {
  const context = usePaperChat(host.context, manifest);
  const shownProfile = context?.profile;
  const table = host.context?.chat.profileTable ?? null;
  const [chosen, setChosen] = useState<ProfileChoice | null>(null), [choosing, setChoosing] = useState(false), [pending, setPending] = useState(false);
  const profile = chosen ?? shownProfile;
  const [consented, setConsented] = useState(() => host.consented());
  const [asking, setAsking] = useState(false);
  const [result, setResult] = useState<PaperExplainerResult | null>(() => host.saved(manifest, shownProfile));
  const controller = useRef<AbortController | null>(null);
  const lastShown = useRef<number | null>(null);
  useEffect(() => () => controller.current?.abort(), []);
  // Free AI (migration 0150): why free credits couldn't pay for the explainer, from a fresh balance read.
  const freeBalance = useMemo(() => sessionBalance(host.context?.chat), [host.context?.chat]);
  const freeRefusal = useFreeAIRefusal(result?.issue, freeBalance, profile?.model);

  const run = () => {
    controller.current?.abort();
    const c = new AbortController(); controller.current = c;
    lastShown.current = null;
    setResult(loading());
    void host.run(r => { if (!c.signal.aborted) setResult(r); }, c.signal, profile).catch(() => {});
  };
  // Opening the page: the kept explainer at once; otherwise which model first (as the figure explainer's AI Explainer).
  useEffect(() => { if (!result) setChoosing(true); }, []); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (!pending) return;
    setPending(false);
    const saved = host.saved(manifest, profile);
    if (saved) { setResult(saved); return; }
    if (!consented && !host.consented()) { setAsking(true); return; }
    setConsented(true); setAsking(false); run();
  }, [pending, JSON.stringify(profile)]); // eslint-disable-line react-hooks/exhaustive-deps
  const allow = () => { if (host.accept()) { setConsented(true); setAsking(false); run(); } };

  const explainer = result?.explainer ?? null;
  const streaming = result?.phase === 'loading';
  const live = streaming ? result!.progress ?? PREPARING : null;
  const progress = live ? paperExplainerProgress({ ...live, expected: live.announced, previous: lastShown.current }) : null;
  if (progress?.value != null) lastShown.current = progress.value;
  const nothingYet = streaming && !explainer?.summary && !explainer?.background.length && !explainer?.ideas.length && !result!.text;
  const explanation = explainer ? paperExplainerText(explainer) : result?.text ?? '';
  // Once done, the bar fades out where it was (at once with Reduce Motion), and "Done" is said to assistive technology.
  const [fading, setFading] = useState(false), streamed = useRef(false);
  useEffect(() => {
    if (streaming) { streamed.current = true; setFading(false); return; }
    if (!streamed.current || result?.phase !== 'done' || reducedMotion()) return;
    setFading(true);
    const t = setTimeout(() => setFading(false), 300);
    return () => clearTimeout(t);
  }, [streaming, result?.phase]);
  const announced = progress?.label ?? (streamed.current && result?.phase === 'done' ? 'Done' : '');
  const note = result?.phase === 'done' && result.charged === false && (explainer || result.text.trim()) ? interruptionNote(false, { charged: false }) : null;
  const cite = (n: number) => onCite(n);
  const answerClick = (e: React.MouseEvent) => {
    const control = (e.target as Element).closest('.cite[data-cite]'), marker = Number(control?.getAttribute('data-cite'));
    if (control && control.tagName !== 'BUTTON' && Number.isInteger(marker) && marker >= 1) { e.preventDefault(); cite(marker); }
  };

  return <Dialog open onClose={onClose} title="AI Explainer" wide className="figure-dialog paper-explainer-dialog">
    <SheetTop onClose={onClose} testID="paper-explainer-close" trailing={context && <button type="button" className="icon-button" aria-label="Open in Chat" data-testid="paper-explainer-open-chat"
      onClick={() => { promoteContextual(context, explanation, undefined, result?.phase === 'done' && explainer ? explainer : undefined); onClose(); }}><Icon name="chat" /></button>}>
      <h2 className="explainer-heading">AI Explainer</h2>
    </SheetTop>
    <div className="paper-explainer" data-testid="paper-explainer">
      <p className="paper-explainer-title" data-testid="paper-explainer-title">{title}</p>
      <p className="visually-hidden" aria-live="polite" data-testid="paper-progress-status">{announced}</p>
      {!result && !asking && !choosing && <div className="paper-explainer-intro">
        <p className="muted">The background this paper assumes, its key ideas and a diagram of how they fit together. Uses credits.</p>
        <button type="button" className="primary small" onClick={() => setChoosing(true)} data-testid="paper-explainer-start">Explain this paper</button>
      </div>}
      {asking && !consented ? <section className="equation-consent" data-testid="paper-explainer-consent">
        <p>Explaining the paper uses cloud AI: the paper’s text goes through OpenRouter to Google Vertex or DeepInfra according to your choice, as with chat. They may retain requests under their API terms. Answers use credits.</p>
        <div className="dialog-actions"><button className="secondary" onClick={() => setAsking(false)}>Not now</button><button className="primary" onClick={allow}>Allow and explain</button></div>
      </section> : result && <div className="figure-walkthrough" data-testid="paper-explainer-result" onClick={answerClick}>
        <section className="equation-section" aria-labelledby="paper-short">
          <h3 id="paper-short">In short</h3>
          {explainer?.summary ? <div data-testid="paper-summary"><Answer text={explainer.summary} /></div>
            : !explainer && result.text ? <div data-testid="paper-words"><Answer text={result.text} streaming={streaming} /></div>
            : nothingYet && progress ? <div className="figure-pending"><ProgressBar state={progress} /><SummarySkeleton /></div> : null}
        </section>
        {explainer && <ConceptCards explainer={explainer} streaming={streaming} onCite={cite} />}
        {streaming && !nothingYet && progress && <div className="figure-pending"><ProgressBar state={progress} /><ItemSkeleton /></div>}
        {fading && !streaming && <ProgressBar state={{ label: 'Done', value: 1 }} fading />}
        {result.phase === 'failed' && <div className="equation-issue" role="alert" data-testid="paper-explainer-issue"><p>{(result.issue === 'insufficient_credits' && freeRefusal) || failureText(result.issue ?? 'provider_unavailable')}</p>
          {result.issue !== 'invalid_request' && result.issue !== 'storage_retired' && <button className="secondary small" onClick={run} data-testid="paper-explainer-retry">Try again</button>}
          {result.issue !== 'storage_retired' && <button className="secondary small" onClick={() => setChoosing(true)} data-testid="paper-explainer-change">Change AI</button>}</div>}
        {(result.model || profile) && <p className="fine answer-by" data-testid="paper-explainer-model">{result.model ? modelName(result.model) : modelOption(table, profile!.model).label}</p>}
        {note && <p className="fine" data-testid="paper-explainer-note">{note}</p>}
      </div>}
      <ContextualChat context={context} explanation={explanation} onCite={anchor => { const n = citedMarker(anchor); if (n) cite(n); }} />
    </div>
    <ExplainerModelDialog open={choosing} table={table} defaultChoice={shownProfile ?? STANDARD_PROFILE} onClose={() => setChoosing(false)}
      onRetry={() => host.context?.chat.reloadProfiles() ?? Promise.resolve()}
      onUse={choice => { setChoosing(false); setChosen({ ...choice }); setPending(true); }} />
  </Dialog>;
}
