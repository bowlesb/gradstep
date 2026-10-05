// Account deletion steps after the database has closed the account: remove its
// private and support files from Storage, mark them deleted, delete the login.
// Every step is repeatable; storage and auth calls are retried.
import type { SupabaseClient } from '@supabase/supabase-js';

export const DELETION_CONFIRMATION = 'delete my account';
const PAPER_BUCKET = 'paper-assets';
const MAX_LISTED = 20_000;

export interface DeletionBegin {
  objects?: { bucket: string; path: string }[];
  prefixes?: { bucket: string; prefix: string }[];
  private_prefix?: string;
}

/** Only these folders may be emptied for an account: its private folder, its
 * support folder, and its private conversions' raw/ and reader/ folders. */
export function allowedPrefix(accountID: string, bucket: string, prefix: string): boolean {
  if (bucket === 'paper-assets') return prefix === `private/${accountID}/` || /^(raw|reader)\/[0-9a-f]{64}\/$/.test(prefix);
  if (bucket === 'support') return prefix === `${accountID}/`;
  return false;
}
export interface DeletionOutcome { complete: boolean; step?: 'files' | 'finish' | 'login' }

async function retry<T>(attempts: number, work: () => Promise<T>): Promise<T> {
  let last: unknown;
  for (let attempt = 1; attempt <= attempts; attempt++) {
    try { return await work(); } catch (error) { last = error; await new Promise(resolve => setTimeout(resolve, 250 * attempt)); }
  }
  throw last;
}

/** Every object path under `prefix` (folders are listed recursively, bounded). */
export async function listPrefix(service: SupabaseClient, bucket: string, prefix: string): Promise<string[]> {
  const files: string[] = [], folders = [prefix.replace(/\/$/, '')];
  while (folders.length && files.length < MAX_LISTED) {
    const folder = folders.pop()!;
    for (let offset = 0; ; offset += 1000) {
      const { data, error } = await service.storage.from(bucket).list(folder, { limit: 1000, offset });
      if (error) throw new Error('storage_list_failed');
      for (const entry of data ?? []) {
        const path = `${folder}/${entry.name}`;
        if (entry.id === null) folders.push(path); else files.push(path);
      }
      if (!data || data.length < 1000) break;
    }
  }
  return files;
}

export async function completeAccountDeletion(service: SupabaseClient, accountID: string, begun: DeletionBegin | null): Promise<DeletionOutcome> {
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
  } catch { return { complete: false, step: 'files' }; }
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

/** Finishes deletions left incomplete (login still linked, rows written in a
 * race, files not removed). Run by the paper worker on every invocation. */
export async function sweepAccountDeletions(service: SupabaseClient, log: (fields: Record<string, unknown>) => void): Promise<void> {
  const pending = await service.rpc('worker_account_deletions_pending', { p_limit: 3 });
  if (pending.error || !Array.isArray(pending.data)) return;
  for (const accountID of pending.data as string[]) {
    const begun = await service.rpc('worker_delete_account_begin', { p_account_id: accountID });
    if (begun.error) { log({ event: 'account_deletion_sweep_failed', account_id: accountID, step: 'begin' }); continue; }
    const outcome = await completeAccountDeletion(service, accountID, begun.data);
    log({ event: outcome.complete ? 'account_deletion_swept' : 'account_deletion_sweep_failed', account_id: accountID, step: outcome.step });
  }
}
