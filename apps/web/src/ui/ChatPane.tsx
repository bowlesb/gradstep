import {readVisualAnswers} from '../lib/chat-session';
import { decodeStoredFigureParts, hasPartMarkers, partSegments, storedPaths, stripPartMarkers } from '../lib/chat-figures';
import type { DiagramFormat } from '../lib/events';
// The existing right panel, backed by one account-owned controller (it survives pane/navigation unmounts).
import { type CSSProperties, lazy, memo, Suspense, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react';
import { TranscriptFollow } from '../lib/chat-follow';
import { answerActionPrompt, chatTitle, composerPlaceholder, conversationPreview, failureText, progressText } from '../lib/chat';
import { answeredBy, profileSummary, modelOption } from '../lib/chat-profiles';
import { AI_USE_CASE_TITLES, ChatSession, composerBusy, type Composer, type FigureFacts } from '../lib/chat-session';
import type { FigureStructure } from '../lib/figure-structure';
import { chooseStarters, type StarterPaper } from '../lib/chat-starters';
import { MAX_TITLE_CHARACTERS, type ConversationSummary, type TextAnchor } from '../lib/events';
import { citationAnchor } from '../lib/passage';
import { AnswerOptionsDialog, ExplainerModelDialog } from './ChatProfile';
import { safeLink } from '../lib/links';
import { Dialog, formatDate, MenuButton, SheetTop } from './common';
import { CopyButton } from './CopyButton';
import { Diagram, FigurePartInline, FigurePartsOverview, useFigureDataURL, usePartCrops } from './Diagram';
import { Icon, iconName } from './icons';
import { useMedia, useStored } from './prefs';
import { PaneHeader, useWorkspaceControls } from './Shell';
import { isVisualFollowUp, STUDY_ENTRY, STUDY_EXPLAIN, STUDY_HINT } from '../lib/study';
import { sessionBalance, useFreeAIRefusal } from './free-ai';
import { PaperExplainerCards } from './PaperExplainer';
import { PapersInAnswer, type AnswerPapers } from './AnswerPapers';
import { AnswerSelectionBar, formulaPick, useAnswerSelection } from './AnswerSelection';
import { persistenceState, subscribePersistence } from '../lib/persistence';
import { asOf } from '../lib/retry';

export function useChatUpdates(chat: ChatSession) {
  useSyncExternalStore(chat.subscribe, chat.getVersion);
  return useSyncExternalStore(chat.history.subscribe, chat.history.getVersion);
}
export interface PaperContext { documentID: string; title: string; available: boolean }
/** Chat text size (B8; RootView's chat … › Smaller text / Larger text): per browser, 13–26 px; none set follows the layout. */
const CHAT_TEXT_KEY = 'gradstep.chat.textSize', CHAT_TEXT_MIN = 13, CHAT_TEXT_MAX = 26;
const validChatText = (v: unknown) => v === null || (typeof v === 'number' && Number.isInteger(v) && v >= CHAT_TEXT_MIN && v <= CHAT_TEXT_MAX);

/** A conversation's title as shown: its topic title (generated or renamed) as is, else today's derived title. */
export function summaryTitle(summary: ConversationSummary): string {
  if (summary.titleSource !== undefined) return summary.title;
  const t = chatTitle(summary.title);
  return [t.label, t.text].filter(Boolean).join(' · ');
}

/** Inline rename: Enter or Save keeps it (≤ 80 characters), Escape or Cancel leaves the title unchanged. */
function RenameField({ initial, onSave, onCancel, label }: { initial: string; onSave: (title: string) => Promise<boolean>; onCancel: () => void; label: string }) {
  const [value, setValue] = useState(initial), [busy, setBusy] = useState(false), [failed, setFailed] = useState(false);
  const save = () => {
    if (!value.trim() || busy) return;
    setBusy(true); setFailed(false);
    onSave(value).then(ok => { if (!ok) setFailed(true); }, () => setFailed(true)).finally(() => setBusy(false));
  };
  return <form className="rename-field" onSubmit={e => { e.preventDefault(); save(); }}>
    <input aria-label={label} value={value} maxLength={MAX_TITLE_CHARACTERS} autoFocus disabled={busy} data-testid="rename-input"
      onChange={e => setValue(e.target.value)} onKeyDown={e => { if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); onCancel(); } }} />
    <button type="submit" className="primary small" disabled={busy || !value.trim()}>Save</button>
    <button type="button" className="secondary small" disabled={busy} onClick={onCancel}>Cancel</button>
    {failed && <p className="issue fine" role="alert">The new name couldn’t be saved. Keep it here and try again.</p>}
  </form>;
}

/** A fresh 32-bit seed for a new empty chat's starter questions. */
const starterSeed = () => crypto.getRandomValues(new Uint32Array(1))[0];

