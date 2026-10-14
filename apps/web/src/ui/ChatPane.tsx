// The existing right panel, backed by one account-owned controller (it survives pane/navigation unmounts).
import { lazy, Suspense, useEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react';
import { chatTitle, failureText, progressText } from '../lib/chat';
import { answeredBy, profileSummary } from '../lib/chat-profiles';
import { ChatSession, composerBusy } from '../lib/chat-session';
import { MAX_TITLE_CHARACTERS, type ConversationSummary, type TextAnchor } from '../lib/events';
import { citationAnchor } from '../lib/passage';
import { ProfileControl } from './ChatProfile';
import { safeLink } from '../lib/links';
import { Dialog, formatDate } from './common';
import { CopyButton } from './CopyButton';
import { Diagram } from './Diagram';
import { Icon } from './icons';
import { PaneHeader, useWorkspaceControls } from './Shell';
import { StudyPanel } from './StudyPanel';

export function useChatUpdates(chat: ChatSession) {
  useSyncExternalStore(chat.subscribe, chat.getVersion);
  return useSyncExternalStore(chat.history.subscribe, chat.history.getVersion);
}
export interface PaperContext { documentID: string; title: string; available: boolean }

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

export function ChatPane({ chat, paper, mode, onMode, onAllChats, onPassage }: {
  chat: ChatSession | null; paper: PaperContext | null; mode: 'paper' | 'general'; onMode: (mode: 'paper' | 'general') => void;
  onAllChats: () => void; onPassage: (documentID: string, anchor: TextAnchor) => void;
}) {
  return chat ? <ConnectedChat chat={chat} paper={paper} mode={mode} onMode={onMode} onAllChats={onAllChats} onPassage={onPassage} />
    : <div className="empty" role="status">Opening chats…</div>;
}
function ConnectedChat({ chat, paper, mode, onMode, onAllChats, onPassage }: {
  chat: ChatSession; paper: PaperContext | null; mode: 'paper' | 'general'; onMode: (mode: 'paper' | 'general') => void;
  onAllChats: () => void; onPassage: (documentID: string, anchor: TextAnchor) => void;
}) {
  const historyVersion = useChatUpdates(chat);
  const workspace = useWorkspaceControls();
  const documentID = mode === 'paper' ? paper?.documentID ?? null : null;
  const c = chat.current(documentID);
  const branch = useMemo(() => chat.branch(c), [chat, c, c.head, c.conversationID, c.phase, historyVersion]);
  const summaries = useMemo(() => chat.history.state.conversationSummaries(), [chat, historyVersion]);
  const summary = summaries.find(s => s.id === c.conversationID);
  const branches = useMemo(() => c.conversationID ? chat.history.state.conversationBranches(c.conversationID) : [], [chat, c.conversationID, historyVersion]);
  const diagrams = useMemo(() => chat.history.state.diagramsByMessage(), [chat, historyVersion]);
  const [link, setLink] = useState<string | null>(null), [inputIssue, setInputIssue] = useState(false);
  const [renaming, setRenaming] = useState(false);
  useEffect(() => setRenaming(false), [c.id, c.conversationID]);
  const table = chat.profileTable, choice = chat.profileFor(c);
  const viewport = useRef<HTMLDivElement>(null), bottom = useRef<HTMLDivElement>(null), follow = useRef(true);
  const [away, setAway] = useState(false);
  const field = useRef<HTMLTextAreaElement>(null);
  const [displayText, setDisplayText] = useState(c.liveText);
  // Fixed cadence, not a debounce: continuously arriving tokens must remain visibly streaming.
  const latestText = useRef(c.liveText); latestText.current = c.liveText;
  useEffect(() => {
    setDisplayText(c.liveText);
    if (c.phase !== 'streaming') return;
    const t = setInterval(() => setDisplayText(latestText.current), 80);
    return () => clearInterval(t);
  }, [c.id, c.phase]);
  useEffect(() => { follow.current = true; setAway(false); }, [c.id]);
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
  useEffect(() => { if (follow.current) bottom.current?.scrollIntoView({ block: 'end' }); }, [branch?.head, branch?.messages.length, displayText, c.phase, c.id]);
  const messages = branch?.messages ?? [];
  const savedLive = messages.some(m => m.payload.entityID === c.liveID);
  const titleText = summary ? summaryTitle(summary) || 'Chat' : mode === 'paper' ? 'Ask about this paper' : 'General chat';
  const deleted = !!c.conversationID && chat.history.state.isDeleted(c.conversationID);
  const last = messages.at(-1);
  const retired = chat.storageRetired; // another tab updated storage: nothing new is sent from this page
  const canAnswer = !retired && !chat.hasUnresolvedTurn(c) && !['refused', 'invalid_request'].includes(c.issue ?? '') && !c.answer && !composerBusy(c) && (c.question || last?.payload.role === 'user');
  const disabled = retired || chat.history.status !== 'ready' || !!chat.history.issue || deleted || (mode === 'paper' && !paper?.available);
  const send = () => { if (!disabled) void chat.send(c); };
  // Study (experimental): an adaptive tutor for this paper; offered when the paper is numbered on this device.
  const studyOffered = mode === 'paper' && !!paper?.available && chat.canStudy(documentID) && !c.study && !deleted && !retired;
  const startStudy = () => { if (!disabled) void chat.startStudy(c); };

  return <div className="chat-pane" data-testid="chat-pane">
    <PaneHeader title={<span className="segmented" role="group" aria-label="Chat mode">
      <button className={mode === 'paper' ? 'segment on' : 'segment'} aria-pressed={mode === 'paper'} disabled={!paper} onClick={() => onMode('paper')}>Paper</button>
      <button className={mode === 'general' ? 'segment on' : 'segment'} aria-pressed={mode === 'general'} onClick={() => onMode('general')}>General</button>
    </span>} onClose={() => workspace?.show('right', false)} closeLabel="Hide chat">
      <button className="icon-button" onClick={onAllChats} aria-label="All chats" title="All chats"><Icon name="chats" /></button>
      <button className="icon-button" onClick={() => { chat.newChat(documentID); field.current?.focus(); }} aria-label="New chat" title="New chat"><Icon name="plus" /></button>
    </PaneHeader>
    <div className="chat-heading">
      {renaming && summary ? <RenameField initial={titleText} label="Chat name" onCancel={() => setRenaming(false)}
        onSave={async name => { const ok = await chat.rename(summary.id, name); if (ok) setRenaming(false); return ok; }} />
        : <div className="chat-title-row"><strong title={titleText} data-testid="chat-title">{titleText}</strong>
          {summary && !deleted && <button className="link small rename-link" disabled={retired} onClick={() => setRenaming(true)} aria-label={`Rename “${titleText}”`}>Rename</button>}
          {studyOffered && messages.length > 0 && <button className="link small" data-testid="study-start" disabled={disabled || composerBusy(c) || !!c.answer} onClick={startStudy}>Study this paper</button>}</div>}
      {mode === 'paper' && <span className="fine chat-paper" title={paper?.title}>{paper?.title ?? 'Paper chat'}</span>}
      {summary?.anchor && summary.documentID && <button className="link small" onClick={() => onPassage(summary.documentID!, summary.anchor!)}>Go to passage</button>}
      {branches.length > 1 && <label className="branch-picker">Branch <select aria-label="Conversation branch" value={c.head ?? ''} disabled={composerBusy(c) || !!c.answer} onChange={e => chat.chooseBranch(c, e.target.value)}>
        <option value="" disabled>Choose a branch</option>{branches.map((b, i) => <option key={b.head} value={b.head}>Branch {i + 1} · {b.messages.length} messages</option>)}
      </select></label>}
    </div>
    {(chat.history.status !== 'ready' || chat.history.issue || chat.history.unsaved > 0) && <div className="chat-sync fine" role="status">
      {chat.history.issue ?? (chat.history.status === 'loading' ? 'Loading encrypted history…' : chat.durable ? 'Saved on this device. Syncing encrypted history…' : 'Saving encrypted history… Keep this tab open.')}
      {chat.history.issue && <button className="link" onClick={() => void chat.history.sync().catch(() => {})}>Retry sync</button>}
    </div>}
    <div ref={viewport} className="chat-transcript" role="region" aria-label="Conversation" tabIndex={0} onScroll={() => {
      const el = viewport.current!; follow.current = el.scrollHeight - el.scrollTop - el.clientHeight < 80; setAway(!follow.current);
    }} onClick={e => {
      if (cite(e.target as Element)) { e.preventDefault(); return; }
      const a = (e.target as Element).closest('a[href]'); if (!a) return;
      e.preventDefault(); const href = safeLink(a.getAttribute('href') ?? ''); if (href) setLink(href);
    }} onKeyDown={e => { if ((e.key === 'Enter' || e.key === ' ') && (e.target as Element).classList?.contains('cite') && cite(e.target as Element)) e.preventDefault(); }}>
      {!messages.length && !composerBusy(c) && <div className="chat-empty"><Icon name="chat" size={28} /><p className="chat-empty-title">{mode === 'paper' ? 'A closer look at the paper' : 'What are you working on?'}</p>
        <p className="fine">{mode === 'paper' ? 'Ask a question, or select a passage to explore it.' : 'Discuss an idea, work through an equation, or ask for a diagram.'}</p>
        {studyOffered && <div className="study-offer"><button type="button" className="secondary small" data-testid="study-start" disabled={disabled} onClick={startStudy}>Study this paper</button>
          <p className="fine">A tutor asks one question at a time, teaches what you miss, and maps what you know. Experimental.</p></div>}</div>}
      {messages.map(m => <div key={m.payload.entityID} className={`chat-message ${m.payload.role}`} data-testid={`chat-${m.payload.role}`}>
        {m.payload.role === 'user' ? <><div className="message-label">You</div><div className="question-text">{m.payload.text}</div></> : <><div className="message-label-row"><div className="message-label">Gradstep</div><CopyButton text={m.payload.text ?? ''} label="Copy answer" /></div><Answer text={m.payload.text ?? ''} /></>}
        {m.payload.status === 'interrupted' && <span className="fine interrupted">Answer interrupted</span>}
        {m.payload.role === 'assistant' && answeredBy(m.payload.model, m.payload.profile, table) && <p className="fine answer-by" data-testid="answer-by">{answeredBy(m.payload.model, m.payload.profile, table)}</p>}
        {diagrams.has(m.payload.entityID) && <Diagram title={diagrams.get(m.payload.entityID)!.title} source={diagrams.get(m.payload.entityID)!.source} />}
      </div>)}
      {c.liveID && !savedLive && <div key={c.liveID} className="chat-message assistant" data-testid="chat-streaming"><div className="message-label">Gradstep</div>
        <Answer text={displayText} streaming />{!c.liveText && <p className="fine" role="status">{c.progress ? progressText(c.progress) : waited >= 5 ? `Thinking… ${waited} s` : 'Thinking…'}</p>}</div>}
      {c.followUps && !composerBusy(c) && !c.answer && !c.issue && last?.payload.role === 'assistant' && <div className="follow-ups" role="group" aria-label="Suggested questions">
        {c.followUps.map(question => <button key={question} type="button" className="follow-up" data-testid="follow-up" disabled={disabled}
          onClick={() => { if (chat.edit(c, question)) field.current?.focus(); }}>{question}</button>)}</div>}
      {c.progress && c.liveText && <p className="fine chat-progress" role="status">{progressText(c.progress)}</p>}
      {c.issue && <div className="chat-issue" role="alert"><p>{failureText(c.issue)}</p>
        {c.issue === 'local_save' && !retired && <button className="secondary small" onClick={() => void chat.retryDeviceSave(c)}>Retry device save</button>}
        {canAnswer && <button className="secondary small" disabled={deleted || (mode === 'paper' && !paper?.available)} onClick={() => void chat.retry(c)}>Get answer</button>}
        {c.answer && !retired && <button className="secondary small" onClick={() => void chat.retry(c)}>Retry saving</button>}
      </div>}
      {!c.issue && canAnswer && !composerBusy(c) && last?.payload.role === 'user' && <button className="secondary small" disabled={deleted || (mode === 'paper' && !paper?.available)} onClick={() => void chat.retry(c)}>Get answer</button>}
      {canAnswer && (c.issue || last?.payload.role === 'user') && <p className="fine" data-testid="retry-profile">This question: {profileSummary(chat.retryProfile(c), table)}</p>}
      {c.credits !== null && <p className="fine answer-cost">{c.credits === 0 && c.issue ? 'No credits used' : `${c.credits} ${c.credits === 1 ? 'credit' : 'credits'} used`}</p>}
      {deleted && <p className="issue">This conversation was deleted. Your draft is still here to copy.</p>}
      {away && <button className="jump-latest secondary small" onClick={() => { follow.current = true; setAway(false); bottom.current?.scrollIntoView({ block: 'end' }); }}>Latest message <Icon name="chevronDown" size={12} /></button>}
      <div ref={bottom} />
    </div>
    {c.study && <StudyPanel map={c.study} busy={composerBusy(c) || !!c.answer} onEnd={() => chat.endStudy(c)}
      onPassage={paragraph => { if (documentID) onPassage(documentID, citationAnchor(paragraph)); }} />}
    <form className="chat-composer" onSubmit={e => { e.preventDefault(); send(); }}>
      <textarea ref={field} data-composer-id={c.id} aria-label="Message" placeholder={c.study ? 'Your answer…' : mode === 'paper' ? 'Ask about this paper…' : 'Message…'} value={c.draft} rows={2} maxLength={200_000} readOnly={retired}
        title="Enter sends; Shift+Enter starts a new line"
        onChange={e => setInputIssue(!chat.edit(c, e.target.value))}
        onKeyDown={e => { if (e.key === 'Enter' && !e.shiftKey && !e.nativeEvent.isComposing) { e.preventDefault(); if (!composerBusy(c)) send(); } }} />
      <div className="composer-footer"><div className="composer-meta">
        <ProfileControl table={table} choice={choice} defaultChoice={chat.defaultProfile} disabled={retired || composerBusy(c) || !!c.answer}
          onChange={next => chat.setProfile(c, next)} onMakeDefault={next => chat.setDefaultProfile(next)} onRetry={() => chat.reloadProfiles()} />
        <span className="fine composer-balance" title="Add credits in Gradstep on iPhone, iPad or Mac">{chat.balance ? `${chat.balance.available} credits${chat.balance.reserved ? ` · ${chat.balance.reserved} held` : ''}` : 'Uses credits'}</span></div>
        {c.phase === 'streaming' ? <button type="button" className="secondary small" onClick={() => chat.stop(c)}>Stop</button>
          : <button type="submit" className="primary small" disabled={disabled || composerBusy(c) || !!c.answer || !c.draft.trim()}>{c.phase === 'saving' || c.phase === 'finishing' ? 'Saving…' : 'Send'}</button>}
      </div>
      {inputIssue && <p className="issue fine">This draft is too long. Shorten it to continue.</p>}
      {(() => {
        // Only what the reader should act on: a stopped tab, a failed device save, or a draft that is not kept after a reload.
        const hint = retired ? 'This tab has stopped sending. Select your text to copy it.'
          : chat.durable ? (c.issue === 'local_save' ? 'Couldn’t save this edit on this device. Keep this tab open and copy your text.'
            : c.draft && c.revision > c.savedRevision ? 'Saving draft on this device…' : 'Saved on this device.')
          : 'Unsent drafts stay in this tab only and aren’t kept after a reload.';
        return hint ? <p className="fine draft-hint" data-testid="draft-status">{hint}</p> : null;
      })()}
    </form>
    <Dialog open={c.phase === 'consent'} onClose={() => void chat.consent(c, false)} title="Cloud AI answers">
      <h2>Cloud AI answers</h2><p>Your question, selected passage, earlier turns and the paper’s text go to Anthropic to write an answer.</p>
      <p>Web searches may go to Tavily or Anthropic’s search provider. Anthropic and the search services may retain requests under their API terms.</p>
      <p className="muted">Gradstep passes the request through without storing the text. Saved chats are encrypted with your device keys. Answers use credits.</p>
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
function Answer({ text, streaming = false }: { text: string; streaming?: boolean }) {
  return <Suspense fallback={<div className="question-text">{text}</div>}><RichAnswer text={text} streaming={streaming} /></Suspense>;
}

export function ChatHistory({ chat, open, onClose, papers, currentDocument, onOpen }: {
  chat: ChatSession | null; open: boolean; onClose: () => void; papers: Map<string, string>; currentDocument: string | null;
  onOpen: (documentID: string | null) => void;
}) {
  return <Dialog open={open} onClose={onClose} title="All chats" wide>{chat ? <HistoryList chat={chat} papers={papers} currentDocument={currentDocument} onClose={onClose} onOpen={onOpen} /> : <p>Loading chats…</p>}</Dialog>;
}
function HistoryList({ chat, papers, currentDocument, onClose, onOpen }: { chat: ChatSession; papers: Map<string, string>; currentDocument: string | null; onClose: () => void; onOpen: (documentID: string | null) => void }) {
  useChatUpdates(chat);
  const [search, setSearch] = useState(''), [filter, setFilter] = useState(currentDocument ? 'this' : 'all');
  const [sort, setSort] = useState<'last' | 'title' | 'started'>('last');
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
  const rows = chat.history.state.conversationSummaries().filter(c => (filter === 'all' || (filter === 'this' ? c.documentID === currentDocument : filter === 'paper' ? !!c.documentID : !c.documentID))
    && normalized(search).split(/\s+/).filter(Boolean).every(word => normalized(`${c.title} ${c.questions} ${papers.get(c.documentID ?? '') ?? ''}`).includes(word)));
  rows.sort((a, b) => sort === 'title' ? summaryTitle(a).localeCompare(summaryTitle(b)) : (sort === 'started' ? (b.startedAt ?? -1) - (a.startedAt ?? -1) : (b.lastUsedAt ?? -1) - (a.lastUsedAt ?? -1)) || b.lastArrival - a.lastArrival);
  return <>
    <div className="dialog-heading"><h2>All chats</h2><div className="history-heading-actions">
      <button className="secondary small" disabled={chat.storageRetired} onClick={newGeneral}>New general chat</button>
      <button className="link" onClick={onClose}>Done</button>
    </div></div>
    <input type="search" autoFocus aria-label="Search chats" placeholder="Search chats" value={search} onChange={e => setSearch(e.target.value)} />
    <div className="history-filters">{(currentDocument ? ['this', 'all', 'paper', 'general'] : ['all', 'paper', 'general']).map(f => <button key={f} className={`seg${filter === f ? ' on' : ''}`} aria-pressed={filter === f} onClick={() => setFilter(f)}>{({ this: 'This paper', all: 'All', paper: 'Paper chats', general: 'General' })[f]}</button>)}</div>
    <p className="fine">{rows.length} chats · Synced encrypted history</p>
    {[...chat.composers.values()].filter(c => c.draft).map(c => <div className="history-draft" key={c.id}><button className="link" onClick={() => { chat.chooseDraft(c.id); onOpen(c.documentID); onClose(); }}>Draft · {papers.get(c.documentID ?? '') ?? 'General chat'}</button><button className="link" disabled={composerBusy(c) || !!c.answer || chat.hasUnresolvedTurn(c) || chat.storageRetired}
      title={c.answer || chat.hasUnresolvedTurn(c) ? 'Finish saving this answer before discarding the draft.' : undefined} onClick={() => chat.discardDraft(c.id)}>Discard</button></div>)}
    {chat.history.issue && <p role="alert">{chat.history.issue}</p>}
    <div className="history-table-wrap"><table className="history-table"><thead><tr><th><button className="link" onClick={() => setSort('title')}>Conversation</button></th><th className="history-paper">Paper</th><th><button className="link" onClick={() => setSort(sort === 'started' ? 'last' : 'started')}>{sort === 'started' ? 'Started' : 'Last used'}</button></th><th><span className="sr-only">Actions</span></th></tr></thead>
      <tbody>{rows.map(c => <tr key={c.id}><td>{renamingID === c.id
        ? <RenameField initial={summaryTitle(c) || 'Chat'} label="Chat name" onCancel={() => setRenamingID(null)}
          onSave={async name => { const ok = await chat.rename(c.id, name); if (ok) setRenamingID(null); return ok; }} />
        : <><button className="history-title" onClick={() => { chat.open(c.id); onOpen(c.documentID ?? null); onClose(); }}>{summaryTitle(c) || 'Chat'}</button>
          <span className="fine history-meta">{c.messageCount} messages · <button className="link history-rename" disabled={chat.storageRetired} aria-label={`Rename ${summaryTitle(c) || 'chat'}`} onClick={() => setRenamingID(c.id)}>Rename</button></span></>}</td>
        <td className="history-paper">{c.documentID ? papers.get(c.documentID) ?? 'Paper no longer in library' : 'General'}</td><td className="fine">{formatDate(sort === 'started' ? c.startedAt : c.lastUsedAt)}</td>
        <td><button className="link" aria-label={`Delete ${c.title}`} disabled={chat.storageRetired} onClick={() => { setDeleting(c); setDeleteError(false); setDeleteEntry(null); }}>Delete</button></td></tr>)}</tbody>
    </table></div>
    {!rows.length && <p className="muted">{search ? 'No matching chats.' : 'Your saved conversations will appear here.'}</p>}
    {deleting && <div className="chat-delete" role="alert"><p>Delete “{summaryTitle(deleting) || 'this chat'}” from chats on all your devices?</p><div className="dialog-actions"><button className="secondary" onClick={() => setDeleting(null)}>Cancel</button><button className="primary" disabled={deleteBusy} onClick={() => {
      const entry = deleteEntry ?? { id: crypto.randomUUID(), event: { kind: 'tombstone' as const, entityID: deleting.id, parents: [], createdAt: Date.now() } };
      setDeleteEntry(entry); setDeleteBusy(true);
      void chat.history.append([entry]).then(() => setDeleting(null), () => setDeleteError(true)).finally(() => setDeleteBusy(false));
    }}>Delete conversation</button></div>{deleteError && <p className="issue">Deletion has not synced. Keep this tab open and retry sync.</p>}</div>}
  </>;
}
