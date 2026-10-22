// Kept explanations (B4): the AI Explainer's finished answers for equations and figures, kept in this browser across
// reloads as the apps keep them on the device (ReaderModel's equation-answers / figure-answers): sealed with this
// browser's non-extractable local key, the account bound into the authenticated data, never synced or sent. At most
// 400 of each kind, the oldest dropped first (EquationView.swift's store limit). A figure's image is not kept; it is
// prepared again from the paper on this device when the answer is shown. Losing this store only means asking again.
import { config } from './backend';
import { fromUtf8, utf8 } from './bytes';
import { idb } from './idb';
import type { DeviceRecord, PreparedLocal } from './keys';
import { open, seal } from './wire';

/** `paper`: the paper's AI Explainer (2026-10-22), kept per paper revision and model. */
export type KeptKind = 'equation' | 'figure' | 'paper';
export interface KeptEntry {
  kind: KeptKind;
  /** The cache key the session reads it by (equationKey / figureKey: manifest, target, action, model, part). */
  key: string;
  /** For Your assets: the paper, its bundle, the equation or figure and its name; only the main answer is listed. */
  listed: { documentID: string; manifest: string; targetID: string; label: string } | null;
  /** The finished result (a figure's without its image). */
  result: unknown;
  savedAt: number;
}
export const MAX_KEPT_PER_KIND = 400;
const MAX_BYTES = 16 * 1024 * 1024;
export const KEPT_SUFFIX = ':explanations';
const aad = (account: string) => utf8(`gradstep/web-explanations/v1/${account}`);
const storageKey = (account: string) => `${config.environment}:${account}`;
const saves = new Map<string, Promise<void>>();

const validEntry = (e: KeptEntry) => !!e && (e.kind === 'equation' || e.kind === 'figure' || e.kind === 'paper') && typeof e.key === 'string' && e.key.length <= 1_000
  && Number.isSafeInteger(e.savedAt) && !!e.result && typeof e.result === 'object'
  && (e.listed === null || (typeof e.listed === 'object' && typeof e.listed.documentID === 'string' && typeof e.listed.manifest === 'string'
    && typeof e.listed.targetID === 'string' && typeof e.listed.label === 'string' && e.listed.label.length <= 200));

/** Newest first, each key once, at most MAX_KEPT_PER_KIND of each kind. */
export function boundKept(entries: readonly KeptEntry[]): KeptEntry[] {
  const seen = new Set<string>(), counts: Record<KeptKind, number> = { equation: 0, figure: 0, paper: 0 }, out: KeptEntry[] = [];
  for (const e of [...entries].sort((a, b) => b.savedAt - a.savedAt)) {
    const id = `${e.kind}|${e.key}`;
    if (seen.has(id) || counts[e.kind] >= MAX_KEPT_PER_KIND) continue;
    seen.add(id); counts[e.kind]++; out.push(e);
  }
  return out;
}

export async function loadKept(device: DeviceRecord): Promise<KeptEntry[]> {
  try {
    const sealed = await idb.get<Uint8Array<ArrayBuffer>>('activity', storageKey(device.accountID) + KEPT_SUFFIX);
    if (!sealed) return [];
    const value = JSON.parse(fromUtf8(await open(device.localKey, sealed, aad(device.accountID)))) as KeptEntry[];
    return Array.isArray(value) ? boundKept(value.filter(validEntry)) : [];
  } catch { return []; } // unreadable: start empty, replaced on the next save
}

/** Saves the whole bounded list; saves are queued, so an older list never overtakes a newer one. */
export function saveKept(device: DeviceRecord, entries: readonly KeptEntry[], local: PreparedLocal): Promise<void> {
  const identity = storageKey(device.accountID), captured = boundKept(entries);
  const write = async () => {
    let bytes = utf8(JSON.stringify(captured));
    // Over the bound, the oldest go until it fits (a figure's walkthrough is a few kilobytes).
    for (let keep = captured.length; bytes.length > MAX_BYTES && keep > 0; keep = Math.floor(keep * 0.8)) bytes = utf8(JSON.stringify(captured.slice(0, keep)));
    const sealed = await seal(device.localKey, bytes, aad(device.accountID));
    await idb.putActivity(identity, device.deviceID, sealed, local.fence, local.current, KEPT_SUFFIX);
  };
  const next = (saves.get(identity) ?? Promise.resolve()).catch(() => {}).then(write).finally(() => { if (saves.get(identity) === next) saves.delete(identity); });
  saves.set(identity, next);
  return next;
}
