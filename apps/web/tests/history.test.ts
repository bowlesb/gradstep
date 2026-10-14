// Encrypted history sync against an in-memory event log with the v1_append_event / v3_pull_events shapes.
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { fromBytea, sha256, toBytea } from '../src/lib/bytes';

const server = vi.hoisted(() => ({ log: [] as Record<string, unknown>[], failNextAppend: false, appended: [] as string[], corrupt: false }));
vi.mock('../src/lib/backend', async importOriginal => {
  const actual = await importOriginal<typeof import('../src/lib/backend')>();
  return {
    ...actual,
    rpc: async (name: string, p: Record<string, unknown>) => {
      if (name === 'v1_append_event') {
        if (server.failNextAppend) { server.failNextAppend = false; throw new actual.BackendError('connection'); }
        server.appended.push(p.p_ciphertext as string);
        const existing = server.log.find(e => e.id === p.p_id);
        if (existing) { if (existing.ciphertext !== p.p_ciphertext) throw new actual.BackendError('request_failed'); return existing.cursor; }
        const bytes = fromBytea(p.p_ciphertext);
        const row = { id: p.p_id, device_id: p.p_device_id, cursor: server.log.length + 1, epoch: p.p_epoch, format: p.p_format, ciphertext: p.p_ciphertext,
          ciphertext_sha256: toBytea(await sha256(bytes)) };
        server.log.push(row);
        return row.cursor;
      }
      if (name === 'v3_pull_events') {
        const after = p.p_after as number, limit = p.p_limit as number;
        const events = server.log.filter(e => (e.cursor as number) > after).slice(0, limit).map(e => (server.corrupt ? { ...e, ciphertext_sha256: toBytea(new Uint8Array(32)) } : e));
        return { events, next_cursor: (events.at(-1)?.cursor as number | undefined) ?? after, has_more: server.log.filter(e => (e.cursor as number) > after).length > limit };
      }
      if (name === 'v1_acknowledge_cursor') return null;
      throw new Error(`unexpected ${name}`);
    },
  };
});

const { History } = await import('../src/lib/history');
const { keyRing, generateBundle } = await import('../src/lib/wire');
const account = '11111111-2222-4333-8444-555555555555';
const deviceA = 'aaaaaaaa-0000-4000-8000-000000000001', deviceB = 'bbbbbbbb-0000-4000-8000-000000000002';
const C = 'cccccccc-0000-4000-8000-000000000003';

describe('encrypted history sync', () => {
  beforeEach(() => { server.log = []; server.appended = []; server.failNextAppend = false; server.corrupt = false; });

  it('sends this browser’s events, reads another device’s, and keeps ID and bytes across a retry', async () => {
    const ring = await keyRing(generateBundle(account)), signal = new AbortController().signal;
    const a = new History(account, deviceA, ring, signal, async () => ring), b = new History(account, deviceB, ring, signal, async () => ring);
    await a.sync(); await b.sync();
    expect(a.status).toBe('ready');
    const root = crypto.randomUUID(), question = crypto.randomUUID();
    server.failNextAppend = true;
    await expect(a.append([
      { id: root, event: { kind: 'conversation', entityID: C, parents: [], text: 'What is DPO?', createdAt: 1 } },
      { id: question, event: { kind: 'message', entityID: crypto.randomUUID(), parents: [root], conversationID: C, text: 'What is DPO?', role: 'user', status: 'complete' } },
    ])).rejects.toThrow('history_unsaved');
    expect(a.unsaved).toBe(2);
    expect(a.state.conversationSummaries()).toHaveLength(1); // shown here meanwhile
    await a.sync();
    expect(a.unsaved).toBe(0);
    expect(server.log).toHaveLength(2);
    expect(new Set(server.appended).size).toBe(2); // the retried event carried identical bytes
    await b.sync();
    const branch = b.state.conversationBranches(C)[0];
    expect(branch.messages.map(m => m.payload.text)).toEqual(['What is DPO?']);
    expect(branch.messages[0].deviceID).toBe(deviceA);
    await b.append([{ id: crypto.randomUUID(), event: { kind: 'message', entityID: crypto.randomUUID(), parents: [question], conversationID: C, text: 'An objective.', role: 'assistant', status: 'complete' } }]);
    await a.sync();
    expect(a.state.conversationBranches(C)[0].messages.map(m => m.payload.role)).toEqual(['user', 'assistant']);
  });

  it('stops at a page whose digest does not match, without advancing', async () => {
    const ring = await keyRing(generateBundle(account)), signal = new AbortController().signal;
    const a = new History(account, deviceA, ring, signal, async () => ring);
    await a.append([{ id: crypto.randomUUID(), event: { kind: 'note', entityID: crypto.randomUUID(), parents: [], text: 'x' } }]);
    const b = new History(account, deviceB, ring, signal, async () => ring);
    server.corrupt = true;
    await expect(b.sync()).rejects.toThrow();
    expect(b.status).toBe('error');
    expect(b.state.events.size).toBe(0);
  });

  it('refuses events sealed for another account', async () => {
    const ring = await keyRing(generateBundle(account)), other = await keyRing({ ...generateBundle(account) });
    const signal = new AbortController().signal;
    await new History(account, deviceA, ring, signal, async () => ring).append([{ id: crypto.randomUUID(), event: { kind: 'note', entityID: crypto.randomUUID(), parents: [], text: 'x' } }]);
    await expect(new History(account, deviceB, other, signal, async () => other).sync()).rejects.toThrow();
  });
});

describe('history integrity and retirement', () => {
  beforeEach(() => { server.log = []; server.appended = []; server.failNextAppend = false; server.corrupt = false; });
  it('retries a saved batch with identical IDs without resealing or duplicating it', async () => {
    const ring = await keyRing(generateBundle(account)), signal = new AbortController().signal;
    const h = new History(account, deviceA, ring, signal, async () => ring);
    const entries = [{ id: crypto.randomUUID(), event: { kind: 'note' as const, entityID: crypto.randomUUID(), parents: [], text: 'Immutable' } }];
    await h.append(entries); const bytes = server.log[0].ciphertext;
    await h.append(entries); expect(server.log).toHaveLength(1); expect(server.log[0].ciphertext).toBe(bytes);
    await expect(h.append([{ ...entries[0], event: { ...entries[0].event, text: 'Changed' } }])).rejects.toThrow('event_conflict');
  });
  it('retires before accepting any late encrypted batch', async () => {
    const ring = await keyRing(generateBundle(account)), owner = new AbortController(), h = new History(account, deviceA, ring, owner.signal, async () => ring);
    owner.abort();
    await expect(h.append([{ id: crypto.randomUUID(), event: { kind: 'note', entityID: crypto.randomUUID(), parents: [], text: 'Late' } }])).rejects.toThrow();
    expect(h.state.events.size).toBe(0); expect(server.log).toHaveLength(0);
  });
  it('rolls back an entire local batch if its second event closes a causal cycle', async () => {
    const ring = await keyRing(generateBundle(account)), h = new History(account, deviceA, ring, new AbortController().signal, async () => ring);
    const a = crypto.randomUUID(), b = crypto.randomUUID();
    await expect(h.append([
      { id: a, event: { kind: 'note', entityID: crypto.randomUUID(), parents: [b], text: 'A' } },
      { id: b, event: { kind: 'note', entityID: crypto.randomUUID(), parents: [a], text: 'B' } },
    ])).rejects.toThrow();
    expect(h.state.events.size).toBe(0); expect(h.unsaved).toBe(0); expect(server.log).toHaveLength(0);
  });
});
