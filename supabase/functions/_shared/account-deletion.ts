// Account deletion steps after the database has closed the account: remove its
// private and support files from Storage, mark them deleted, delete the login.
// Every step is repeatable; storage and auth calls are retried.
import type { SupabaseClient } from '@supabase/supabase-js';

export const DELETION_CONFIRMATION = 'delete my account';
const PAPER_BUCKET = 'paper-assets';
const MAX_LISTED = 20_000;

/** A bounded traversal did not prove that all private objects were enumerated. */
export class IncompleteDeletionScan extends Error {
  readonly code = 'deletion_scan_incomplete';
  constructor() { super('deletion_scan_incomplete'); }
}

export interface DeletionBegin {
  blocked?: 'asset_write_uncertain';
  objects?: { bucket: string; path: string }[];
  prefixes?: { bucket: string; prefix: string }[];
  private_prefix?: string;
}

/** Only these folders may be emptied for an account: its private folder, its
 * support folder, its PDF uploads folder, and its private conversions' raw/ and reader/ folders. */
export function allowedPrefix(accountID: string, bucket: string, prefix: string): boolean {
  if (bucket === 'paper-assets') return prefix === `private/${accountID}/` || /^(raw|reader)\/[0-9a-f]{64}\/$/.test(prefix);
  if (bucket === 'support') return prefix === `${accountID}/`;
  if (bucket === 'paper-uploads') return prefix === `${accountID}/`;
  // The account's private episodes and the paper text its devices sent for them (migration 070).
  if (bucket === 'podcast-assets') return prefix === `private/${accountID}/`;
  if (bucket === 'private-content') return prefix === `podcast-sources/${accountID}/`;
  return false;
}
export interface DeletionOutcome { complete: boolean; step?: 'files' | 'finish' | 'login'; code?: 'deletion_scan_incomplete' | 'asset_write_uncertain' }

async function retry<T>(attempts: number, work: () => Promise<T>): Promise<T> {
  let last: unknown;
  for (let attempt = 1; attempt <= attempts; attempt++) {
    try { return await work(); } catch (error) {
      if (error instanceof IncompleteDeletionScan) throw error;
      last = error; await new Promise(resolve => setTimeout(resolve, 250 * attempt));
    }
  }
  throw last;
}

/** Every object path under `prefix` (folders are listed recursively, bounded). */
export async function listPrefix(service: SupabaseClient, bucket: string, prefix: string): Promise<string[]> {
  const files: string[] = [], folders = [prefix.replace(/\/$/, '')];
  let visited = 0;
  while (folders.length) {
    if (++visited > MAX_LISTED) throw new IncompleteDeletionScan();
    const folder = folders.pop()!;
    for (let offset = 0; ; offset += 1000) {
      const { data, error } = await service.storage.from(bucket).list(folder, { limit: 1000, offset });
      if (error) throw new Error('storage_list_failed');
      for (const entry of data ?? []) {
        const path = `${folder}/${entry.name}`;
        if (entry.id === null) {
          if (visited + folders.length >= MAX_LISTED) throw new IncompleteDeletionScan();
          folders.push(path);
        } else {
          if (files.length >= MAX_LISTED) throw new IncompleteDeletionScan();
          files.push(path);
        }
      }
      if (!data || data.length < 1000) break;
    }
  }
  return files;
}

