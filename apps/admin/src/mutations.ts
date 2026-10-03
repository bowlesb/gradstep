import { rpc } from './backend';

// Persist only a digest and operation ID. Notes, replies, and tokens never enter
// this retry journal. An acknowledged operation removes its entry, so sending
// the same text intentionally a second time is a new operation.
export async function mutate<T>(account: string, name: string, parameters: Record<string, unknown>): Promise<T> {
  const encoded = new TextEncoder().encode(JSON.stringify({ name, parameters }));
  const digest = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', encoded)), byte => byte.toString(16).padStart(2, '0')).join('');
  const key = `science-reader.admin.retry.${account}.${digest}`;
  const id = sessionStorage.getItem(key) ?? crypto.randomUUID();
  sessionStorage.setItem(key, id);
  const result = await rpc<T>(name, { ...parameters, p_id: id });
  sessionStorage.removeItem(key);
  return result;
}
