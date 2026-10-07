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
export function Dialog({ open, onClose, title, children, wide = false }: { open: boolean; onClose: () => void; title: string; children: ReactNode; wide?: boolean }) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const dialog = ref.current;
    if (!dialog) return;
    if (open && !dialog.open) dialog.showModal();
    if (!open && dialog.open) dialog.close();
  }, [open]);
  return (
    <dialog ref={ref} className={wide ? 'dialog wide' : 'dialog'} onClose={onClose} onCancel={e => { e.preventDefault(); onClose(); }} aria-label={title}
      onClick={e => { if (e.target === ref.current) onClose(); }}>
      {open && <div className="dialog-body">{children}</div>}
    </dialog>
  );
}

export const NOT_YET = 'Not yet available in the browser. Use Gradstep on iPhone, iPad or Mac for this for now.';

export function formatDate(ms: number | null | undefined): string {
  if (!ms) return '—';
  const date = new Date(ms), now = new Date();
  const sameYear = date.getFullYear() === now.getFullYear();
  return date.toLocaleDateString(undefined, sameYear ? { month: 'short', day: 'numeric' } : { year: 'numeric', month: 'short', day: 'numeric' });
}