export async function completeAccountDeletion(service: SupabaseClient, accountID: string, begun: DeletionBegin | null): Promise<DeletionOutcome> {
  if (begun?.blocked === 'asset_write_uncertain') return { complete: false, step: 'files', code: begun.blocked };
  try {
    const byBucket = new Map<string, Set<string>>();
    for (const object of begun?.objects ?? []) {
      if (!byBucket.has(object.bucket)) byBucket.set(object.bucket, new Set());
      byBucket.get(object.bucket)!.add(object.path);
    }
    // Folders: the account's private and support folders and its private
    // conversions' raw/reader folders (validated; anything else is ignored).
    const prefixes = begun?.prefixes ?? (begun?.private_prefix ? [{ bucket: PAPER_BUCKET, prefix: begun.private_prefix }] : []);
    for (const { bucket, prefix } of prefixes) {
      if (!allowedPrefix(accountID, bucket, prefix)) continue;
      if (!byBucket.has(bucket)) byBucket.set(bucket, new Set());
      for (const path of await retry(3, () => listPrefix(service, bucket, prefix))) byBucket.get(bucket)!.add(path);
    }
    for (const [bucket, paths] of byBucket) {
      const all = [...paths];
      for (let i = 0; i < all.length; i += 100) {
        const batch = all.slice(i, i + 100);
        await retry(3, async () => { const { error } = await service.storage.from(bucket).remove(batch); if (error) throw new Error('storage_remove_failed'); });
      }
    }
  } catch (error) {
    return { complete: false, step: 'files', ...(error instanceof IncompleteDeletionScan ? { code: error.code } : {}) };
  }
  try {
    await retry(3, async () => {
      const { error } = await service.rpc('worker_delete_account_finish', { p_account_id: accountID });
      if (error) throw new Error('finish_failed');
    });
  } catch { return { complete: false, step: 'finish' }; }
  try {
    await retry(3, async () => {
      const { error } = await service.auth.admin.deleteUser(accountID);
      if (error && !/not.?found/i.test(error.message)) throw new Error('login_delete_failed');
    });
  } catch { return { complete: false, step: 'login' }; }
  return { complete: true };
}

/** Cancels the account's podcast work in its own transaction before deletion
 * begins (deletion refuses while an operation is unsettled; a cancel request made
 * inside that refused transaction would roll back). Best effort: a database
 * without migration 048 has no such function, and deletion proceeds unchanged. */
export async function closePodcastWork(service: SupabaseClient, accountID: string): Promise<void> {
  try { await service.rpc('worker_podcast_account_closing', { p_account_id: accountID }); } catch { /* deletion decides */ }
}

/** Finishes deletions left incomplete (login still linked, rows written in a
 * race, files not removed). Run by the paper worker on every invocation. Each
 * outcome is reported (migration 128): a failure backs the account off, so one
 * that cannot finish never holds every slot, and a stall reaches Health. */
export async function sweepAccountDeletions(service: SupabaseClient, log: (fields: Record<string, unknown>) => void): Promise<void> {
  const pending = await service.rpc('worker_account_deletions_pending', { p_limit: 3 });
  if (pending.error || !Array.isArray(pending.data)) return;
  for (const accountID of pending.data as string[]) {
    await closePodcastWork(service, accountID);
    const begun = await service.rpc('worker_delete_account_begin', { p_account_id: accountID });
    if (begun.error) {
      log({ event: 'account_deletion_sweep_failed', account_id: accountID, step: 'begin' });
      await reportSweep(service, accountID, false, 'begin', begun.error.message === 'account_busy' ? 'account_busy' : 'begin_failed');
      continue;
    }
    const outcome = await completeAccountDeletion(service, accountID, begun.data);
    log({ event: outcome.complete ? 'account_deletion_swept' : 'account_deletion_sweep_failed', account_id: accountID, step: outcome.step,
      ...(outcome.code ? { code: outcome.code } : {}) });
    await reportSweep(service, accountID, outcome.complete, outcome.complete ? null : outcome.step ?? null, outcome.code ?? null);
  }
}

/** Best effort: a database before migration 128 has no such function, and the sweep proceeds as before. */
async function reportSweep(service: SupabaseClient, accountID: string, complete: boolean, step: string | null, code: string | null): Promise<void> {
  try { await service.rpc('worker_account_deletion_attempt', { p_account_id: accountID, p_complete: complete, p_step: step, p_code: code }); }
  catch { /* the next sweep tries again */ }
}