export function ChatPane({ chat, paper, mode, onMode, onAllChats, onPassage, onChatOptions, papers, onBackToNote }: {
  chat: ChatSession | null; paper: PaperContext | null; mode: 'paper' | 'general'; onMode: (mode: 'paper' | 'general') => void;
  onAllChats: () => void; onPassage: (documentID: string, anchor: TextAnchor) => void; onChatOptions: () => void;
  /** The library, for each answer's Papers in this answer (B2). */
  papers?: AnswerPapers;
  /** A note snippet's chat: Back to note (2026-10-21). */
  onBackToNote?: (noteID: string, entryID: string) => void;
}) {
  return chat ? <ConnectedChat chat={chat} paper={paper} mode={mode} onMode={onMode} onAllChats={onAllChats} onPassage={onPassage} onChatOptions={onChatOptions} papers={papers} onBackToNote={onBackToNote} />
    : <div className="empty" role="status">Opening chats…</div>;
}
export interface ContextualConversation { composer: Composer; quote: string; label: string; anchor: TextAnchor; explanation?: string; image?:string }
export function ConnectedChat({ chat, paper, mode, onMode, onAllChats, onPassage, onChatOptions, context: providedContext, papers, onBackToNote }: {
  context?: ContextualConversation; chat: ChatSession; paper: PaperContext | null; mode: 'paper' | 'general'; onMode: (mode: 'paper' | 'general') => void;
  onAllChats: () => void; onPassage: (documentID: string, anchor: TextAnchor) => void; onChatOptions: () => void; papers?: AnswerPapers;
  onBackToNote?: (noteID: string, entryID: string) => void;
}) {
  const historyVersion = useChatUpdates(chat);
  const workspace = useWorkspaceControls();
  const persistence = useSyncExternalStore(subscribePersistence, persistenceState, persistenceState);
  const documentID = mode === 'paper' ? paper?.documentID ?? null : null;
  const c = providedContext?.composer ?? chat.current(documentID);
  const promoted = chat.promotedContexts.get(c.id);
  const context = providedContext ?? (promoted ? {...promoted,composer:c} : undefined);
  const branch = useMemo(() => chat.branch(c), [chat, c, c.head, c.conversationID, c.phase, historyVersion]);
  const summaries = useMemo(() => chat.history.state.conversationSummaries(), [chat, historyVersion]);
  const summary = summaries.find(s => s.id === c.conversationID);
  const branches = useMemo(() => c.conversationID ? chat.history.state.conversationBranches(c.conversationID) : [], [chat, c.conversationID, historyVersion]);
  const [showFollowUps, setShowFollowUps] = useState(false);
  const diagrams = useMemo(() => chat.history.state.diagramsByMessage(), [chat, historyVersion]);
  // Free AI (migration 0150): why free credits couldn't pay for this answer, from a fresh balance read.
  const freeBalance = useMemo(() => sessionBalance(chat), [chat]);
  const freeRefusal = useFreeAIRefusal(c.issue, freeBalance, chat.retryProfile(c).model);
  // An answer with figure parts whose text marks where they go shows them inline (and the whole figure under it).
  const inlineParts = (entityID: string) => {
    const d = diagrams.get(entityID), text = messages.find(m => m.payload.entityID === entityID)?.payload.text ?? '';
    return d?.format === 'figure-parts-v1' && !!decodeStoredFigureParts(d.source) && hasPartMarkers(text);
  };
  const [link, setLink] = useState<string | null>(null), [inputIssue, setInputIssue] = useState(false);
  const [renaming, setRenaming] = useState(false);
  useEffect(() => setRenaming(false), [c.id, c.conversationID]);
  const table = chat.profileTable, choice = chat.profileFor(c);
  const viewport = useRef<HTMLDivElement>(null), bottom = useRef<HTMLDivElement>(null), follow = useRef(new TranscriptFollow());
  const [away, setAway] = useState(false);
  const showLatest = useCallback(() => {
    const el = viewport.current; if (!el) return;
    const top = el.scrollHeight - el.clientHeight;
    if (Math.abs(el.scrollTop - top) <= 1) return;
    follow.current.programmatic(top); el.scrollTop = top;
  }, []);
  const field = useRef<HTMLTextAreaElement>(null);
  const [displayText, setDisplayText] = useState(c.liveText);
  // Fixed cadence, not a debounce: continuously arriving tokens must remain visibly streaming. It reads the composer's
  // text itself, which the session updates in place; the session notifies less often than text arrives (C2).
  const live = useRef(c); live.current = c;
  useEffect(() => {
    setDisplayText(c.liveText);
    if (c.phase !== 'streaming') return;
    const t = setInterval(() => setDisplayText(live.current.liveText), 80);
    return () => clearInterval(t);
  }, [c.id, c.phase]);
  useLayoutEffect(() => { follow.current.reset(); setAway(false); }, [c.id]);
  // Seconds spent waiting for the first text: a long think shows its length instead of a frozen "Thinking…".
  const [waited, setWaited] = useState(0);
  useEffect(() => {
    if (c.phase !== 'streaming' || c.liveText) { setWaited(0); return; }
    const started = Date.now(), t = setInterval(() => setWaited(Math.floor((Date.now() - started) / 1000)), 1000);
    return () => clearInterval(t);
  }, [c.id, c.phase, !c.liveText]);
  // An answer's [¶N] citation: the paper opens (if needed) and lands on that block.
  const cite = (target: Element | null) => {
    const control = target?.closest('.cite'), marker = Number(control?.getAttribute('data-cite'));
    if (!control || !documentID || !Number.isInteger(marker) || marker < 1) return false;
    onPassage(documentID, citationAnchor(marker)); return true;
  };
  useLayoutEffect(() => { if (follow.current.mayFollow) showLatest(); }, [branch?.head, branch?.messages.length, displayText, c.phase, c.id, showLatest]);
  const endScrollInput = () => {
    const el = viewport.current; if (!el) return;
    setAway(!follow.current.endInput(el.scrollTop, el.scrollHeight - el.clientHeight));
  };
  useEffect(() => {
    const end = (event: PointerEvent) => {
      // Touch scrolling cancels its pointer when the browser takes over the pan, before the finger lifts.
      // The touchend/touchcancel path owns release for that gesture.
      if (event.pointerType === 'touch') return;
      const el = viewport.current;
      if (el && follow.current.isHolding) setAway(!follow.current.endInput(el.scrollTop, el.scrollHeight - el.clientHeight));
    };
    window.addEventListener('pointerup', end, { passive: true });
    window.addEventListener('pointercancel', end, { passive: true });
    return () => { window.removeEventListener('pointerup', end); window.removeEventListener('pointercancel', end); };
  }, []);
  const messages = branch?.messages ?? [];
  const savedLive = messages.some(m => m.payload.entityID === c.liveID);
  // A promoted explainer chat is named for its figure, table or equation until it has its own title (build 73, AHYZ:
  // it read "New chat" and looked like another conversation).
  const titleText = summary ? summaryTitle(summary) || 'Chat' : promoted && !providedContext ? promoted.label : mode === 'paper' ? 'Ask about this paper' : 'General chat';
  const deleted = !!c.conversationID && chat.history.state.isDeleted(c.conversationID);
  const last = messages.at(-1);
  const retired = chat.storageRetired; // another tab updated storage: nothing new is sent from this page
  const canAnswer = !retired && !chat.hasUnresolvedTurn(c) && !['refused', 'invalid_request'].includes(c.issue ?? '') && !c.answer && !composerBusy(c) && (c.question || last?.payload.role === 'user');
  const disabled = retired || chat.history.blocksSending || deleted || (mode === 'paper' && !paper?.available);
  const send = () => {
    if (disabled) return;
    if (context) {
      if (!c.draft.trim()) return;
      if (!c.draft.startsWith(`About ${context.label}:`)) chat.edit(c, `About ${context.label}: ${c.draft}`);
      const selection = [...(context.quote + (context.explanation ? '\nEarlier AI explanation (may contain errors):\n' + context.explanation : ''))].slice(0, 4000).join('');
      void chat.send(c, selection, null, context.anchor);
    } else void chat.send(c);
  };
  // Selected answer text or a formula (B1): Quote in Chat puts it in the draft; Explain and Define ask at once when the
  // box is empty, else join the draft without sending (ReaderModel's chat actions).
  const region = useCallback(() => viewport.current, []);
  const [pick, setPick] = useAnswerSelection(region, c.id);
  const focusEnd = () => requestAnimationFrame(() => { const f = field.current; if (f) { f.focus(); f.setSelectionRange(f.value.length, f.value.length); } });
  const quoteInChat = (quote: string) => { if (chat.edit(c, `About “${quote}”: ${c.draft}`)) focusEnd(); };
  const askAbout = (action: 'explain' | 'define', quote: string) => {
    const prompt = answerActionPrompt(action, quote);
    if (!c.draft.trim()) { if (chat.edit(c, prompt)) send(); }
    else if (chat.edit(c, `${prompt}\n\n${c.draft}`)) focusEnd();
  };
  // Study mode (LEARNING_GUIDE.md): the chat becomes a tutor; offered when the paper is numbered on this device. One tap
  // enters it and sends the opening turn; Hint and Explain instead send their turn; Stop leaves it and sends nothing.
  const studyOffered = !context && mode === 'paper' && !!paper?.available && chat.canStudy(documentID) && !c.study && !deleted && !retired;
  const startStudy = () => { if (!disabled) void chat.startStudy(c); };
  const studyBusy = disabled || composerBusy(c) || !!c.answer;
  const choiceBusy = retired || composerBusy(c) || !!c.answer;
  const [answerOptions, setAnswerOptions] = useState(false);
  // The model under the field asks Default or Choose model (B7, the apps' AISelectionButton); Length stays in ⋯ › Answer options.
  const [modelChoice, setModelChoice] = useState(false);
  useEffect(() => { setAnswerOptions(false); setModelChoice(false); }, [c.id]);
  // The main chat's text size; an equation or figure thread keeps the standard size, as on iPhone.
  const [textSize, setTextSize] = useStored<number | null>(CHAT_TEXT_KEY, null, validChatText);
  const layoutText = useMedia('(max-width: 600px)') ? 15 : 14, chatText = textSize ?? layoutText;

  // Starter questions (CHAT.md, 2026-10-16): a fresh seed whenever another empty chat is shown, kept while it stays on
  // screen; the paper's structure from its verified bundle on this device (none for a general chat).
  const empty = !messages.length && !composerBusy(c) && !c.liveID;
  const seed = useMemo(starterSeed, [c.id]);
  const structures = useRef(new Map<string, StarterPaper>());
  const [structure, setStructure] = useState<{ documentID: string; paper: StarterPaper } | null>(null);
  useEffect(() => {
    if (!empty || !documentID) return;
    const known = structures.current.get(documentID);
    if (known) { setStructure({ documentID, paper: known }); return; }
    let live = true;
    void chat.starterPaper(documentID).then(paper => { structures.current.set(documentID, paper); if (live) setStructure({ documentID, paper }); });
    return () => { live = false; };
  }, [chat, documentID, empty]);
  const starters = useMemo(() => !documentID ? chooseStarters(null, seed) : structure?.documentID === documentID ? chooseStarters(structure.paper, seed) : [],
    [documentID, structure, seed]);
  const showStarters = !context && empty && !deleted && !retired && !c.study && (!c.draft.trim() || starters.some(s => s.text === c.draft));
  const pickStarter = (text: string) => {
    if (!chat.edit(c, text)) return;
    requestAnimationFrame(() => { const f = field.current; if (f) { f.focus(); f.setSelectionRange(f.value.length, f.value.length); } });
  };
  // The pill grows with its text up to its maximum height, then scrolls.
  useLayoutEffect(() => {
    const f = field.current; if (!f) return;
    f.style.height = 'auto'; f.style.height = `${Math.min(f.scrollHeight + 2, 168)}px`;
  }, [c.draft, c.id]);

  return <div className={`chat-pane${empty ? ' chat-pane-empty' : ''}`} data-testid="chat-pane"
    style={!providedContext && textSize !== null ? { '--chat-text': `${textSize}px` } as CSSProperties : undefined}>
    {/* The main chat keeps its header and title for a promoted explainer chat too; an explainer's own embedded chat has none. */}
    {!providedContext && <PaneHeader title={<span className="segmented" role="group" aria-label="Chat mode">
      <button className={mode === 'paper' ? 'segment on' : 'segment'} aria-pressed={mode === 'paper'} disabled={!paper} onClick={() => onMode('paper')}>Paper</button>
      <button className={mode === 'general' ? 'segment on' : 'segment'} aria-pressed={mode === 'general'} onClick={() => onMode('general')}>General</button>
    </span>} onClose={() => workspace?.show('right', false)} closeLabel="Hide chat">
      <button className="icon-button" onClick={onAllChats} aria-label="All chats" title="All chats"><Icon name="chats" /></button>
      <button className="icon-button" onClick={() => { chat.newChat(documentID); field.current?.focus(); }} aria-label="New chat" title="New chat"><Icon name="plus" /></button>
      {/* The chat's ⋯ menu (owner, build 57: "put the chat settings in the top right drop down … Enter Study Mode"). */}
      <MenuButton icon="more" label="Chat menu" testID="chat-menu">{close => <>
        <button type="button" role="menuitem" className="menu-item menu-item-detail" data-testid="answer-options-item" disabled={choiceBusy}
          onClick={() => { close(); setAnswerOptions(true); }}>
          <Icon name="sliders" size={14} /><span><span className="menu-item-title">Answer options…</span><span className="fine" data-testid="answer-options-summary">{profileSummary(choice, table)}</span></span></button>
        {studyOffered && <button type="button" role="menuitem" className="menu-item" data-testid="study-start" disabled={disabled || composerBusy(c) || !!c.answer}
          onClick={() => { close(); startStudy(); }}><Icon name="book" size={14} /> Study mode</button>}
        {c.study && <button type="button" role="menuitem" className="menu-item" data-testid="study-end-menu" disabled={composerBusy(c) || !!c.answer}
          onClick={() => { close(); chat.endStudy(c); }}><Icon name="book" size={14} /> End study mode</button>}
        {summary?.anchor && summary.documentID && !deleted && <button type="button" role="menuitem" className="menu-item" data-testid="chat-menu-passage"
          onClick={() => { close(); onPassage(summary.documentID!, summary.anchor!); }}><Icon name="list" size={14} /> Go to passage</button>}
        <div className="menu-row chat-text-size" role="group" aria-label="Chat text size">
          <button type="button" role="menuitem" className="seg" disabled={chatText <= CHAT_TEXT_MIN} onClick={() => setTextSize(Math.max(CHAT_TEXT_MIN, chatText - 1))}
            data-testid="chat-text-smaller"><span className="a-small" aria-hidden="true">A</span> Smaller text</button>
          <button type="button" role="menuitem" className="seg" disabled={chatText >= CHAT_TEXT_MAX} onClick={() => setTextSize(Math.min(CHAT_TEXT_MAX, chatText + 1))}
            data-testid="chat-text-larger"><span className="a-large" aria-hidden="true">A</span> Larger text</button>
        </div>
      </>}</MenuButton>
    </PaneHeader>}
    {!providedContext && <div className="chat-heading">
      {renaming && summary ? <RenameField initial={titleText} label="Chat name" onCancel={() => setRenaming(false)}
        onSave={async name => { const ok = await chat.rename(summary.id, name); if (ok) setRenaming(false); return ok; }} />
        : <div className="chat-title-row"><strong title={titleText} data-testid="chat-title">{titleText}</strong>
          {summary && !deleted && <button className="link small rename-link" disabled={retired} onClick={() => setRenaming(true)} aria-label={`Rename “${titleText}”`}>Rename</button>}</div>}
      {mode === 'paper' && <span className="fine chat-paper" title={paper?.title}>{paper?.title ?? 'Paper chat'}</span>}
      {summary?.anchor && summary.documentID && <button className="link small" onClick={() => onPassage(summary.documentID!, summary.anchor!)}>Go to passage</button>}
      {branches.length > 1 && <label className="branch-picker">Branch <select aria-label="Conversation branch" value={c.head ?? ''} disabled={composerBusy(c) || !!c.answer} onChange={e => chat.chooseBranch(c, e.target.value)}>
        <option value="" disabled>Choose a branch</option>{branches.map((b, i) => <option key={b.head} value={b.head}>Branch {i + 1} · {b.messages.length} messages</option>)}
      </select></label>}
    </div>
    }
    {(chat.history.status !== 'ready' || chat.history.issue || chat.history.unsaved > 0) && <div className="chat-sync fine" role="status">
      {chat.history.issue ?? (chat.history.status === 'loading' ? 'Loading encrypted history…' : chat.durable ? 'Saved on this device. Syncing encrypted history…'
        : chat.journalState === 'unsupported' ? 'This browser can’t keep chats between visits: they stay for this session and sync while this tab is open.' : 'Saving encrypted history… Keep this tab open.')}
      {chat.history.issue && <button className="link" onClick={() => void chat.history.sync().catch(() => {})}>Retry sync</button>}
    </div>}
    <div ref={viewport} className="chat-transcript" role="region" aria-label="Conversation" tabIndex={0}
    onWheelCapture={e => {
      const el = viewport.current!;
      if (e.deltaY !== 0 && (e.deltaY < 0 || el.scrollHeight - el.scrollTop - el.clientHeight > 2)) follow.current.input();
    }}
    onPointerDownCapture={() => follow.current.input(true)}
    onPointerUpCapture={e => { if (e.pointerType !== 'touch') endScrollInput(); }}
    onPointerCancelCapture={e => { if (e.pointerType !== 'touch') endScrollInput(); }}
    onTouchStartCapture={() => follow.current.input(true)}
    onTouchEndCapture={e => { if (!e.touches.length) endScrollInput(); }}
    onTouchCancelCapture={e => { if (!e.touches.length) endScrollInput(); }}
    onKeyDownCapture={e => { if (['ArrowUp', 'ArrowDown', 'PageUp', 'PageDown', 'Home', 'End', ' '].includes(e.key)) follow.current.input(); }}
    onKeyUpCapture={() => {
      const el = viewport.current!;
      setAway(!follow.current.scrolled(el.scrollTop, el.scrollHeight - el.clientHeight));
    }}
    onScroll={() => {
      const el = viewport.current!;
      setAway(!follow.current.scrolled(el.scrollTop, el.scrollHeight - el.clientHeight));
    }} onClick={e => {
      if (cite(e.target as Element)) { e.preventDefault(); return; }
      // A click on a formula in a saved answer offers its actions; elsewhere it puts them away (not on the bar itself).
      if ((e.target as Element).closest?.('.chat-selection-bar')) return;
      const formula = (e.target as Element).closest?.('[data-answer] .answer-math[data-latex]');
      if (formula && document.getSelection()?.isCollapsed !== false) { const picked = formulaPick(formula); if (picked) setPick({ ...picked, clicked: true }); return; }
      if (pick?.clicked) setPick(null);
      const a = (e.target as Element).closest('a[href]'); if (!a) return;
      e.preventDefault(); const href = safeLink(a.getAttribute('href') ?? ''); if (href) setLink(href);
    }} onKeyDown={e => { if ((e.key === 'Enter' || e.key === ' ') && (e.target as Element).classList?.contains('cite') && cite(e.target as Element)) e.preventDefault(); }}>
      {empty && !context && <div className="chat-empty" data-testid="chat-empty">
        {/* With starters there is no heading, as on iPhone, iPad and Mac (owner, build 57: Gemini's empty chat). */}
        {!(showStarters && starters.length > 0) && <>
          <p className="chat-empty-title">{mode === 'paper' ? 'A closer look at the paper' : 'What are you working on?'}</p>
          <p className="fine">{mode === 'paper' ? 'Ask a question, or select a passage to explore it.' : 'Discuss an idea, work through an equation, or ask for a diagram.'}</p>
        </>}
        {/* Gemini's layout (owner, build 57): three rows, a small icon and one line each, no heading; a click fills the box. */}
        {showStarters && starters.length > 0 && <div className="chat-starters" role="group" aria-label="Starter questions" data-testid="chat-starters">
          {starters.map(s => { const icon = iconName(s.icon);
            return <button key={`${s.category}:${s.text}`} type="button" className="chat-starter" data-testid="chat-starter" data-category={s.category} title={s.text} disabled={disabled}
              onClick={() => pickStarter(s.text)}>{icon ? <Icon name={icon} size={16} /> : <span className="chat-starter-dot" aria-hidden="true" />}<span>{s.text}</span></button>; })}
          {studyOffered && <button type="button" className="chat-starter chat-starter-study" data-testid="study-entry" title={STUDY_ENTRY} disabled={studyBusy}
            onClick={startStudy}><Icon name="cap" size={16} /><span>{STUDY_ENTRY}</span></button>}
        </div>}
      </div>}
      {!providedContext && promoted && <section className="promoted-explanation" data-testid="promoted-context">
        {/* A note snippet's chat: the way back to its entry, like the explainers' Back (2026-10-21). */}
        {promoted.noteReturn && onBackToNote && <button type="button" className="secondary small back-to-note" onClick={() => onBackToNote(promoted.noteReturn!.noteID, promoted.noteReturn!.entryID)}
          data-testid="back-to-note"><Icon name="chevronLeft" size={14} /> Back to snippets</button>}
        <h3>{promoted.label}</h3>{promoted.image && <img src={promoted.image} alt={promoted.label} style={{maxWidth:'100%'}} data-testid="promoted-image"/>}
        {promoted.noteReturn && promoted.image ? <p className="fine" data-testid="promoted-image-note">{promoted.imageSent ? 'This picture goes with your questions in this chat.'
          : 'This paper isn’t on this device, so the picture stays here; the chat knows where it came from.'}</p>
          : promoted.paperExplainer ? <PaperExplainerCards explainer={promoted.paperExplainer} onCite={() => { /* the pane's own [¶N] handling (.cite[data-cite]) takes these */ }} />
          : <Answer text={promoted.explanation ?? promoted.quote} />}</section>}
      {messages.map(m => <div key={m.payload.entityID} className={`chat-message ${m.payload.role}`} data-testid={`chat-${m.payload.role}`} data-answer={m.payload.role === 'assistant' ? m.payload.entityID : undefined}>
        {m.payload.role === 'user' ? <><div className="message-label">You</div><div className="question-text">{m.payload.text}</div></> : <><div className="message-label-row"><div className="message-label">Gradstep</div><CopyButton text={stripPartMarkers(m.payload.text ?? '')} label="Copy answer" /></div>
          {inlineParts(m.payload.entityID) ? <FigurePartsAnswer text={m.payload.text ?? ''} diagram={diagrams.get(m.payload.entityID)!} image={(manifest, paths) => chat.figureImage(c.documentID, manifest, paths)} caption={(manifest, blockID, paths) => chat.figureFacts(c.documentID, manifest, blockID, paths)} />
            : <Answer text={stripPartMarkers(m.payload.text ?? '')} />}
          {/* A finished answer's papers (B2): never while it streams or when it was cut short. */}
          {papers && m.payload.status === 'complete' && <PapersInAnswer text={stripPartMarkers(m.payload.text ?? '')} papers={papers} />}</>}
        {/* What an early end cost, while this session lasts (2026-10-16); earlier answers keep "Answer interrupted". */}
        {m.payload.status === 'interrupted' && <span className="fine interrupted" data-testid="chat-interrupted">{chat.interruptionNote(m.payload.entityID) ?? 'Answer interrupted'}</span>}
        {m.payload.role === 'assistant' && answeredBy(m.payload.model, m.payload.profile, table) && <p className="fine answer-by" data-testid="answer-by">{answeredBy(m.payload.model, m.payload.profile, table)}</p>}
        {diagrams.has(m.payload.entityID) && !inlineParts(m.payload.entityID) && <AnswerDiagram diagram={diagrams.get(m.payload.entityID)!} image={(manifest, paths) => chat.figureImage(c.documentID, manifest, paths)} caption={(manifest, blockID, paths) => chat.figureFacts(c.documentID, manifest, blockID, paths)} />}
      </div>)}
      {c.liveID && !savedLive && <div key={c.liveID} className="chat-message assistant" data-testid="chat-streaming"><div className="message-label">Gradstep</div>
        <Answer text={stripPartMarkers(displayText, true)} streaming />{!c.liveText && <p className="fine" role="status">{c.progress ? progressText(c.progress) : waited >= 5 ? `Thinking… ${waited} s` : 'Thinking…'}</p>}</div>}
      {(c.followUps || studyOffered) && !c.study && !composerBusy(c) && !c.answer && !c.issue && last?.payload.role === 'assistant' && (() => {
        // The model's own picture question (2026-10-22: "Create a diagram explaining the background of X") replaces the
        // generic Draw a diagram / Create a visual explanation rows; Enter Study Mode is always the last (paper chats).
        const questions = c.followUps ?? [], generic = questions.length > 0 && !questions.some(isVisualFollowUp);
        const count = questions.length + (generic ? (readVisualAnswers() ? 2 : 1) : 0) + (studyOffered ? 1 : 0);
        return <div className="follow-ups" role="group" aria-label="Suggested questions">
          {/* On request (owner, build 46: "they need to be upon request… take up too much space"). */}
          <button type="button" className="link small follow-ups-toggle" aria-expanded={showFollowUps} data-testid="follow-ups-toggle"
            onClick={() => setShowFollowUps(v => !v)}>{showFollowUps ? 'Hide suggested questions' : `Suggested questions (${count})`}</button>
          {showFollowUps && generic && <><button type="button" className="follow-up" data-testid="follow-up-diagram" onClick={()=>{chat.edit(c,'Draw a Mermaid diagram explaining the answer above.');field.current?.focus();}}>Draw a diagram</button>
            {readVisualAnswers() && <button type="button" className="follow-up" data-testid="follow-up-visual" onClick={()=>{chat.edit(c,'Create an interactive HTML visual explanation of the answer above.');field.current?.focus();}}>Create a visual explanation</button>}</>}
          {showFollowUps && questions.map(question => <button key={question} type="button" className="follow-up" data-testid="follow-up" disabled={disabled}
            onClick={() => { if (chat.edit(c, question)) field.current?.focus(); }}>{question}</button>)}
          {showFollowUps && studyOffered && <button type="button" className="follow-up follow-up-study" data-testid="study-entry" disabled={studyBusy}
            onClick={startStudy}><Icon name="cap" size={13} /> {STUDY_ENTRY}</button>}
        </div>; })()}
      {c.progress && c.liveText && <p className="fine chat-progress" role="status">{progressText(c.progress)}</p>}
      {c.issue && <div className="chat-issue" role="alert"><p>{freeRefusal ?? failureText(c.issue)}</p>
        {c.issue === 'local_save' && !retired && <button className="secondary small" onClick={() => void chat.retryDeviceSave(c)}>Retry device save</button>}
        {canAnswer && <button className="secondary small" disabled={deleted || (mode === 'paper' && !paper?.available)} onClick={() => void chat.retry(c)}>Get answer</button>}
        {c.answer && !retired && <button className="secondary small" onClick={() => void chat.retry(c)}>Retry saving</button>}
      </div>}
      {!c.issue && canAnswer && !composerBusy(c) && last?.payload.role === 'user' && <button className="secondary small" disabled={deleted || (mode === 'paper' && !paper?.available)} onClick={() => void chat.retry(c)}>Get answer</button>}
      {canAnswer && (c.issue || last?.payload.role === 'user') && <p className="fine" data-testid="retry-profile">This question: {profileSummary(chat.retryProfile(c), table)}</p>}
      {c.credits !== null && <p className="fine answer-cost">{c.credits === 0 && c.issue ? 'No credits used' : `${c.credits} ${c.credits === 1 ? 'credit' : 'credits'} used`}</p>}
      {deleted && <p className="issue">This conversation was deleted. Your draft is still here to copy.</p>}
      {pick && <AnswerSelectionBar pick={pick} canQuote={!retired} canAsk={!disabled && !composerBusy(c) && !c.answer}
        onQuote={quoteInChat} onExplain={quote => askAbout('explain', quote)} onDefine={quote => askAbout('define', quote)}
        onDone={() => { document.getSelection()?.removeAllRanges(); setPick(null); }} />}
      {away && <button className="jump-latest secondary small" onClick={() => { follow.current.reset(); setAway(false); showLatest(); }}>Latest message <Icon name="chevronDown" size={12} /></button>}
      <div ref={bottom} />
    </div>
    {/* Study mode's one slim row (replacing the knowledge map): Hint and Explain instead send at once; Stop sends nothing. */}
    {c.study && <div className="study-bar" role="group" aria-label="Study mode" data-testid="study-bar">
      <span className="study-label"><Icon name="cap" size={14} /> Study mode</span>
      <button type="button" className="study-action" disabled={studyBusy} onClick={() => void chat.studyReply(c, STUDY_HINT)} data-testid="study-hint"
        title="Ask the tutor for a hint (sends at once)">Hint</button>
      <button type="button" className="study-action" disabled={studyBusy} onClick={() => void chat.studyReply(c, STUDY_EXPLAIN)} data-testid="study-explain"
        title="Ask the tutor to explain instead (sends at once)">Explain instead</button>
      <button type="button" className="study-action study-stop" disabled={composerBusy(c) || !!c.answer} onClick={() => chat.endStudy(c)} data-testid="study-stop"
        title="Leave Study mode; the conversation stays">Stop</button>
    </div>}
    {/* One full-width pill: the field, then Send (Stop while answering) inside it on the right; nothing beside it
        (owner, build 57: "We can't have the typing window awkwardly to the right side"). */}
    <form className="chat-composer" onSubmit={e => { e.preventDefault(); send(); }}>
      <div className="composer-pill">
        <textarea ref={field} data-composer-id={c.id} aria-label="Message" placeholder={context ? `Ask about ${context.label.toLowerCase()}…` : composerPlaceholder(mode, !!c.study)} value={c.draft} rows={1} maxLength={200_000} readOnly={retired}
          title="Enter sends; Shift+Enter starts a new line"
          onChange={e => setInputIssue(!chat.edit(c, e.target.value))}
          onKeyDown={e => { if (e.key === 'Enter' && !e.shiftKey && !e.nativeEvent.isComposing) { e.preventDefault(); if (!composerBusy(c)) send(); } }} />
        <button type="button" className="link composer-model" disabled={choiceBusy} onClick={() => setModelChoice(true)} aria-label={`Model: ${modelOption(table, choice.model).label}`} data-testid="composer-model">{modelOption(table, choice.model).label} <Icon name="sliders" size={14} /></button>
        {c.phase === 'streaming' ? <button type="button" className="composer-send stop" aria-label="Stop" title="Stop" onClick={() => chat.stop(c)}><Icon name="stop" size={16} /></button>
          : <button type="submit" className="composer-send" aria-label={c.phase === 'saving' || c.phase === 'finishing' ? 'Saving…' : 'Send'} title="Send (Enter)"
            disabled={disabled || composerBusy(c) || !!c.answer || !c.draft.trim()}><Icon name="arrowUp" size={17} /></button>}
      </div>
      {inputIssue && <p className="issue fine">This draft is too long. Shorten it to continue.</p>}
      {(() => {
        // Only what the reader should act on: a stopped tab, a failed device save, or a draft that is not kept after a reload.
        const hint = retired ? 'This tab has stopped sending. Select your text to copy it.'
          : chat.durable ? (c.issue === 'local_save' ? 'Couldn’t save this edit on this device. Keep this tab open and copy your text.'
            : c.draft && c.revision > c.savedRevision ? 'Saving draft on this device…' : '')
          : 'Unsent drafts stay in this tab only and aren’t kept after a reload.';
        const balance = chat.balance ? `${chat.balance.unlimited_testing ? 'Unlimited testing' : `${chat.balance.available} credits`}${chat.balance.reserved ? ` · ${chat.balance.reserved} held` : ''}${chat.balanceStale && chat.balanceAt ? ` · as of ${asOf(chat.balanceAt)}` : ''}` : null;
        return <div className="composer-status">
          {hint && <p className="fine draft-hint" data-testid="draft-status">{hint}</p>}
          {balance && <p className="fine draft-hint composer-balance" title="Add credits in Gradstep on iPhone, iPad or Mac">{balance}</p>}
        </div>;
      })()}
    </form>
    <AnswerOptionsDialog open={answerOptions} onClose={() => setAnswerOptions(false)} table={table} choice={choice} defaultChoice={chat.defaultFor(c)} reason={chat.profileReason(c)}
      activity={AI_USE_CASE_TITLES[chat.activityFor(c)].toLowerCase()}
      onChange={next => chat.setProfile(c, next)} onMakeDefault={next => chat.setDefaultFor(c,next)} onRetry={() => chat.reloadProfiles()}
      onAbout={() => { setAnswerOptions(false); onChatOptions(); }} />
    <ExplainerModelDialog open={modelChoice} table={table} defaultChoice={chat.defaultFor(c)} onClose={() => setModelChoice(false)}
      onRetry={() => chat.reloadProfiles()} onUse={next => { setModelChoice(false); chat.setProfile(c, next); }} />
    <Dialog open={c.phase === 'consent'} onClose={() => void chat.consent(c, false)} title="Cloud AI answers">
      {/* Consent cloud-ai-v5 (CHAT.md, 2026-10-16), worded as on iPhone, iPad and Mac. */}
      <h2>Cloud AI answers</h2><p>All cloud answers use OpenRouter. Gemini Flash and Claude run on Google Vertex; DeepSeek runs on DeepInfra. To answer, Gradstep sends:</p>
      <ul className="consent-list" data-testid="consent-list">
        <li>Your question and any passage you selected</li>
        <li>Earlier messages in this conversation</li>
        <li>For paper chats, the paper’s full text</li>
        <li>When you ask about a figure or table, its image from the paper</li>
        <li>When a question needs it, web searches the model writes go to Tavily, a search service</li>
        <li>All model requests pass through OpenRouter. Titles and suggested questions use Claude on Google Vertex. A random account ID accompanies requests for cost accounting</li>
      </ul>
      <p className="muted">OpenRouter and the selected processor handle this under their API terms. Gradstep requests routes with no data collection and zero data retention; search services see only the searches and may keep them under their own terms. Gradstep’s servers pass it through without saving it; your saved conversation stays encrypted with your device keys.</p>
      <p className="fine">Each answer uses credits from your balance.</p>
      <p className="fine">This question: {profileSummary(chat.retryProfile(c), table)}</p>
      <div className="dialog-actions"><button className="secondary" onClick={() => void chat.consent(c, false)}>Not now</button><button className="primary" onClick={() => void chat.consent(c, true)}>Allow and get answer</button></div>
    </Dialog>
    <Dialog open={!!link} onClose={() => setLink(null)} title="Open source">
      <h2>Open source?</h2><p className="source-address">{link}</p><p className="fine">This link was included in an AI answer. Check the destination before opening.</p>
      <div className="dialog-actions"><button className="secondary" onClick={() => setLink(null)}>Cancel</button><a className="primary" href={link ?? undefined} target="_blank" rel="noopener noreferrer" onClick={() => setLink(null)}>Open link</a></div>
    </Dialog>
  </div>;
}
const RichAnswer = lazy(() => import('./Answer'));
const Answer = memo(function Answer({ text, streaming = false }: { text: string; streaming?: boolean }) {
  return <Suspense fallback={<div className="question-text">{text}</div>}><RichAnswer text={text} streaming={streaming} /></Suspense>;
});

