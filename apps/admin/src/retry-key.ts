// One request ID per pending admin change (review A14, 2026-10-21). Only a digest and the ID are kept: notes, replies,
// reasons and tokens never enter this journal. The ID is reused while the outcome is unknown (a lost answer, a server
// error, a rate limit), so a retry applies the change once. A final answer (acknowledged, or refused by the server for
// the request itself) clears it, so the same change made again later is a new request: a stale ID can never re-apply
// an old intent after newer changes.
type RetryStorage = Pick<Storage, 'getItem' | 'setItem' | 'removeItem'>;

/** A refusal the server gave for this request (not a lost or temporary failure): retrying the same ID cannot help. */
export class FinalRequestError extends Error {
  readonly final = true;
}
export const isFinal = (error: unknown): boolean => !!error && typeof error === 'object' && (error as { final?: unknown }).final === true;

export async function once<T>(account: string, name: string, parameters: Record<string, unknown>, send: (id: string) => Promise<T>,
  storage: RetryStorage = sessionStorage): Promise<T> {
  const encoded = new TextEncoder().encode(JSON.stringify({ name, parameters }));
  const digest = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', encoded)), byte => byte.toString(16).padStart(2, '0')).join('');
  const key = `science-reader.admin.retry.${account}.${digest}`;
  const id = storage.getItem(key) ?? crypto.randomUUID();
  storage.setItem(key, id);
  let result: T;
  try { result = await send(id); }
  catch (error) {
    if (isFinal(error)) storage.removeItem(key);
    throw error;
  }
  storage.removeItem(key);
  return result;
}
