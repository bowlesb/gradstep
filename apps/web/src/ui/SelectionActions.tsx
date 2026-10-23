// A selection's actions in the paper (owner, 2026-10-22: "What I noticed didn't work well on web was those 5 options
// sitting in the middle of the paper at the bottom"). A compact one-line glass capsule anchored to the selection, like
// the system edit menu: just above the selected text, or just below it near the top of the paper's view, centred on it
// and kept inside the paper's column; it follows the selection as the paper scrolls and never pushes content. It holds
// the first action, Save snippet and ⋯ (the rest). Right-click on a selection shows every action as a context menu.
// Below 600 px it docks at the bottom of the paper as the same one-line capsule (the iPhone app's place).
import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import { MenuButton } from './common';

export interface SelectionItem { key: string; label: string; testID?: string; run: () => void }
/** The selection's box and the paper's text column, in the paper frame's coordinates (frame-shim.js `selectionRect`). */
export interface SelectionGeometry { rect: [number, number, number, number]; column: [number, number] }

const MARGIN = 8, GAP = 8;
/** Where the capsule goes: centred over the selection, clamped to the column (and the stage), above it unless that would
 * leave the top of the view, then below; null while the selection is scrolled out of view. */
export function placeCapsule(selection: { x: number; y: number; w: number; h: number }, column: [number, number], stage: { w: number; h: number },
  size: { w: number; h: number }): { left: number; top: number } | null {
  if (selection.y + selection.h < 0 || selection.y > stage.h) return null;
  const min = Math.max(MARGIN, column[0]), max = Math.min(stage.w - MARGIN, column[1]);
  const left = Math.max(min, Math.min(selection.x + selection.w / 2 - size.w / 2, max - size.w));
  let top = selection.y - size.h - GAP;
  if (top < MARGIN) top = selection.y + selection.h + GAP;
  return { left: Math.max(MARGIN, left), top: Math.max(MARGIN, Math.min(top, stage.h - size.h - MARGIN)) };
}

export function SelectionActions({ label, items, more, geometry, docked, context, contextItems, onContextClose }: {
  label: string; items: SelectionItem[]; more: SelectionItem[]; geometry: SelectionGeometry | null; docked: boolean;
  /** A right-click on the selection, in the page's coordinates. */ context: { x: number; y: number } | null;
  contextItems: SelectionItem[]; onContextClose: () => void;
}) {
  const bar = useRef<HTMLDivElement>(null);
  const [place, setPlace] = useState<{ left: number; top: number } | null>(null);
  const anchored = !docked && !!geometry;
  useLayoutEffect(() => {
    const element = bar.current, stage = element?.parentElement;
    if (!anchored || !element || !stage || !geometry) { setPlace(null); return; }
    const [x, y, w, h] = geometry.rect;
    setPlace(placeCapsule({ x, y, w, h }, geometry.column, { w: stage.clientWidth, h: stage.clientHeight }, { w: element.offsetWidth, h: element.offsetHeight }));
  }, [anchored, geometry, items.length, more.length]);
  return <>
    <div ref={bar} className={`selection-bar selection-capsule${anchored ? ' anchored' : ' docked'}`} role="toolbar" aria-label={label} data-testid="selection-actions"
      style={anchored ? (place ? { left: place.left, top: place.top } : { visibility: 'hidden' }) : undefined}>
      {items.map(item => <button key={item.key} type="button" data-testid={item.testID} onClick={item.run}>{item.label}</button>)}
      {more.length > 0 && <MenuButton icon="more" label="More actions" testID="selection-more">{close => more.map(item =>
        <button key={item.key} type="button" role="menuitem" className="menu-item" data-testid={item.testID} onClick={() => { close(false); item.run(); }}>{item.label}</button>)}</MenuButton>}
    </div>
    {context && <SelectionMenu at={context} items={contextItems} label={label} onClose={onContextClose} />}
  </>;
}

/** Right-click on a selection: every action in a small menu at the pointer (Esc, a click elsewhere or a choice closes it). */
function SelectionMenu({ at, items, label, onClose }: { at: { x: number; y: number }; items: SelectionItem[]; label: string; onClose: () => void }) {
  const menu = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const m = menu.current; if (!m) return;
    m.style.left = `${Math.max(8, Math.min(at.x, innerWidth - m.offsetWidth - 8))}px`;
    m.style.top = `${Math.max(8, Math.min(at.y, innerHeight - m.offsetHeight - 8))}px`;
    m.querySelector<HTMLElement>('[role=menuitem]')?.focus();
  }, [at]);
  useEffect(() => {
    const away = (event: PointerEvent) => { if (!menu.current?.contains(event.target as Node)) onClose(); };
    const key = (event: KeyboardEvent) => { if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); onClose(); } };
    document.addEventListener('pointerdown', away); document.addEventListener('keydown', key, true); addEventListener('blur', onClose);
    return () => { document.removeEventListener('pointerdown', away); document.removeEventListener('keydown', key, true); removeEventListener('blur', onClose); };
  }, [onClose]);
  const keys = (event: React.KeyboardEvent<HTMLDivElement>) => {
    const all = [...event.currentTarget.querySelectorAll<HTMLElement>('[role=menuitem]')], i = all.indexOf(document.activeElement as HTMLElement);
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') { event.preventDefault(); all[(i + (event.key === 'ArrowDown' ? 1 : -1) + all.length) % all.length]?.focus(); }
  };
  return <div ref={menu} className="menu popup-menu selection-context-menu" role="menu" aria-label={label} onKeyDown={keys} data-testid="selection-context-menu" style={{ left: at.x, top: at.y }}>
    {items.map(item => <button key={item.key} type="button" role="menuitem" className="menu-item" onClick={() => { onClose(); item.run(); }}>{item.label}</button>)}
  </div>;
}
