import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { loadActivity, saveActivity } from '../src/lib/activity';
import type { DeviceRecord } from '../src/lib/keys';
import { generateDeviceKeyPair } from '../src/lib/wire';

const stored = vi.hoisted(() => new Map<string, unknown>());
vi.mock('../src/lib/idb', () => ({ idb: {
  get: async (_store: string, key: string) => stored.get(key),
  putActivity: async (key: string, _deviceID: string, value: unknown) => { stored.set(key, value); },
} }));
beforeEach(() => { stored.clear(); vi.stubGlobal('navigator', {}); });
afterEach(() => { vi.unstubAllGlobals(); });

it('concurrent and stale reading snapshots retain the newest place and papers from both snapshots', async () => {
  const pair = await generateDeviceKeyPair();
  const device: DeviceRecord = { ...pair, accountID: '11111111-2222-4333-8444-555555555555',
    deviceID: crypto.randomUUID(), challenge: new Uint8Array(32),
    localKey: await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']) };
  await Promise.all([
    saveActivity(device, new Map([['paper-a', { opened: 100, progress: 0.1 }]])),
    saveActivity(device, new Map([['paper-a', { opened: 200, progress: 0.8 }]])),
  ]);
  // Another view later writes an older snapshot and a paper this view did not have.
  await saveActivity(device, new Map([['paper-a', { opened: 100, progress: 0.1 }], ['paper-b', { opened: 150, progress: 0.3 }]]));
  expect(await loadActivity(device)).toEqual(new Map([
    ['paper-a', { opened: 200, progress: 0.8 }], ['paper-b', { opened: 150, progress: 0.3 }],
  ]));
  expect([...stored.values()][0]).toBeInstanceOf(Uint8Array); // actual AES-GCM persistence, not plaintext JSON
});
