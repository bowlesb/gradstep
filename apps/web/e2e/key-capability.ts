import { type Page } from '@playwright/test';

/** Independent engine probe: do not declare Safari support based on generateKey alone. No account keys. */
export async function durableKeys(page: Page): Promise<boolean> {
  await page.goto('/');
  return page.evaluate(async () => {
    const name = 'gradstep-key-capability-' + crypto.randomUUID();
    let db: IDBDatabase | undefined;
    try {
      db = await new Promise<IDBDatabase>((resolve, reject) => {
        const request = indexedDB.open(name, 1);
        request.onupgradeneeded = () => request.result.createObjectStore('probe');
        request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
      });
      const pair = await crypto.subtle.generateKey({ name: 'X25519' }, false, ['deriveBits']) as CryptoKeyPair;
      const put = db.transaction('probe', 'readwrite'); put.objectStore('probe').put(pair.privateKey, 'key');
      await new Promise<void>((resolve, reject) => { put.oncomplete = () => resolve(); put.onerror = () => reject(put.error); });
      const get = db.transaction('probe'), request = get.objectStore('probe').get('key');
      await new Promise<void>((resolve, reject) => { get.oncomplete = () => resolve(); get.onerror = () => reject(get.error); });
      if (!request.result || request.result.extractable) return false;
      const expected = new Uint8Array(await crypto.subtle.deriveBits({ name: 'X25519', public: pair.publicKey }, pair.privateKey, 256));
      const actual = new Uint8Array(await crypto.subtle.deriveBits({ name: 'X25519', public: pair.publicKey }, request.result, 256));
      return actual.length === expected.length && actual.every((v, i) => v === expected[i]);
    } catch { return false; }
    finally { db?.close(); indexedDB.deleteDatabase(name); }
  });
}
