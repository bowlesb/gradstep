import { useMemo, useRef, useState, useSyncExternalStore } from 'react';
import type { ChatSession } from '../lib/chat-session';
import { LibraryCatalogs, catalogEvent, catalogName, type CatalogOperation } from '../lib/library-catalogs';

export function useCatalogs(chat: ChatSession | null) {
  const version = useSyncExternalStore(chat?.history.subscribe ?? (() => () => {}), chat?.history.getVersion ?? (() => 0));
  const state = useMemo(() => new LibraryCatalogs(chat?.history.state), [chat, version]);
  const [selected, select] = useState<string | null>(null);
  const currentID = state.resolve(selected ?? state.defaultID);
  const tail = useRef<Promise<void>>(Promise.resolve());
  const ready = !!chat && !chat.signal.aborted && chat.history.status === 'ready';
  const currentState = () => new LibraryCatalogs(chat?.history.state);
  const write = (operations: CatalogOperation[]) => {
    const work = tail.current.catch(() => {}).then(async () => {
      if (!chat || chat.signal.aborted || chat.history.status !== 'ready') throw Error('Unlock your library before changing catalogs.');
      await chat.history.commit([{ id: crypto.randomUUID(), event: catalogEvent(chat.history.state, operations) }]);
      chat.signal.throwIfAborted(); void chat.history.sync().catch(() => {});
    });
    tail.current = work; return work;
  };
  const name = (raw: string, excluding?: string) => {
    const value = catalogName(raw);
    if (!value || currentState().catalogs.some(c => c.id !== excluding && c.name.toLocaleLowerCase() === value.toLocaleLowerCase()))
      throw Error('Choose a different name, up to 80 characters.');
    return value;
  };
  const create = async (raw: string) => { const id = crypto.randomUUID(); await write([{ action: 'create', catalogID: id, name: name(raw) }]); select(id); };
  const rename = (id: string, raw: string) => write([{ action: 'rename', catalogID: id, name: name(raw, id) }]);
  const makeDefault = (id: string) => { select(currentID); return write([{ action: 'makeDefault', catalogID: id }]); };
  const assign = async (key: string, id = currentID) => {
    if (currentState().catalogFor(key) !== currentState().resolve(id)) await write([{ action: 'assign', catalogID: id, paperKey: key }]);
  };
  const retire = (id: string, destination?: string, newName?: string) => {
    const operations: CatalogOperation[] = [];
    if (newName !== undefined) { destination = crypto.randomUUID(); operations.push({ action: 'create', catalogID: destination, name: name(newName, id) }); }
    if (!destination || destination === id || (!operations.length && !currentState().catalogs.some(c => c.id === destination))) throw Error('Choose another catalog.');
    operations.push({ action: 'retire', catalogID: id, destinationID: destination });
    return write(operations);
  };
  return { state, currentID, currentState, select, ready, create, rename, makeDefault, assign, retire, signal: chat?.signal };
}
export type CatalogController = ReturnType<typeof useCatalogs>;
