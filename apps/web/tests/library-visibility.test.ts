// Actual synthetic PostgreSQL output, exercised through the unchanged public
// Reconciler/RPC path. Neither private decoder is exported just for these tests.
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { rpc } from '../src/lib/backend';
import { Reconciler } from '../src/lib/library';

vi.mock('../src/lib/backend', () => ({
  rpc: vi.fn(),
  BackendError: class extends Error { constructor(readonly code: string) { super(code); } },
}));
const request = vi.mocked(rpc);
const bytes = readFileSync(new URL('../../../tests/fixtures/library-visibility/legacy-v3.json', import.meta.url));
const fixture = JSON.parse(bytes.toString('utf8'));
const lineage = JSON.parse(readFileSync(new URL('../../../tests/fixtures/library-visibility/lineage.json', import.meta.url), 'utf8'));
const account = '39500000-0000-0000-0000-000000000001';
const arxiv = '39500000-0000-0000-0000-000000000012', web = '39500000-0000-0000-0000-000000000014';

// Test harness bootstrapping only: an empty account at cursor0 lets the actual
// captured deltas pass through the existing network/decode/reconcile path.
const emptyInitialBaseline = { format: 2, account_id: account, baseline_cursor: 0, retained_after: 0,
  entries: [], next_cursor: null, has_more: false };
const respond = (...pages: unknown[]) => pages.forEach(page => request.mockResolvedValueOnce(structuredClone(page)));
const ids = (value: Reconciler) => [...value.entries.values()].map(entry => entry.id).sort();
beforeEach(() => request.mockReset());

describe('SQL-captured legacy source visibility', () => {
  it('retains capture lineage and contains no upload, descriptor or visibility internals', () => {
    expect(createHash('sha256').update(bytes).digest('hex')).toBe(lineage.fixture_sha256);
    expect(fixture.baselines).toHaveLength(2); expect(fixture.changes).toHaveLength(5);
    const inspect = (value: unknown): void => {
      if (!value || typeof value !== 'object') return;
      if (Array.isArray(value)) { value.forEach(inspect); return; }
      const fields = value as Record<string, unknown>;
      for (const key of ['descriptor_ref', 'minimum_source_level', 'read_level', 'dataset_epoch']) expect(fields).not.toHaveProperty(key);
      expect(fields.source).not.toBe('upload'); expect(String(fields.source_id ?? '').startsWith('upload:')).toBe(false);
      Object.values(fields).forEach(inspect);
    };
    inspect(fixture);
    for (const hidden of ['39500000-0000-0000-0000-000000000011', '39500000-0000-0000-0000-000000000013']) {
      expect(bytes.toString()).not.toContain(hidden); // Also catches source-null upload tombstones.
    }
    expect(fixture.changes.map((page: { next_cursor: number }) => page.next_cursor)).toEqual([2, 5, 3, 5, 6]);
    expect(fixture.changes.map((page: { has_more: boolean }) => page.has_more)).toEqual([true, false, false, false, false]);
  });

  it.each([0, 1])('accepts source-restricted full baseline %s through the unchanged fetch/decode path', async index => {
    const value = new Reconciler(account);
    respond(fixture.baselines[index], fixture.changes[3]);
    await value.pull();
    expect(value.phase).toBe('ready'); expect(value.committed).toBe(5);
    expect(ids(value)).toEqual(index === 0 ? [arxiv] : [arxiv, web]);
    expect(request.mock.calls.map(([name]) => name)).toEqual(['v3_library_page', 'v3_library_changes']);
    expect(request.mock.calls[1][1]).toEqual({ p_after: 5, p_through: null, p_limit: 100 });
  });

  it('skips a hidden prefix and middle, then finishes past a hidden tail without a phantom page', async () => {
    const value = new Reconciler(account);
    respond(emptyInitialBaseline, fixture.changes[0], fixture.changes[1]);
    await value.pull();
    expect(value.phase).toBe('ready'); expect(value.committed).toBe(5); expect(ids(value)).toEqual([arxiv, web]);
    expect(request.mock.calls.map(([, params]) => params)).toEqual([
      { p_cursor: null, p_limit: 100 }, { p_after: 0, p_through: null, p_limit: 100 }, { p_after: 2, p_through: 5, p_limit: 100 },
    ]);
    expect(fixture.changes[0].changes.map((batch: { seq: number }) => batch.seq)).toEqual([2]);
    expect(fixture.changes[1].changes.map((batch: { seq: number }) => batch.seq)).toEqual([4]);
  });

  it('finishes a short fixed boundary when only hidden work follows its last visible batch', async () => {
    const value = new Reconciler(account);
    respond(emptyInitialBaseline, fixture.changes[2]);
    await value.pull();
    expect(value.phase).toBe('ready'); expect(value.committed).toBe(3); expect(ids(value)).toEqual([arxiv]);
    expect(request).toHaveBeenCalledTimes(2);
  });

  it('accepts all-hidden completion and applies the visible member of a mixed removal group', async () => {
    const value = new Reconciler(account);
    respond(fixture.baselines[1], fixture.changes[3]);
    await value.pull();
    expect(fixture.changes[3].changes).toEqual([]); expect(value.committed).toBe(5);
    respond(fixture.changes[4]);
    await value.pull();
    expect(value.phase).toBe('ready'); expect(value.committed).toBe(6); expect(ids(value)).toEqual([arxiv, web]);
    expect(value.entries.get('import:' + arxiv)).toMatchObject({ visible: false, state_seq: 6 });
    expect(value.entries.get('import:' + web)).toMatchObject({ visible: true, state_seq: 4 });
    expect(fixture.changes[4].changes).toHaveLength(1); expect(fixture.changes[4].changes[0].entries).toHaveLength(1);
    expect(request).toHaveBeenCalledTimes(3);
  });

  it.each([false, true])('still rejects the reviewed raw-scan defect (empty page: %s)', async empty => {
    const value = new Reconciler(account), broken = structuredClone(fixture.changes[0]);
    if (empty) { broken.changes = []; broken.next_cursor = 1; } else broken.next_cursor = 3;
    respond(emptyInitialBaseline, broken);
    await expect(value.pull()).rejects.toThrow('cursor');
    expect(value.committed).toBe(0); expect(value.entries.size).toBe(0);
    expect(request).toHaveBeenCalledTimes(2);
  });
});
