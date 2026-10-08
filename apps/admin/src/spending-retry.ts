import { canonicalTimestamp, canonicalUUID, parseSpendingDraft, parseSpendingObservation, spendingReceipt,
  type SpendingObservationDraft, type SpendingObservationRequest, type SpendingObservationReceipt } from '../../../supabase/functions/_shared/spending-observations.ts';

interface RetryEntry { digest: string; id: string; observed_at: string }
type JournalStorage = Pick<Storage, 'getItem' | 'setItem' | 'removeItem'>;
const CAPACITY = 32, MAX_BYTES = 8192;
const journalFailure = () => new Error('The retry record is unavailable. Nothing new was sent. Keep this tab open and try again.');
function key(environment: string, ownerID: string): string {
  if (!canonicalUUID(ownerID) || environment.trim() !== environment || environment.length > 32 || !/^[a-z0-9_-]+$/.test(environment)) throw journalFailure();
  return `science-reader.admin.spending-retry.${environment}.${ownerID}`;
}
function read(storage: JournalStorage, storageKey: string): RetryEntry[] {
  try {
    const text = storage.getItem(storageKey);
    if (text === null) return [];
    if (text.length > MAX_BYTES) throw journalFailure();
    const entries: unknown = JSON.parse(text);
    if (!Array.isArray(entries) || entries.length > CAPACITY) throw journalFailure();
    const digests = new Set(), ids = new Set();
    for (const entry of entries) {
      if (!entry || typeof entry !== 'object' || Object.keys(entry).length !== 3 || typeof entry.digest !== 'string'
        || entry.digest.length !== 64 || !/^[a-f0-9]+$/.test(entry.digest) || !canonicalUUID(entry.id) || !canonicalTimestamp(entry.observed_at)
        || digests.has(entry.digest) || ids.has(entry.id)) throw journalFailure();
      digests.add(entry.digest); ids.add(entry.id);
    }
    return entries as RetryEntry[];
  } catch { throw journalFailure(); }
}
function write(storage: JournalStorage, storageKey: string, entries: RetryEntry[]) {
  try { if (entries.length) storage.setItem(storageKey, JSON.stringify(entries)); else storage.removeItem(storageKey); }
  catch { throw journalFailure(); }
}
async function draftDigest(draft: SpendingObservationDraft): Promise<string> {
  const bytes = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(JSON.stringify(draft)));
  return Array.from(new Uint8Array(bytes), byte => byte.toString(16).padStart(2, '0')).join('');
}
async function sendRequest(storage: JournalStorage, storageKey: string, request: SpendingObservationRequest,
  send: (request: SpendingObservationRequest) => Promise<SpendingObservationReceipt>): Promise<SpendingObservationReceipt> {
  const result = spendingReceipt(await send(request), request.request_id);
  if (!result) throw new Error('The observation was not confirmed. Retry the same entry.');
  // Reread so another pending entry (including a later one with the same fields) is not erased.
  try { write(storage, storageKey, read(storage, storageKey).filter(row => row.id !== request.request_id)); } catch { /* keep replay evidence */ }
  return result;
}

// Concurrent mounts share preparation, but each receives the exact request in its send callback.
// Keep it until every such caller completes: one fast acknowledgment must not create a second initial ID.
const preparing = new WeakMap<JournalStorage, Map<string, { request: Promise<SpendingObservationRequest>; callers: number }>>();

export function pendingSpendingEntries(environment: string, ownerID: string, storage: JournalStorage = sessionStorage): number {
  return read(storage, key(environment, ownerID)).length;
}

/** Persist only retry metadata before sending. The same fields recover the same UUID and timestamp after a reload. */
export async function recordSpendingOnce(environment: string, ownerID: string, input: SpendingObservationDraft,
  send: (request: SpendingObservationRequest) => Promise<SpendingObservationReceipt>, storage: JournalStorage = sessionStorage): Promise<SpendingObservationReceipt> {
  const draft = parseSpendingDraft(input), storageKey = key(environment, ownerID);
  let active = preparing.get(storage);
  if (!active) { active = new Map(); preparing.set(storage, active); }
  const preparationKey = storageKey + JSON.stringify(draft);
  let preparation = active.get(preparationKey);
  if (!preparation) {
    if (active.size >= CAPACITY) throw new Error('Too many evidence entries are being sent. Wait for them to finish.');
    const request = (async () => {
      const digest = await draftDigest(draft), entries = read(storage, storageKey);
      let entry = entries.find(row => row.digest === digest);
      if (!entry) {
        if (entries.length >= CAPACITY) throw new Error('There are 32 unconfirmed evidence entries in this tab. Retry an existing entry before adding another.');
        entry = { digest, id: crypto.randomUUID(), observed_at: new Date().toISOString() };
        write(storage, storageKey, [...entries, entry]);
      }
      return { ...draft, request_id: entry.id, observed_at: entry.observed_at };
    })();
    preparation = { request, callers: 0 }; active.set(preparationKey, preparation);
  }
  preparation.callers++;
  try { return await sendRequest(storage, storageKey, await preparation.request, send); }
  finally { if (--preparation.callers === 0) active.delete(preparationKey); }
}

/** A mounted form retries its frozen request even if another mount already acknowledged and cleared the journal. */
export async function retrySpendingObservation(environment: string, ownerID: string, frozen: SpendingObservationRequest,
  send: (request: SpendingObservationRequest) => Promise<SpendingObservationReceipt>, storage: JournalStorage = sessionStorage): Promise<SpendingObservationReceipt> {
  const request = parseSpendingObservation(frozen), storageKey = key(environment, ownerID);
  const { request_id, observed_at, ...draft } = request;
  const digest = await draftDigest(draft), entries = read(storage, storageKey), prior = entries.find(row => row.id === request_id);
  if (prior && (prior.digest !== digest || prior.observed_at !== observed_at)) throw new Error('This retry differs from its saved entry. Keep the request ID for review.');
  if (!prior && !entries.some(row => row.digest === digest)) {
    if (entries.length >= CAPACITY) throw new Error('The retry journal is full. Keep the request ID for review.');
    write(storage, storageKey, [...entries, { digest, id: request_id, observed_at }]);
  }
  return sendRequest(storage, storageKey, request, send);
}
