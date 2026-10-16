import { type KeyboardEvent, type ReactNode, useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react';
import { Icon, type IconName } from './icons';

export function Brand({ small = false }: { small?: boolean }) {
  return (
    <div className={small ? 'brand small' : 'brand'}>
      <img src="/brand-icon.svg" alt="" width={small ? 22 : 28} height={small ? 22 : 28} />
      <span>Gradstep</span>
    </div>
  );
}

/** A modal dialog on the native <dialog> element (focus trap, Escape, inert page). */
export function Dialog({ open, onClose, title, children, wide = false, className }: { open: boolean; onClose: () => void; title: string; children: ReactNode; wide?: boolean; className?: string }) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const dialog = ref.current;
    if (!dialog) return;
    if (open && !dialog.open) dialog.showModal();
    if (!open && dialog.open) dialog.close();
  }, [open]);
  return (
    <dialog ref={ref} className={`${wide ? 'dialog wide' : 'dialog'}${className ? ` ${className}` : ''}`} onClose={onClose} onCancel={e => { e.preventDefault(); onClose(); }} aria-label={title}
      onClick={e => { if (e.target === ref.current) onClose(); }}>
      {open && <div className="dialog-body">{children}</div>}
    </dialog>
  );
}

/** An icon button that opens a small menu under it (the chat's ⋯, All chats' ≡): the first item takes focus; arrow
 * keys, Home and End move; Esc closes it (and only it, inside a dialog) and returns focus to the button; Tab or a
 * click elsewhere closes it. `children` gets `close` for items that act. */
export function MenuButton({ icon, label, testID, className, disabled = false, children }: {
  icon: IconName; label: string; testID?: string; className?: string; disabled?: boolean; children: (close: (focus?: boolean) => void) => ReactNode;
}) {
  const [open, setOpen] = useState(false);
  const box = useRef<HTMLDivElement>(null), button = useRef<HTMLButtonElement>(null), menu = useRef<HTMLDivElement>(null);
  const close = useCallback((focus = true) => { setOpen(false); if (focus) button.current?.focus(); }, []);
  useEffect(() => { if (disabled) setOpen(false); }, [disabled]);
  // Fixed to the viewport under the button, so a pane or a dialog's scrolling never clips it.
  useLayoutEffect(() => {
    const m = menu.current, b = button.current;
    if (!open || !m || !b) return;
    const place = () => {
      const r = b.getBoundingClientRect(), below = innerHeight - r.bottom - 12, above = r.top - 12, up = below < 220 && above > below;
      m.style.right = `${Math.max(8, innerWidth - r.right)}px`;
      m.style.maxHeight = `${Math.max(160, up ? above : below)}px`;
      if (up) { m.style.top = ''; m.style.bottom = `${innerHeight - r.top + 6}px`; } else { m.style.bottom = ''; m.style.top = `${r.bottom + 6}px`; }
    };
    place();
    addEventListener('resize', place);
    return () => removeEventListener('resize', place);
  }, [open]);
  useEffect(() => {
    if (!open) return;
    menu.current?.querySelector<HTMLElement>('[role^=menuitem]:not(:disabled)')?.focus();
    const away = (event: PointerEvent) => { if (!box.current?.contains(event.target as Node)) setOpen(false); };
    document.addEventListener('pointerdown', away);
    return () => document.removeEventListener('pointerdown', away);
  }, [open]);
  const keys = (event: KeyboardEvent<HTMLDivElement>) => {
    const items = [...event.currentTarget.querySelectorAll<HTMLElement>('[role^=menuitem]:not(:disabled)')];
    const index = items.indexOf(document.activeElement as HTMLElement);
    if (['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) {
      event.preventDefault();
      items[event.key === 'Home' ? 0 : event.key === 'End' ? items.length - 1 : (index + (event.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length]?.focus();
    } else if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); close(); }
    else if (event.key === 'Tab') setOpen(false);
  };
  return <div className={`menu-anchor${className ? ` ${className}` : ''}`} ref={box}>
    <button ref={button} type="button" className={`icon-button${open ? ' on' : ''}`} aria-haspopup="menu" aria-expanded={open} aria-label={label} title={label}
      data-testid={testID} disabled={disabled} onClick={() => setOpen(o => !o)}
      onKeyDown={event => { if ((event.key === 'ArrowDown' || event.key === 'ArrowUp') && !open) { event.preventDefault(); setOpen(true); } }}><Icon name={icon} /></button>
    {open && <div ref={menu} className="menu popup-menu" role="menu" aria-label={label} onKeyDown={keys}>{children(close)}</div>}
  </div>;
}

export const NOT_YET = 'Not yet available in the browser. Use Gradstep on iPhone, iPad or Mac for this for now.';

/** The Library's Added and Opened columns, to the minute (owner, build 46): "11:02 PM" today, "Yest. 9:14 PM",
 * "Mon 9:14 PM" within the week, "Sep 28, 9:14 PM" this year, "Sep 28, 2025" before (LibraryFormat.tableDate). */
export function formatDateTime(ms: number | null | undefined, now = new Date()): string {
  if (!ms) return '—';
  const date = new Date(ms);
  const day = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  const days = Math.round((day(now) - day(date)) / 86_400_000);
  const time = date.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
  if (days <= 0) return time;
  if (days === 1) return `Yest. ${time}`;
  if (days < 7) return `${date.toLocaleDateString(undefined, { weekday: 'short' })} ${time}`;
  if (date.getFullYear() !== now.getFullYear()) return date.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
  return `${date.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })}, ${time}`;
}
/** The same in a narrow column, on two lines (LibraryFormat.tableDateLines): the day ("Today", "Yest.", "Mon", "Sep 28")
 * and the time under it; an earlier year's date ("Sep 2025") has no time. */
export function dateLines(ms: number, now = new Date()): { day: string; time: string | null } {
  const date = new Date(ms);
  const start = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  const days = Math.round((start(now) - start(date)) / 86_400_000);
  const time = date.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
  if (date.getFullYear() !== now.getFullYear() && days >= 7) return { day: date.toLocaleDateString(undefined, { month: 'short', year: 'numeric' }), time: null };
  const day = days <= 0 ? 'Today' : days === 1 ? 'Yest.' : days < 7 ? date.toLocaleDateString(undefined, { weekday: 'short' }) : date.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
  return { day, time };
}
export function formatDate(ms: number | null | undefined): string {
  if (!ms) return '—';
  const date = new Date(ms), now = new Date();
  const sameYear = date.getFullYear() === now.getFullYear();
  return date.toLocaleDateString(undefined, sameYear ? { month: 'short', day: 'numeric' } : { year: 'numeric', month: 'short', day: 'numeric' });
}