export function ChatHistory({ chat, open, onClose, papers, currentDocument, onOpen, topics }: {
  chat: ChatSession | null; open: boolean; onClose: () => void; papers: Map<string, string>; currentDocument: string | null;
  onOpen: (documentID: string | null, anchor?: TextAnchor) => void;
  /** Each paper's library tags (All chats' Topics). */ topics?: Map<string, string[]>;
}) {
  return <Dialog open={open} onClose={onClose} title="All chats" wide className="history-dialog">{chat ? <HistoryList chat={chat} papers={papers} currentDocument={currentDocument} onClose={onClose} onOpen={onOpen} topics={topics} /> : <p>Loading chats…</p>}</Dialog>;
}
// The apps' All chats columns in their order (ChatHistoryView): Kind, Topics and Answer length since B9; a choice saved
// before them keeps working (they start off).
type HistoryColumn = 'paper' | 'kind' | 'topics' | 'messages' | 'started' | 'length';
type HistoryColumns = Record<'paper' | 'messages' | 'started', boolean> & Partial<Record<'kind' | 'topics' | 'length', boolean>>;
const HISTORY_COLUMNS: readonly [HistoryColumn, string][] = [['paper', 'Paper'], ['kind', 'Kind'], ['topics', 'Topics'], ['messages', 'Messages'], ['started', 'Started'], ['length', 'Answer length']];
const DEFAULT_HISTORY_COLUMNS: HistoryColumns = { paper: true, messages: false, started: false };
const validHistoryColumns = (v: unknown) => !!v && typeof v === 'object' && ['paper', 'messages', 'started'].every(k => typeof (v as Record<string, unknown>)[k] === 'boolean')
  && ['kind', 'topics', 'length'].every(k => (v as Record<string, unknown>)[k] === undefined || typeof (v as Record<string, unknown>)[k] === 'boolean');
