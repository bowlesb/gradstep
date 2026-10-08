import { defaultRangeExtractor, type Range, type VirtualItem, useVirtualizer } from '@tanstack/react-virtual';
import { Fragment, type KeyboardEvent, type ReactNode, type RefObject, useCallback, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { flushSync } from 'react-dom';
import type { Row } from '../lib/paper';

interface RowFocus { key: string; control: number }
/** Account-session memory only. No library identities or reading activity are written to storage. */
export interface LibraryViewport {
  query: string; columns: string; width: number; top: number; left: number;
  anchor: string | null; index: number; inset: number; focus: RowFocus | null; measurements: VirtualItem[];
}
export interface LibraryRowsCommands { beforePrint(): void; beforeSequentialNavigation(): void }
export const WINDOW_THRESHOLD = 100;
const controls = 'a[href], button:not(:disabled), input:not(:disabled), select:not(:disabled), [tabindex="0"]';

/** Native rows and gap spacers retain the table's column sizing and sticky title/header cells. */
export function LibraryRows({ rows, scroller, header, query, columns, full, printing, viewport, commands, showAll, render }: {
  rows: Row[]; scroller: RefObject<HTMLDivElement | null>; header: RefObject<HTMLTableSectionElement | null>;
  query: string; columns: readonly string[]; full: boolean; printing: boolean; viewport: RefObject<LibraryViewport | null>;
  commands: RefObject<LibraryRowsCommands | null>; showAll: () => void;
  render: (row: Row, index: number, measure?: (element: HTMLTableRowElement | null) => void) => ReactNode;
}) {
  const body = useRef<HTMLTableSectionElement>(null);
  // Parent host refs attach after child layout effects. A layout-phase follow-up observes the
  // actual scroller before paint, including when this table returns from the reader.
  const [mounted, setMounted] = useState(false);
  useLayoutEffect(() => setMounted(true), []);
  const initial = useRef(viewport.current?.query === query ? viewport.current : null);
  const [focused, setFocused] = useState<string | null>(initial.current?.focus?.key ?? null);
  const [restoringKey, setRestoringKey] = useState<string | null>(initial.current?.anchor ?? null);
  const pendingFocus = useRef<string | null>(null);
  const [headerHeight, setHeaderHeight] = useState(33);
  const active = rows.length >= WINDOW_THRESHOLD && !full;
  const columnKey = columns.join(',');
  const byKey = useMemo(() => new Map(rows.map((row, index) => [row.key, index])), [rows]);
  const getKey = useCallback((index: number) => rows[index].key, [rows]);
  const rangeExtractor = useCallback((range: Range) => {
    const indices = defaultRangeExtractor(range);
    for (const key of [focused, restoringKey]) {
      const index = key ? byKey.get(key) : undefined;
      if (index !== undefined && !indices.includes(index)) indices.push(index);
    }
    return indices.sort((a, b) => a - b);
  }, [byKey, focused, restoringKey]);
  const virtualizer = useVirtualizer<HTMLDivElement, HTMLTableRowElement>({
    count: rows.length, getScrollElement: () => scroller.current, getItemKey: getKey,
    estimateSize: () => 58, overscan: 8, rangeExtractor, enabled: active,
    paddingStart: headerHeight, scrollPaddingStart: headerHeight,
    initialOffset: initial.current?.top ?? 0,
    initialMeasurementsCache: initial.current?.columns === columnKey ? initial.current.measurements : [],
  });
  const live = useRef({ rows, byKey, active, query, columnKey, printing, showAll });
  live.current = { rows, byKey, active, query, columnKey, printing, showAll };
  const restoration = useRef<{ saved: LibraryViewport; key: string; focus: boolean; frame: number; attempts: number; stable: number } | null>(null);
  const printed = useRef<LibraryViewport | null>(null);
  const skipModeRestore = useRef(false);
  const headHeight = useCallback(() => header.current?.getBoundingClientRect().height ?? 33, [header]);
  // The usable fold is below the sticky heading. A measured row hidden behind that heading must
  // compensate scroll just like a row above the physical scroll viewport.
  virtualizer.shouldAdjustScrollPositionOnItemSizeChange = (item, _delta, instance) =>
    item.end <= (instance.scrollOffset ?? 0) + headHeight();

  // Binary search in actual table rows is O(log mounted rows), including in full mode. No complete
  // measurement snapshot, library scan or React state update occurs in the scroll handler.
  const capture = useCallback((snapshot = false) => {
    const element = scroller.current, tableBody = body.current, context = live.current;
    if (!element || !tableBody || context.printing || restoration.current) return viewport.current;
    const edge = element.getBoundingClientRect().top + headHeight(), mounted = tableBody.rows;
    let lo = 0, hi = mounted.length;
    while (lo < hi) { const mid = (lo + hi) >>> 1; if (mounted[mid].getBoundingClientRect().bottom <= edge + 1) lo = mid + 1; else hi = mid; }
    while (lo < mounted.length && !mounted[lo].dataset.rowKey) lo++;
    const row = mounted[lo], key = row?.dataset.rowKey ?? null;
    if (row && row.getBoundingClientRect().top > element.getBoundingClientRect().bottom) return viewport.current;
    const focusedElement = document.activeElement as HTMLElement | null;
    const focusRow = focusedElement?.closest<HTMLElement>('[data-row-key]');
    const focus = focusRow && tableBody.contains(focusRow) ? { key: focusRow.dataset.rowKey!, control: [...focusRow.querySelectorAll(controls)].indexOf(focusedElement!) } : null;
    const previous = viewport.current;
    const measurements = snapshot && context.active ? virtualizer.takeSnapshot()
      : previous?.query === context.query && previous.columns === context.columnKey && previous.width === element.clientWidth ? previous.measurements : [];
    viewport.current = { query: context.query, columns: context.columnKey, width: element.clientWidth, top: element.scrollTop, left: element.scrollLeft,
      anchor: key, index: key ? context.byKey.get(key) ?? 0 : 0, inset: row ? Math.max(0, edge - row.getBoundingClientRect().top) : 0, focus, measurements };
    return viewport.current;
  }, [headHeight, scroller, viewport, virtualizer]);

  const cancelRestore = useCallback(() => {
    if (!restoration.current) return;
    cancelAnimationFrame(restoration.current.frame); restoration.current = null; setRestoringKey(null);
  }, []);
  const beforeSequentialNavigation = useCallback(() => {
    if (!live.current.active) return;
    cancelRestore(); skipModeRestore.current = true;
    flushSync(live.current.showAll);
  }, [cancelRestore]);
  const restore = useCallback((saved: LibraryViewport | null, focus = false) => {
    cancelRestore();
    const context = live.current, element = scroller.current;
    if (!saved || !element || saved.query !== context.query || context.printing || !context.rows.length) return;
    // A removed anchor falls back to the row now at its old logical position, bounded by the new list.
    const index = (saved.anchor ? context.byKey.get(saved.anchor) : undefined) ?? Math.min(saved.index, context.rows.length - 1);
    const key = context.rows[index].key;
    const pending = { saved, key, focus, frame: 0, attempts: 0, stable: 0 };
    restoration.current = pending; setRestoringKey(key);
    element.scrollLeft = saved.left;
    const settle = () => {
      if (restoration.current !== pending) return;
      const latest = live.current, index = latest.byKey.get(key), element = scroller.current;
      if (!element || index === undefined || latest.printing) { cancelRestore(); return; }
      const row = body.current?.querySelector<HTMLElement>(`[data-index="${index}"]`);
      if (row) {
        const bounds = row.getBoundingClientRect();
        const inset = Math.min(saved.inset, Math.max(0, bounds.height - 1));
        const delta = bounds.top - element.getBoundingClientRect().top - headHeight() + inset;
        if (Math.abs(delta) > 0.75) {
          if (latest.active) virtualizer.scrollToOffset(element.scrollTop + delta);
          else element.scrollTop += delta;
          pending.stable = 0;
        } else pending.stable++;
      } else if (latest.active) virtualizer.scrollToIndex(index, { align: 'start' });
      if (++pending.attempts < 12 && pending.stable < 2) pending.frame = requestAnimationFrame(settle);
      else {
        restoration.current = null; setRestoringKey(null);
        if (pending.focus && saved.focus) {
          const focusIndex = latest.byKey.get(saved.focus.key);
          const row = body.current?.querySelector<HTMLElement>(`[data-index="${focusIndex}"]`);
          row?.querySelectorAll<HTMLElement>(controls)[Math.max(0, saved.focus.control)]?.focus({ preventScroll: true });
        }
        capture();
      }
    };
    // Correct a full-mode transition in its layout phase, before a selected row can visibly move.
    settle();
  }, [cancelRestore, capture, headHeight, scroller, virtualizer]);

  const previous = useRef<{ rows: Row[]; query: string; columns: string; active: boolean; printing: boolean } | null>(null);
  useLayoutEffect(() => {
    const element = scroller.current, before = previous.current;
    if (!element) return;
    previous.current = { rows, query, columns: columnKey, active, printing };
    if (printing) { cancelRestore(); return; }
    if (before && before.query !== query) {
      cancelRestore(); pendingFocus.current = null; viewport.current = null;
      element.scrollTop = 0; if (active) virtualizer.scrollToOffset(0);
      capture();
    } else if (!before) {
      if (initial.current && (initial.current.width !== element.clientWidth || initial.current.columns !== columnKey)) virtualizer.measure();
      restore(initial.current, true);
      if (!initial.current) capture();
    } else if (before.printing) {
      virtualizer.measure(); restore(printed.current, true); printed.current = null;
    } else if (before.rows !== rows || before.columns !== columnKey || before.active !== active) {
      const saved = viewport.current;
      if (before.columns !== columnKey) virtualizer.measure();
      if (skipModeRestore.current) { skipModeRestore.current = false; cancelRestore(); }
      else restore(saved);
    }
  }, [mounted, rows, query, columnKey, active, printing, cancelRestore, capture, restore, scroller, viewport, virtualizer]);

  useLayoutEffect(() => {
    const element = scroller.current, head = header.current;
    if (!element || !head) return;
    let width = element.clientWidth, height = head.getBoundingClientRect().height;
    const resize = () => {
      const nextWidth = element.clientWidth, nextHeight = head.getBoundingClientRect().height;
      setHeaderHeight(nextHeight); element.style.scrollPaddingTop = `${nextHeight}px`;
      if (live.current.printing) { width = nextWidth; height = nextHeight; return; }
      if (nextWidth !== width || nextHeight !== height) {
        width = nextWidth; height = nextHeight;
        const saved = viewport.current;
        virtualizer.measure(); restore(saved);
      }
    };
    const fonts = () => { if (!live.current.printing) { virtualizer.measure(); restore(viewport.current); } };
    resize();
    const observer = new ResizeObserver(resize);
    observer.observe(element); observer.observe(head);
    document.fonts.addEventListener('loadingdone', fonts);
    const save = () => capture();
    const interrupt = () => { cancelRestore(); };
    const key = (event: globalThis.KeyboardEvent) => {
      interrupt();
      if (!live.current.active) return;
      // Native sequential navigation needs every intervening control. Let the browser choose the next
      // control after synchronous expansion, preserving the exact focused DOM node and default action.
      if (event.key === 'Tab' || ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'a' && !/^(INPUT|TEXTAREA)$/.test((event.target as HTMLElement).tagName))) {
        beforeSequentialNavigation();
      }
    };
    const selection = () => {
      const selected = document.getSelection();
      if (live.current.active && selected && !selected.isCollapsed && (body.current?.contains(selected.anchorNode) || body.current?.contains(selected.focusNode))) {
        capture(); flushSync(live.current.showAll);
      }
    };
    const portalFocus = (event: FocusEvent) => {
      const target = event.target;
      if (target instanceof Element && !body.current?.contains(target))
        setFocused(target.closest<HTMLElement>('[data-library-row-owner]')?.dataset.libraryRowOwner ?? null);
    };
    element.addEventListener('scroll', save, { passive: true });
    element.addEventListener('keydown', key, true);
    element.addEventListener('wheel', interrupt, { passive: true });
    element.addEventListener('touchstart', interrupt, { passive: true });
    document.addEventListener('pointerdown', interrupt, true);
    document.addEventListener('selectionchange', selection);
    document.addEventListener('focusin', portalFocus);
    commands.current = { beforePrint() { capture(true); printed.current = viewport.current; }, beforeSequentialNavigation };
    return () => {
      // Snapshot once at navigation, never on a scrolling frame. The saved layout signature decides
      // whether it can be reused; the key/inset remains authoritative after a changed layout.
      capture(true); cancelRestore(); commands.current = null;
      observer.disconnect(); document.fonts.removeEventListener('loadingdone', fonts);
      element.removeEventListener('scroll', save); element.removeEventListener('keydown', key, true);
      element.removeEventListener('wheel', interrupt); element.removeEventListener('touchstart', interrupt);
      document.removeEventListener('pointerdown', interrupt, true); document.removeEventListener('selectionchange', selection); document.removeEventListener('focusin', portalFocus);
    };
  }, [mounted, beforeSequentialNavigation, cancelRestore, capture, commands, header, restore, scroller, viewport, virtualizer]);

  const move = (event: KeyboardEvent<HTMLTableSectionElement>) => {
    if (event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return;
    if (!['ArrowDown', 'ArrowUp', 'Home', 'End', 'PageDown', 'PageUp'].includes(event.key)) return;
    const link = (event.target as HTMLElement).closest('a.title'), key = link?.closest<HTMLElement>('[data-row-key]')?.dataset.rowKey;
    if (!key) return;
    const index = byKey.get(key);
    if (index === undefined) return;
    const step = ['ArrowDown', 'PageDown', 'Home'].includes(event.key) ? 1 : -1;
    const distance = event.key.startsWith('Page') ? Math.max(1, Math.floor((scroller.current?.clientHeight ?? 400) / 58) - 1) : 1;
    let next = event.key === 'Home' ? 0 : event.key === 'End' ? rows.length - 1 : Math.max(0, Math.min(rows.length - 1, index + step * distance));
    while (next >= 0 && next < rows.length && !rows[next].readable) next += step;
    if (next < 0 || next >= rows.length) return;
    event.preventDefault();
    pendingFocus.current = rows[next].key; setFocused(rows[next].key);
    if (active) virtualizer.scrollToIndex(next, { align: 'auto' });
    else body.current?.querySelector<HTMLElement>(`[data-index="${next}"] a.title`)?.scrollIntoView({ block: 'nearest' });
  };
  useLayoutEffect(() => {
    if (!pendingFocus.current) return;
    const index = byKey.get(pendingFocus.current);
    const link = body.current?.querySelector<HTMLElement>(`[data-index="${index}"] a.title`);
    if (link) { link.focus({ preventScroll: true }); pendingFocus.current = null; }
  });
  useLayoutEffect(() => {
    if (focused && !byKey.has(focused)) {
      setFocused(null); pendingFocus.current = null;
      if (document.activeElement === document.body) scroller.current?.focus({ preventScroll: true });
    }
  }, [byKey, focused, scroller]);

  // Measuring mounted rows can move their DOM positions without a scroll event. Remember the
  // completed layout as well, so a later live reorder never restores an earlier estimate.
  useLayoutEffect(() => { if (mounted) capture(); });

  const items = active ? virtualizer.getVirtualItems() : rows.map((row, index) => ({ key: row.key, index, start: 0, end: 0 }));
  const spacer = (height: number, key: string) => height > 0.5
    ? <tr key={key} className="library-spacer" aria-hidden="true" role="presentation"><td colSpan={columns.length + 1} style={{ height }} /></tr> : null;
  let edge = headerHeight;
  return <tbody ref={body} onKeyDown={move} onClickCapture={() => capture(true)}
    onFocusCapture={event => { setFocused((event.target as HTMLElement).closest<HTMLElement>('[data-row-key]')?.dataset.rowKey ?? null); capture(); }}
    onBlurCapture={event => {
      if (!event.currentTarget.contains(event.relatedTarget as Node | null)) {
        const portalOwner = event.relatedTarget instanceof Element ? event.relatedTarget.closest<HTMLElement>('[data-library-row-owner]')?.dataset.libraryRowOwner : null;
        setFocused(portalOwner ?? null);
      }
    }}>
    {items.map(item => {
      const gap = active ? item.start - edge : 0; edge = item.end;
      // Keep the same keyed wrapper and row child in both modes, including during native selection.
      return <Fragment key={item.key}>{spacer(gap, `gap:${item.key}`)}{render(rows[item.index], item.index, active ? virtualizer.measureElement : undefined)}</Fragment>;
    })}
    {active && spacer(virtualizer.getTotalSize() - edge, 'tail')}
    {rows.length === 0 && <tr><td colSpan={columns.length + 1} className="no-match"><span>No papers match.</span></td></tr>}
  </tbody>;
}
