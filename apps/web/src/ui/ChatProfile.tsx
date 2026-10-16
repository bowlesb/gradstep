// Answer options (chat redesign from build 57, docs/architecture/CHAT.md 2026-10-16): the reader chooses the model and
// the length; effort is chosen automatically where the server offers it. The chat's ⋯ menu opens Answer options for
// this chat; Settings › AI chat options (the account menu) sets what new chats start with and explains each model and
// its usual cost. Estimates and labels come from the server's published table; nothing here decides a price or limit
// (the chat function holds and charges).
import { type KeyboardEvent, useEffect, useId, useRef, useState } from 'react';
import { EFFORTS, effortOption, hasAutoEffort, LENGTHS, lengthOption, listedModels, MODEL_STRENGTHS, modelOption, modelProvider, offersModelLength,
  sameChoice, typicalEstimate, withChoice, type Estimate, type LengthChoice, type ModelChoice, type ProfileChoice, type ProfileTable } from '../lib/chat-profiles';
import { Dialog } from './common';
import { Icon } from './icons';

type Group = 'model' | 'length';

/** Model and Length, each a radiogroup with arrow-key movement and the chosen option's one-line detail. */
export function ChoicePicker({ table, choice, onChange, autoFocus = false }: {
  table: ProfileTable | null; choice: ProfileChoice; onChange: (choice: ProfileChoice) => void; autoFocus?: boolean;
}) {
  const id = useId(), first = useRef<HTMLButtonElement>(null);
  // After the dialog opens (showModal runs after this effect and focuses its first control), the chosen model.
  useEffect(() => {
    if (!autoFocus) return;
    const frame = requestAnimationFrame(() => first.current?.focus());
    return () => cancelAnimationFrame(frame);
  }, [autoFocus]);
  const groups: { key: Group; title: string; values: readonly string[] }[] = [
    { key: 'model', title: 'Model', values: listedModels(table) }, { key: 'length', title: 'Length', values: LENGTHS }];
  const possible = (group: Group, value: string) => !!table && (group === 'model'
    ? offersModelLength(table, value as ModelChoice, choice.length) : offersModelLength(table, choice.model, value as LengthChoice));
  const option = (group: Group, value: string) => group === 'model' ? modelOption(table, value as ModelChoice) : lengthOption(table, value as LengthChoice);
  const pick = (group: Group, value: string) => {
    if (!possible(group, value)) return;
    onChange(withChoice(table, choice, group === 'model' ? { model: value as ModelChoice } : { length: value as LengthChoice }));
  };
  const keys = (group: Group, values: readonly string[]) => (e: KeyboardEvent<HTMLButtonElement>) => {
    const step = e.key === 'ArrowRight' || e.key === 'ArrowDown' ? 1 : e.key === 'ArrowLeft' || e.key === 'ArrowUp' ? -1 : 0;
    if (!step) return;
    e.preventDefault();
    const usable = values.filter(v => possible(group, v) || v === choice[group]);
    const index = usable.indexOf(choice[group]), next = usable[(index + step + usable.length) % usable.length];
    pick(group, next);
    const container = e.currentTarget.parentElement;
    requestAnimationFrame(() => container?.querySelector<HTMLButtonElement>(`[data-value="${next}"]`)?.focus());
  };
  return <div className="profile-picker">
    {groups.map((g, gi) => <div className="profile-group" key={g.key}>
      <div className="profile-group-title" id={`${id}-${g.key}`}>{g.title}</div>
      <div className="profile-options" role="radiogroup" aria-labelledby={`${id}-${g.key}`} aria-describedby={`${id}-${g.key}-detail`}>
        {g.values.map(value => {
          const checked = choice[g.key] === value;
          return <button key={value} type="button" role="radio" aria-checked={checked} data-value={value} tabIndex={checked ? 0 : -1}
            ref={gi === 0 && checked ? first : undefined} className={checked ? 'seg on' : 'seg'} disabled={!possible(g.key, value) && !checked}
            onClick={() => pick(g.key, value)} onKeyDown={keys(g.key, g.values)}>{option(g.key, value).label}</button>;
        })}
      </div>
      <p className="fine profile-detail" id={`${id}-${g.key}-detail`}>{option(g.key, choice[g.key]).detail}</p>
    </div>)}
  </div>;
}

