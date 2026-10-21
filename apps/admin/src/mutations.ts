import { rpc } from './backend';
import { once } from './retry-key';

// Persist only a digest and operation ID (retry-key.ts). An acknowledged operation, or one the server refused, removes
// its entry, so sending the same text intentionally a second time is a new operation.
export { once };

export function mutate<T>(account: string, name: string, parameters: Record<string, unknown>): Promise<T> {
  return once(account, name, parameters, id => rpc<T>(name, { ...parameters, p_id: id }));
}
