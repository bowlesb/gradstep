import { beforeEach, describe, expect, it, vi } from 'vitest';
import { BackendError, rpc } from '../src/lib/backend';
import { type CommandResponse, decodeEntry, Reconciler, sendCommand } from '../src/lib/library';

vi.mock('../src/lib/backend', () => ({
  rpc: vi.fn(),
  BackendError: class extends Error { constructor(readonly code: string) { super(code); } },
}));
const request = vi.mocked(rpc);
const account = '11111111-2222-4333-8444-555555555555';
const itemID = 'aaaaaaaa-0000-4000-8000-000000000001';
const importID = 'bbbbbbbb-0000-4000-8000-000000000001';
const documentID = 'dddddddd-0000-4000-8000-000000000001';
const operationID = 'eeeeeeee-0000-4000-8000-000000000001';
const item = (extra: Record<string, unknown> = {}) => ({
  kind: 'item', id: itemID, document_id: documentID, created_seq: 1, state_seq: 3, membership_revision: 1,
  visible: true, added_at: '2026-10-07T09:00:00Z', last_remove_seq: 0, scope: 'shared_catalog', page_count: 10, readiness: 'unverified', ...extra,
});
const imported = (extra: Record<string, unknown> = {}) => ({
  kind: 'import', id: importID, created_seq: 2, state_seq: 3, intent_revision: 1, visible: true, phase: 'acquiring',
  source: 'arxiv', source_id: '1706.03762', source_url: 'https://arxiv.org/abs/1706.03762', retryable: false, ...extra,
});
const baseline = (entries: ReturnType<typeof item | typeof imported>[], through = 5) => {
  const last = entries.at(-1);
  return { format: 2, account_id: account, baseline_cursor: through, retained_after: 0, entries, has_more: false,
    next_cursor: last ? { format: 2, account_id: account, through, created_seq: last.created_seq, id: last.id, kind: last.kind } : null };
};
const changes = (through: number, batches: { seq: number; entries: unknown[] }[] = [], next = through, more = false) => ({
  format: 2, account_id: account, through, retained_after: 0, changes: batches, next_cursor: next, has_more: more,
});
async function ready(entries = [item()]) {
  const reconciler = new Reconciler(account);
  request.mockResolvedValueOnce(baseline(entries)).mockResolvedValueOnce(changes(5));
  await reconciler.pull();
  request.mockClear();
  return reconciler;
}
beforeEach(() => request.mockReset());

describe('complete library observations', () => {
  it('allows a current baseline row ahead of its creation boundary only after catch-up covers it', async () => {
    const reconciler = new Reconciler(account);
    request.mockResolvedValueOnce(baseline([item({ state_seq: 7 })])).mockResolvedValueOnce(changes(5));
    await expect(reconciler.pull()).rejects.toThrow('incomplete_observation');
    expect(reconciler.phase).toBe('catching_up');
    expect(reconciler.committed).toBe(5);
    request.mockResolvedValueOnce(changes(7, [{ seq: 7, entries: [item({ state_seq: 7 })] }]));
    await reconciler.pull();
    expect(reconciler.phase).toBe('ready');
    expect(reconciler.committed).toBe(7);
  });

  it('rejects a complete boundary with an import mapping to a missing item', async () => {
    const reconciler = new Reconciler(account);
    request.mockResolvedValueOnce(baseline([imported({ phase: 'ready', visible: false, library_item_id: itemID, document_id: documentID })]))
      .mockResolvedValueOnce(changes(5));
    await expect(reconciler.pull()).rejects.toThrow('incomplete_observation');
    expect(reconciler.phase).toBe('catching_up');
  });

  it('observes both cancelled import and withdrawn item from their grouped delta', async () => {
    const reconciler = new Reconciler(account);
    request.mockResolvedValueOnce(baseline([item(), imported({ library_item_id: itemID, document_id: documentID })])).mockResolvedValueOnce(changes(5));
    await reconciler.pull();
    request.mockResolvedValueOnce(changes(6, [{ seq: 6, entries: [
      item({ state_seq: 6, visible: false, membership_revision: 2 }),
      imported({ state_seq: 6, phase: 'cancelled', visible: false, intent_revision: 2, library_item_id: itemID, document_id: documentID }),
    ] }]));
    await reconciler.pull(undefined, 6, true);
    expect(reconciler.phase).toBe('ready');
    expect([...reconciler.entries.values()].every(e => !e.visible && e.state_seq === 6)).toBe(true);
  });

  it('rejects the whole page if a later group corrupts identity', async () => {
    const reconciler = await ready();
    const original = reconciler.entries.get('item:' + itemID);
    request.mockResolvedValueOnce(changes(7, [
      { seq: 6, entries: [item({ state_seq: 6, tags: ['New'] })] },
      { seq: 7, entries: [item({ state_seq: 7, document_id: importID })] },
    ]));
    await expect(reconciler.pull()).rejects.toThrow('identity');
    expect(reconciler.entries.get('item:' + itemID)).toBe(original);
    expect(reconciler.committed).toBe(5);
  });

  it('fails a fresh boundary below the receipt floor without advancing the cursor or polling forever', async () => {
    const reconciler = await ready();
    request.mockResolvedValueOnce(changes(7));
    await expect(reconciler.pull(undefined, 9, true)).rejects.toThrow('receipt_not_observed');
    expect(reconciler.committed).toBe(7);
    expect(reconciler.phase).toBe('catching_up');
    expect(request).toHaveBeenCalledTimes(1);
  });

  it.each([0, 9])('finishes an interrupted fixed boundary, then starts a fresh receipt observation (floor %i)', async minimum => {
    const reconciler = await ready();
    request.mockResolvedValueOnce(changes(8, [{ seq: 6, entries: [item({ state_seq: 6, tags: ['First'] })] }], 6, true))
      .mockRejectedValueOnce(new BackendError('connection'));
    await expect(reconciler.pull()).rejects.toThrow('connection');
    expect(reconciler.committed).toBe(6);
    request.mockClear();
    request.mockResolvedValueOnce(changes(8)).mockResolvedValueOnce(changes(9, [{ seq: 9, entries: [item({ state_seq: 9, tags: ['Latest'] })] }]));
    await reconciler.pull(undefined, minimum, true);
    expect(request.mock.calls.map(([, params]) => params)).toEqual([
      { p_after: 6, p_through: 8, p_limit: 100 }, { p_after: 8, p_through: null, p_limit: 100 },
    ]);
    expect(reconciler.committed).toBe(9);
    expect(reconciler.entries.get('item:' + itemID)).toMatchObject({ tags: ['Latest'] });
  });

  it('does not apply a late reply after its owner is cancelled', async () => {
    const reconciler = new Reconciler(account), controller = new AbortController();
    request.mockImplementationOnce(async () => { controller.abort(); return baseline([item()]); });
    await expect(reconciler.pull(controller.signal)).rejects.toThrow();
    expect(reconciler.entries.size).toBe(0);
    expect(reconciler.committed).toBeNull();
  });
});

