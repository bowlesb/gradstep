import { type ReactNode, useEffect, useRef } from 'react';

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
