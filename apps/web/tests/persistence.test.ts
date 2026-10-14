import { beforeEach, describe, expect, it } from 'vitest';
import { persistenceState, requestPersistence, resetPersistence, subscribePersistence } from '../src/lib/persistence';

describe('storage persistence outcome', () => {
  beforeEach(resetPersistence);
  it('records granted, declined, already-persisted and unsupported answers and notifies listeners', async () => {
    let notified = 0; const stop = subscribePersistence(() => notified++);
    expect(await requestPersistence({ persist: async () => true, persisted: async () => false })).toBe('persisted');
    expect(await requestPersistence({ persist: async () => false, persisted: async () => false })).toBe('best-effort');
    expect(await requestPersistence({ persist: async () => false, persisted: async () => true })).toBe('persisted');
    expect(await requestPersistence(undefined)).toBe('unsupported');
    expect(await requestPersistence({ persist: async () => { throw new Error('no'); }, persisted: async () => false })).toBe('best-effort');
    expect(persistenceState()).toBe('best-effort'); expect(notified).toBe(5); stop();
  });
});