/** "1 word", "320 words", "1.2k words" (ChatHistory's answer length); none is a dash. */
export function answerLength(words: number): string {
  if (!words) return '—';
  if (words === 1) return '1 word';
  return words < 1000 ? `${words} words` : `${(words / 1000).toFixed(1).replace(/\.0$/, '')}k words`;
}
function useNarrow() {
  const query = '(max-width: 600px)';
  const [narrow, setNarrow] = useState(() => typeof matchMedia === 'function' && matchMedia(query).matches);
  useEffect(() => {
    if (typeof matchMedia !== 'function') return;
    const list = matchMedia(query), change = () => setNarrow(list.matches);
    list.addEventListener('change', change); change();
    return () => list.removeEventListener('change', change);
  }, []);
  return narrow;
}
function HistoryList({ chat, papers, currentDocument, onClose, onOpen, topics }: { chat: ChatSession; papers: Map<string, string>; currentDocument: string | null; onClose: () => void; onOpen: (documentID: string | null, anchor?: TextAnchor) => void; topics?: Map<string, string[]> }) {
  const historyVersion = useChatUpdates(chat);
  // All first and chosen (owner, build 57: "You can put All to the left and make that the default").
  const [search, setSearch] = useState(''), [filter, setFilter] = useState('all');
  const [sort, setSort] = useState<'last' | 'title' | 'started'>('last');
  const [columns, setColumns] = useStored<HistoryColumns>('gradstep.chat-history.columns.v1', DEFAULT_HISTORY_COLUMNS, validHistoryColumns);
  const [deleting, setDeleting] = useState<ConversationSummary | null>(null), [deleteError, setDeleteError] = useState(false);
  const [deleteEntry, setDeleteEntry] = useState<{ id: string; event: { kind: 'tombstone'; entityID: string; parents: string[]; createdAt: number } } | null>(null);
  const [deleteBusy, setDeleteBusy] = useState(false);
  const [renamingID, setRenamingID] = useState<string | null>(null);
  const newGeneral = () => {
    const composer = chat.newChat(null);
    onOpen(null); onClose();
    // Let the history dialog close before focusing its destination; a newer navigation or login
    // must not move focus into a different composer.
    requestAnimationFrame(() => requestAnimationFrame(() => {
      if (!chat.signal.aborted && !chat.storageRetired) document.querySelector<HTMLTextAreaElement>(`textarea[data-composer-id="${composer.id}"]`)?.focus();
    }));
  };
  const normalized = (s: string) => s.normalize('NFD').replace(/\p{M}/gu, '').toLowerCase();
  // Filtered and sorted once per history change or choice, not on every streamed answer's update (C2).
  const rows = useMemo(() => {
    const words = normalized(search).split(/\s+/).filter(Boolean);
    const list = chat.history.state.conversationSummaries().filter(c => (filter === 'all' || (filter === 'this' ? c.documentID === currentDocument : filter === 'paper' ? !!c.documentID : !c.documentID))
      && words.every(word => normalized(`${c.title} ${c.questions} ${papers.get(c.documentID ?? '') ?? ''}`).includes(word)));
    return list.sort((a, b) => sort === 'title' ? summaryTitle(a).localeCompare(summaryTitle(b)) : (sort === 'started' ? (b.startedAt ?? -1) - (a.startedAt ?? -1) : (b.lastUsedAt ?? -1) - (a.lastUsedAt ?? -1)) || b.lastArrival - a.lastArrival);
  }, [chat, historyVersion, filter, currentDocument, search, papers, sort]); // eslint-disable-line react-hooks/exhaustive-deps
  // The reader's columns (≡ › Columns); a narrow window shows the conversation and Last read only (as an iPhone in portrait).
  const narrow = useNarrow();
  const shown = { paper: columns.paper && !narrow, messages: columns.messages && !narrow, started: columns.started && !narrow,
    kind: !!columns.kind && !narrow, topics: !!columns.topics && !narrow, length: !!columns.length && !narrow };
  const paperName = (c: ConversationSummary) => c.documentID ? papers.get(c.documentID) ?? 'Paper no longer in library' : 'General';
  // Owner, build 57: "The paper should only be in its column not duplicated on left column".
  const secondLine = (c: ConversationSummary) => shown.paper || !c.documentID ? conversationPreview(c) : paperName(c);
  const sortTitles = { last: 'Last read', started: 'Started', title: 'Title' } as const;
  return <>
    {/* One row (owner, build 57: "the search bar at the top with the three lines at the right of the search bar"), in the
        information sheet's top row with its title and a round X (UX audit S23: the only close was inside ≡). */}
    <SheetTop onClose={onClose} closeLabel="Close" testID="history-close" trailing={
      <MenuButton icon="menu" label="All chats options" testID="history-menu">{close => <>
        <button type="button" role="menuitem" className="menu-item" disabled={chat.storageRetired} onClick={() => { close(false); newGeneral(); }}><Icon name="plus" size={14} /> New general chat</button>
        <div className="menu-section" role="group" aria-label="Sort by"><p className="fine menu-heading">Sort by</p>
          {(['last', 'started', 'title'] as const).map(s => <button key={s} type="button" role="menuitemradio" aria-checked={sort === s} className="menu-item menu-check"
            onClick={() => { setSort(s); close(); }}><span className="menu-check-mark" aria-hidden="true">{sort === s ? '✓' : ''}</span>{sortTitles[s]}</button>)}</div>
        <div className="menu-section" role="group" aria-label="Columns"><p className="fine menu-heading">Columns</p>
          {HISTORY_COLUMNS.map(([k, label]) => <button key={k} type="button" role="menuitemcheckbox" aria-checked={!!columns[k]} className="menu-item menu-check"
            onClick={() => setColumns(v => ({ ...v, [k]: !v[k] }))}><span className="menu-check-mark" aria-hidden="true">{columns[k] ? '✓' : ''}</span>{label}</button>)}
          {narrow && <p className="fine">A wider window shows them.</p>}</div>
      </>}</MenuButton>}>
      <h2>All chats</h2>
      <input type="search" autoFocus aria-label="Search chats" placeholder="Search chats" value={search} onChange={e => setSearch(e.target.value)} />
    </SheetTop>
    <div className="history-filters">{(currentDocument ? ['all', 'this', 'paper', 'general'] : ['all', 'paper', 'general']).map(f => <button key={f} className={`seg${filter === f ? ' on' : ''}`} aria-pressed={filter === f} onClick={() => setFilter(f)}>{({ this: 'This paper', all: 'All', paper: 'Paper chats', general: 'General' })[f]}</button>)}</div>
    <p className="fine">{rows.length} chats · Synced encrypted history</p>
    {[...chat.composers.values()].filter(c => c.draft).map(c => <div className="history-draft" key={c.id}><button className="link" onClick={() => { chat.chooseDraft(c.id); onOpen(c.documentID); onClose(); }}>Draft · {papers.get(c.documentID ?? '') ?? 'General chat'}</button><button className="link" disabled={composerBusy(c) || !!c.answer || chat.hasUnresolvedTurn(c) || chat.storageRetired}
      title={c.answer || chat.hasUnresolvedTurn(c) ? 'Finish saving this answer before discarding the draft.' : undefined} onClick={() => chat.discardDraft(c.id)}>Discard</button></div>)}
    {chat.history.issue && <p role="alert">{chat.history.issue}</p>}
    <div className="history-table-wrap"><table className="history-table" data-testid="history-table"><thead><tr>
      <th className="history-conversation"><button className="link" aria-pressed={sort === 'title'} onClick={() => setSort('title')}>Conversation</button></th>
      {shown.paper && <th className="history-paper">Paper</th>}
      {shown.kind && <th className="history-kind">Kind</th>}
      {shown.topics && <th className="history-topics">Topics</th>}
      {shown.messages && <th className="history-count">Messages</th>}
      {shown.started && <th className="history-started"><button className="link" aria-pressed={sort === 'started'} onClick={() => setSort('started')}>Started</button></th>}
      {shown.length && <th className="history-length">Answer length</th>}
      <th className="history-last"><button className="link" aria-pressed={sort === 'last'} onClick={() => setSort('last')}>Last read</button></th>
      <th className="history-actions"><span className="sr-only">Actions</span></th></tr></thead>
      <tbody>{rows.map(c => <tr key={c.id}><td>{renamingID === c.id
        ? <RenameField initial={summaryTitle(c) || 'Chat'} label="Chat name" onCancel={() => setRenamingID(null)}
          onSave={async name => { const ok = await chat.rename(c.id, name); if (ok) setRenamingID(null); return ok; }} />
        : <><button className="history-title" onClick={() => { chat.open(c.id); onOpen(c.documentID ?? null); onClose(); }}>{summaryTitle(c) || 'Chat'}</button>
          <span className="fine history-meta" data-testid="history-second-line">{secondLine(c) || ' '}</span></>}</td>
        {shown.paper && <td className="history-paper">{paperName(c)}</td>}
        {shown.kind && <td className="fine history-kind">{c.documentID ? 'Paper' : 'General'}</td>}
        {shown.topics && <td className="history-topics">{(c.documentID && topics?.get(c.documentID)?.length) ? <span className="tags">{topics.get(c.documentID)!.slice(0, 3).map(t => <span key={t} className="tag">{t}</span>)}</span> : null}</td>}
        {shown.messages && <td className="fine history-count">{c.messageCount}</td>}
        {shown.started && <td className="fine">{formatDate(c.startedAt)}</td>}
        {shown.length && <td className="fine history-length">{answerLength(c.latestAnswerWords)}</td>}
        <td className="fine">{formatDate(c.lastUsedAt)}</td>
        <td className="history-row-actions">{c.anchor && c.documentID && papers.has(c.documentID) && <button className="link" aria-label={`Go to the passage of ${summaryTitle(c) || 'chat'}`}
          onClick={() => { chat.open(c.id); onOpen(c.documentID!, c.anchor); onClose(); }}>Go to passage</button>}
          <button className="link" disabled={chat.storageRetired} aria-label={`Rename ${summaryTitle(c) || 'chat'}`} onClick={() => setRenamingID(c.id)}>Rename</button>
          <button className="link" aria-label={`Delete ${c.title}`} disabled={chat.storageRetired} onClick={() => { setDeleting(c); setDeleteError(false); setDeleteEntry(null); }}>Delete</button></td></tr>)}</tbody>
    </table></div>
    {!rows.length && <p className="muted">{search ? 'No matching chats.' : 'Your saved conversations will appear here.'}</p>}
    {deleting && <div className="chat-delete" role="alert"><p>Delete “{summaryTitle(deleting) || 'this chat'}” from chats on all your devices?</p><div className="dialog-actions"><button className="secondary" onClick={() => setDeleting(null)}>Cancel</button><button className="primary" disabled={deleteBusy} onClick={() => {
      const entry = deleteEntry ?? { id: crypto.randomUUID(), event: { kind: 'tombstone' as const, entityID: deleting.id, parents: [], createdAt: Date.now() } };
      setDeleteEntry(entry); setDeleteBusy(true);
      void chat.history.append([entry]).then(() => setDeleting(null), () => setDeleteError(true)).finally(() => setDeleteBusy(false));
    }}>Delete conversation</button></div>{deleteError && <p className="issue">Deletion has not synced. Keep this tab open and retry sync.</p>}</div>}
  </>;
}

