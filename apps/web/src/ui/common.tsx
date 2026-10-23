import { type KeyboardEvent, type ReactNode, createContext, useCallback, useContext, useEffect, useId, useLayoutEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { Icon, type IconName } from './icons';
import './screen-options.css';

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
    <dialog ref={ref} className={`${wide ? 'dialog wide' : 'dialog'}${className ? ` ${className}` : ''}`}
      onClose={e => { if (e.target === e.currentTarget) onClose(); }}
      onCancel={e => { if (e.target === e.currentTarget) { e.preventDefault(); e.stopPropagation(); onClose(); } }} aria-label={title}
      onClick={e => { if (e.target === ref.current) onClose(); }}>
      {open && <div className="dialog-body">{children}</div>}
    </dialog>
  );
}

/** An icon button that opens a small menu under it (the chat's ⋯, All chats' ≡): the first item takes focus; arrow
 * keys, Home and End move; Esc closes it (and only it, inside a dialog) and returns focus to the button; Tab or a
 * click elsewhere closes it. `children` gets `close` for items that act. */
export function MenuButton({ icon, label, testID, className, disabled = false, text, align = 'end', children }: {
  icon: IconName; label: string; testID?: string; className?: string; disabled?: boolean;
  /** A title menu (an explainer's "Figure 3 ⌄"): the words with a chevron instead of the icon. */
  text?: string;
  /** Which edge of the button the menu lines up with: `start` for a control at a row's start. */
  align?: 'start' | 'end';
  children: (close: (focus?: boolean) => void) => ReactNode;
}) {
  const [open, setOpen] = useState(false);
  // A submenu (SubMenu) shows in the menu's place, with a Back row at its top (the apps' nested menus).
  const [sub, setSub] = useState<string | null>(null);
  const [slot, setSlot] = useState<HTMLDivElement | null>(null);
  const lastSub = useRef<string | null>(null);
  const box = useRef<HTMLDivElement>(null), button = useRef<HTMLButtonElement>(null), menu = useRef<HTMLDivElement>(null);
  const close = useCallback((focus = true) => { setOpen(false); setSub(null); if (focus) button.current?.focus(); }, []);
  useEffect(() => { if (disabled) { setOpen(false); setSub(null); } }, [disabled]);
  useEffect(() => { if (!open) setSub(null); }, [open]);
  // Fixed to the viewport under the button, so a pane or a dialog's scrolling never clips it.
  useLayoutEffect(() => {
    const m = menu.current, b = button.current;
    if (!open || !m || !b) return;
    const place = () => {
      const r = b.getBoundingClientRect(), below = innerHeight - r.bottom - 12, above = r.top - 12, up = below < 220 && above > below;
      if (align === 'start') { m.style.right = ''; m.style.left = `${Math.max(8, Math.min(r.left, innerWidth - m.offsetWidth - 8))}px`; }
      else { m.style.left = ''; m.style.right = `${Math.max(8, innerWidth - r.right)}px`; }
      m.style.maxHeight = `${Math.max(160, up ? above : below)}px`;
      if (up) { m.style.top = ''; m.style.bottom = `${innerHeight - r.top + 6}px`; } else { m.style.bottom = ''; m.style.top = `${r.bottom + 6}px`; }
    };
    place();
    addEventListener('resize', place);
    return () => removeEventListener('resize', place);
  }, [open, align]);
  useEffect(() => {
    if (!open) return;
    const away = (event: PointerEvent) => { if (!box.current?.contains(event.target as Node)) setOpen(false); };
    document.addEventListener('pointerdown', away);
    return () => document.removeEventListener('pointerdown', away);
  }, [open]);
  // Focus: the first item when the menu opens; a submenu's current choice (or its first choice) when it opens; the row
  // that opened it on Back.
  useEffect(() => {
    if (!open) { lastSub.current = null; return; }
    const m = menu.current;
    if (sub && slot) {
      const items = [...slot.querySelectorAll<HTMLElement>('[role^=menuitem]:not(:disabled)')];
      (items.find(e => e.getAttribute('aria-checked') === 'true') ?? items[1] ?? items[0])?.focus();
    } else if (!sub && lastSub.current) {
      [...(m?.querySelectorAll<HTMLElement>('[data-submenu]') ?? [])].find(e => e.dataset.submenu === lastSub.current)?.focus();
    } else if (!sub) m?.querySelector<HTMLElement>('[role^=menuitem]:not(:disabled)')?.focus();
    lastSub.current = sub;
  }, [open, sub, slot]);
  const keys = (event: KeyboardEvent<HTMLDivElement>) => {
    const items = [...event.currentTarget.querySelectorAll<HTMLElement>('[role^=menuitem]:not(:disabled)')].filter(e => e.getClientRects().length > 0);
    const index = items.indexOf(document.activeElement as HTMLElement);
    const focused = document.activeElement as HTMLElement | null;
    if (['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) {
      event.preventDefault();
      items[event.key === 'Home' ? 0 : event.key === 'End' ? items.length - 1 : (index + (event.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length]?.focus();
    } else if (event.key === 'ArrowRight' && focused?.dataset.submenu) { event.preventDefault(); setSub(focused.dataset.submenu); }
    else if ((event.key === 'ArrowLeft' || event.key === 'Escape') && sub) { event.preventDefault(); event.stopPropagation(); setSub(null); }
    else if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); close(); }
    else if (event.key === 'Tab') setOpen(false);
  };
  return <div className={`menu-anchor${className ? ` ${className}` : ''}`} ref={box}>
    <button ref={button} type="button" className={`${text ? 'title-menu-button' : 'icon-button'}${open ? ' on' : ''}`} aria-haspopup="menu" aria-expanded={open} aria-label={label} title={label}
      data-testid={testID} disabled={disabled} onClick={() => setOpen(o => !o)}
      onKeyDown={event => { if ((event.key === 'ArrowDown' || event.key === 'ArrowUp') && !open) { event.preventDefault(); setOpen(true); } }}>
      {text ? <><span>{text}</span><Icon name="chevronDown" size={14} /></> : <Icon name={icon} />}</button>
    {open && <div ref={menu} className="menu popup-menu" role="menu" aria-label={label} onKeyDown={keys}>
      <SubMenuContext.Provider value={{ active: sub, open: setSub, slot }}>
        <div className="menu-main" hidden={!!sub}>{children(close)}</div>
        {sub && <div ref={setSlot} className="menu-main submenu-slot" />}
      </SubMenuContext.Provider>
    </div>}
  </div>;
}

const SubMenuContext = createContext<{ active: string | null; open: (label: string | null) => void; slot: HTMLDivElement | null } | null>(null);

/** A row of a MenuButton's menu that opens a submenu in the menu's place: its words, the current choice in grey and a
 * chevron (the apps' "Sort by › Added"). ArrowRight or a click opens it; its Back row, ArrowLeft or Esc return. */
export function SubMenu({ label, value, icon, testID, children }: { label: string; value?: string; icon?: IconName; testID?: string; children: ReactNode }) {
  const context = useContext(SubMenuContext);
  const trigger = <button type="button" role="menuitem" aria-haspopup="menu" className="menu-item menu-sub" onClick={() => context?.open(label)} data-submenu={label} data-testid={testID}>
    {icon && <Icon name={icon} size={14} />}<span className="menu-sub-label">{label}</span>{value && <span className="menu-sub-value">{value}</span>}<Icon name="chevronRight" size={14} /></button>;
  if (context?.active !== label || !context.slot) return trigger;
  return <>{trigger}{createPortal(<div className="submenu-page" role="group" aria-label={label} data-testid={testID ? `${testID}-menu` : undefined}>
    <button type="button" role="menuitem" className="menu-item menu-back" onClick={() => context.open(null)} aria-label={`Back from ${label}`}>
      <Icon name="chevronLeft" size={14} /><span>{label}</span></button>
    {children}
  </div>, context.slot)}</>;
}

/** A menu row with a check: one of a submenu's choices (radio), or an on/off option (checkbox). */
export function MenuCheck({ checked, radio = false, onClick, children, testID, disabled = false }: { checked: boolean; radio?: boolean; onClick: () => void; children: ReactNode; testID?: string; disabled?: boolean }) {
  return <button type="button" role={radio ? 'menuitemradio' : 'menuitemcheckbox'} aria-checked={checked} className="menu-item menu-check" onClick={onClick} data-testid={testID} disabled={disabled}>
    <span className="menu-check-mark" aria-hidden="true">{checked ? '✓' : ''}</span><span>{children}</span></button>;
}

/** An information sheet's one top row (owner, build 62; docs/DESIGN.md "Sheet top row"): its controls at the start —
 * a title menu, the page's actions — and a round close X at the end. No Done, no separate action bar. */
export function SheetTop({ children, onClose, closeLabel = 'Close', closeDisabled = false, testID, trailing }: {
  children?: ReactNode; onClose: () => void; closeLabel?: string; closeDisabled?: boolean; testID?: string; trailing?:ReactNode;
}) {
  return <header className="sheet-top">
    <div className="sheet-top-start">{children}</div>
    {trailing}
    <button type="button" className="icon-button sheet-close" onClick={onClose} disabled={closeDisabled} aria-label={closeLabel} title={closeLabel}
      data-testid={testID}><Icon name="close" /></button>
  </header>;
}

/** An ⓘ just to the right of a row's words (owner, build 57: descriptive sentences behind an info icon): a click or
 * Enter shows the text in a small popover, Esc or a click elsewhere hides it; screen readers hear it as the button's
 * description either way. */
export function InfoTip({ text, testID, label = 'More information' }: { text: ReactNode; testID?: string; label?: string }) {
  const [open, setOpen] = useState(false);
  const box = useRef<HTMLSpanElement>(null), note = useRef<HTMLSpanElement>(null), id = useId();
  // Kept inside the dialog (or the box marked `data-info-bounds`, or the window) it opens in: shifted left when it would
  // run past the right edge.
  useLayoutEffect(() => {
    const n = note.current; if (!n) return;
    n.style.left = ''; n.style.top = ''; n.style.bottom = '';
    if (!open) return;
    const frame = (n.closest('dialog, [data-info-bounds]') ?? document.documentElement).getBoundingClientRect(), r = n.getBoundingClientRect();
    const over = r.right - (Math.min(frame.right, innerWidth) - 12);
    if (over > 0) n.style.left = `${-6 - Math.min(over, r.left - Math.max(frame.left, 0) - 12)}px`;
    // Above its ⓘ when it would run past the bottom of its dialog (or window) and there is room above.
    const bottom = Math.min(frame.bottom, innerHeight) - 12, top = Math.max(frame.top, 0) + 12, button = n.parentElement!.getBoundingClientRect();
    if (r.bottom > bottom && button.top - r.height - 4 >= top) { n.style.top = 'auto'; n.style.bottom = 'calc(100% + 4px)'; }
  }, [open]);
  useEffect(() => {
    if (!open) return;
    const away = (event: PointerEvent) => { if (!box.current?.contains(event.target as Node)) setOpen(false); };
    document.addEventListener('pointerdown', away);
    return () => document.removeEventListener('pointerdown', away);
  }, [open]);
  return <span className="info-tip" ref={box}>
    <button type="button" className="info-tip-button" aria-label={label} aria-expanded={open} aria-describedby={id} data-testid={testID}
      onClick={event => { event.preventDefault(); event.stopPropagation(); setOpen(o => !o); }}
      onKeyDown={event => { if (event.key === 'Escape' && open) { event.preventDefault(); event.stopPropagation(); setOpen(false); } }}><Icon name="info" size={14} /></button>
    {/* The rest of the screen darkens while the bubble shows (owner, build 59: "so the bubble text stands out"); a
        press on it hides the bubble. */}
    {open && <span className="info-scrim" aria-hidden="true" data-testid="info-scrim" onPointerDown={event => event.preventDefault()}
      onClick={event => { event.preventDefault(); event.stopPropagation(); setOpen(false); }} />}
    <span id={id} ref={note} role="note" className={open ? 'info-tip-text open' : 'info-tip-text'}>{text}</span>
  </span>;
}


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
