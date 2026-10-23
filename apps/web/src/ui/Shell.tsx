// The large-screen workspace from the legacy app (reference/web/app/page.tsx): a left rail (library
// filters, or the paper's contents and the library), the center view, and the chat on the right.
// Panes resize by dragging their divider, collapse to the legacy edge handles, and remember their
// widths and visibility per route in this browser. Narrow windows show the side panes as drawers.
import { type ReactNode, createContext, useCallback, useContext, useEffect, useRef, useState } from 'react';
import { Icon } from './icons';
import { PANE_LIMITS, type Route, clampWidth, paneWanted, usePaneLayout } from './prefs';

type Side = 'left' | 'right';
export interface PaneState { open: boolean; inline: boolean; width: number }
export type WorkspaceControls = ReturnType<typeof useWorkspace>;

const LEFT_INLINE = 760, RIGHT_INLINE = 1100;

export function useWorkspace(route: Route) {
  const { layout, setWidth, setOpen, reset } = usePaneLayout();
  const [width, setViewport] = useState(() => (typeof innerWidth === 'number' ? innerWidth : 1280));
  const [overlay, setOverlay] = useState<Side | null>(null);
  const observer = useRef<ResizeObserver | null>(null);
  const measure = useCallback((element: HTMLElement | null) => {
    observer.current?.disconnect();
    if (!element) return;
    observer.current = new ResizeObserver(([entry]) => setViewport(Math.round(entry.contentRect.width)));
    observer.current.observe(element);
  }, []);
  useEffect(() => setOverlay(null), [route]);

  const wanted = { left: paneWanted(layout, route, 'left', width), right: paneWanted(layout, route, 'right', width) };
  const leftInline = width >= LEFT_INLINE;
  const leftOpen = leftInline ? wanted.left : overlay === 'left';
  let rightInline = width >= RIGHT_INLINE, left = layout.left, right = layout.right;
  // The paper keeps a readable width: the chat narrows first, then becomes a drawer.
  if (leftInline && leftOpen) left = Math.max(PANE_LIMITS.left.min, Math.min(left, width - PANE_LIMITS.center - (rightInline && wanted.right ? PANE_LIMITS.right.min : 0)));
  if (rightInline && wanted.right) {
    const room = width - (leftInline && leftOpen ? left : 0) - PANE_LIMITS.center;
    if (room < PANE_LIMITS.right.min) rightInline = false; else right = Math.min(right, room);
  }
  const rightOpen = rightInline ? wanted.right : overlay === 'right';
  const state: Record<Side, PaneState> = { left: { open: leftOpen, inline: leftInline, width: left }, right: { open: rightOpen, inline: rightInline, width: right } };

  const show = useCallback((side: Side, open = true) => {
    if (state[side].inline) setOpen(route, side, open);
    else setOverlay(current => (open ? side : current === side ? null : current));
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [route, setOpen, leftInline, rightInline]);
  const toggle = useCallback((side: Side) => show(side, !state[side].open),
  // eslint-disable-next-line react-hooks/exhaustive-deps
    [show, leftOpen, rightOpen]);
  return { route, width, left: state.left, right: state.right, overlay: overlay !== null && !state[overlay].inline ? overlay : null,
    show, toggle, setWidth, reset, measure };
}

const WorkspaceContext = createContext<WorkspaceControls | null>(null);
export const useWorkspaceControls = () => useContext(WorkspaceContext);

export function Workspace({ controls, left, center, right, leftLabel, rightLabel }: {
  controls: WorkspaceControls; left: ReactNode; center: ReactNode; right: ReactNode; leftLabel: string; rightLabel: string;
}) {
  const [preview, setPreview] = useState<{ side: Side; width: number } | null>(null);
  const width = (side: Side) => (preview?.side === side ? preview.width : controls[side].width);
  // A screen with nothing for its side panel yet (an empty library) passes null: no pane, divider or edge handle.
  const has = { left: left !== null, right: right !== null };
  const pane = (side: Side, content: ReactNode, label: string) => {
    const state = controls[side];
    if (!state.open || !has[side]) return null;
    return (
      <aside className={`pane pane-${side}${state.inline ? '' : ' overlay'}`} style={{ width: state.inline ? width(side) : undefined }} aria-label={label} data-testid={`pane-${side}`}>
        {content}
      </aside>
    );
  };
  return (
    <WorkspaceContext.Provider value={controls}>
      <div className="workspace" ref={controls.measure}>
        {pane('left', left, leftLabel)}
        {has.left && controls.left.open && controls.left.inline && (
          <Splitter side="left" label={`Resize ${leftLabel.toLowerCase()}`} width={width('left')} onPreview={setPreview}
            onCommit={w => { setPreview(null); if (w === null) controls.show('left', false); else controls.setWidth('left', w); }} onReset={() => controls.reset('left')} />
        )}
        <main className="pane-center" id="main">{center}</main>
        {has.right && controls.right.open && controls.right.inline && (
          <Splitter side="right" label={`Resize ${rightLabel.toLowerCase()}`} width={width('right')} onPreview={setPreview}
            onCommit={w => { setPreview(null); if (w === null) controls.show('right', false); else controls.setWidth('right', w); }} onReset={() => controls.reset('right')} />
        )}
        {pane('right', right, rightLabel)}
        {has.left && controls.left.inline && !controls.left.open && <CollapseHandle side="left" label={`Show ${leftLabel.toLowerCase()}`} onClick={() => controls.show('left')} />}
        {has.right && controls.right.inline && !controls.right.open && <CollapseHandle side="right" label={`Show ${rightLabel.toLowerCase()}`} onClick={() => controls.show('right')} />}
        {controls.overlay && has[controls.overlay] && <div className="scrim" onClick={() => controls.show(controls.overlay!, false)} aria-hidden="true" />}
      </div>
    </WorkspaceContext.Provider>
  );
}

/** A pane divider: drag (pointer captured, so the paper frame can't swallow it), arrow keys, double-click for the default width.
 * Dragging well past the minimum collapses the pane, as the legacy panels did. */
function Splitter({ side, label, width, onPreview, onCommit, onReset }: {
  side: Side; label: string; width: number; onPreview: (p: { side: Side; width: number } | null) => void; onCommit: (width: number | null) => void; onReset: () => void;
}) {
  const drag = useRef<{ x: number; width: number; latest: number; collapse: boolean } | null>(null);
  const frame = useRef(0);
  const limits = PANE_LIMITS[side];
  const sign = side === 'left' ? 1 : -1;
  const end = (commit: boolean) => {
    const state = drag.current;
    drag.current = null; cancelAnimationFrame(frame.current);
    document.documentElement.classList.remove('resizing');
    if (!state) return;
    if (commit) onCommit(state.collapse ? null : state.latest); else onPreview(null);
  };
  return (
    <div className={`splitter splitter-${side}`} role="separator" aria-orientation="vertical" aria-label={label} tabIndex={0}
      aria-valuemin={limits.min} aria-valuemax={limits.max} aria-valuenow={Math.round(width)} title="Drag to resize · double-click for the default width"
      onPointerDown={event => {
        if (event.button !== 0) return;
        event.preventDefault();
        event.currentTarget.setPointerCapture(event.pointerId);
        drag.current = { x: event.clientX, width, latest: width, collapse: false };
        document.documentElement.classList.add('resizing');
      }}
      onPointerMove={event => {
        const state = drag.current;
        if (!state) return;
        const raw = state.width + sign * (event.clientX - state.x);
        state.collapse = raw < limits.min - 64;
        state.latest = clampWidth(side, raw);
        cancelAnimationFrame(frame.current);
        frame.current = requestAnimationFrame(() => onPreview({ side, width: state.latest }));
      }}
      onPointerUp={() => end(true)} onPointerCancel={() => end(false)} onLostPointerCapture={() => { if (drag.current) end(true); }}
      onDoubleClick={onReset}
      onKeyDown={event => {
        const step = event.shiftKey ? 64 : 16;
        if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') {
          event.preventDefault();
          onCommit(clampWidth(side, width + (event.key === 'ArrowRight' ? step : -step) * sign));
        } else if (event.key === 'Home' || event.key === 'End') {
          event.preventDefault();
          onCommit((event.key === 'Home') === (side === 'left') ? limits.min : limits.max);
        } else if (event.key === 'Enter') { event.preventDefault(); onCommit(null); }
      }} />
  );
}

/** The legacy edge tab that brings a collapsed pane back. */
function CollapseHandle({ side, label, onClick }: { side: Side; label: string; onClick: () => void }) {
  return <button className={`collapse-handle collapse-${side}`} onClick={onClick} aria-label={label} title={label}><span aria-hidden="true">⋮⋮</span></button>;
}

/** A small header row inside a pane. */
export function PaneHeader({ title, children, onClose, closeLabel }: { title: ReactNode; children?: ReactNode; onClose?: () => void; closeLabel?: string }) {
  return (
    <div className="pane-header">
      <div className="pane-title">{title}</div>
      <div className="pane-actions">
        {children}
        {onClose && <button className="icon-button" onClick={onClose} aria-label={closeLabel ?? 'Hide'} title={closeLabel ?? 'Hide'}><Icon name="close" size={14} /></button>}
      </div>
    </div>
  );
}
