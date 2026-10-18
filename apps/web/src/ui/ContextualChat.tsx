import { useEffect, useMemo, useSyncExternalStore } from 'react';
import type { ChatSession } from '../lib/chat-session';
import type { TextAnchor } from '../lib/events';
import { ConnectedChat } from './ChatPane';
export interface ContextualHost { chat: ChatSession; documentID: string; title: string; onPromote?: () => void }
const subscribe = () => () => {}, version = () => 0;
export function useContextualChat(host: ContextualHost | undefined, manifest: string, element: string | null, label: string, quote: string) {
  useSyncExternalStore(host?.chat.subscribe ?? subscribe, host?.chat.getVersion ?? version);
  const anchor = useMemo<TextAnchor>(() => ({ manifestSHA256: manifest, elementID: element ?? undefined, quote: [...quote].slice(0, 4000).join(''), prefix: '', suffix: '' }), [manifest, element, quote]);
  const composer = useMemo(() => host && element && quote ? host.chat.contextualComposer(host.documentID, anchor, label.startsWith('Equation') ? 'equations' : 'figures') : null, [host?.chat, host?.documentID, anchor, element, quote]);
  useEffect(() => () => { if (host && composer && !host.chat.promotedContexts.has(composer.id)) host.chat.stop(composer); }, [host?.chat, composer]);
  return host && composer ? { host, composer, anchor, label, quote, profile: host.chat.profileTable ? host.chat.profileFor(composer) : undefined } : null;
}
export function ContextualChat({ context, explanation, onCite }: { context: ReturnType<typeof useContextualChat>; explanation?: string; onCite: (anchor: TextAnchor) => void }) {
  return context && <section className="contextual-chat" aria-label={`Chat about ${context.label}`} data-testid="contextual-chat">
    <ConnectedChat chat={context.host.chat} paper={{documentID:context.host.documentID,title:context.host.title,available:true}} mode="paper"
      context={{composer:context.composer,anchor:context.anchor,label:context.label,quote:context.quote,explanation}}
      onMode={() => {}} onAllChats={() => {}} onPassage={(_, anchor) => onCite(anchor)} onChatOptions={() => {}} />
  </section>;
}

export function promoteContextual(context:ReturnType<typeof useContextualChat>,explanation:string,image?:string) {
  if (!context) return;
  context.host.chat.promoteContextual(context.composer,{anchor:context.anchor,label:context.label,quote:context.quote,explanation:[...explanation].slice(0,12000).join(''),image});
  context.host.onPromote?.();
}
