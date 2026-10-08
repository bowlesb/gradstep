// Podcast playback helpers: device-local listening positions (v1 keeps listening history in this browser only — no
// server copy and no encrypted-history events) and transcript/chapter lookups. Pure apart from localStorage access.
import { config } from './backend';
import type { Chapter, Evidence, Segment } from './podcast';
import type { TextAnchor } from './events';

export interface SavedPosition {
  positionMs: number; durationMs: number; completed: boolean;
  /** A play session (one open of an episode) and its save counter. Within a session the later save wins even when it is
   * an earlier position (seeking back is intentional); between sessions the later session start wins. Never max(position). */
  session: string; sessionStartedAt: number; sequence: number; savedAt: number;
}
interface Store { version: 1; positions: Record<string, SavedPosition> }

/** At most this many episodes keep a position; the least recently saved is dropped first. */
export const MAX_POSITIONS = 200;
export const positionsKey = (account: string) => `gradstep.${config.environment}.podcast-positions.${account}`;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const whole = (v: unknown, max: number) => Number.isSafeInteger(v) && (v as number) >= 0 && (v as number) <= max;

function validPosition(v: unknown): v is SavedPosition {
  const p = v as SavedPosition;
  return !!p && whole(p.positionMs, 86_400_000) && whole(p.durationMs, 86_400_000) && typeof p.completed === 'boolean'
    && typeof p.session === 'string' && uuid.test(p.session) && whole(p.sessionStartedAt, 2 ** 52) && whole(p.sequence, 2 ** 31) && whole(p.savedAt, 2 ** 52);
}

function read(account: string): Store {
  try {
    const raw = JSON.parse(localStorage.getItem(positionsKey(account)) ?? 'null') as Store | null;
    if (!raw || raw.version !== 1 || typeof raw.positions !== 'object' || !raw.positions) return { version: 1, positions: {} };
    const positions: Record<string, SavedPosition> = {};
    for (const [id, p] of Object.entries(raw.positions)) if (uuid.test(id) && validPosition(p)) positions[id] = p;
    return { version: 1, positions };
  } catch { return { version: 1, positions: {} }; }
}

/** The deterministic merge rule: later session wins; within a session, the higher sequence; ties keep the stored one. */
export function newer(candidate: SavedPosition, stored: SavedPosition | undefined): boolean {
  if (!stored) return true;
  if (candidate.session === stored.session) return candidate.sequence > stored.sequence;
  if (candidate.sessionStartedAt !== stored.sessionStartedAt) return candidate.sessionStartedAt > stored.sessionStartedAt;
  return candidate.session > stored.session;
}

export function loadPosition(account: string, releaseID: string): SavedPosition | null {
  return read(account).positions[releaseID] ?? null;
}

/** Saves only if this write is newer under `newer`, so another tab's later session is never overwritten by a stale one. */
export function savePosition(account: string, releaseID: string, position: SavedPosition): boolean {
  if (!uuid.test(releaseID) || !validPosition(position)) return false;
  const store = read(account);
  if (!newer(position, store.positions[releaseID])) return false;
  store.positions[releaseID] = position;
  const ids = Object.keys(store.positions);
  if (ids.length > MAX_POSITIONS) {
    for (const old of ids.sort((a, b) => store.positions[a].savedAt - store.positions[b].savedAt).slice(0, ids.length - MAX_POSITIONS)) delete store.positions[old];
  }
  try { localStorage.setItem(positionsKey(account), JSON.stringify(store)); return true; } catch { return false; }
}

/** Sign-out removes this account's listening places from this browser. */
export function clearPositions(account: string): void {
  try { localStorage.removeItem(positionsKey(account)); } catch { /* storage unavailable: nothing was kept */ }
}

/** Where to resume: a completed episode, or one within the last five seconds, starts again. */
export function resumeAt(saved: SavedPosition | null, durationMs: number): number {
  if (!saved || saved.completed || saved.positionMs >= durationMs - 5_000) return 0;
  return Math.max(0, saved.positionMs);
}

// ---------- Transcript and chapters ----------

/** The segment playing at `ms` (the last one starting at or before it), by binary search over start times. */
export function segmentAt(segments: readonly Segment[], ms: number): Segment | null {
  let low = 0, high = segments.length - 1, found = -1;
  while (low <= high) {
    const mid = (low + high) >> 1;
    if (segments[mid].startMs <= ms) { found = mid; low = mid + 1; } else high = mid - 1;
  }
  return found < 0 ? null : segments[found];
}

export function chapterAt(chapters: readonly Chapter[], ms: number): Chapter | null {
  let current: Chapter | null = null;
  for (const chapter of chapters) { if (chapter.startMs <= ms) current = chapter; else break; }
  return current;
}

/** "4:58" (or "1:02:03"); never negative. */
export function clock(ms: number): string {
  const total = Math.max(0, Math.floor(ms / 1000)), h = Math.floor(total / 3600), m = Math.floor((total % 3600) / 60), s = total % 60;
  return h ? `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}` : `${m}:${String(s).padStart(2, '0')}`;
}

/** A card's duration: "5 min", or seconds under a minute. */
export function durationLabel(ms: number): string {
  const seconds = Math.round(ms / 1000);
  return seconds < 60 ? `${seconds} s` : `${Math.round(seconds / 60)} min`;
}

/** What screen readers hear for the position slider. */
export const positionText = (ms: number, durationMs: number) => `${clock(ms)} of ${clock(durationMs)}`;

/** An evidence quote as a passage anchor for the reader's existing finder: text search only (no artifact or block pin),
 * so it also works on a newer conversion of the same paper. */
export function evidenceAnchor(evidence: Evidence): TextAnchor {
  return { artifactID: '', quote: evidence.quote, prefix: '', suffix: '' };
}

export const SPEEDS = [0.75, 1, 1.25, 1.5, 1.75, 2] as const;
export const SKIP_MS = 15_000;
