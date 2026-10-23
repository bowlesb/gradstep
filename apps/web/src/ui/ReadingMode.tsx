// Line width and reading mode (docs/architecture/READING_MODE.md). Owner, 2026-10-15: "when your reading space gets
// wider there should be new words on a line … there needs to be some option", and "a really good full screen reading
// mode … that feels like a truly great experience". The measure is applied by the shared reader bridge; reading mode is
// the app's chrome stepping aside (and the window going full screen when the browser allows it).
import { type KeyboardEvent, useCallback, useEffect, useRef, useState } from 'react';
import { flushSync } from 'react-dom';
import { LINE_WIDTHS, type LineWidth } from '../reader/line-width';
import { readStored } from './prefs';
import type { WorkspaceControls } from './Shell';

export const LINE_WIDTH_KEY = 'gradstep.reader.lineWidth';
export const readLineWidth = (): LineWidth => readStored(LINE_WIDTH_KEY, 'comfortable', v => LINE_WIDTHS.includes(v as LineWidth));
export const LINE_WIDTH_TITLES: Record<LineWidth, string> = { comfortable: 'Comfortable', wide: 'Wide', full: 'Full width' };
export const LINE_WIDTH_DETAILS: Record<LineWidth, string> = {
  comfortable: 'About 72 characters a line', wide: 'About 100 characters a line', full: 'Lines fill the window: wider means more words',
};

/** Three lines whose length says the measure. */
function Glyph({ width }: { width: LineWidth }) {
  const x = width === 'comfortable' ? 6 : width === 'wide' ? 3.5 : 1.5;
  return <svg width="18" height="16" viewBox="0 0 18 16" aria-hidden="true" focusable="false">
    {[4, 8, 12].map(y => <line key={y} x1={x} x2={18 - x} y1={y} y2={y} stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />)}
  </svg>;
}

/** Comfortable, Wide, Full width: a radio group (arrow keys move), beside the text size. */
export function LineWidthControl({ value, onChange }: { value: LineWidth; onChange: (next: LineWidth) => void }) {
  const move = (event: KeyboardEvent) => {
    const step = event.key === 'ArrowRight' || event.key === 'ArrowDown' ? 1 : event.key === 'ArrowLeft' || event.key === 'ArrowUp' ? -1 : 0;
    if (!step) return;
    event.preventDefault();
    const next = LINE_WIDTHS[(LINE_WIDTHS.indexOf(value) + step + LINE_WIDTHS.length) % LINE_WIDTHS.length];
    onChange(next);
    (event.currentTarget.querySelector(`[data-width="${next}"]`) as HTMLElement | null)?.focus();
  };
  return <span className="line-width" role="radiogroup" aria-label="Line width" onKeyDown={move} data-testid="line-width">
    {LINE_WIDTHS.map(width => <button key={width} type="button" role="radio" aria-checked={value === width} tabIndex={value === width ? 0 : -1}
      className={`icon-button line-width-option${value === width ? ' on' : ''}`} data-width={width} data-testid={`line-width-${width}`}
      aria-label={LINE_WIDTH_TITLES[width]} title={`${LINE_WIDTH_TITLES[width]} · ${LINE_WIDTH_DETAILS[width]}`} onClick={() => onChange(width)}>
      <Glyph width={width} /></button>)}
  </span>;
}

/** `/` or ⌘K: the search field. Reading mode hides the top bar, so it ends first, committed at once so the field is shown
 * and takes focus before the next letter arrives; otherwise focus would stay in the paper and the next letters typed
 * would be read as shortcuts (UX audit R5). */
export function focusSearch(reading: Pick<ReadingMode, 'on' | 'exit'> | null, focus: () => void, commit: (run: () => void) => void = flushSync) {
  if (reading?.on) commit(() => reading.exit());
  focus();
}

export interface ReadingMode {
  on: boolean;
  /** The window is full screen (false: the browser refused it, and reading mode is the focus layout in the window). */
  fullscreen: boolean;
  enter: () => void; exit: () => void; toggle: () => void;
}

/** Reading mode for the open paper: the side panels close (each comes back as a slide-over when asked for) and are
 * restored on exit; the page goes full screen when the browser allows, and leaving full screen leaves reading mode. */
export function useReadingMode(ws: WorkspaceControls, available: boolean): ReadingMode {
  const [on, setOn] = useState(false);
  const [fullscreen, setFullscreen] = useState(false);
  const latest = useRef({ ws, on, fullscreen });
  latest.current = { ws, on, fullscreen };
  const before = useRef<{ left: boolean; right: boolean } | null>(null);

  const exit = useCallback(() => {
    if (!latest.current.on) return;
    const { ws } = latest.current, saved = before.current;
    before.current = null;
    setOn(false); setFullscreen(false);
    if (saved) { if (ws.left.open !== saved.left) ws.show('left', saved.left); if (ws.right.open !== saved.right) ws.show('right', saved.right); }
    if (document.fullscreenElement) void document.exitFullscreen().catch(() => {});
  }, []);
  const enter = useCallback(() => {
    if (latest.current.on || !available) return;
    const { ws } = latest.current;
    before.current = { left: ws.left.open, right: ws.right.open };
    if (ws.left.open) ws.show('left', false);
    if (ws.right.open) ws.show('right', false);
    setOn(true);
    const root = document.documentElement;
    if (typeof root.requestFullscreen === 'function' && document.fullscreenEnabled) {
      root.requestFullscreen({ navigationUI: 'hide' }).then(() => setFullscreen(true), () => setFullscreen(false));
    }
  }, [available]);
  const toggle = useCallback(() => { if (latest.current.on) exit(); else enter(); }, [enter, exit]);

  // Leaving full screen the browser's way (Esc, the browser's own control) leaves reading mode too.
  useEffect(() => {
    const changed = () => { if (!document.fullscreenElement && latest.current.on && latest.current.fullscreen) exit(); };
    document.addEventListener('fullscreenchange', changed);
    return () => document.removeEventListener('fullscreenchange', changed);
  }, [exit]);
  // Nothing to read: reading mode ends (the paper closed, or another view opened).
  useEffect(() => { if (!available && latest.current.on) exit(); }, [available, exit]);
  return { on, fullscreen, enter, exit, toggle };
}
