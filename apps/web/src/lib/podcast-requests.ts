// Opaque, per-tab recovery hints for explicit podcast Starts. This is not the encrypted chat journal
// or an offline queue. An unresolved identity survives React unmount/reload, never authorizes a paid
// request on its own, and is never evicted to make room for a different request.
import { auth, config, type AuthSnapshot } from './backend';
import { isUUID } from './bytes';
import { CONSENT_VERSION, CONSENT_VERSIONS, MAX_QUOTE_CREDITS, PROVIDER_LABEL, type Quote } from './podcast';

export const MAX_UNRESOLVED_PODCASTS = 20;
const MAX_BYTES = 16_384;
const MAX_DATE = 8_640_000_000_000_000;
export class PodcastTrackingError extends Error {
  constructor(readonly code: 'unavailable' | 'damaged' | 'full' | 'retired' | 'conflict') { super(`podcast_tracking_${code}`); }
}
interface RecordV1 { itemID: string; requestID: string; quoteID: string; expiresAt: number }
export interface UnresolvedPodcast { itemID: string; requestID: string; quote: Quote }
interface Ledger { version: 1; records: RecordV1[] }
const keysAre = (v: object, keys: string[]) => Object.keys(v).sort().join(',') === keys.sort().join(',');
const valid = (v: unknown): v is RecordV1 => {
  if (!v || typeof v !== 'object' || !keysAre(v, ['itemID', 'requestID', 'quoteID', 'expiresAt'])) return false;
  const r = v as RecordV1;
  return isUUID(r.itemID) && isUUID(r.requestID) && isUUID(r.quoteID)
    && Number.isSafeInteger(r.expiresAt) && r.expiresAt > 0 && r.expiresAt <= MAX_DATE;
};
export function podcastRequestsKey(account: string, lifetime: string) {
  return `gradstep.${encodeURIComponent(config.environment)}.podcast-requests.${encodeURIComponent(new URL(config.url).origin)}.${account}.${encodeURIComponent(lifetime)}.v1`;
}
function decode(raw: string | null): Ledger {
  if (raw === null) return { version: 1, records: [] };
  if (raw.length > MAX_BYTES) throw new PodcastTrackingError('damaged');
  let v: Ledger;
  try { v = JSON.parse(raw); } catch { throw new PodcastTrackingError('damaged'); }
  if (!v || typeof v !== 'object' || !keysAre(v, ['version', 'records']) || v.version !== 1 || !Array.isArray(v.records)
    || v.records.length > MAX_UNRESOLVED_PODCASTS || !v.records.every(valid)
    || new Set(v.records.map(r => r.itemID)).size !== v.records.length || new Set(v.records.map(r => r.requestID)).size !== v.records.length) {
    throw new PodcastTrackingError('damaged');
  }
  return v;
}
function quoteFor(r: RecordV1): Quote {
  // V1's finite consent/profile contract is validated before persistence; never store server display text.
  return { id: r.quoteID, expiresAt: r.expiresAt, maxCredits: 150, targetSeconds: 300, consentVersion: CONSENT_VERSION,
    providers: ['Anthropic (script)', 'Google Vertex AI (speech)'], estimate: 'Estimate — charged for actual usage, maximum 150 credits' };
}
const observed = new Set<string>();
function observeLifetime(key: string, owner: AuthSnapshot) {
  if (owner.signal.aborted || observed.has(key)) return;
  observed.add(key);
  owner.signal.addEventListener('abort', () => {
    try { sessionStorage.removeItem(key); } catch { /* the retired scope can never be reused */ }
    observed.delete(key);
  }, { once: true });
}
// Observe at the account module boundary, including a reload followed by sign-out before the paper
// sheet ever mounts. Ordinary component cleanup must not erase a request that may have started.
function observeAccount() {
  const owner = auth.snapshot();
  if (!config.url || !owner.session) return;
  observeLifetime(podcastRequestsKey(owner.session.user.id, owner.session.lifetime), owner);
}
observeAccount(); auth.subscribe(observeAccount);

/** One captured login lifetime; ordinary component cleanup intentionally does not erase unresolved work. */
export class PodcastRequests {
  private readonly key: string;
  constructor(private readonly account: string, private readonly owner: AuthSnapshot) {
    this.key = podcastRequestsKey(account, owner.session?.lifetime ?? 'signed-out');
  }
  private active() {
    const current = auth.snapshot();
    if (this.owner.signal.aborted || this.owner.session?.user.id !== this.account || current.generation !== this.owner.generation || current.session?.user.id !== this.account
      || current.session.lifetime !== this.owner.session?.lifetime) throw new PodcastTrackingError('retired');
    observeLifetime(this.key, this.owner);
  }
  private access<T>(work: () => T): T {
    this.active();
    try { return work(); } catch (e) { if (e instanceof PodcastTrackingError) throw e; throw new PodcastTrackingError('unavailable'); }
  }
  get(itemID: string): UnresolvedPodcast | null {
    return this.access(() => {
      const record = decode(sessionStorage.getItem(this.key)).records.find(r => r.itemID === itemID);
      return record ? { itemID, requestID: record.requestID, quote: quoteFor(record) } : null;
    });
  }
  remember(itemID: string, requestID: string, quote: Quote): UnresolvedPodcast {
    return this.access(() => {
      const next: RecordV1 = { itemID, requestID, quoteID: quote.id, expiresAt: quote.expiresAt };
      if (!valid(next) || !Number.isSafeInteger(quote.maxCredits) || quote.maxCredits < 1 || quote.maxCredits > MAX_QUOTE_CREDITS
        || !Number.isSafeInteger(quote.targetSeconds) || quote.targetSeconds < 1 || !CONSENT_VERSIONS.includes(quote.consentVersion)
        || quote.providers.length < 1 || quote.providers.length > 3 || !quote.providers.every(label => PROVIDER_LABEL.test(label))) throw new PodcastTrackingError('damaged');
      const ledger = decode(sessionStorage.getItem(this.key));
      const old = ledger.records.find(r => r.itemID === itemID || r.requestID === requestID);
      if (old && (old.itemID !== next.itemID || old.requestID !== next.requestID || old.quoteID !== next.quoteID || old.expiresAt !== next.expiresAt)) throw new PodcastTrackingError('conflict');
      if (!old) {
        if (ledger.records.length >= MAX_UNRESOLVED_PODCASTS) throw new PodcastTrackingError('full');
        ledger.records.push(next);
      }
      const bytes = JSON.stringify(ledger);
      sessionStorage.setItem(this.key, bytes);
      if (sessionStorage.getItem(this.key) !== bytes) throw new PodcastTrackingError('unavailable');
      return { itemID, requestID, quote: quoteFor(next) };
    });
  }
  /** Called only for the exact request's authoritative result, never a paper-discovery miss. */
  resolve(itemID: string, requestID: string): void {
    this.access(() => {
      const ledger = decode(sessionStorage.getItem(this.key));
      if (!ledger.records.some(r => r.itemID === itemID && r.requestID === requestID)) return;
      ledger.records = ledger.records.filter(r => r.itemID !== itemID || r.requestID !== requestID);
      const bytes = JSON.stringify(ledger);
      sessionStorage.setItem(this.key, bytes);
      if (sessionStorage.getItem(this.key) !== bytes) throw new PodcastTrackingError('unavailable');
    });
  }
}
