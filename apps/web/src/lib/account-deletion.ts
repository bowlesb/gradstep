// Deleting the account from the browser (owner, 2026-10-16), as the apps do (RootView.swift DeleteAccountView,
// ReaderModel.deleteAccount): the server deletes first (`account-delete`); only after it answers does this browser
// forget what it held for the account. A failed request changes nothing here, so Try again is always safe.
import { BackendError, functionPost } from './backend';

/** The function's confirmation (supabase/functions/_shared/account-deletion.ts DELETION_CONFIRMATION). */
export const DELETION_CONFIRMATION = 'delete my account';
/** What the reader types to enable the button, as in the apps. */
export const TYPED_CONFIRMATION = 'DELETE';

type Post = <T>(path: string, body: unknown, options: { account: string; maximum: number; timeout: number }) => Promise<T>;

/** Asks the server to delete the signed-in account. Resolves only when the server says it is deleted (a sweep may
 * finish the last storage step later: `complete: false` is still deleted, as the apps treat it). */
export async function requestAccountDeletion(account: string, post: Post = functionPost): Promise<void> {
  const reply = await post<{ deleted?: unknown }>('account-delete', { confirm: DELETION_CONFIRMATION }, { account, maximum: 4_096, timeout: 60_000 });
  if (reply?.deleted !== true) throw new BackendError('invalid_response');
}

/** One plain sentence for a failed request; nothing local has changed when it is shown. */
export function deletionFailure(error: unknown): string {
  const code = error instanceof BackendError ? error.code : '';
  const wait = error instanceof BackendError ? error.retryAfter : undefined;
  if (code === 'connection') return 'Couldn’t reach Gradstep. Check your connection and try again.';
  if (code === 'throttled' || code === 'rate_limited' || code === 'request_rate_limit')
    return wait ? `Too many requests right now. Try again in ${wait} second${wait === 1 ? '' : 's'}.` : 'Too many requests right now. Try again in a moment.';
  if (code === 'account_busy') return 'An episode or another task is still finishing. Try again in a moment.';
  if (code === 'sign_in_required') return 'Your sign-in has expired. Sign in again, then delete the account.';
  return 'The account couldn’t be deleted. Try again.';
}

/** Per-browser keys that hold the account's own words: the Library's tag filter is one of its tags (App.tsx). */
const CONTENT_KEYS = new Set(['gradstep.library.tag']);

/** Every key this app stored for the account in `storage` (consent, the Feed's offer, episode positions, episode
 * requests): `gradstep.…` keys with the account's id as one of their dot-separated parts, and the per-browser keys
 * holding its words. Per-browser settings (theme, columns, filters) and the session (signing out removes it) are not
 * the account's. Returns the keys removed. */
export function forgetAccountStorage(account: string, storage: Pick<Storage, 'length' | 'key' | 'removeItem'>): string[] {
  const id = account.toLowerCase(), keys: string[] = [], removed: string[] = [];
  for (let i = 0; i < storage.length; i++) { const key = storage.key(i); if (key) keys.push(key); }
  for (const key of keys) {
    if (CONTENT_KEYS.has(key) || (key.startsWith('gradstep.') && key.split('.').some(part => part.toLowerCase() === id))) { storage.removeItem(key); removed.push(key); }
  }
  return removed;
}

// The confirmation after signing out: the account's screens are gone, so the sign-in screen says it once.
let deleted = false;
export function noteAccountDeleted(): void { deleted = true; }
export function takeAccountDeletedNotice(): boolean { const value = deleted; deleted = false; return value; }
