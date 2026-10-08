import { beforeEach, describe, expect, it, vi } from 'vitest';
import { BackendError, rpc } from '../src/lib/backend';
import { type Command, sendCommand } from '../src/lib/library';

vi.mock('../src/lib/backend', () => ({ rpc: vi.fn(), BackendError: class extends Error { constructor(readonly code: string) { super(code); } } }));
const request = vi.mocked(rpc);
const account = '11111111-2222-4333-8444-555555555555', itemID = 'aaaaaaaa-0000-4000-8000-000000000001';
const documentID = 'dddddddd-0000-4000-8000-000000000001', operationID = 'eeeeeeee-0000-4000-8000-000000000001';
const receipt = () => ({ result: { status: 'applied', kind: 'item', id: itemID, seq: 6, revision: 2 }, replayed: false,
  entry: { kind: 'item', id: itemID, document_id: documentID, created_seq: 1, state_seq: 6, membership_revision: 2, visible: true,
    added_at: '2026-10-08T09:00:00Z', last_remove_seq: 0, scope: 'shared_catalog', page_count: 10, readiness: 'unverified' } });
const shared = { expectedItemID: itemID, p_document_id: documentID, p_expected_revision: 1 };
const tagCommand = (): Extract<Command, { endpoint: 'v2_set_item_tags' }> => ({ ...shared, endpoint: 'v2_set_item_tags', p_tags: ['Review'], p_hidden_tags: ['Alignment'] });
beforeEach(() => request.mockReset());

describe('revision-checked paper actions', () => {
  it.each<Command>([tagCommand(), { ...shared, endpoint: 'v2_set_item_archived', p_archived: true }, { ...shared, endpoint: 'v2_set_library_item', p_present: false }])
  ('sends $endpoint with a local-only item binding and the same operation ID on a lost reply', async command => {
    request.mockRejectedValueOnce(new BackendError('connection')).mockResolvedValueOnce({ ...receipt(), replayed: true });
    await expect(sendCommand(account, command, operationID)).resolves.toMatchObject({ replayed: true });
    expect(request).toHaveBeenCalledTimes(2);
    expect(request.mock.calls[0]).toEqual(request.mock.calls[1]);
    expect(request.mock.calls[0][0]).toBe(command.endpoint);
    expect(request.mock.calls[0][1]).toMatchObject({ p_operation_id: operationID, p_document_id: documentID, p_expected_revision: 1 });
    expect(request.mock.calls[0][1]).not.toHaveProperty('expectedItemID');
  });
  it('freezes tag arrays and receipt identity before the first asynchronous send', async () => {
    const deferred = Promise.withResolvers<unknown>();
    request.mockReturnValueOnce(deferred.promise).mockResolvedValueOnce({ ...receipt(), replayed: true });
    const command = tagCommand(), sent = sendCommand(account, command, operationID);
    command.p_tags.push('Late draft'); command.p_hidden_tags.length = 0; command.p_expected_revision = 99; command.expectedItemID = operationID;
    deferred.reject(new BackendError('connection'));
    await sent;
    expect(request.mock.calls[0]).toEqual(request.mock.calls[1]);
    expect(request.mock.calls[1][1]).toEqual({ p_operation_id: operationID, p_document_id: documentID, p_expected_revision: 1, p_tags: ['Review'], p_hidden_tags: ['Alignment'] });
  });
  it('accepts a historical replay accompanied by its newer current item', async () => {
    const wire = receipt(); wire.entry.state_seq = 9; wire.entry.membership_revision = 4; wire.entry.visible = false;
    request.mockResolvedValueOnce({ ...wire, replayed: true });
    await expect(sendCommand(account, tagCommand(), operationID)).resolves.toMatchObject({ result: { revision: 2 }, entry: { membership_revision: 4 } });
  });
  it('accepts a revision race receipt without rewriting or retrying the user’s draft', async () => {
    const wire = receipt();
    request.mockResolvedValueOnce({ ...wire, result: { status: 'revision_conflict', kind: 'item', id: itemID, revision: 2 } });
    await expect(sendCommand(account, tagCommand(), operationID)).resolves.toMatchObject({ result: { status: 'revision_conflict' } });
    expect(request).toHaveBeenCalledTimes(1);
    expect(request.mock.calls[0][1]).toMatchObject({ p_tags: ['Review'], p_expected_revision: 1 });
  });
  it.each(['item', 'document', 'revision', 'unchanged-conflict'])('rejects a mismatched %s receipt binding', async mode => {
    const wire = receipt();
    if (mode === 'item') wire.entry.id = wire.result.id = operationID;
    if (mode === 'document') wire.entry.document_id = operationID;
    if (mode === 'revision') wire.entry.membership_revision = wire.result.revision = 3;
    request.mockResolvedValueOnce(mode === 'unchanged-conflict' ? { ...wire, result: { status: 'revision_conflict', kind: 'item', id: itemID, revision: 1 } } : wire);
    await expect(sendCommand(account, tagCommand(), operationID)).rejects.toThrow('command_binding');
    expect(request).toHaveBeenCalledTimes(1);
  });
  it('bounds automatic lost-response retry and never retries a rejected or invalid command', async () => {
    request.mockRejectedValue(new BackendError('connection'));
    await expect(sendCommand(account, tagCommand(), operationID)).rejects.toThrow('connection');
    expect(request).toHaveBeenCalledTimes(2);
    request.mockReset().mockRejectedValueOnce(new BackendError('request_rate_limit'));
    await expect(sendCommand(account, tagCommand(), operationID)).rejects.toThrow('request_rate_limit');
    expect(request).toHaveBeenCalledTimes(1);
    request.mockReset();
    await expect(sendCommand(account, { ...tagCommand(), p_tags: ['a'.repeat(41)] }, operationID)).rejects.toThrow('invalid_tags_command');
    expect(request).not.toHaveBeenCalled();
  });
});
