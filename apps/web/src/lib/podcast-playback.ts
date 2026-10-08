// V1 device-local listening places. No audio or transcript is persisted. Each save has its own immutable key,
// so concurrent tabs never read/modify/write a shared map (or overwrite another session's backward seek).
import { auth, config } from './backend';
import type { Chapter, Evidence, Segment } from './podcast';
import type { TextAnchor } from './events';

export interface SavedPosition {
  positionMs: number; durationMs: number; completed: boolean;
  session: string; sessionStartedAt: number; sequence: number; savedAt: number;
  removed?: boolean;
}
export const MAX_POSITIONS = 200;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const whole = (v: unknown, max: number) => Number.isSafeInteger(v) && (v as number) >= 0 && (v as number) <= max;
const owner = (account: string) => auth.session()?.user.id === account ? auth.session()!.lifetime : 'signed-out';
/** A prior login's delayed cleanup cannot erase a new login's positions, even for the same account. */
const accountPrefix = (account: string) => `gradstep.${config.environment}.podcast-positions.${encodeURIComponent(new URL(config.url || 'https://unconfigured.invalid').origin)}.${account}.v2.`;
export const positionsKey = (account: string, lifetime = owner(account)) => `${accountPrefix(account)}${encodeURIComponent(lifetime)}.`;

function validPosition(v: unknown): v is SavedPosition {
  const p = v as SavedPosition;
  return !!p && whole(p.positionMs, 86_400_000) && whole(p.durationMs, 86_400_000) && p.positionMs <= p.durationMs && typeof p.completed === 'boolean'
    && typeof p.session === 'string' && uuid.test(p.session) && whole(p.sessionStartedAt, 2 ** 52) && whole(p.sequence, 2 ** 31) && whole(p.savedAt, 2 ** 52)
    && (p.removed === undefined || typeof p.removed === 'boolean');
}
interface RecordEntry { key: string; releaseID: string; position: SavedPosition }
function read(account: string, lifetime?: string): RecordEntry[] {
  try {
    const prefix = positionsKey(account, lifetime), records: RecordEntry[] = [];
    // Snapshot keys before reading. A simultaneous writer has a different immutable key and cannot be erased by this snapshot.
    const keys = Array.from({ length: localStorage.length }, (_, i) => localStorage.key(i)).filter((k): k is string => !!k && k.startsWith(prefix));
    for (const key of keys) {
      const [releaseID, session, sequence, removed] = key.slice(prefix.length).split('.');
      if (!uuid.test(releaseID) || !uuid.test(session)) continue;
      let position: unknown;
      try { position = JSON.parse(localStorage.getItem(key) ?? 'null'); } catch { continue; }
      if (validPosition(position) && position.session === session && String(position.sequence) === sequence && (position.removed ? '1' : '0') === removed)
        records.push({ key, releaseID, position });
    }
    return records;
  } catch { return []; }
}

/** Later session wins; equal starts use session ID; same session uses sequence; an exact-tie tombstone wins. */
export function newer(candidate: SavedPosition, stored: SavedPosition | undefined): boolean {
  if (!stored) return true;
  if (candidate.session !== stored.session) return candidate.sessionStartedAt !== stored.sessionStartedAt
    ? candidate.sessionStartedAt > stored.sessionStartedAt : candidate.session > stored.session;
  return candidate.sequence !== stored.sequence ? candidate.sequence > stored.sequence : !!candidate.removed && !stored.removed;
}
function winners(records: RecordEntry[]) {
  const result = new Map<string, RecordEntry>();
  for (const entry of records) if (newer(entry.position, result.get(entry.releaseID)?.position)) result.set(entry.releaseID, entry);
  return result;
}
export function loadPosition(account: string, releaseID: string, lifetime?: string): SavedPosition | null {
  const p = winners(read(account, lifetime)).get(releaseID)?.position;
  return p && !p.removed ? p : null;
}

export function savePosition(account: string, releaseID: string, position: SavedPosition, lifetime?: string): boolean {
  if (!uuid.test(releaseID) || !validPosition(position)) return false;
  try {
    const key = `${positionsKey(account, lifetime)}${releaseID}.${position.session}.${position.sequence}.${position.removed ? 1 : 0}`;
    if (localStorage.getItem(key) !== null) return false;
    localStorage.setItem(key, JSON.stringify(position));
    const records = read(account, lifetime), latest = winners(records);
    const kept = new Set([...latest.values()].sort((a, b) => b.position.savedAt - a.position.savedAt).slice(0, MAX_POSITIONS).map(e => e.key));
    // Delete only immutable keys we observed, never an episode/session bucket another writer could have updated.
    for (const entry of records) if (!kept.has(entry.key)) localStorage.removeItem(entry.key);
    return kept.has(key);
  } catch { return false; }
}

/** A retained tombstone rejects stale tab saves. The 200-entry bound also evicts old tombstones; positions never authorize audio. */
export function removePosition(account: string, releaseID: string, lifetime?: string): void {
  const previous = winners(read(account, lifetime)).get(releaseID)?.position;
  const at = Math.max(Date.now(), (previous?.sessionStartedAt ?? 0) + 1);
  savePosition(account, releaseID, { positionMs: 0, durationMs: 0, completed: false, session: crypto.randomUUID(),
    sessionStartedAt: at, sequence: 0, savedAt: at, removed: true }, lifetime);
}

/** Confirmed auth retirement passes its captured lifetime. Explicit Forget may omit it to remove all lifetimes for this deployment/account. */
export function clearPositions(account: string, lifetime?: string): void {
  try {
    const prefix = lifetime === undefined ? accountPrefix(account) : positionsKey(account, lifetime);
    const keys = Array.from({ length: localStorage.length }, (_, i) => localStorage.key(i));
    for (const key of keys) if (key?.startsWith(prefix)) localStorage.removeItem(key);
  } catch { /* storage unavailable */ }
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
