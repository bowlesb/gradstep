import { useMemo, useState } from 'react';
import type { ChatSession, Explanation } from '../lib/chat-session';
import { Dialog, formatDateTime, InfoTip, SheetTop } from './common';
import { Icon } from './icons';

const INFO = 'The Gradstep apps keep these explanations on your iPhone, iPad or Mac. This browser keeps them only until this tab closes.';

/** Your assets › Equation explanations / Figure explanations (owner, build 62: "We should also have Equation
 * Explanations, and Figure Explanations in the list of your assets"), as the apps' KeptExplanationsView: this tab's,
 * newest first, each equation or figure once, with its paper. A row opens the paper at that equation or figure, where
 * the explanation shows again without a new request. */
export function ExplanationsDialog({ chat, kind, paperTitle, onOpen, onClose }: {
  chat: ChatSession; kind: Explanation['kind'];
  /** The paper's title in the library, or null when it isn't in the library any more. */
  paperTitle: (documentID: string) => string | null;
  /** Opens the paper there; false when it can't be opened. */
  onOpen: (explanation: Explanation) => boolean; onClose: () => void;
}) {
  const rows = useMemo(() => chat.explanations(kind), [chat, kind]);
  const [missing, setMissing] = useState<string | null>(null);
  const title = kind === 'equation' ? 'Equation explanations' : 'Figure explanations';
  return <Dialog open onClose={onClose} title={title} className="explanations-dialog">
    <SheetTop onClose={onClose} testID="explanations-close"><h2>{title}</h2><InfoTip text={INFO} testID="explanations-info" /></SheetTop>
    {missing && <p className="issue" role="alert">{missing}</p>}
    {rows.length ? <ul className="diagram-list" data-testid="explanations-list">{rows.map(e => {
      const paper = paperTitle(e.documentID);
      return <li key={`${e.documentID}/${e.targetID}`}>
        <button className="diagram-row explanation-row" data-testid={`explanation-${e.targetID}`} onClick={() => {
          setMissing(null);
          if (!paper || !onOpen(e)) setMissing(`This paper isn’t in your library here, so its ${kind} can’t be opened.`);
        }}>
          <Icon name={kind === 'equation' ? 'function' : 'image'} size={16} />
          <span className="explanation-row-text"><strong>{e.label}</strong><span className="fine">{paper ?? 'Not in your library'}</span></span>
          <span className="fine">{formatDateTime(e.at)}</span>
          <Icon name="chevronRight" size={14} />
        </button></li>;
    })}</ul> : <p className="muted" data-testid="explanations-empty">None yet</p>}
  </Dialog>;
}