/** An answer's drawing; figure parts first load their figure from this chat's paper on this device. */
/** The caption of the figure an answer's parts were cut from (its panel letters cap the parts: FIGURE_VIEW.md "Parts as
 * viewports"), from the paper on this device. */
type CaptionLookup = (manifest: string, blockID: string, paths: string[]) => Promise<FigureFacts | null>;
export function AnswerDiagram({ diagram, image, caption }: { diagram: { title: string; source: string; format: DiagramFormat }; image: (manifest: string, paths: string[]) => Promise<Blob | null>; caption?: CaptionLookup }) {
  const [figure, setFigure] = useState<Blob | null>(null), [named, setNamed] = useState(''), [structure, setStructure] = useState<FigureStructure | null>(null);
  useEffect(() => {
    if (diagram.format !== 'figure-parts-v1') return;
    const stored = decodeStoredFigureParts(diagram.source);
    if (!stored) return;
    let live = true;
    void caption?.(stored.manifestSHA256, stored.blockID, storedPaths(stored)).then(facts => { if (live && facts) { setNamed(facts.caption); setStructure(facts.structure); } });
    void image(stored.manifestSHA256, storedPaths(stored)).then(blob => { if (live) setFigure(blob); });
    return () => { live = false; };
    // The image function is recreated each render; the stored parts decide what to load.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [diagram.format, diagram.source]);
  return <Diagram title={diagram.title} source={diagram.source} format={diagram.format} figureImage={figure} figureCaption={named} figureStructure={structure} />;
}

/** An answer whose text marks where its figure's parts go (owner, 2026-10-15: "the crops should be inline, right as the
 * chat discusses each one"): the text in pieces with each part's crop between them, and the whole figure under it. */
function FigurePartsAnswer({ text, diagram, image, caption }: { text: string; diagram: { title: string; source: string }; image: (manifest: string, paths: string[]) => Promise<Blob | null>; caption?: CaptionLookup }) {
  const stored = decodeStoredFigureParts(diagram.source)!;
  const [figure, setFigure] = useState<Blob | null>(null), [named, setNamed] = useState(''), [structure, setStructure] = useState<FigureStructure | null>(null);
  useEffect(() => {
    let live = true;
    void caption?.(stored.manifestSHA256, stored.blockID, storedPaths(stored)).then(facts => { if (live && facts) { setNamed(facts.caption); setStructure(facts.structure); } });
    void image(stored.manifestSHA256, storedPaths(stored)).then(blob => { if (live) setFigure(blob); });
    return () => { live = false; };
    // The image function is recreated each render; the stored parts decide what to load.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [diagram.source]);
  const { url, size } = useFigureDataURL(figure);
  const crops = usePartCrops(stored, figure, named, size, structure);
  return <>
    <div className="answer-with-parts">{partSegments(text, stored.parts.length).map((segment, i) => segment.kind === 'text'
      ? <Answer key={i} text={segment.text} />
      : <FigurePartInline key={i} number={segment.number} part={stored.parts[segment.number - 1]} url={url} size={size} shown={crops?.[segment.number - 1]} />)}</div>
    <FigurePartsOverview title={diagram.title} stored={stored} url={url} size={size} crops={crops} />
  </>;
}
