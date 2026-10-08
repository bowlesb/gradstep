// Model, effort and length for a chat (owner request 2026-10-08), the browser's version of the app's composer control:
// a compact button in the composer row ("Sonnet · Low · Standard") that opens a small panel, and the same choices as
// this browser's default for new chats. Estimates and labels come from the server's published table; nothing here
// decides a price or limit (the chat function holds and charges).
import { type KeyboardEvent, useEffect, useId, useRef, useState } from 'react';
import { EFFORTS, effortOption, LENGTHS, lengthOption, MODELS, modelOption, offers, profileSummary, sameProfile, tableEstimate,
  type ProfileChoice, type ProfileTable } from '../lib/chat-profiles';
import { Dialog } from './common';
import { Icon } from './icons';

type Group = 'model' | 'effort' | 'length';
const GROUPS: { key: Group; title: string; values: readonly string[] }[] = [
  { key: 'model', title: 'Model', values: MODELS }, { key: 'effort', title: 'Effort', values: EFFORTS }, { key: 'length', title: 'Length', values: LENGTHS },
];
const option = (table: ProfileTable | null, group: Group, value: string) => group === 'model' ? modelOption(table, value as ProfileChoice['model'])
  : group === 'effort' ? effortOption(table, value as ProfileChoice['effort']) : lengthOption(table, value as ProfileChoice['length']);

/** Three single-choice groups, each a radiogroup with arrow-key movement, and the live estimate for the choice. */
export function ProfilePicker({ table, choice, onChange, autoFocus = false }: {
  table: ProfileTable | null; choice: ProfileChoice; onChange: (choice: ProfileChoice) => void; autoFocus?: boolean;
}) {
  const id = useId(), first = useRef<HTMLButtonElement>(null);
  useEffect(() => { if (autoFocus) first.current?.focus(); }, [autoFocus]);
  const estimate = tableEstimate(table, choice);
  const pick = (group: Group, value: string) => {
    const next = { ...choice, [group]: value } as ProfileChoice;
    if (table && offers(table, next)) onChange(next);
  };
  const keys = (group: Group, values: readonly string[]) => (e: KeyboardEvent<HTMLButtonElement>) => {
    const step = e.key === 'ArrowRight' || e.key === 'ArrowDown' ? 1 : e.key === 'ArrowLeft' || e.key === 'ArrowUp' ? -1 : 0;
    if (!step) return;
    e.preventDefault();
    const index = values.indexOf(choice[group]), next = values[(index + step + values.length) % values.length];
    pick(group, next);
    const container = e.currentTarget.parentElement;
    requestAnimationFrame(() => container?.querySelector<HTMLButtonElement>(`[data-value="${next}"]`)?.focus());
  };
  return <div className="profile-picker">
    {GROUPS.map((g, gi) => <div className="profile-group" key={g.key}>
      <div className="profile-group-title" id={`${id}-${g.key}`}>{g.title}</div>
      <div className="profile-options" role="radiogroup" aria-labelledby={`${id}-${g.key}`} aria-describedby={`${id}-${g.key}-detail`}>
        {g.values.map(value => {
          const checked = choice[g.key] === value, possible = !!table && offers(table, { ...choice, [g.key]: value } as ProfileChoice);
          return <button key={value} type="button" role="radio" aria-checked={checked} data-value={value} tabIndex={checked ? 0 : -1}
            ref={gi === 0 && checked ? first : undefined} className={checked ? 'seg on' : 'seg'} disabled={!possible && !checked}
            onClick={() => pick(g.key, value)} onKeyDown={keys(g.key, g.values)}>{option(table, g.key, value).label}</button>;
        })}
      </div>
      <p className="fine profile-detail" id={`${id}-${g.key}-detail`}>{option(table, g.key, choice[g.key]).detail}</p>
    </div>)}
    <div className="profile-estimate" aria-live="polite" data-testid="profile-estimate">
      {estimate ? <strong>{estimate}</strong> : <span className="fine">{table ? 'Not offered right now.' : 'Answer options couldn’t be loaded. Answers use Sonnet · Low · Standard.'}</span>}
      {table?.note && <p className="fine">{table.note}</p>}
    </div>
  </div>;
}

/** The composer's control and its panel. */
export function ProfileControl({ table, choice, defaultChoice, onChange, onMakeDefault, disabled = false }: {
  table: ProfileTable | null; choice: ProfileChoice; defaultChoice: ProfileChoice; onChange: (choice: ProfileChoice) => void;
  onMakeDefault: (choice: ProfileChoice) => void; disabled?: boolean;
}) {
  const [open, setOpen] = useState(false);
  const box = useRef<HTMLDivElement>(null), button = useRef<HTMLButtonElement>(null), panelID = useId();
  const close = (focus = true) => { setOpen(false); if (focus) button.current?.focus(); };
  useEffect(() => {
    if (!open) return;
    const away = (event: Event) => { if (!box.current?.contains(event.target as Node)) setOpen(false); };
    const key = (event: globalThis.KeyboardEvent) => { if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); close(); } };
    document.addEventListener('pointerdown', away); document.addEventListener('keydown', key, true);
    return () => { document.removeEventListener('pointerdown', away); document.removeEventListener('keydown', key, true); };
  }, [open]);
  const summary = profileSummary(choice, table), isDefault = sameProfile(choice, defaultChoice);
  return <div className="profile-control" ref={box}>
    <button ref={button} type="button" className="profile-button" aria-haspopup="dialog" aria-expanded={open} aria-controls={open ? panelID : undefined}
      disabled={disabled} onClick={() => setOpen(o => !o)} data-testid="profile-button"
      aria-label={`Answer settings: ${summary}`} title={table ? 'Model, effort and length for this chat' : 'Answer options are unavailable'}>
      <span className="profile-button-text">{summary}</span><Icon name="chevronUp" size={12} />
    </button>
    {open && <div className="profile-panel" role="dialog" id={panelID} aria-label="Answers in this chat" data-testid="profile-panel">
      <div className="profile-panel-heading"><strong>Answers in this chat</strong>
        <button type="button" className="icon-button" aria-label="Close" onClick={() => close()}><Icon name="close" size={14} /></button></div>
      <ProfilePicker table={table} choice={choice} onChange={onChange} autoFocus />
      <div className="profile-panel-actions">
        {isDefault ? <span className="fine">Default for new chats</span>
          : <button type="button" className="link small" disabled={!table} onClick={() => onMakeDefault(choice)}>Use as default for new chats</button>}
      </div>
    </div>}
  </div>;
}

/** Account menu › Chat defaults: the choice new chats start with in this browser. */
export function ChatDefaultsDialog({ open, onClose, table, choice, onChange }: {
  open: boolean; onClose: () => void; table: ProfileTable | null; choice: ProfileChoice; onChange: (choice: ProfileChoice) => void;
}) {
  return <Dialog open={open} onClose={onClose} title="Chat defaults">
    <h2>Chat defaults</h2>
    <p className="muted">New chats in this browser start with these. Each chat can change them from its message box; a chat keeps the choice its answers used.</p>
    <ProfilePicker table={table} choice={choice} onChange={onChange} autoFocus />
    <div className="dialog-actions"><button className="primary" onClick={onClose}>Done</button></div>
  </Dialog>;
}
