// Device-local reading activity (Opened, Progress, last position) — the browser's counterpart of
// the native reading-activity.enc: sealed with this browser's non-extractable local key, account
// bound into the authenticated data, never synced or sent anywhere. Losing it only forgets places.
import { fromUtf8, utf8 } from './bytes';
import { config } from './backend';
import { idb } from './idb';
import type { DeviceRecord, PreparedLocal } from './keys';
import { open, seal } from './wire';

export interface Location { block: number; fraction: number; height: number; y: number }
export interface Activity { opened: number; progress: number; location?: Location; manifest?: string }

const MAX = 5_000;
const key = (account: string) => `${config.environment}:${account}`;
const aad = (account: string) => utf8(`gradstep/web-reading/v1/${account}`);
const saves = new Map<string, Promise<void>>();

export async function loadActivity(device: DeviceRecord): Promise<Map<string, Activity>> {
  try {
    const sealed = await idb.get<Uint8Array<ArrayBuffer>>('activity', key(device.accountID));
    if (!sealed) return new Map();
    const value = JSON.parse(fromUtf8(await open(device.localKey, sealed, aad(device.accountID)))) as [string, Activity][];
    return new Map(value.filter(([id, a]) => typeof id === 'string' && typeof a?.opened === 'number' && typeof a?.progress === 'number'));
  } catch { return new Map(); } // unreadable: start empty, replaced on the next save
}

export function saveActivity(device: DeviceRecord, activity: Map<string, Activity>, local: PreparedLocal): Promise<void> {
  const identity = key(device.accountID), captured = [...activity];
  const write = async () => {
    const merged = await loadActivity(device);
    for (const [id, value] of captured) if (!merged.has(id) || merged.get(id)!.opened <= value.opened) merged.set(id, value);
    const entries = [...merged].sort((a, b) => b[1].opened - a[1].opened).slice(0, MAX);
    const sealed = await seal(device.localKey, utf8(JSON.stringify(entries)), aad(device.accountID));
    await idb.putActivity(identity, device.deviceID, sealed, local.fence, local.current);
  };
  // Queue before encryption, and serialize cooperating tabs. An older snapshot cannot overtake a newer one.
  const next = (saves.get(identity) ?? Promise.resolve()).catch(() => {}).then(() =>
    navigator.locks ? navigator.locks.request(`gradstep.activity.${identity}`, write) : write())
    .finally(() => { if (saves.get(identity) === next) saves.delete(identity); });
  saves.set(identity, next);
  return next;
}