describe('receipts bound to their frozen command', () => {
  const cancel = { endpoint: 'v2_cancel_import' as const, p_import_id: importID, p_expected_revision: 1 };
  const response = () => ({ result: { status: 'applied', kind: 'import', id: importID, seq: 6, revision: 2 }, replayed: true,
    entry: imported({ state_seq: 9, intent_revision: 3, phase: 'cancelled', visible: false }) });

  it('accepts a replay whose current entry advanced past its historical receipt', async () => {
    request.mockResolvedValueOnce(response());
    await expect(sendCommand(account, cancel, operationID)).resolves.toMatchObject({ result: { seq: 6, revision: 2 }, entry: { state_seq: 9, intent_revision: 3 } });
  });

  it('rejects a response for another import even when the generic response is valid', async () => {
    const wire = response(); wire.result.id = operationID; wire.entry.id = operationID;
    request.mockResolvedValueOnce(wire);
    await expect(sendCommand(account, cancel, operationID)).rejects.toThrow('command_binding');
  });

  it('rejects the wrong resulting revision', async () => {
    const wire = response(); wire.result.revision = 3;
    request.mockResolvedValueOnce(wire);
    await expect(sendCommand(account, cancel, operationID)).rejects.toThrow('command_binding');
  });

  it('requires begin-import to match the original source and operation UUID', async () => {
    request.mockResolvedValueOnce({ result: { status: 'applied', kind: 'import', id: operationID, seq: 3, revision: 1 },
      replayed: false, entry: imported({ id: operationID }) });
    await expect(sendCommand(account, { endpoint: 'v2_begin_import', p_source_id: '2305.18290', p_requested_revision: null, p_observed_cursor: 2 }, operationID))
      .rejects.toThrow('command_binding');
  });

  it('replays the exact body and operation UUID after a lost reply', async () => {
    request.mockRejectedValueOnce(new BackendError('connection')).mockResolvedValueOnce(response());
    await sendCommand(account, cancel, operationID);
    expect(request.mock.calls[0]).toEqual(request.mock.calls[1]);
    expect(request).toHaveBeenCalledTimes(2);
  });
});

describe('receipt targets in a complete observation', () => {
  const receipt = (): CommandResponse => ({ result: { status: 'applied', kind: 'import', id: importID, seq: 6, revision: 2 }, replayed: true,
    entry: decodeEntry(imported({ state_seq: 9, intent_revision: 3 })) });

  it.each(['missing', 'old'])('does not resolve a receipt at a sufficient cursor if its target is %s', async mode => {
    const reconciler = new Reconciler(account);
    request.mockResolvedValueOnce(baseline(mode === 'old' ? [imported()] : [], 9)).mockResolvedValueOnce(changes(9));
    await reconciler.pull(undefined, 9, true);
    expect(() => reconciler.requireReceipt(receipt())).toThrow('receipt_not_observed');
  });

  it('rejects contradictory target contents at the same sequence', async () => {
    const reconciler = new Reconciler(account);
    request.mockResolvedValueOnce(baseline([imported({ state_seq: 9, intent_revision: 3, phase: 'cancelled', visible: false })], 9))
      .mockResolvedValueOnce(changes(9));
    await reconciler.pull();
    expect(() => reconciler.requireReceipt(receipt())).toThrow('conflicting_revision');
  });

  it('accepts a target that advanced again after the receipt, preserving its identity', async () => {
    const reconciler = new Reconciler(account);
    request.mockResolvedValueOnce(baseline([imported({ state_seq: 10, intent_revision: 4, phase: 'cancelled', visible: false })], 10))
      .mockResolvedValueOnce(changes(10));
    await reconciler.pull();
    expect(() => reconciler.requireReceipt(receipt())).not.toThrow();
  });
});