/** The chat's ⋯ › Answer options: Model, Length, Use for new chats and the link to Settings › AI chat options. Nothing else. */
export function AnswerOptionsDialog({ open, onClose, table, choice, defaultChoice, onChange, onMakeDefault, onRetry, onAbout }: {
  open: boolean; onClose: () => void; table: ProfileTable | null; choice: ProfileChoice; defaultChoice: ProfileChoice;
  onChange: (choice: ProfileChoice) => void; onMakeDefault: (choice: ProfileChoice) => void; onRetry: () => Promise<void>; onAbout: () => void;
}) {
  return <Dialog open={open} onClose={onClose} title="Answer options" className="answer-options">
    <div className="answer-options-body" data-testid="answer-options">
      <div className="profile-panel-heading"><h2>Answer options</h2>
        <button type="button" className="icon-button" aria-label="Close" onClick={onClose}><Icon name="close" size={14} /></button></div>
      <ChoicePicker table={table} choice={choice} onChange={onChange} autoFocus />
      {!table && <p className="fine">Answer options couldn’t be loaded. Answers use Sonnet · Standard. <RetryOptions onRetry={onRetry} /></p>}
      <div className="answer-options-actions">
        {sameChoice(choice, defaultChoice) ? <span className="fine" data-testid="default-note">New chats start with these.</span>
          : <button type="button" className="secondary small" disabled={!table} onClick={() => onMakeDefault(choice)} data-testid="use-for-new-chats">Use for new chats</button>}
        <button type="button" className="link small" onClick={onAbout} data-testid="about-chat-options">About AI chat options</button>
      </div>
    </div>
  </Dialog>;
}

const range = (e: Estimate) => e.low === e.high ? `${e.low}` : `${e.low}–${e.high}`;

/** Account menu › AI chat options (formerly Chat defaults): what new chats start with in this browser, each model in a
 * little more detail, and the usual credits per question from the server's published estimates. */
export function ChatOptionsDialog({ open, onClose, table, choice, onChange, onRetry, visualAnswers, onVisualAnswers }: {
  open: boolean; onClose: () => void; table: ProfileTable | null; choice: ProfileChoice; onChange: (choice: ProfileChoice) => void; onRetry: () => Promise<void>;
  visualAnswers?: boolean; onVisualAnswers?: (on: boolean) => void;
}) {
  const models = listedModels(table), auto = hasAutoEffort(table);
  return <Dialog open={open} onClose={onClose} title="AI chat options" wide className="chat-options">
    <h2>AI chat options</h2>
    <p className="muted">New chats in this browser start with these. Each chat can change them from its ⋯ menu › Answer options.</p>
    <ChoicePicker table={table} choice={choice} onChange={onChange} autoFocus />
    <p className="fine" data-testid="effort-note">{auto ? 'Effort is chosen automatically for each question: harder questions and longer answers get more thinking.'
      : `Answers use ${effortOption(table, EFFORTS.includes(choice.effort) ? choice.effort : 'low').label.toLowerCase()} effort.`}</p>
    {onVisualAnswers && <label className="check-row"><input type="checkbox" checked={visualAnswers ?? true} onChange={e => onVisualAnswers(e.target.checked)} data-testid="visual-answers" />
      <span>Visual answers <span className="fine">— diagrams and drawn explanations beside answers; off, the assistant answers in prose</span></span></label>}
    {!table && <p className="fine">Answer options couldn’t be loaded. <RetryOptions onRetry={onRetry} /></p>}
    <section className="chat-options-section" aria-labelledby="chat-options-models">
      <h3 id="chat-options-models">Models</h3>
      <dl className="chat-options-models" data-testid="chat-options-models">{models.map(m => <div key={m}>
        <dt>{modelOption(table, m).label}</dt>
        <dd>{modelOption(table, m).detail ? `${modelOption(table, m).detail}. ` : ''}{MODEL_STRENGTHS[m]} <span className="fine">Processed by {modelProvider(table, m)}.</span></dd>
      </div>)}</dl>
    </section>
    {table && <section className="chat-options-section" aria-labelledby="chat-options-credits">
      <h3 id="chat-options-credits">Credits per question</h3>
      <div className="chat-credits-wrap"><table className="chat-credits" data-testid="chat-credits">
        <thead><tr><th scope="col"><span className="sr-only">Model</span></th>{LENGTHS.map(l => <th scope="col" key={l}>{lengthOption(table, l).label}</th>)}</tr></thead>
        <tbody>{models.map(m => <tr key={m}><th scope="row">{modelOption(table, m).label}</th>{LENGTHS.map(l => {
          const e = typicalEstimate(table, m, l);
          return <td key={l}>{e ? <><span className="chat-credits-usual">{range(e)}</span><span className="fine">up to {e.max}</span></> : <span className="fine">—</span>}</td>;
        })}</tr>)}</tbody>
      </table></div>
      <p className="fine">Usually this many credits for one question; “up to” is the most one answer can cost, held before it starts and settled to what it used.{table.note ? ` ${table.note}` : ''}</p>
    </section>}
    <div className="dialog-actions"><button className="primary" onClick={onClose}>Done</button></div>
  </Dialog>;
}

function RetryOptions({ onRetry }: { onRetry: () => Promise<void> }) {
  const [loading, setLoading] = useState(false);
  return <button type="button" className="link small" disabled={loading} onClick={() => {
    setLoading(true); void onRetry().finally(() => setLoading(false));
  }}>{loading ? 'Loading options…' : 'Retry loading options'}</button>;
}
