import { rpc } from './backend';

// Persist only a digest and operation ID. Notes, replies, reasons and tokens never enter
// this retry journal. An acknowledged operation removes its entry, so sending the same
// text intentionally a second time is a new operation.
export async function once<T>(account: string, name: string, parameters: Record<string, unknown>, send: (id: string) => Promise<T>): Promise<T> {
  const encoded = new TextEncoder().encode(JSON.stringify({ name, parameters }));
  const digest = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', encoded)), byte => byte.toString(16).padStart(2, '0')).join('');
  const key = `science-reader.admin.retry.${account}.${digest}`;
  const id = sessionStorage.getItem(key) ?? crypto.randomUUID();
  sessionStorage.setItem(key, id);
  const result = await send(id);
  sessionStorage.removeItem(key);
  return result;
}

export function mutate<T>(account: string, name: string, parameters: Record<string, unknown>): Promise<T> {
  return once(account, name, parameters, id => rpc<T>(name, { ...parameters, p_id: id }));
}
