import { useEffect, useMemo, useSyncExternalStore } from 'react';
import type { ChatSession } from '../lib/chat-session';
import type { TextAnchor } from '../lib/events';
import type { PaperExplainer } from '../lib/paper-explainer';
import { ConnectedChat } from './ChatPane';
export interface ContextualHost { chat: ChatSession; documentID: string; title: string; onPromote?: () => void }
const subscribe = () => () => {}, version = () => 0;
export function useContextualChat(host: ContextualHost | undefined, manifest: string, element: string | null, label: string, quote: string) {
  useSyncExternalStore(host?.chat.subscribe ?? subscribe, host?.chat.getVersion ?? version);
  const anchor = useMemo<TextAnchor>(() => ({ manifestSHA256: manifest, elementID: element ?? undefined, quote: [...quote].slice(0, 4000).join(''), prefix: '', suffix: '' }), [manifest, element, quote]);
  const composer = useMemo(() => host && element && quote ? host.chat.contextualComposer(host.documentID, anchor, label.startsWith('Equation') ? 'equations' : 'figures') : null, [host?.chat, host?.documentID, anchor, element, quote]);
  // Closing the view stops its answer, and lets go of a composer it only showed (C8).
  useEffect(() => {
    if (host && composer) host.chat.retainContextual(composer, label.startsWith('Equation') ? 'equations' : 'figures');
    return () => { if (host && composer && !host.chat.promotedContexts.has(composer.id)) { host.chat.stop(composer); host.chat.releaseContextual(composer); } };
  }, [host?.chat, composer]); // eslint-disable-line react-hooks/exhaustive-deps
  return host && composer ? { host, composer, anchor, label, quote, profile: host.chat.profileTable ? host.chat.profileFor(composer) : undefined } : null;
}
export function ContextualChat({ context, explanation, onCite }: { context: ReturnType<typeof useContextualChat>; explanation?: string; onCite: (anchor: TextAnchor) => void }) {
  return context && <section className="contextual-chat" aria-label={`Chat about ${context.label}`} data-testid="contextual-chat">
    <ConnectedChat chat={context.host.chat} paper={{documentID:context.host.documentID,title:context.host.title,available:true}} mode="paper"
      context={{composer:context.composer,anchor:context.anchor,label:context.label,quote:context.quote,explanation}}
      onMode={() => {}} onAllChats={() => {}} onPassage={(_, anchor) => onCite(anchor)} onChatOptions={() => {}} />
  </section>;
}

export function promoteContextual(context:ReturnType<typeof useContextualChat>,explanation:string,image?:string,paperExplainer?:PaperExplainer) {
  if (!context) return;
  context.host.chat.promoteContextual(context.composer,{anchor:context.anchor,label:context.label,quote:context.quote,explanation:[...explanation].slice(0,12000).join(''),image,
    ...(paperExplainer?{paperExplainer}:{})});
  context.host.onPromote?.();
  // The native dialog must release its focus trap before the promoted composer takes focus. Bind to this
  // exact composer and account so a later navigation or sign-out cannot focus an unrelated conversation.
  requestAnimationFrame(() => requestAnimationFrame(() => {
    if (context.host.chat.signal.aborted || context.host.chat.storageRetired) return;
    const field = document.querySelector<HTMLTextAreaElement>(`.pane-right textarea[data-composer-id="${context.composer.id}"]`);
    field?.focus();
    if (field) field.setSelectionRange(field.value.length, field.value.length);
  }));
}
