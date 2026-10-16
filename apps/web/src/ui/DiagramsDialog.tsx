import { useEffect, useMemo, useState } from 'react';
import type { ChatSession } from '../lib/chat-session';
import { AnswerDiagram, useChatUpdates } from './ChatPane';
import { Dialog, formatDateTime } from './common';
import { Icon } from './icons';

/** Your assets › Diagrams (native HistoryView with `diagrams: true`): every diagram, visual and figure breakdown the
 * reader's chats drew, newest first; one opens as it does in its answer, with Full size. Chats that were deleted take
 * their diagrams with them. */
export function DiagramsDialog({ chat, open, onClose }: { chat: ChatSession; open: boolean; onClose: () => void }) {
  const version = useChatUpdates(chat);
  const diagrams = useMemo(() => open ? chat.history.state.savedDiagrams() : [], [chat, version, open]);
  const [selected, setSelected] = useState<string | null>(null);
  useEffect(() => { if (!open) setSelected(null); }, [open]);
  const current = selected ? diagrams.find(d => d.id === selected) : undefined;
  return <Dialog open={open} onClose={onClose} title="All diagrams" wide className="diagrams-dialog">
    <div className="dialog-heading">
      {current ? <button className="link back-link" onClick={() => setSelected(null)} data-testid="diagrams-back"><Icon name="chevronLeft" size={14} /> All diagrams</button>
        : <h2>All diagrams</h2>}
      <button className="link" onClick={onClose}>Done</button>
    </div>
    {current ? <div className="diagram-detail" data-testid="diagram-detail">
      <AnswerDiagram diagram={current} image={(manifest, paths) => chat.figureImage(current.documentID ?? null, manifest, paths)} />
    </div>
      : diagrams.length ? <ul className="diagram-list" data-testid="diagram-list">{diagrams.map(d => <li key={d.id}>
        <button className="diagram-row" onClick={() => setSelected(d.id)} data-testid={`diagram-row-${d.id}`}>
          <span className="diagram-row-title">{d.title}</span>
          {d.createdAt !== undefined && <span className="fine">{formatDateTime(d.createdAt)}</span>}
          <Icon name="chevronRight" size={14} />
        </button></li>)}</ul>
        : <p className="muted" data-testid="diagrams-empty">No diagrams yet</p>}
  </Dialog>;
}
