// The right pane: chat (legacy ChatPanel position). Milestone 1 holds its place and says plainly that
// chat isn't in the browser yet; streaming, encrypted history and selection actions come next.
import { Icon } from './icons';
import { PaneHeader, useWorkspaceControls } from './Shell';

export function ChatPane({ paperTitle, onAllChats }: { paperTitle: string | null; onAllChats: () => void }) {
  const workspace = useWorkspaceControls();
  return (
    <div className="chat-pane">
      <PaneHeader title={<span className="segmented" role="group" aria-label="Chat mode">
        <span className={paperTitle ? 'segment on' : 'segment'} aria-disabled={!paperTitle}>Paper chat</span>
        <span className={paperTitle ? 'segment' : 'segment on'}>General chat</span>
      </span>} onClose={() => workspace?.show('right', false)} closeLabel="Hide chat">
        <button className="icon-button" onClick={onAllChats} aria-label="All chats" title="All chats"><Icon name="chats" /></button>
      </PaneHeader>
      <div className="chat-empty">
        <Icon name="chat" size={28} />
        <p className="chat-empty-title">Chat is not yet available in the browser.</p>
        <p className="fine">{paperTitle ? `Asking about “${paperTitle}”, selection actions` : 'General chat, paper chat'} and your encrypted chat history are coming here next.
          Until then, use Gradstep on iPhone, iPad or Mac.</p>
      </div>
      <div className="composer disabled" aria-hidden="true"><span>{paperTitle ? 'Ask about this paper' : 'Chat'}</span><Icon name="chevronUp" size={14} /></div>
    </div>
  );
}
